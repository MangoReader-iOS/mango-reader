import Foundation
import MankoData
import MankoDomain
import MankoExtensions

/// Non-sensitive preferences carried by a current-format manko backup.
/// Keychain account identifiers and credential material are intentionally absent.
struct AppBackupSettings: Codable, Sendable {
    static let currentVersion = 5

    var version = Self.currentVersion
    var sources: [SourceDescriptor]
    var sourceOptions: [String: [String: String]]
    var sourceSearchExclusions: [String: [SourceSearchSelection]]? = nil
    /// Repository metadata and legacy trust fields. Executable bytes
    /// and all extension state are deliberately excluded.
    var repositories: [RepositoryRecord]
    var installedRepositorySources: [InstalledRepositorySource]
    var libraryLayout: String
    var librarySort: String
    var preferredAppearance: String
    var wifiOnlyDownloads: Bool
    var syncImportedFiles: Bool
    var readerAdditionalPreferences: ReaderAdditionalPreferences? = nil
    var readerDirection: String
    var epubScroll: Bool
    var publisherStyles: Bool
    var verticalWriting: Bool
    var publicationTheme: String
    var readerFontScale: Double
    var readerFontPreset: String
    var readerFontWeight: Double
    var readerLineHeight: Double
    var readerParagraphSpacing: Double
    var readerParagraphIndent: Double
    var readerPageMargins: Double
    var readerWordSpacing: Double
    var readerLetterSpacing: Double
    var readerHyphenation: Bool
    var readerTextNormalization: Bool
    var readerTextAlignment: String
    var readerColumnCount: String
    var pdfDoublePage: Bool
    var pdfContinuous: Bool
    var reduceReaderTransitions: Bool
    var imageReaderPageSpread: String
    var imageReaderWidePageBehavior: String
    var imageReaderCropMargins: Bool
    var imageReaderLiveText: Bool
    var imageReaderTransition: String
    var imageReaderTapLeadingAction: String
    var imageReaderTapCenterAction: String
    var imageReaderTapTrailingAction: String
    var automationRules: LibraryAutomationRules

    static func decodeCompatible(from data: Data) throws -> Self {
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        guard ((currentVersion - 1) ... currentVersion).contains(decoded.version) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return decoded
    }
}

/// Sparse setup payload. Absence is distinct from an explicitly selected empty section.
struct BackupSetupPayload: Codable, Sendable {
    static let currentVersion = 6
    var version = Self.currentVersion
    var extensions: ExtensionReferences?
    var servers: ServerReferences?
    var readerPreferences: [String: Data]?
    var settings: [String: Data]?

    struct ExtensionReferences: Codable, Sendable {
        var repositories: [RepositoryRecord]
        var installed: [InstalledRepositorySource]
        var sources: [SourceDescriptor]
    }
    struct ServerReferences: Codable, Sendable {
        var sources: [SourceDescriptor]
        var options: [String: [String: String]]
    }

    static let readerKeys: Set<String> = [
        "readerAdditionalPreferences", "readerDirection", "epubScroll", "publisherStyles", "verticalWriting",
        "publicationTheme", "readerFontScale", "readerFontPreset", "readerFontWeight", "readerLineHeight",
        "readerParagraphSpacing", "readerParagraphIndent", "readerPageMargins", "readerWordSpacing",
        "readerLetterSpacing", "readerHyphenation", "readerTextNormalization", "readerTextAlignment",
        "readerColumnCount", "pdfDoublePage", "pdfContinuous", "reduceReaderTransitions", "imageReaderPageSpread",
        "imageReaderWidePageBehavior", "imageReaderCropMargins", "imageReaderLiveText", "imageReaderTransition",
        "imageReaderTapLeadingAction", "imageReaderTapCenterAction", "imageReaderTapTrailingAction"
    ]
    static let appKeys: Set<String> = [
        "libraryLayout", "librarySort", "preferredAppearance", "wifiOnlyDownloads", "syncImportedFiles", "libraryAutomationRules", "sourceSearchExclusions"
    ]
    static let safeSourceOptions: Set<String> = ["connectorExtensionID", "allowsLANHTTP"]

    static func encodePreference(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
    }

    static func decodePreference(_ data: Data) throws -> Any {
        guard let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let value = object["value"], value is String || value is NSNumber || value is Data else {
            throw CocoaError(.coderReadCorrupt)
        }
        return value
    }

    static func decodeCompatible(from data: Data) throws -> Self {
        let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if header?["version"] as? Int == currentVersion {
            return try JSONDecoder().decode(Self.self, from: data)
        }
        let legacy = try AppBackupSettings.decodeCompatible(from: data)
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        var result = Self()
        result.extensions = .init(repositories: legacy.repositories, installed: legacy.installedRepositorySources.filter { $0.entryType == .mankoExtension },
            sources: legacy.sources.filter { $0.kind == .mankoExtension })
        result.servers = .init(sources: legacy.sources.filter { $0.kind != .mankoExtension && $0.kind != .local },
            options: legacy.sourceOptions.mapValues { $0.filter { safeSourceOptions.contains($0.key) } })
        var reader: [String: Data] = [:]
        var settings: [String: Data] = [:]
        for key in readerKeys.union(appKeys) {
            if key == "readerAdditionalPreferences", let preferences = legacy.readerAdditionalPreferences {
                reader[key] = try encodePreference(preferences.encoded)
            } else if key == "sourceSearchExclusions" {
                settings[key] = try encodePreference(JSONEncoder().encode(legacy.sourceSearchExclusions ?? [:]))
            } else if key == "libraryAutomationRules" {
                settings[key] = try encodePreference(JSONEncoder().encode(legacy.automationRules))
            } else if let value = raw[key], !(value is NSNull) {
                if readerKeys.contains(key) { reader[key] = try encodePreference(value) }
                else { settings[key] = try encodePreference(value) }
            }
        }
        result.readerPreferences = reader
        result.settings = settings
        return result
    }

    /// Scrubs nested typed repository metadata as well as top-level source fields.
    /// A required field that cannot survive sanitization makes the export fail.
    static func sanitized<T: Codable>(_ value: T) throws -> T {
        func scrub(_ value: Any) -> Any? {
            if let dictionary = value as? [String: Any] {
                var result: [String: Any] = [:]
                for (key, value) in dictionary {
                    let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                    if ["accessgrant", "credential", "credentials", "credentialaccount", "password", "apikey", "token", "refreshtoken", "authorization", "cookie", "cookies", "secret"].contains(normalized) { continue }
                    if key == "options", let options = value as? [String: Any] {
                        if options.values.contains(where: { $0 is [String: Any] }) {
                            result[key] = options.mapValues { value in
                                (value as? [String: Any] ?? [:]).filter { safeSourceOptions.contains($0.key) }
                            }
                        } else {
                            result[key] = options.filter { safeSourceOptions.contains($0.key) }
                        }
                    } else if let clean = scrub(value) { result[key] = clean }
                }
                return result
            }
            if let array = value as? [Any] { return array.compactMap(scrub) }
            if let string = value as? String, string.hasPrefix("https://") || string.hasPrefix("http://") {
                return BackupPrivacy.publicURL(URL(string: string))?.absoluteString
            }
            return value
        }
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        guard let cleaned = scrub(raw) else { throw CocoaError(.coderReadCorrupt) }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: cleaned))
    }

    func validated(selection: BackupRestoreSelection) throws -> Self {
        var result = self
        if !selection.contains(.extensions) { result.extensions = nil }
        if !selection.contains(.servers) { result.servers = nil }
        if !selection.contains(.readerPreferences) { result.readerPreferences = nil }
        if !selection.contains(.settings) { result.settings = nil }
        guard (!selection.contains(.extensions) || result.extensions != nil),
              (!selection.contains(.servers) || result.servers != nil),
              (!selection.contains(.readerPreferences) || result.readerPreferences != nil),
              (!selection.contains(.settings) || result.settings != nil) else {
            throw CocoaError(.coderReadCorrupt)
        }
        for source in result.servers?.sources ?? [] {
            guard let url = source.baseURL else { throw CocoaError(.coderReadCorrupt) }
            _ = try BackupPrivacy.requiredURL(url)
        }
        for repo in result.extensions?.repositories ?? [] {
            _ = try BackupPrivacy.requiredURL(repo.repositoryURL)
            _ = try BackupPrivacy.requiredURL(repo.manifestURL)
        }
        for (values, allowed) in [(result.readerPreferences, Self.readerKeys), (result.settings, Self.appKeys)] {
            for (key, data) in values ?? [:] {
                guard allowed.contains(key) else { throw CocoaError(.coderReadCorrupt) }
                _ = try Self.decodePreference(data)
            }
        }
        result = try Self.sanitized(result)
        let options = result.servers?.options.mapValues { $0.filter { Self.safeSourceOptions.contains($0.key) } } ?? [:]
        result.servers?.options = options
        return result
    }
}
