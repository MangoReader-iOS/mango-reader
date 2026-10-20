import Foundation
import MangoReaderDomain
import Observation

@MainActor @Observable
final class WorkDetailReaderPreparation {
    private(set) var isPreparing = false
    private(set) var workID: WorkID?
    private(set) var installmentID: InstallmentID?
    private var gate = LatestOperationGate()
    private var task: Task<Void, Never>?

    @discardableResult
    func start(
        workID: WorkID? = nil,
        installmentID: InstallmentID?,
        prepare: @escaping @MainActor () async -> PreparedReaderContent?,
        present: @escaping @MainActor (PreparedReaderContent) -> Void
    ) -> Task<Void, Never> {
        if let workID, isPreparing, self.workID == workID,
           self.installmentID == installmentID, let task { return task }
        cancel()
        let generation = gate.begin()
        self.workID = workID
        self.installmentID = installmentID
        isPreparing = true
        let operation = Task { [weak self] in
            let prepared = await prepare()
            guard let self, !Task.isCancelled, gate.accepts(generation) else { return }
            isPreparing = false
            self.workID = nil
            self.installmentID = nil
            task = nil
            if let prepared { present(prepared) }
        }
        task = operation
        return operation
    }

    func cancel() {
        gate.invalidate()
        task?.cancel()
        task = nil
        isPreparing = false
        workID = nil
        installmentID = nil
    }
}

/// Owned by the presented reader, rather than the screen that launched it.
/// The generation also fences loaders that don't promptly honor cancellation.
@MainActor @Observable
final class ReaderOpeningState {
    private(set) var content: PreparedReaderContent?
    private(set) var failure: String?
    private(set) var attempt = UUID()
    private var generation: UUID?
    private var privatePublications: Set<URL> = []

    init(prepared: PreparedReaderContent? = nil) {
        content = prepared
        if let url = prepared?.temporaryPublicationURL { privatePublications.insert(url) }
    }

    func load(_ operation: @MainActor () async throws -> PreparedReaderContent) async {
        guard content == nil else { return }
        let id = attempt
        generation = id
        failure = nil
        do {
            let prepared = try await operation()
            guard !Task.isCancelled, generation == id else {
                Self.removePrivatePublication(prepared.temporaryPublicationURL)
                return
            }
            replace(prepared)
        } catch is CancellationError {
            guard !Task.isCancelled, generation == id else { return }
            failure = "Opening was interrupted. Retry to use the current source settings."
        }
        catch {
            guard !Task.isCancelled, generation == id else { return }
            failure = error.localizedDescription
        }
    }

    func replace(_ prepared: PreparedReaderContent) {
        content = prepared
        if let url = prepared.temporaryPublicationURL { privatePublications.insert(url) }
    }

    func retry() { generation = nil; failure = nil; attempt = UUID() }
    func cancel() {
        generation = nil
        for url in privatePublications { Self.removePrivatePublication(url) }
        privatePublications.removeAll()
    }

    static func removePrivatePublication(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
