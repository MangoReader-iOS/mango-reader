import Foundation
import MankoDomain
import Observation

public enum ReaderChapterDirection: String, Hashable, Sendable {
    case previous, next
    public var isForward: Bool { self == .next }
}

public enum ReaderChapterBoundaryState: Equatable, Sendable {
    case loading(Installment?)
    case available(Installment)
    case absent
    case failed(String, Installment?)

    public var neighbor: Installment? {
        switch self {
        case let .loading(chapter), let .failed(_, chapter): chapter
        case let .available(chapter): chapter
        case .absent: nil
        }
    }
}

/// Cached chapters remain useful while the source confirms the catalogue's ends.
@MainActor @Observable
public final class ReaderChapterCatalog {
    public private(set) var chapters: [Installment]
    public private(set) var isComplete: Bool
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    @ObservationIgnored private let load: @MainActor () async throws -> [Installment]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var neighbors: [NeighborKey: NeighborResolution] = [:]

    private struct NeighborKey: Hashable {
        let chapterID: InstallmentID
        let direction: ReaderChapterDirection
        let skipDuplicates: Bool
    }

    private struct NeighborResolution {
        let chapter: Installment
        let neighbor: Installment?
        let containsChapter: Bool
    }

    public init(chapters: [Installment], isComplete: Bool,
                load: @escaping @MainActor () async throws -> [Installment]) {
        self.chapters = Self.unique(chapters)
        self.isComplete = isComplete
        self.load = load
    }

    public func boundary(from chapter: Installment, direction: ReaderChapterDirection, skipDuplicates: Bool) -> ReaderChapterBoundaryState {
        // Keep the observable read even on a cache hit: a catalog replacement
        // must invalidate readers, but scrolling must not repeatedly sort it.
        let chapters = self.chapters
        let key = NeighborKey(chapterID: chapter.id, direction: direction, skipDuplicates: skipDuplicates)
        let resolution: NeighborResolution
        if let cached = neighbors[key], cached.chapter == chapter {
            resolution = cached
        } else {
            resolution = NeighborResolution(chapter: chapter,
                neighbor: ReaderChapterPolicy.adjacent(to: chapter, in: chapters,
                    forward: direction.isForward, skipDuplicates: skipDuplicates),
                containsChapter: chapters.contains { $0.id == chapter.id })
            neighbors[key] = resolution
        }
        if let neighbor = resolution.neighbor { return .available(neighbor) }
        if isLoading { return .loading(nil) }
        if let errorMessage { return .failed(errorMessage, nil) }
        guard isComplete else { return .loading(nil) }
        guard resolution.containsChapter else {
            return .failed("This chapter is no longer in the source’s chapter list. Choose a chapter from the list or retry.", nil)
        }
        return .absent
    }

    public func refreshIfNeeded() async {
        guard !isComplete, errorMessage == nil else { return }
        await refresh()
    }

    public func refresh() async {
        if let task { await task.value; return }
        let token = UUID(); generation = token
        isLoading = true; errorMessage = nil
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == token { task = nil; isLoading = false } }
            do {
                let chapters = try await load()
                guard generation == token, !Task.isCancelled else { return }
                neighbors.removeAll()
                self.chapters = Self.unique(chapters)
                isComplete = true
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
        task = operation
        await operation.value
    }

    public func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isLoading = false
    }

    private static func unique(_ chapters: [Installment]) -> [Installment] {
        var seen: Set<InstallmentID> = []
        return chapters.filter { seen.insert($0.id).inserted }
    }
}
