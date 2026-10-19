import CloudKit
import CryptoKit
import Foundation

/// Persists the opaque CloudKit metadata required to update an existing
/// record, including its server change tag. Application fields are never
/// included in these archives.
public actor CloudRecordSystemFieldsStore {
    public static let maximumArchiveSize = 1_048_576

    private let directoryURL: URL
    private let zoneID: CKRecordZone.ID
    private let maximumArchiveSize: Int
    private let fileManager: FileManager

    public init(
        directoryURL: URL? = nil,
        zoneID: CKRecordZone.ID = CKRecordZone.ID(
            zoneName: CloudSyncEngine.zoneName,
            ownerName: CKCurrentUserDefaultName
        ),
        maximumArchiveSize: Int = CloudRecordSystemFieldsStore.maximumArchiveSize,
        fileManager: FileManager = .default
    ) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.directoryURL = applicationSupport
                .appendingPathComponent("manko", isDirectory: true)
                .appendingPathComponent("CloudSync", isDirectory: true)
                .appendingPathComponent("SystemFields", isDirectory: true)
        }
        self.zoneID = zoneID
        self.maximumArchiveSize = max(1, maximumArchiveSize)
        self.fileManager = fileManager
    }

    /// Returns a record containing only decoded CloudKit system fields. Invalid
    /// or stale archives are discarded so the caller can fall back to a fresh
    /// record and let normal conflict recovery obtain the current server copy.
    public func record(for id: CKRecord.ID, expectedType: String) throws -> CKRecord? {
        guard id.zoneID == zoneID, !expectedType.isEmpty else { return nil }
        let fileURL = fileURL(for: id)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize > 0,
            fileSize <= maximumArchiveSize
        else {
            discardInvalidArchive(at: fileURL)
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.uncached])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        guard data.count <= maximumArchiveSize else {
            discardInvalidArchive(at: fileURL)
            return nil
        }

        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = true
            unarchiver.decodingFailurePolicy = .setErrorAndReturn
            defer { unarchiver.finishDecoding() }

            guard
                let record = CKRecord(coder: unarchiver),
                unarchiver.error == nil,
                record.recordID == id,
                record.recordID.zoneID == zoneID,
                record.recordType == expectedType
            else {
                discardInvalidArchive(at: fileURL)
                return nil
            }
            return record
        } catch {
            discardInvalidArchive(at: fileURL)
            return nil
        }
    }

    public func saveSystemFields(for record: CKRecord) throws {
        guard record.recordID.zoneID == zoneID else {
            throw CocoaError(.coderInvalidValue)
        }

        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        let data = archiver.encodedData
        guard !data.isEmpty, data.count <= maximumArchiveSize else {
            throw CocoaError(.fileWriteUnknown)
        }

        try prepareDirectory()
        let fileURL = fileURL(for: record.recordID)
#if targetEnvironment(macCatalyst)
        try data.write(to: fileURL, options: [.atomic])
#else
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
#endif
        try excludeFromBackup(fileURL)
    }

    public func remove(for id: CKRecord.ID) throws {
        guard id.zoneID == zoneID else { return }
        let fileURL = fileURL(for: id)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    public func removeAll() throws {
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
        try prepareDirectory()
    }

    func archiveURL(for id: CKRecord.ID) -> URL {
        fileURL(for: id)
    }

    private func fileURL(for id: CKRecord.ID) -> URL {
        let identity = [
            id.zoneID.ownerName,
            id.zoneID.zoneName,
            id.recordName,
        ].joined(separator: "\u{001F}")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directoryURL.appendingPathComponent(digest, isDirectory: false)
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try excludeFromBackup(directoryURL)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private func discardInvalidArchive(at url: URL) {
        try? fileManager.removeItem(at: url)
    }
}
