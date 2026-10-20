import Foundation
import MangoReaderDomain
import Observation
import OSLog

/// One reader owns one cancellable transfer. Retries replay validated blocks,
/// checking the existing prefix instead of appending duplicate text.
@MainActor @Observable
public final class ProgressivePublicationSession {
    public typealias Delivery = @Sendable ([ProgressivePublicationBlock], Bool) async throws -> Void
    public typealias Loader = @Sendable (@escaping Delivery) async throws -> Void
    public private(set) var blocks: [ProgressivePublicationBlock] = []
    @ObservationIgnored public private(set) var textOffsets: [Int] = []
    public var textLength: Int { (textOffsets.last ?? 0) + (blocks.last?.text.utf16.count ?? 0) }
    public var positionCount: Int { complete ? max(1, (textLength + 1_023) / 1_024) : 0 }
    public func position(index: Int, fraction: Double) -> Int {
        guard blocks.indices.contains(index) else { return 0 }
        let position = (textOffsets[index] + Int(fraction * Double(blocks[index].text.utf16.count))) / 1_024
        return complete ? min(max(0, positionCount - 1), position) : position
    }
    public private(set) var complete = false
    public private(set) var failure: String?
    public private(set) var revision = 0
    public private(set) var firstTextUptime: TimeInterval?
    public private(set) var completedUptime: TimeInterval?
    public private(set) var legacySections: GeneratedPublicationSections?
    public private(set) var legacyLoading = false
    @ObservationIgnored private let legacyLoader: (@Sendable () async throws -> GeneratedPublicationSections?)?
    public let workID: String
    public let volumeID: String
    public let isPrivate: Bool
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    public init(workID: String, volumeID: String, isPrivate: Bool = false, legacyLoader: (@Sendable () async throws -> GeneratedPublicationSections?)? = nil, loader: @escaping Loader) {
        self.workID = workID; self.volumeID = volumeID; self.isPrivate = isPrivate; self.loader = loader; self.legacyLoader = legacyLoader
    }
    public func start() {
        guard task == nil, !complete else { return }
        failure = nil
        let generation = UUID(); self.generation = generation
        task = Task { [weak self] in
            guard let self else { return }
            legacyLoading = legacyLoader != nil
            let legacyTask = Task { [weak self] in
                guard let self, let legacyLoader else { return }
                let metadata = try? await legacyLoader()
                guard !Task.isCancelled, self.generation == generation else { return }
                legacySections = metadata; legacyLoading = false; revision += 1
            }
            defer {
                legacyTask.cancel()
                if self.generation == generation { task = nil; legacyLoading = false }
            }
            do {
                try await loader { [weak self] incoming, complete in
                    guard let self else { throw CancellationError() }
                    try await self.receive(incoming, complete: complete)
                }
                try Task.checkCancellation()
                await legacyTask.value
                guard complete else { throw SessionFailure.incomplete }
            } catch {
                if !Task.isCancelled, self.generation == generation { failure = error.localizedDescription; revision += 1 }
            }
        }
    }
    public func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        if isPrivate { blocks.removeAll(); textOffsets.removeAll(); complete = false; failure = nil; legacySections = nil; legacyLoading = false; revision += 1 }
    }
    public func retry() { guard task == nil else { return }; start() }
    public func snapshot() -> ProgressivePublicationSnapshot {
        .init(workID: workID, volumeID: volumeID, blocks: blocks, complete: complete)
    }
    private func receive(_ incoming: [ProgressivePublicationBlock], complete: Bool) throws {
        try Task.checkCancellation()
        for block in incoming {
            guard block.index >= 0 else { throw SessionFailure.incomplete }
            if block.index < blocks.count {
                guard blocks[block.index] == block else { throw SessionFailure.changed }
            } else {
                guard block.index == blocks.count else { throw SessionFailure.incomplete }
                textOffsets.append(textLength)
                blocks.append(block)
            }
        }
        if !blocks.isEmpty, firstTextUptime == nil {
            firstTextUptime = ProcessInfo.processInfo.systemUptime
            Logger(subsystem: "com.k800k.manko", category: "ReaderOpening").debug("LNORI first validated text at \(self.firstTextUptime!, privacy: .public)")
        }
        if complete {
            guard !blocks.isEmpty else { throw SessionFailure.incomplete }
            guard incoming.last?.index == blocks.count - 1 else { throw SessionFailure.changed }
            self.complete = true; completedUptime = ProcessInfo.processInfo.systemUptime
        }
        revision += 1
    }
    private enum SessionFailure: Error, LocalizedError {
        case changed, incomplete
        var errorDescription: String? {
            switch self {
            case .changed: "This volume changed while loading. Reopen it to load the updated text."
            case .incomplete: "The volume did not finish loading. Retry to continue reading."
            }
        }
    }
}
