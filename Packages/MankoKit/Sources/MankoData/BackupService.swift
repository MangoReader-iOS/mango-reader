import CryptoKit
import Foundation
import ReadiumZIPFoundation

public struct BackupManifest: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 2
    public static let currentDatabaseSchemaVersion = 8

    public let formatVersion: Int
    public let databaseSchemaVersion: Int
    public let createdAt: Date
    public let appIdentifier: String
    public let includesLibraryFiles: Bool
    public let payloadSHA256: String
    public let settingsSHA256: String?
    public let recordCounts: [String: Int]
    public let includedGroups: Set<BackupRestoreGroup>?

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        databaseSchemaVersion: Int = Self.currentDatabaseSchemaVersion,
        createdAt: Date = .now,
        appIdentifier: String = "com.k800k.manko",
        includesLibraryFiles: Bool,
        payloadSHA256: String,
        settingsSHA256: String? = nil,
        recordCounts: [String: Int],
        includedGroups: Set<BackupRestoreGroup>? = nil
    ) {
        self.formatVersion = formatVersion
        self.databaseSchemaVersion = databaseSchemaVersion
        self.createdAt = createdAt
        self.appIdentifier = appIdentifier
        self.includesLibraryFiles = includesLibraryFiles
        self.payloadSHA256 = payloadSHA256
        self.settingsSHA256 = settingsSHA256
        self.recordCounts = recordCounts
        self.includedGroups = includedGroups ?? (formatVersion >= 2 ? Set(BackupRestoreGroup.allCases)
            .subtracting(includesLibraryFiles ? [] : [.importedMedia])
            .subtracting(settingsSHA256 == nil ? [.settings, .extensions, .servers, .readerPreferences] : []) : nil)
    }
}

/// User-selectable logical sections of a backup. Reader state and other child
/// records require the library identities they reference, while settings are
/// independent and imported media is coupled to its local title metadata.
public enum BackupRestoreGroup: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case library
    case readingActivity
    case organization
    case bookmarksAndAnnotations
    case downloadMetadata
    case settings
    case extensions
    case servers
    case readerPreferences
    case importedMedia

    public var id: Self { self }

    public var requiredGroups: Set<Self> {
        switch self {
        case .readingActivity, .organization, .bookmarksAndAnnotations, .downloadMetadata,
             .importedMedia:
            [.library]
        case .library, .settings, .extensions, .servers, .readerPreferences:
            []
        }
    }

    public func isAvailable(in manifest: BackupManifest) -> Bool {
        if let groups = manifest.includedGroups { return groups.contains(self) }
        switch self {
        case .settings, .extensions, .servers, .readerPreferences:
            return manifest.settingsSHA256 != nil
        case .importedMedia:
            return manifest.includesLibraryFiles
        case .library, .readingActivity, .organization, .bookmarksAndAnnotations,
             .downloadMetadata:
            return true
        }
    }

    public func recordCount(in manifest: BackupManifest) -> Int {
        let keys: [String]
        switch self {
        case .library:
            keys = ["works", "installments", "libraryEntries", "importedOriginalReferences"]
        case .readingActivity:
            keys = ["readingProgress", "readingSessions"]
        case .organization:
            keys = ["categories", "categoryMemberships", "savedFilters"]
        case .bookmarksAndAnnotations:
            keys = ["bookmarks", "annotations", "userTitleStates"]
        case .downloadMetadata:
            keys = ["downloads"]
        case .settings, .extensions, .servers, .readerPreferences:
            return isAvailable(in: manifest) ? 1 : 0
        case .importedMedia:
            return manifest.includesLibraryFiles ? 1 : 0
        }
        return keys.reduce(into: 0) { count, key in
            count += manifest.recordCounts[key, default: 0]
        }
    }
}

/// A dependency-safe selection for a staged restore.
///
/// Enabling a child group automatically includes its requirements. Disabling
/// a requirement removes all of its dependents, so a caller cannot request
/// orphaned progress, annotations, categories, or transfer records.
public struct BackupRestoreSelection: Codable, Hashable, Sendable {
    public private(set) var groups: Set<BackupRestoreGroup>

    public init(groups: Set<BackupRestoreGroup> = []) {
        self.groups = Self.addingRequirements(to: groups)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(groups: try container.decode(Set<BackupRestoreGroup>.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(groups)
    }

    public static func allAvailable(in manifest: BackupManifest) -> Self {
        Self(groups: Set(BackupRestoreGroup.allCases.filter { $0.isAvailable(in: manifest) }))
            .normalized(for: manifest)
    }

    public static var exportDefault: Self {
        Self(groups: Set(BackupRestoreGroup.allCases).subtracting([.importedMedia]))
    }

    public var includesSetup: Bool { !groups.isDisjoint(with: [.settings, .extensions, .servers, .readerPreferences]) }
    public var includesPersonalData: Bool { restoresDatabaseRecords || contains(.servers) || contains(.importedMedia) }
    public var isEmpty: Bool { groups.isEmpty }

    public var restoresDatabaseRecords: Bool {
        !groups.isDisjoint(with: Self.databaseGroups)
    }

    public func contains(_ group: BackupRestoreGroup) -> Bool {
        groups.contains(group)
    }

    public mutating func set(_ group: BackupRestoreGroup, isEnabled: Bool) {
        if isEnabled {
            groups.insert(group)
            groups = Self.addingRequirements(to: groups)
        } else {
            groups.remove(group)
            groups = Set(groups.filter { candidate in
                !Self.transitiveRequirements(of: candidate).contains(group)
            })
        }
    }

    public func normalized(for manifest: BackupManifest) -> Self {
        let available = Set(BackupRestoreGroup.allCases.filter { $0.isAvailable(in: manifest) })
        let permitted = groups.intersection(available).filter { $0.requiredGroups.isSubset(of: available) }
        return Self(groups: Set(permitted))
    }

    static let databaseGroups: Set<BackupRestoreGroup> = [
        .library,
        .readingActivity,
        .organization,
        .bookmarksAndAnnotations,
        .downloadMetadata,
    ]

    private static func addingRequirements(
        to initial: Set<BackupRestoreGroup>
    ) -> Set<BackupRestoreGroup> {
        var result = initial
        var pending = Array(initial)
        while let group = pending.popLast() {
            for requirement in group.requiredGroups where result.insert(requirement).inserted {
                pending.append(requirement)
            }
        }
        return result
    }

    private static func transitiveRequirements(
        of group: BackupRestoreGroup
    ) -> Set<BackupRestoreGroup> {
        addingRequirements(to: [group]).subtracting([group])
    }
}

public enum BackupRestoreMode: String, CaseIterable, Sendable { case merge, replace }

public struct BackupRestoreReport: Sendable {
    public var addedRecords = 0
    public var skippedConflicts = 0
    public init() {}
}

public struct StagedBackupRestore: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let manifest: BackupManifest

    public var defaultSelection: BackupRestoreSelection {
        .allAvailable(in: manifest)
    }

    let stagingDirectory: URL
    let payloadURL: URL
    let settingsURL: URL?
    let stagedLibraryFilesDirectory: URL?

    init(
        id: UUID,
        manifest: BackupManifest,
        stagingDirectory: URL,
        payloadURL: URL,
        settingsURL: URL?,
        stagedLibraryFilesDirectory: URL?
    ) {
        self.id = id
        self.manifest = manifest
        self.stagingDirectory = stagingDirectory
        self.payloadURL = payloadURL
        self.settingsURL = settingsURL
        self.stagedLibraryFilesDirectory = stagedLibraryFilesDirectory
    }
}

public actor BackupService {
    private static let manifestPath = "manifest.json"
    private static let payloadPath = "database.json"
    private static let settingsPath = "settings.json"
    private static let libraryFilesPrefix = "LibraryFiles/"
    private static let maximumManifestBytes: UInt64 = 1_048_576
    private static let maximumSettingsBytes: UInt64 = 4 * 1_024 * 1_024
    private static let maximumPayloadBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
    private static let maximumArchiveBytes: UInt64 = 24 * 1_024 * 1_024 * 1_024
    private static let maximumEntryCount = 200_000

    private let database: MankoDatabase
    private let storagePaths: StoragePaths
    private var recoveryRequired: Set<UUID> = []

    public init(database: MankoDatabase, storagePaths: StoragePaths) throws {
        try storagePaths.prepare()
        self.database = database
        self.storagePaths = storagePaths
    }

    @discardableResult
    public func export(
        to destinationURL: URL,
        includeLibraryFiles: Bool = false,
        settingsData: Data? = nil,
        selection requestedSelection: BackupRestoreSelection? = nil
    ) async throws -> BackupManifest {
        guard settingsData.map({ UInt64($0.count) <= Self.maximumSettingsBytes }) ?? true else {
            throw MankoDataError.corruptBackup("The settings payload is oversized.")
        }
        let selection = requestedSelection ?? BackupRestoreSelection(groups:
            Set(BackupRestoreGroup.allCases).subtracting(includeLibraryFiles ? [] : [.importedMedia])
                .subtracting(settingsData == nil ? [.settings, .extensions, .servers, .readerPreferences] : []))
        guard !selection.isEmpty else { throw MankoDataError.corruptBackup("Choose at least one section to export.") }
        let includeLibraryFiles = selection.contains(.importedMedia)
        let settingsData = selection.includesSetup ? settingsData : nil
        let payload = try await database.backupPayload().selected(selection)
        let payloadData = try BackupCoding.encode(payload)
        try BackupPrivacy.validatePublicURLs(in: payloadData)
        let manifest = BackupManifest(
            includesLibraryFiles: includeLibraryFiles,
            payloadSHA256: Self.sha256Hex(payloadData),
            settingsSHA256: settingsData.map(Self.sha256Hex),
            recordCounts: payload.recordCounts,
            includedGroups: selection.groups
        )
        let manifestData = try BackupCoding.encode(manifest)

        let workDirectory = storagePaths.backupStagingDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        let archiveURL = workDirectory.appending(
            path: "manko.mankobackup",
            directoryHint: .notDirectory
        )
        let manifestURL = workDirectory.appending(path: Self.manifestPath)
        let payloadURL = workDirectory.appending(path: Self.payloadPath)
        let settingsURL = workDirectory.appending(path: Self.settingsPath)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try StoragePaths.excludeFromBackup(workDirectory)
        defer { try? fileManager.removeItem(at: workDirectory) }

        try manifestData.write(to: manifestURL, options: .atomic)
        try payloadData.write(to: payloadURL, options: .atomic)
        if let settingsData {
            try settingsData.write(to: settingsURL, options: .atomic)
        }

        let archive: Archive
        do {
            archive = try await Archive(url: archiveURL, accessMode: .create)
            try await archive.addEntry(
                with: Self.manifestPath,
                fileURL: manifestURL,
                compressionMethod: .deflate
            )
            try await archive.addEntry(
                with: Self.payloadPath,
                fileURL: payloadURL,
                compressionMethod: .deflate
            )
            if settingsData != nil {
                try await archive.addEntry(
                    with: Self.settingsPath,
                    fileURL: settingsURL,
                    compressionMethod: .deflate
                )
            }
            if includeLibraryFiles {
                try await addLibraryFiles(to: archive)
            }
        } catch {
            throw MankoDataError.corruptBackup(
                "The archive could not be created: \(error.localizedDescription)"
            )
        }

        try await copyExportAtomically(from: archiveURL, to: destinationURL)
        return manifest
    }

    public func inspect(_ backupURL: URL) async throws -> BackupManifest {
        try await withSecurityScopedAccess(to: backupURL) {
            let archive = try await openArchive(at: backupURL)
            try await validateArchiveEntries(archive)
            guard let entry = try await archive.get(Self.manifestPath) else {
                throw MankoDataError.corruptBackup("The manifest is missing.")
            }
            let data = try await extractData(
                entry,
                from: archive,
                maximumBytes: Self.maximumManifestBytes
            )
            let manifest = try BackupCoding.decode(BackupManifest.self, from: data)
            try validate(manifest)
            return manifest
        }
    }

    public func stageRestore(from backupURL: URL) async throws -> StagedBackupRestore {
        try await withSecurityScopedAccess(to: backupURL) {
            let archive = try await openArchive(at: backupURL)
            try await validateArchiveEntries(archive)

            guard
                let manifestEntry = try await archive.get(Self.manifestPath),
                let payloadEntry = try await archive.get(Self.payloadPath)
            else {
                throw MankoDataError.corruptBackup("Required files are missing.")
            }

            let manifestData = try await extractData(
                manifestEntry,
                from: archive,
                maximumBytes: Self.maximumManifestBytes
            )
            let manifest = try BackupCoding.decode(BackupManifest.self, from: manifestData)
            try validate(manifest)

            let restoreID = UUID()
            let stagingDirectory = storagePaths.backupStagingDirectory.appending(
                path: restoreID.uuidString,
                directoryHint: .isDirectory
            )
            let payloadURL = stagingDirectory.appending(path: Self.payloadPath)
            let settingsURL = manifest.settingsSHA256 == nil
                ? nil
                : stagingDirectory.appending(path: Self.settingsPath)
            let stagedFilesDirectory = manifest.includesLibraryFiles
                ? stagingDirectory.appending(path: "LibraryFiles", directoryHint: .isDirectory)
                : nil
            let fileManager = FileManager.default

            do {
                try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
                try StoragePaths.excludeFromBackup(stagingDirectory)
                _ = try await archive.extract(payloadEntry, to: payloadURL)

                if let expectedSettingsHash = manifest.settingsSHA256 {
                    guard
                        let settingsEntry = try await archive.get(Self.settingsPath),
                        let settingsURL
                    else {
                        throw MankoDataError.corruptBackup("The settings payload is missing.")
                    }
                    _ = try await archive.extract(settingsEntry, to: settingsURL)
                    let settingsData = try Data(contentsOf: settingsURL, options: .mappedIfSafe)
                    guard UInt64(settingsData.count) <= Self.maximumSettingsBytes,
                          Self.sha256Hex(settingsData) == expectedSettingsHash
                    else {
                        throw MankoDataError.corruptBackup("The settings checksum does not match.")
                    }
                } else if try await archive.get(Self.settingsPath) != nil {
                    throw MankoDataError.corruptBackup("The manifest does not declare its settings payload.")
                }

                if let stagedFilesDirectory {
                    try fileManager.createDirectory(
                        at: stagedFilesDirectory,
                        withIntermediateDirectories: true
                    )
                    for entry in try await archive.entries() where entry.path.hasPrefix(Self.libraryFilesPrefix) {
                        guard entry.type != .symlink else {
                            throw MankoDataError.corruptBackup("A library file is a symbolic link.")
                        }
                        let relativePath = String(entry.path.dropFirst(Self.libraryFilesPrefix.count))
                        guard !relativePath.isEmpty else { continue }
                        let destination = stagedFilesDirectory.appending(
                            path: relativePath,
                            directoryHint: entry.type == .directory ? .isDirectory : .notDirectory
                        )
                        if entry.type == .directory {
                            try fileManager.createDirectory(
                                at: destination,
                                withIntermediateDirectories: true
                            )
                        } else {
                            try fileManager.createDirectory(
                                at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            _ = try await archive.extract(entry, to: destination)
                        }
                    }
                }

                let payloadData = try Data(contentsOf: payloadURL, options: .mappedIfSafe)
                guard Self.sha256Hex(payloadData) == manifest.payloadSHA256 else {
                    throw MankoDataError.corruptBackup("The database checksum does not match.")
                }
                _ = try BackupCoding.decode(DatabaseBackupPayload.self, from: payloadData)

                return StagedBackupRestore(
                    id: restoreID,
                    manifest: manifest,
                    stagingDirectory: stagingDirectory,
                    payloadURL: payloadURL,
                    settingsURL: settingsURL,
                    stagedLibraryFilesDirectory: stagedFilesDirectory
                )
            } catch {
                try? fileManager.removeItem(at: stagingDirectory)
                throw error
            }
        }
    }

    @discardableResult
    public func commitRestore(
        _ staged: StagedBackupRestore,
        selection requestedSelection: BackupRestoreSelection,
        mode: BackupRestoreMode = .replace,
        sourceIDMapping: [String: String] = [:],
        applySettings: @Sendable () async throws -> Void = {}
    ) async throws -> BackupRestoreReport {
        let fileManager = FileManager.default
        guard
            fileManager.fileExists(atPath: staged.stagingDirectory.path),
            fileManager.fileExists(atPath: staged.payloadURL.path)
        else {
            throw MankoDataError.stagedRestoreMissing
        }

        let payloadData = try Data(contentsOf: staged.payloadURL, options: .mappedIfSafe)
        guard Self.sha256Hex(payloadData) == staged.manifest.payloadSHA256 else {
            throw MankoDataError.corruptBackup("The staged database checksum changed.")
        }
        var payload = try BackupCoding.decode(DatabaseBackupPayload.self, from: payloadData)
        payload.remapSources(sourceIDMapping)

        let selection = requestedSelection.normalized(for: staged.manifest)
        guard !selection.isEmpty else {
            throw MankoDataError.corruptBackup("No restore contents were selected.")
        }

        let restoreLibraryFiles = selection.contains(.importedMedia)
        if restoreLibraryFiles {
            guard let stagedFiles = staged.stagedLibraryFilesDirectory else {
                throw MankoDataError.corruptBackup("The selected imported media is missing.")
            }
            try validateLocalPublicationFiles(in: payload, stagedFilesDirectory: stagedFiles)
        }

        let previousPayload = selection.restoresDatabaseRecords ? try await database.backupPayload() : nil
        var mergedFilesDirectory: URL?
        if restoreLibraryFiles, mode == .merge, let stagedFiles = staged.stagedLibraryFilesDirectory {
            let combined = staged.stagingDirectory.appending(path: "MergedLibraryFiles")
            try? fileManager.removeItem(at: combined)
            mergedFilesDirectory = combined
            do {
                try fileManager.copyItem(at: storagePaths.libraryFilesDirectory, to: combined)
                try mergeLibraryFiles(from: stagedFiles, into: combined, payload: &payload)
            } catch {
                try? fileManager.removeItem(at: combined)
                throw error
            }
        }
        defer { if let mergedFilesDirectory, !recoveryRequired.contains(staged.id) { try? fileManager.removeItem(at: mergedFilesDirectory) } }
        var previousLibraryFilesURL: URL?
        if restoreLibraryFiles, let stagedFiles = mergedFilesDirectory ?? staged.stagedLibraryFilesDirectory {
            let previousURL = staged.stagingDirectory.appending(
                path: "PreviousLibraryFiles",
                directoryHint: .isDirectory
            )
            if fileManager.fileExists(atPath: storagePaths.libraryFilesDirectory.path) {
                try fileManager.moveItem(
                    at: storagePaths.libraryFilesDirectory,
                    to: previousURL
                )
                previousLibraryFilesURL = previousURL
            }
            do {
                try fileManager.moveItem(
                    at: stagedFiles,
                    to: storagePaths.libraryFilesDirectory
                )
                try StoragePaths.applyStandardProtection(to: storagePaths.libraryFilesDirectory)
            } catch {
                let failure = error
                do { try rollBackLibraryFiles(previous: previousLibraryFilesURL, replacement: stagedFiles) }
                catch {
                    recoveryRequired.insert(staged.id)
                    throw MankoDataError.databaseRestoreFailed("File recovery failed. Recovery files have been retained. \(error.localizedDescription)")
                }
                throw failure
            }
        }

        var report = BackupRestoreReport()
        var databaseCommitted = false
        do {
            if selection.restoresDatabaseRecords {
                report = try await database.restore(
                    payload,
                    selection: selection,
                    libraryFilesDirectory: storagePaths.libraryFilesDirectory,
                    mode: mode
                )
                databaseCommitted = true
            }
            try await applySettings()
        } catch {
            let commitError = error
            if databaseCommitted, let previousPayload {
                do { try await database.restoreSnapshot(previousPayload) }
                catch {
                    recoveryRequired.insert(staged.id)
                    throw MankoDataError.databaseRestoreFailed("Import failed and database recovery failed. Recovery files were retained. \(error.localizedDescription)")
                }
            }
            if restoreLibraryFiles, let stagedFiles = mergedFilesDirectory ?? staged.stagedLibraryFilesDirectory {
                do { try rollBackLibraryFiles(previous: previousLibraryFilesURL, replacement: stagedFiles) }
                catch {
                    recoveryRequired.insert(staged.id)
                    throw MankoDataError.databaseRestoreFailed("File recovery failed. Recovery files have been retained. \(error.localizedDescription)")
                }
            }
            throw commitError
        }

        try? fileManager.removeItem(at: staged.stagingDirectory)
        return report
    }

    /// Returns the validated, non-sensitive settings payload from a staged
    /// restore. Call this before `commitRestore`, which removes staging files.
    public func settingsData(for staged: StagedBackupRestore) throws -> Data? {
        guard let settingsURL = staged.settingsURL else { return nil }
        let data = try Data(contentsOf: settingsURL, options: .mappedIfSafe)
        guard UInt64(data.count) <= Self.maximumSettingsBytes,
              let expectedHash = staged.manifest.settingsSHA256,
              Self.sha256Hex(data) == expectedHash
        else {
            throw MankoDataError.corruptBackup("The staged settings checksum changed.")
        }
        return data
    }

    public func discard(_ staged: StagedBackupRestore) throws {
        let fileManager = FileManager.default
        guard !recoveryRequired.contains(staged.id) else {
            throw MankoDataError.databaseRestoreFailed("This import needs recovery. Its recovery files have been retained.")
        }
        guard fileManager.fileExists(atPath: staged.stagingDirectory.path) else { return }
        try fileManager.removeItem(at: staged.stagingDirectory)
    }

    private func rollBackLibraryFiles(previous: URL?, replacement: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: storagePaths.libraryFilesDirectory.path) {
            try manager.moveItem(at: storagePaths.libraryFilesDirectory, to: replacement)
        }
        if let previous { try manager.moveItem(at: previous, to: storagePaths.libraryFilesDirectory) }
    }

    private func mergeLibraryFiles(from incoming: URL, into combined: URL, payload: inout DatabaseBackupPayload) throws {
        let manager = FileManager.default
        var existingByHash: [String: URL] = [:]
        for url in try Self.libraryFileURLs(at: combined) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw MankoDataError.corruptBackup("An imported file is a symbolic link.") }
            guard values.isRegularFile == true else { continue }
            existingByHash[Self.sha256Hex(try Data(contentsOf: url, options: .mappedIfSafe))] = url
        }
        var names: [String: String] = [:]
        for url in try Self.libraryFileURLs(at: incoming) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw MankoDataError.corruptBackup("An imported file is a symbolic link.") }
            guard values.isRegularFile == true else { continue }
            let hash = Self.sha256Hex(try Data(contentsOf: url, options: .mappedIfSafe))
            let target: URL
            if let existing = existingByHash[hash] { target = existing }
            else {
                var destination = combined.appendingPathComponent(url.lastPathComponent)
                if manager.fileExists(atPath: destination.path) {
                    destination = combined.appendingPathComponent(hash + "." + url.pathExtension)
                }
                try manager.copyItem(at: url, to: destination)
                existingByHash[hash] = destination
                target = destination
            }
            names[url.lastPathComponent] = target.lastPathComponent
        }
        let localIDs = Set(payload.works.filter { $0.sourceID == .local }.map(\.id))
        for index in payload.installments.indices where localIDs.contains(payload.installments[index].workID) {
            if let url = payload.installments[index].acquisitionURL, let name = names[url.lastPathComponent] {
                payload.installments[index].acquisitionURL = storagePaths.libraryFilesDirectory.appendingPathComponent(name)
            }
        }
    }

    private func addLibraryFiles(to archive: Archive) async throws {
        let fileURLs = try Self.libraryFileURLs(at: storagePaths.libraryFilesDirectory)
        let canonicalRoot = storagePaths.libraryFilesDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix = canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path
            : canonicalRoot.path + "/"
        for fileURL in fileURLs {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw MankoDataError.corruptBackup("Library files contain a symbolic link.")
            }
            guard values.isRegularFile == true else { continue }
            let canonicalFile = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            guard canonicalFile.path.hasPrefix(rootPrefix) else {
                throw MankoDataError.corruptBackup("A library file escaped its directory.")
            }
            let relativePath = String(canonicalFile.path.dropFirst(rootPrefix.count))
            guard !relativePath.isEmpty else { continue }
            let archivePath = Self.libraryFilesPrefix + relativePath
            try Self.validateArchivePath(archivePath)
            try await archive.addEntry(
                with: archivePath,
                fileURL: fileURL,
                compressionMethod: .deflate
            )
        }
    }

    private func validateLocalPublicationFiles(
        in payload: DatabaseBackupPayload,
        stagedFilesDirectory: URL
    ) throws {
        let localWorkIDs = Set(payload.works.filter { $0.sourceID == .local }.map(\.id))
        let fileManager = FileManager.default

        for installment in payload.installments where localWorkIDs.contains(installment.workID) {
            guard let acquisitionURL = installment.acquisitionURL else { continue }
            guard acquisitionURL.isFileURL, !acquisitionURL.lastPathComponent.isEmpty else {
                throw MankoDataError.corruptBackup(
                    "A local publication has an invalid file reference."
                )
            }
            let stagedURL = stagedFilesDirectory.appending(
                path: acquisitionURL.lastPathComponent,
                directoryHint: .notDirectory
            )
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: stagedURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                throw MankoDataError.corruptBackup(
                    "A local publication file declared by the database is missing."
                )
            }
        }
    }

    private nonisolated static func libraryFileURLs(at directory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw MankoDataError.corruptBackup("Library files could not be enumerated.")
        }
        var urls: [URL] = []
        while let value = enumerator.nextObject() {
            guard let url = value as? URL else { continue }
            urls.append(url)
        }
        return urls
    }

    private func copyExportAtomically(from sourceURL: URL, to destinationURL: URL) async throws {
        try await withSecurityScopedAccess(to: destinationURL) {
            let fileManager = FileManager.default
            let parent = destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let temporaryDestination = parent.appending(
                path: ".\(UUID().uuidString).mankobackup",
                directoryHint: .notDirectory
            )
            defer { try? fileManager.removeItem(at: temporaryDestination) }
            try fileManager.copyItem(at: sourceURL, to: temporaryDestination)
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryDestination)
            } else {
                try fileManager.moveItem(at: temporaryDestination, to: destinationURL)
            }
            try StoragePaths.applyStandardProtection(to: destinationURL)
        }
    }

    private func openArchive(at url: URL) async throws -> Archive {
        do {
            return try await Archive(url: url, accessMode: .read)
        } catch {
            throw MankoDataError.corruptBackup("The archive cannot be opened.")
        }
    }

    private func validateArchiveEntries(_ archive: Archive) async throws {
        var count = 0
        var totalBytes: UInt64 = 0
        var sawManifest = false
        var sawPayload = false
        var sawSettings = false

        for entry in try await archive.entries() {
            count += 1
            guard count <= Self.maximumEntryCount else {
                throw MankoDataError.corruptBackup("The archive contains too many files.")
            }
            try Self.validateArchivePath(entry.path)
            guard entry.type != .symlink else {
                throw MankoDataError.corruptBackup("The archive contains a symbolic link.")
            }
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, newTotal <= Self.maximumArchiveBytes else {
                throw MankoDataError.corruptBackup("The archive expands beyond the safety limit.")
            }
            totalBytes = newTotal

            switch entry.path {
            case Self.manifestPath:
                guard !sawManifest, entry.uncompressedSize <= Self.maximumManifestBytes else {
                    throw MankoDataError.corruptBackup("The manifest is duplicated or oversized.")
                }
                sawManifest = true
            case Self.payloadPath:
                guard !sawPayload, entry.uncompressedSize <= Self.maximumPayloadBytes else {
                    throw MankoDataError.corruptBackup("The database payload is duplicated or oversized.")
                }
                sawPayload = true
            case Self.settingsPath:
                guard !sawSettings, entry.uncompressedSize <= Self.maximumSettingsBytes else {
                    throw MankoDataError.corruptBackup("The settings payload is duplicated or oversized.")
                }
                sawSettings = true
            default:
                guard entry.path.hasPrefix(Self.libraryFilesPrefix) else {
                    throw MankoDataError.corruptBackup("The archive contains an unknown file.")
                }
            }
        }

        guard sawManifest, sawPayload else {
            throw MankoDataError.corruptBackup("Required files are missing.")
        }
    }

    private func extractData(
        _ entry: Entry,
        from archive: Archive,
        maximumBytes: UInt64
    ) async throws -> Data {
        guard entry.uncompressedSize <= maximumBytes else {
            throw MankoDataError.corruptBackup("An entry is oversized.")
        }
        guard maximumBytes <= UInt64(Int.max) else {
            throw MankoDataError.corruptBackup("An entry limit is unsupported.")
        }
        let accumulator = LimitedDataAccumulator(maximumBytes: Int(maximumBytes))
        _ = try await archive.extract(entry) { chunk in
            try await accumulator.append(chunk)
        }
        return await accumulator.value()
    }

    private func validate(_ manifest: BackupManifest) throws {
        guard manifest.appIdentifier == "com.k800k.manko" else {
            throw MankoDataError.corruptBackup("This backup was not created by Manko.")
        }
        guard (1 ... BackupManifest.currentFormatVersion).contains(manifest.formatVersion) else {
            throw MankoDataError.unsupportedBackupVersion(manifest.formatVersion)
        }
        if manifest.formatVersion >= 2 {
            guard let groups = manifest.includedGroups,
                  groups.allSatisfy({ $0.requiredGroups.isSubset(of: groups) }),
                  groups.contains(.importedMedia) == manifest.includesLibraryFiles,
                  groups.isDisjoint(with: [.settings, .extensions, .servers, .readerPreferences]) == (manifest.settingsSHA256 == nil)
            else { throw MankoDataError.corruptBackup("The declared backup sections are inconsistent.") }
        }
        guard ((BackupManifest.currentDatabaseSchemaVersion - 1) ... BackupManifest.currentDatabaseSchemaVersion)
            .contains(manifest.databaseSchemaVersion)
        else {
            throw MankoDataError.corruptBackup("The database schema version is unsupported.")
        }
    }

    private func withSecurityScopedAccess<T: Sendable>(
        to url: URL,
        operation: () async throws -> T
    ) async throws -> T {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try await operation()
    }

    private static func validateArchivePath(_ path: String) throws {
        guard !path.isEmpty, !path.contains("\0") else {
            throw MankoDataError.corruptBackup("An archive path is invalid.")
        }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/") else {
            throw MankoDataError.corruptBackup("An archive path is absolute.")
        }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else {
            throw MankoDataError.corruptBackup("An archive path escapes its container.")
        }
        if let first = components.first, first.contains(":") {
            throw MankoDataError.corruptBackup("An archive path is absolute.")
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum BackupCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
