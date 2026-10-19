import Foundation
import MankoDomain

public enum CompletedCBZExportError: Error, Hashable, Sendable, LocalizedError {
    case invalidState(DownloadState)
    case unsupportedFormat(PublicationFormat?)
    case missingManagedPath
    case unsafeManagedPath(String)
    case invalidDestination(String)
    case destinationIsManagedFile
    case invalidPublication(DownloadValidationError)
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidState(state):
            "Only a completed download can be exported, not \(state.rawValue)."
        case let .unsupportedFormat(format):
            format.map { "Only completed CBZ/ZIP downloads can be exported, not \($0.rawValue)." }
                ?? "Only a download explicitly identified as CBZ/ZIP can be exported."
        case .missingManagedPath:
            "The completed download has no managed offline file."
        case let .unsafeManagedPath(path):
            "The managed download path is unsafe: \(path)"
        case let .invalidDestination(message):
            "The export destination is invalid: \(message)"
        case .destinationIsManagedFile:
            "The export destination must not replace Manko's managed download."
        case let .invalidPublication(error):
            "The managed comic archive is invalid: \(error.localizedDescription)"
        case let .storage(message):
            "The comic archive could not be exported: \(message)"
        }
    }
}

/// Copies a completed, validated comic archive out of OfflineDownloads without
/// mutating the managed publication. The destination is supplied by the caller
/// (normally a security-scoped export URL) and replaced with a sibling rename.
public struct CompletedCBZExportService: Sendable {
    private let validator: DownloadedPublicationValidator

    public init(validationLimits: DownloadValidationLimits = .publication) {
        validator = DownloadedPublicationValidator(limits: validationLimits)
    }

    @concurrent
    @discardableResult
    public func export(
        _ snapshot: DownloadSnapshot,
        offlineDownloadsRoot: URL,
        to destination: URL
    ) async throws -> URL {
        guard snapshot.state == .completed else {
            throw CompletedCBZExportError.invalidState(snapshot.state)
        }
        switch snapshot.transfer.expectedFormat {
        case .cbz, .remoteImageSequence:
            break
        case let format:
            throw CompletedCBZExportError.unsupportedFormat(format)
        }
        guard let relativePath = snapshot.localRelativePath, !relativePath.isEmpty else {
            throw CompletedCBZExportError.missingManagedPath
        }

        let fileManager = FileManager.default
        let managedFile = try managedFileURL(
            relativePath: relativePath,
            root: offlineDownloadsRoot,
            fileManager: fileManager
        )
        let destinationURL = destination.standardizedFileURL
        guard destinationURL.isFileURL else {
            throw CompletedCBZExportError.invalidDestination("A local file URL is required.")
        }
        let resolvedDestination = destinationURL.resolvingSymlinksInPath()
        guard resolvedDestination != managedFile else {
            throw CompletedCBZExportError.destinationIsManagedFile
        }

        var destinationIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &destinationIsDirectory),
           destinationIsDirectory.boolValue {
            throw CompletedCBZExportError.invalidDestination("The selected location is a directory.")
        }
        let parentDirectory = destinationURL.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parentDirectory.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue
        else {
            throw CompletedCBZExportError.invalidDestination("The parent directory does not exist.")
        }

        do {
            _ = try await validator.validate(managedFile, expectedFormat: .cbz)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DownloadValidationError {
            throw CompletedCBZExportError.invalidPublication(error)
        }
        try Task.checkCancellation()

        let temporaryURL = parentDirectory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).manko-export",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        do {
            try fileManager.copyItem(at: managedFile, to: temporaryURL)
            do {
                _ = try await validator.validate(temporaryURL, expectedFormat: .cbz)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DownloadValidationError {
                throw CompletedCBZExportError.invalidPublication(error)
            }
            try Task.checkCancellation()

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
            return destinationURL
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CompletedCBZExportError {
            throw error
        } catch {
            throw CompletedCBZExportError.storage(error.localizedDescription)
        }
    }

    private func managedFileURL(
        relativePath: String,
        root: URL,
        fileManager: FileManager
    ) throws -> URL {
        guard root.isFileURL else {
            throw CompletedCBZExportError.unsafeManagedPath(relativePath)
        }
        let pathComponents = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard
            !(relativePath as NSString).isAbsolutePath,
            !relativePath.contains("\\"),
            !pathComponents.isEmpty,
            !pathComponents.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw CompletedCBZExportError.unsafeManagedPath(relativePath)
        }

        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedRoot.path, isDirectory: &rootIsDirectory),
              rootIsDirectory.boolValue
        else {
            throw CompletedCBZExportError.unsafeManagedPath(relativePath)
        }

        let candidate = resolvedRoot
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootComponents = resolvedRoot.pathComponents
        let candidateComponents = candidate.pathComponents
        guard
            candidateComponents.count > rootComponents.count,
            Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw CompletedCBZExportError.unsafeManagedPath(relativePath)
        }
        return candidate
    }
}
