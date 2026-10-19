import Foundation

/// Durable file-backed queue metadata and URLSession resume blobs.
///
/// The queue contains only download configuration and state. Credentials stay
/// in Keychain; authorization headers are redacted before persistence by the
/// app integration layer and rebuilt when a transfer is enqueued.
public actor FileDownloadStateStore: DownloadStateStore {
    public nonisolated let rootDirectory: URL

    private let isPrivate: Bool
    private let queueURL: URL
    private let resumeDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL, isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        rootDirectory = directory
        queueURL = directory.appendingPathComponent("queue.json", isDirectory: false)
        resumeDirectory = directory.appendingPathComponent("ResumeData", isDirectory: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func loadDownloads() throws -> [DownloadSnapshot] {
        try prepare()
        guard FileManager.default.fileExists(atPath: queueURL.path) else { return [] }
        do {
            return try decoder.decode([DownloadSnapshot].self, from: Data(contentsOf: queueURL))
        } catch {
            throw DownloadCoordinatorError.persistence("The saved download queue is unreadable: \(error.localizedDescription)")
        }
    }

    public func saveDownloads(_ snapshots: [DownloadSnapshot]) throws {
        try prepare()
        do {
            let data = try encoder.encode(snapshots)
            try data.write(to: queueURL, options: [.atomic, isPrivate ? .completeFileProtection : .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw DownloadCoordinatorError.persistence(error.localizedDescription)
        }
    }

    public func loadResumeData(for id: UUID) throws -> Data? {
        try prepare()
        let url = resumeURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func saveResumeData(_ data: Data?, for id: UUID) throws {
        try prepare()
        let url = resumeURL(for: id)
        if let data {
            try data.write(to: url, options: [.atomic, isPrivate ? .completeFileProtection : .completeFileProtectionUntilFirstUserAuthentication])
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func prepare() throws {
        do {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableRoot = rootDirectory
            try mutableRoot.setResourceValues(values)
        } catch {
            throw DownloadCoordinatorError.persistence(error.localizedDescription)
        }
    }

    private func resumeURL(for id: UUID) -> URL {
        resumeDirectory.appendingPathComponent("\(id.uuidString).resume", isDirectory: false)
    }
}
