import CryptoKit
import Foundation
import MangoReaderDomain
import Synchronization

enum ImportedOriginalCloudTransferFaultPoint: Sendable {
    case beforeCloudCommit
    case beforeLocalCommit
}

enum ImportedOriginalCloudInspection: Equatable, Sendable {
    case missing
    case valid
    case unavailable
    case invalid
}

struct ImportedOriginalCloudDirectories: Equatable, Sendable {
    var root: URL
    var app: URL
    var originals: URL
    var staging: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
        app = self.root.appendingPathComponent("manko", isDirectory: true)
        originals = app.appendingPathComponent("ImportedOriginals", isDirectory: true)
        staging = app.appendingPathComponent(".TransferStaging", isDirectory: true)
    }
}

final class ImportedOriginalCloudTransferToken: Sendable {
    let generation: UInt64
    private let isValid = Mutex(true)

    init(generation: UInt64) {
        self.generation = generation
    }

    func invalidate() {
        isValid.withLock { $0 = false }
    }

    func checkCancellation() throws {
        try Task.checkCancellation()
        guard isValid.withLock({ $0 }) else {
            throw CancellationError()
        }
    }
}

enum ImportedOriginalCloudMaterializationState: Equatable, Sendable {
    case missing
    case ready
    case pending
}

enum ImportedOriginalCloudMaterializationOutcome: Equatable, Sendable {
    case missing
    case ready
    case unavailable
}

struct ImportedOriginalCloudMaterializationEnvironment: Sendable {
    var state: @Sendable (
        URL,
        ImportedOriginalCloudTransferToken
    ) async throws -> ImportedOriginalCloudMaterializationState
    var startDownload: @Sendable (
        URL,
        ImportedOriginalCloudTransferToken
    ) async throws -> Void
    var pause: @Sendable () async throws -> Void
}

struct ImportedOriginalCloudMaterializer: Sendable {
    let maximumPollAttempts: Int
    let environment: ImportedOriginalCloudMaterializationEnvironment

    init(
        maximumPollAttempts: Int = 40,
        environment: ImportedOriginalCloudMaterializationEnvironment
    ) {
        self.maximumPollAttempts = max(1, maximumPollAttempts)
        self.environment = environment
    }

    func materialize(
        at url: URL,
        token: ImportedOriginalCloudTransferToken
    ) async throws -> ImportedOriginalCloudMaterializationOutcome {
        try token.checkCancellation()
        switch try await environment.state(url, token) {
        case .missing:
            try token.checkCancellation()
            return .missing
        case .ready:
            try token.checkCancellation()
            return .ready
        case .pending:
            break
        }

        try token.checkCancellation()
        try await environment.startDownload(url, token)
        try token.checkCancellation()

        for attempt in 0 ..< maximumPollAttempts {
            switch try await environment.state(url, token) {
            case .missing:
                try token.checkCancellation()
                return .missing
            case .ready:
                try token.checkCancellation()
                return .ready
            case .pending:
                break
            }
            try token.checkCancellation()
            guard attempt + 1 < maximumPollAttempts else {
                return .unavailable
            }
            try await environment.pause()
            try token.checkCancellation()
        }
        return .unavailable
    }
}

struct ImportedOriginalCloudStreamCopier: Sendable {
    let bufferSize: Int
    let didCopyChunk: @Sendable (Int) throws -> Void

    init(
        bufferSize: Int = 1_048_576,
        didCopyChunk: @escaping @Sendable (Int) throws -> Void = { _ in }
    ) {
        self.bufferSize = max(4_096, bufferSize)
        self.didCopyChunk = didCopyChunk
    }

    func copy(
        from sourceURL: URL,
        to destinationURL: URL,
        token: ImportedOriginalCloudTransferToken
    ) throws {
        try token.checkCancellation()
        let sourceValues = try sourceURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
            throw ImportedOriginalCloudSystemError.unavailable
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw ImportedOriginalCloudSystemError.unavailable
        }

        var completed = false
        defer {
            if !completed {
                try? fileManager.removeItem(at: destinationURL)
            }
        }

        let input = try FileHandle(forReadingFrom: sourceURL)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? input.close()
            try? output.close()
        }

        while true {
            try token.checkCancellation()
            guard let chunk = try input.read(upToCount: bufferSize), !chunk.isEmpty else {
                break
            }
            try output.write(contentsOf: chunk)
            try didCopyChunk(chunk.count)
            try token.checkCancellation()
        }
        try output.synchronize()
        try token.checkCancellation()
        completed = true
    }
}

struct ImportedOriginalCloudFileAccess: Sendable {
    var prepareDirectories: @Sendable (
        URL,
        ImportedOriginalCloudTransferToken
    ) async throws -> ImportedOriginalCloudDirectories
    var inspectCloudFile: @Sendable (
        URL,
        PublicationFormat,
        String,
        Int64,
        ImportedOriginalCloudTransferToken
    ) async throws -> ImportedOriginalCloudInspection
    var copyToCloudStaging: @Sendable (
        URL,
        URL,
        PublicationFormat,
        String,
        Int64,
        ImportedOriginalCloudTransferToken
    ) async throws -> Void
    var copyFromCloud: @Sendable (
        URL,
        URL,
        ImportedOriginalCloudTransferToken
    ) async throws -> Void
    var commitCloudMove: @Sendable (
        URL,
        URL,
        ImportedOriginalCloudTransferToken
    ) async throws -> Void
    var removeCloudItem: @Sendable (URL) async -> Void
    var metadataState: @Sendable (URL, ImportedOriginalCloudTransferToken) async throws -> ImportedOriginalCloudMaterializationState = { url, token in
        try await SystemImportedOriginalCloudFileAccess.materializationState(at: url, token: token)
    }

    static var system: Self {
        SystemImportedOriginalCloudFileAccess.make()
    }
}

private enum ImportedOriginalCloudSystemError: Error, Sendable {
    case unavailable
}

private enum ImportedOriginalCloudFileInspectionError: Error, Sendable {
    case unavailable
    case irregular
    case typeMismatch
    case digestMismatch
}

struct ImportedOriginalCloudFileInspection: Sendable {
    var byteCount: Int64
}

enum ImportedOriginalCloudFileInspector {
    @concurrent
    static func inspect(
        at url: URL,
        format: PublicationFormat,
        expectedDigest: String,
        token: ImportedOriginalCloudTransferToken? = nil
    ) async throws -> ImportedOriginalCloudFileInspection {
        try inspectSynchronously(
            at: url,
            format: format,
            expectedDigest: expectedDigest,
            token: token
        )
    }

    static func inspectSynchronously(
        at url: URL,
        format: PublicationFormat,
        expectedDigest: String,
        token: ImportedOriginalCloudTransferToken? = nil
    ) throws -> ImportedOriginalCloudFileInspection {
        try token?.checkCancellation()
        try Task.checkCancellation()

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
            ])
        } catch {
            throw ImportedOriginalCloudFileInspectionError.unavailable
        }
        if values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current
        {
            throw ImportedOriginalCloudFileInspectionError.unavailable
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ImportedOriginalCloudFileInspectionError.irregular
        }
        let byteCount = Int64(values.fileSize ?? 0)
        guard byteCount > 0 else {
            throw ImportedOriginalCloudFileInspectionError.irregular
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ImportedOriginalCloudFileInspectionError.unavailable
        }
        defer { try? handle.close() }

        let header: Data
        do {
            header = try handle.read(upToCount: 8) ?? Data()
        } catch {
            throw ImportedOriginalCloudFileInspectionError.unavailable
        }
        switch format {
        case .pdf:
            guard header.starts(with: Data("%PDF-".utf8)) else {
                throw ImportedOriginalCloudFileInspectionError.typeMismatch
            }
        case .epub, .cbz:
            let signatures = [
                Data([0x50, 0x4B, 0x03, 0x04]),
                Data([0x50, 0x4B, 0x05, 0x06]),
                Data([0x50, 0x4B, 0x07, 0x08]),
            ]
            guard signatures.contains(where: header.starts(with:)) else {
                throw ImportedOriginalCloudFileInspectionError.typeMismatch
            }
        case .remoteImageSequence:
            throw ImportedOriginalCloudFileInspectionError.typeMismatch
        }

        do {
            try handle.seek(toOffset: 0)
        } catch {
            throw ImportedOriginalCloudFileInspectionError.unavailable
        }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try token?.checkCancellation()
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ImportedOriginalCloudFileInspectionError.unavailable
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedDigest else {
            throw ImportedOriginalCloudFileInspectionError.digestMismatch
        }
        return ImportedOriginalCloudFileInspection(byteCount: byteCount)
    }
}

private enum SystemImportedOriginalCloudFileAccess {
    private static let streamCopier = ImportedOriginalCloudStreamCopier()

    static func make() -> ImportedOriginalCloudFileAccess {
        let materializer = ImportedOriginalCloudMaterializer(
            environment: ImportedOriginalCloudMaterializationEnvironment(
                state: { url, token in
                    try await materializationState(at: url, token: token)
                },
                startDownload: { url, token in
                    try await requestUbiquitousDownload(at: url, token: token)
                },
                pause: {
                    try await Task.sleep(for: .milliseconds(250))
                }
            )
        )
        return ImportedOriginalCloudFileAccess(
            prepareDirectories: { root, token in
                try await prepareDirectories(at: root, token: token)
            },
            inspectCloudFile: { url, format, digest, byteCount, token in
                try await inspectCloudFile(
                    at: url,
                    format: format,
                    expectedDigest: digest,
                    expectedByteCount: byteCount,
                    token: token,
                    materializer: materializer
                )
            },
            copyToCloudStaging: { source, destination, format, digest, byteCount, token in
                try await copyToCloudStaging(
                    from: source,
                    to: destination,
                    format: format,
                    expectedDigest: digest,
                    expectedByteCount: byteCount,
                    token: token
                )
            },
            copyFromCloud: { source, destination, token in
                try await copyFromCloud(
                    from: source,
                    to: destination,
                    token: token,
                    materializer: materializer
                )
            },
            commitCloudMove: { source, destination, token in
                try await commitCloudMove(from: source, to: destination, token: token)
            },
            removeCloudItem: { url in
                await removeCloudItem(at: url)
            }
        )
    }

    @concurrent
    private static func prepareDirectories(
        at root: URL,
        token: ImportedOriginalCloudTransferToken
    ) async throws -> ImportedOriginalCloudDirectories {
        try token.checkCancellation()
        return try await coordinateWriting(at: root, options: []) { coordinatedRoot in
            try token.checkCancellation()
            let directories = ImportedOriginalCloudDirectories(root: coordinatedRoot)
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: directories.root,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: directories.originals,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: directories.staging,
                withIntermediateDirectories: true
            )
            guard
                isSafeDirectory(directories.root),
                isSafeDirectory(directories.app),
                isSafeDirectory(directories.originals),
                isSafeDirectory(directories.staging)
            else {
                throw ImportedOriginalCloudSystemError.unavailable
            }
            try token.checkCancellation()
            return directories
        }
    }

    private static func inspectCloudFile(
        at url: URL,
        format: PublicationFormat,
        expectedDigest: String,
        expectedByteCount: Int64,
        token: ImportedOriginalCloudTransferToken,
        materializer: ImportedOriginalCloudMaterializer
    ) async throws -> ImportedOriginalCloudInspection {
        let outcome = try await materializer.materialize(at: url, token: token)
        switch outcome {
        case .missing:
            return .missing
        case .unavailable:
            return .unavailable
        case .ready:
            break
        }

        do {
            let inspection = try await coordinateReading(at: url, options: []) { coordinatedURL in
                try ImportedOriginalCloudFileInspector.inspectSynchronously(
                    at: coordinatedURL,
                    format: format,
                    expectedDigest: expectedDigest,
                    token: token
                )
            }
            try token.checkCancellation()
            return inspection.byteCount == expectedByteCount ? .valid : .invalid
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ImportedOriginalCloudFileInspectionError {
            switch error {
            case .unavailable:
                return .unavailable
            case .irregular, .typeMismatch, .digestMismatch:
                return .invalid
            }
        } catch {
            return .unavailable
        }
    }

    @concurrent
    private static func copyToCloudStaging(
        from sourceURL: URL,
        to destinationURL: URL,
        format: PublicationFormat,
        expectedDigest: String,
        expectedByteCount: Int64,
        token: ImportedOriginalCloudTransferToken
    ) async throws {
        try token.checkCancellation()
        let inspection = try await coordinateWriting(
            at: destinationURL,
            options: .forReplacing
        ) { coordinatedDestination in
            try token.checkCancellation()
            try streamCopier.copy(
                from: sourceURL,
                to: coordinatedDestination,
                token: token
            )
            return try ImportedOriginalCloudFileInspector.inspectSynchronously(
                at: coordinatedDestination,
                format: format,
                expectedDigest: expectedDigest,
                token: token
            )
        }
        guard inspection.byteCount == expectedByteCount else {
            throw ImportedOriginalCloudSystemError.unavailable
        }
        try token.checkCancellation()
    }

    private static func copyFromCloud(
        from sourceURL: URL,
        to destinationURL: URL,
        token: ImportedOriginalCloudTransferToken,
        materializer: ImportedOriginalCloudMaterializer
    ) async throws {
        guard try await materializer.materialize(at: sourceURL, token: token) == .ready else {
            throw ImportedOriginalCloudSystemError.unavailable
        }
        try await coordinateReading(at: sourceURL, options: []) { coordinatedSource in
            try streamCopier.copy(
                from: coordinatedSource,
                to: destinationURL,
                token: token
            )
        }
        try token.checkCancellation()
    }

    @concurrent
    private static func commitCloudMove(
        from sourceURL: URL,
        to destinationURL: URL,
        token: ImportedOriginalCloudTransferToken
    ) async throws {
        try token.checkCancellation()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationResult: Result<Void, Error>?
        coordinator.coordinate(
            writingItemAt: sourceURL,
            options: .forMoving,
            writingItemAt: destinationURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            operationResult = Result {
                try token.checkCancellation()
                coordinator.item(at: coordinatedSource, willMoveTo: coordinatedDestination)
                try FileManager.default.moveItem(
                    at: coordinatedSource,
                    to: coordinatedDestination
                )
                coordinator.item(at: coordinatedSource, didMoveTo: coordinatedDestination)
                try token.checkCancellation()
            }
        }
        if let operationResult {
            try operationResult.get()
        } else if let coordinationError {
            throw coordinationError
        } else {
            throw ImportedOriginalCloudSystemError.unavailable
        }
        try token.checkCancellation()
    }

    @concurrent
    private static func removeCloudItem(at url: URL) async {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                try? FileManager.default.removeItem(at: coordinatedURL)
            }
        }
        _ = coordinationError
    }

    fileprivate static func materializationState(
        at url: URL,
        token: ImportedOriginalCloudTransferToken
    ) async throws -> ImportedOriginalCloudMaterializationState {
        try token.checkCancellation()
        return try await coordinateReading(
            at: url,
            options: .immediatelyAvailableMetadataOnly
        ) { coordinatedURL -> ImportedOriginalCloudMaterializationState in
            try token.checkCancellation()
            let values = try? coordinatedURL.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
            ])
            try token.checkCancellation()
            if values?.isUbiquitousItem == true {
                return values?.ubiquitousItemDownloadingStatus == .current ? .ready : .pending
            }
            return FileManager.default.fileExists(atPath: coordinatedURL.path) ? .ready : .missing
        }
    }

    private static func requestUbiquitousDownload(
        at url: URL,
        token: ImportedOriginalCloudTransferToken
    ) async throws {
        try token.checkCancellation()
        try await coordinateReading(
            at: url,
            options: .immediatelyAvailableMetadataOnly
        ) { coordinatedURL in
            try token.checkCancellation()
            try FileManager.default.startDownloadingUbiquitousItem(at: coordinatedURL)
            try token.checkCancellation()
        }
    }

    @concurrent
    private static func coordinateReading<T: Sendable>(
        at url: URL,
        options: NSFileCoordinator.ReadingOptions,
        operation: @Sendable (URL) throws -> T
    ) async throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationResult: Result<T, Error>?
        coordinator.coordinate(
            readingItemAt: url,
            options: options,
            error: &coordinationError
        ) { coordinatedURL in
            operationResult = Result {
                try operation(coordinatedURL)
            }
        }
        if let operationResult {
            return try operationResult.get()
        }
        if let coordinationError {
            throw coordinationError
        }
        throw ImportedOriginalCloudSystemError.unavailable
    }

    @concurrent
    private static func coordinateWriting<T: Sendable>(
        at url: URL,
        options: NSFileCoordinator.WritingOptions,
        operation: @Sendable (URL) throws -> T
    ) async throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationResult: Result<T, Error>?
        coordinator.coordinate(
            writingItemAt: url,
            options: options,
            error: &coordinationError
        ) { coordinatedURL in
            operationResult = Result {
                try operation(coordinatedURL)
            }
        }
        if let operationResult {
            return try operationResult.get()
        }
        if let coordinationError {
            throw coordinationError
        }
        throw ImportedOriginalCloudSystemError.unavailable
    }

    private static func isSafeDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}
