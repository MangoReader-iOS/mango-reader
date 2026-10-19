import Foundation

public enum StoragePathsError: Error, Equatable, Sendable, LocalizedError {
    case applicationSupportUnavailable
    case cachesUnavailable
    case unableToCreateDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "The Application Support directory is unavailable."
        case .cachesUnavailable:
            "The caches directory is unavailable."
        case let .unableToCreateDirectory(path):
            "Manko could not create its storage directory at \(path)."
        }
    }
}

/// Stable locations for persistent, re-downloadable, and temporary data.
public struct StoragePaths: Hashable, Sendable {
    public let isPrivate: Bool
    public let applicationSupportDirectory: URL
    public let databaseURL: URL
    public let libraryFilesDirectory: URL
    public let customCoversDirectory: URL
    public let offlineDownloadsDirectory: URL
    public let sourceRepositoriesDirectory: URL
    public let sourceExtensionsDirectory: URL
    public let sourceExtensionStateDirectory: URL
    public let cachesDirectory: URL
    public let backupStagingDirectory: URL

    public init(applicationSupportDirectory: URL, cachesDirectory: URL, isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        self.applicationSupportDirectory = applicationSupportDirectory
        self.databaseURL = applicationSupportDirectory.appending(path: "manko.sqlite", directoryHint: .notDirectory)
        self.libraryFilesDirectory = applicationSupportDirectory.appending(path: "LibraryFiles", directoryHint: .isDirectory)
        self.customCoversDirectory = applicationSupportDirectory.appending(path: "CustomCovers", directoryHint: .isDirectory)
        self.offlineDownloadsDirectory = applicationSupportDirectory.appending(path: "OfflineDownloads", directoryHint: .isDirectory)
        self.sourceRepositoriesDirectory = applicationSupportDirectory.appending(path: "SourceRepositories", directoryHint: .isDirectory)
        self.sourceExtensionsDirectory = applicationSupportDirectory.appending(path: "SourceExtensions", directoryHint: .isDirectory)
        self.sourceExtensionStateDirectory = applicationSupportDirectory.appending(path: "SourceExtensionState", directoryHint: .isDirectory)
        self.cachesDirectory = cachesDirectory
        self.backupStagingDirectory = cachesDirectory.appending(path: "BackupStaging", directoryHint: .isDirectory)
    }

    public static func applicationSupport(
        bundleIdentifier: String = "com.k800k.manko"
    ) throws -> Self {
        let fileManager = FileManager.default
        guard let applicationSupportRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw StoragePathsError.applicationSupportUnavailable
        }
        guard let cachesRoot = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw StoragePathsError.cachesUnavailable
        }

        return Self(
            applicationSupportDirectory: applicationSupportRoot.appending(
                path: bundleIdentifier,
                directoryHint: .isDirectory
            ),
            cachesDirectory: cachesRoot.appending(
                path: bundleIdentifier,
                directoryHint: .isDirectory
            )
        )
    }

    /// Creates all directories and applies the storage policy to them.
    public func prepare() throws {
        let fileManager = FileManager.default
        let directories = [
            applicationSupportDirectory,
            libraryFilesDirectory,
            customCoversDirectory,
            offlineDownloadsDirectory,
            sourceRepositoriesDirectory,
            sourceExtensionsDirectory,
            sourceExtensionStateDirectory,
            cachesDirectory,
            backupStagingDirectory,
        ]

        for directory in directories {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                if isPrivate { try applyProtection(to: directory) }
            } catch {
                throw StoragePathsError.unableToCreateDirectory(directory.path)
            }
        }

        try applyProtection(to: applicationSupportDirectory)
        try applyProtection(to: libraryFilesDirectory)
        try applyProtection(to: customCoversDirectory)
        try applyProtection(to: offlineDownloadsDirectory)
        try applyProtection(to: sourceRepositoriesDirectory)
        try applyProtection(to: sourceExtensionsDirectory)
        try applyProtection(to: sourceExtensionStateDirectory)
        if isPrivate { try Self.excludeFromBackup(applicationSupportDirectory) }
        try Self.excludeFromBackup(offlineDownloadsDirectory)
        try Self.excludeFromBackup(sourceExtensionsDirectory)
        try Self.excludeFromBackup(sourceExtensionStateDirectory)
        try Self.excludeFromBackup(cachesDirectory)
        try Self.excludeFromBackup(backupStagingDirectory)
    }

    /// Private files inherit Complete Protection; copied files need it reapplied.
    public func applyProtection(to url: URL) throws {
        #if os(iOS) || os(tvOS) || os(watchOS)
        try FileManager.default.setAttributes(
            [.protectionKey: isPrivate ? FileProtectionType.complete : .completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    static func applyStandardProtection(to url: URL) throws {
        #if os(iOS) || os(tvOS) || os(watchOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #else
        _ = url
        #endif
    }

    static func excludeFromBackup(_ url: URL) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
    }
}
