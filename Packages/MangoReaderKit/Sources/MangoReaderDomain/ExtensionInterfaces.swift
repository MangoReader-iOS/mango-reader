import Foundation

public enum ExtensionFormFieldKind: String, Codable, CaseIterable, Sendable {
    case text
    case secureText
    case toggle
    case selection
    case multiSelection
    case range
    case button
    case link
}

public struct ExtensionFormOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?

    public init(id: String, title: String, subtitle: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

/// A native-rendered form declaration. Extensions describe fields and values;
/// they never provide SwiftUI/UIKit views or arbitrary native code.
public struct ExtensionFormField: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: ExtensionFormFieldKind
    public var title: String
    public var subtitle: String?
    public var placeholder: String?
    public var options: [ExtensionFormOption]
    public var minimum: Double?
    public var maximum: Double?
    public var step: Double?
    public var destination: URL?
    public var isRequired: Bool

    public init(
        id: String,
        kind: ExtensionFormFieldKind,
        title: String,
        subtitle: String? = nil,
        placeholder: String? = nil,
        options: [ExtensionFormOption] = [],
        minimum: Double? = nil,
        maximum: Double? = nil,
        step: Double? = nil,
        destination: URL? = nil,
        isRequired: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.placeholder = placeholder
        self.options = options
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.destination = destination
        self.isRequired = isRequired
    }
}

public struct ExtensionFormSchema: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var fields: [ExtensionFormField]

    public init(id: String, title: String, fields: [ExtensionFormField]) {
        self.id = id
        self.title = title
        self.fields = fields
    }
}

public enum ExtensionFormValue: Codable, Hashable, Sendable {
    case text(String)
    case toggle(Bool)
    case selection(String)
    case multiSelection(Set<String>)
    case range(Double)
}

public enum SourceDiscoverSectionPresentation: String, Codable, Hashable, Sendable {
    case carousel
    case latestGallery
    case automatic
}

public struct SourceDiscoverSection: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var presentation: SourceDiscoverSectionPresentation

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        presentation: SourceDiscoverSectionPresentation = .automatic
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.presentation = presentation
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case presentation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        presentation = try container.decodeIfPresent(
            SourceDiscoverSectionPresentation.self,
            forKey: .presentation
        ) ?? .automatic
    }
}

public protocol SourceDiscoverSectionProviding: ContentSource {
    func discoverSections() async throws -> [SourceDiscoverSection]
    func discover(sectionID: String, query: SourceQuery) async throws -> SourcePage<Work>
}

public protocol SourceSearchFormProviding: ContentSource {
    func searchForm() async throws -> ExtensionFormSchema?
}

public enum SourceSearchInputKind: String, Codable, Hashable, Sendable {
    case choice, lookup, text, number
}

public struct SourceSearchField: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var queryPrefix: String
    public var placeholder: String?
    public var supportsExclusion: Bool
    public var options: [ExtensionFormOption]
    public var inputKind: SourceSearchInputKind?
    public var maximumSelections: Int?

    public var resolvedInputKind: SourceSearchInputKind {
        inputKind ?? (options.isEmpty ? .lookup : .choice)
    }

    public init(
        id: String,
        title: String,
        queryPrefix: String,
        placeholder: String? = nil,
        supportsExclusion: Bool = false,
        options: [ExtensionFormOption] = [],
        inputKind: SourceSearchInputKind? = nil,
        maximumSelections: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.queryPrefix = queryPrefix
        self.placeholder = placeholder
        self.supportsExclusion = supportsExclusion
        self.options = options
        self.inputKind = inputKind
        self.maximumSelections = maximumSelections
    }
}

public struct SourceSearchSortOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct SourceSearchConfiguration: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var fields: [SourceSearchField]
    public var sortOptions: [SourceSearchSortOption]
    public var defaultSortID: String?
    public var supportsTextWithFilters: Bool?
    public var sortedBrowseSectionID: String?

    public init(
        id: String,
        title: String,
        fields: [SourceSearchField],
        sortOptions: [SourceSearchSortOption] = [],
        defaultSortID: String? = nil,
        supportsTextWithFilters: Bool? = nil,
        sortedBrowseSectionID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.fields = fields
        self.sortOptions = sortOptions
        self.defaultSortID = defaultSortID
        self.supportsTextWithFilters = supportsTextWithFilters
        self.sortedBrowseSectionID = sortedBrowseSectionID
    }
}

public struct SourceSearchValidationError: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public extension SourceSearchConfiguration {
    func validate(selections: [SourceSearchSelection], sortID: String? = nil, query: String = "") throws {
        if supportsTextWithFilters == false, !selections.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SourceSearchValidationError("This source supports filtered browsing or keyword search. Clear the keyword to apply these filters.")
        }
        if let sortID, !sortOptions.contains(where: { $0.id == sortID }) {
            throw SourceSearchValidationError("This source no longer supports the selected sort order.")
        }
        var counts: [String: Int] = [:]
        var seen: Set<String> = []
        for selection in selections {
            guard let field = fields.first(where: { $0.id == selection.fieldID }) else {
                throw SourceSearchValidationError("This source does not support the filter \(selection.fieldID). Remove this selection to continue.")
            }
            guard selection.polarity != .exclude || field.supportsExclusion else {
                throw SourceSearchValidationError("\(field.title) does not support exclusion.")
            }
            let value = selection.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 256 else {
                throw SourceSearchValidationError("Enter a valid value for \(field.title).")
            }
            if field.resolvedInputKind == .choice, !field.options.contains(where: { $0.id == value }) {
                throw SourceSearchValidationError("\(selection.title) is not an available \(field.title.lowercased()) option. Choose another value.")
            }
            if field.resolvedInputKind == .number, Int(value).map({ $0 >= 0 }) != true {
                throw SourceSearchValidationError("\(field.title) must be a whole number of zero or more.")
            }
            guard seen.insert("\(field.id)|\(value)").inserted else {
                throw SourceSearchValidationError("Choose one include or exclude state for \(selection.title).")
            }
            counts[field.id, default: 0] += 1
            if let limit = field.maximumSelections, counts[field.id, default: 0] > limit {
                throw SourceSearchValidationError("Choose at most \(limit) value(s) for \(field.title).")
            }
        }
    }
}

public enum SourceSearchMatching {
    public static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func score(query: String, candidate: String) -> Int? {
        scoreNormalized(query: normalized(query), candidate: normalized(candidate))
    }

    public static func scoreNormalized(query: String, candidate: String) -> Int? {
        PreparedQuery(query).score(candidate: candidate, words: candidate.split(separator: " ").map(String.init))
    }

    /// Reuse query preparation and learned word boundaries across a vocabulary.
    struct PreparedQuery {
        let value: String
        let letters: [Character]
        let limit: Int?
        init(_ value: String) {
            self.value = value
            letters = Array(value)
            limit = (3...100).contains(letters.count) && !value.allSatisfy(\.isNumber)
                ? (letters.count < 6 ? 1 : 2) : nil
        }
        func score(candidate: String, words: [String]) -> Int? {
            guard !value.isEmpty else { return 0 }
            if candidate == value { return 0 }
            if candidate.hasPrefix(value) { return 100 }
            if words.contains(where: { $0.hasPrefix(value) }) { return 200 }
            if candidate.contains(value) { return 300 }
            guard let limit else { return nil }
            var best: Int?
            for word in words {
                if let found = SourceSearchMatching.distance(letters, word, limit: limit) {
                    best = min(best ?? found, found)
                }
            }
            // Multiword input also needs comparison with the complete phrase.
            if words.count > 1, value.contains(" "),
               let found = SourceSearchMatching.distance(letters, candidate, limit: limit) {
                best = min(best ?? found, found)
            }
            return best.map { 400 + $0 }
        }
    }

    private static func distance(_ a: [Character], _ rhs: String, limit: Int) -> Int? {
        let b = Array(rhs.prefix(a.count + limit))
        guard b.count >= max(1, a.count - limit), b.count <= 100 else { return nil }
        // Even with deletions/substitutions, this many query characters must
        // occur in the candidate prefix. Reject unrelated words before DP.
        guard a.filter({ b.contains($0) }).count >= a.count - limit else { return nil }
        var before = Array(0...b.count), previous = before
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            if !b.isEmpty {
                for j in 1...b.count {
                    current[j] = min(current[j-1]+1, previous[j]+1, previous[j-1]+(a[i-1] == b[j-1] ? 0 : 1))
                    if i > 1, j > 1, a[i-1] == b[j-2], a[i-2] == b[j-1] {
                        current[j] = min(current[j], before[j-2]+1)
                    }
                }
            }
            if current.min()! > limit { return nil }
            before = previous
            previous = current
        }
        let best = previous[max(1, a.count - limit)...b.count].min()!
        return best <= limit ? best : nil
    }
}

public struct SourceSearchSuggestionRequest: Codable, Hashable, Sendable {
    /// A specific field to search, or `nil` to search across every supported field.
    public var fieldID: String?
    public var query: String
    public var selections: [SourceSearchSelection]
    public var limit: Int

    public init(
        fieldID: String? = nil,
        query: String,
        selections: [SourceSearchSelection] = [],
        limit: Int = 20
    ) {
        self.fieldID = fieldID
        self.query = query
        self.selections = selections
        self.limit = min(30, max(1, limit))
    }
}

public struct SourceSearchSuggestion: Codable, Hashable, Sendable, Identifiable {
    public var fieldID: String
    public var value: String
    public var title: String
    public var subtitle: String?

    public var id: String { "\(fieldID)|\(value)" }

    public init(
        fieldID: String,
        value: String,
        title: String? = nil,
        subtitle: String? = nil
    ) {
        self.fieldID = fieldID
        self.value = value
        self.title = title ?? value
        self.subtitle = subtitle
    }
}

public protocol SourceSearchConfigurationProviding: ContentSource {
    func searchConfiguration() async throws -> SourceSearchConfiguration?
    func searchSuggestions(
        for request: SourceSearchSuggestionRequest
    ) async throws -> [SourceSearchSuggestion]
}

public extension SourceSearchConfigurationProviding {
    func searchSuggestions(
        for request: SourceSearchSuggestionRequest
    ) async throws -> [SourceSearchSuggestion] {
        []
    }
}

public struct SourceUpdate: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var remoteWorkID: String
    public var changedAt: Date?

    public init(id: String, remoteWorkID: String, changedAt: Date? = nil) {
        self.id = id
        self.remoteWorkID = remoteWorkID
        self.changedAt = changedAt
    }
}

public protocol SourceUpdateProcessing: ContentSource {
    func updates(since: Date?, cursor: SourceCursor?) async throws -> SourcePage<SourceUpdate>
}

public struct ManagedSourceCollection: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var workRemoteIDs: [String]
    public var modifiedAt: Date?

    public init(id: String, title: String, workRemoteIDs: [String], modifiedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.workRemoteIDs = workRemoteIDs
        self.modifiedAt = modifiedAt
    }
}

public protocol SourceManagedCollectionProviding: ContentSource {
    func managedCollections(cursor: SourceCursor?) async throws -> SourcePage<ManagedSourceCollection>
    func synchronizeManagedCollection(_ collection: ManagedSourceCollection) async throws
}

public enum TrackerAuthenticationMode: String, Codable, CaseIterable, Sendable {
    case none
    case credentials
    case apiKey
    case oauth2Implicit
    case oauth2PKCE
    case visibleWebSession
}

public enum TrackerOAuthPKCEMethod: String, Codable, CaseIterable, Sendable {
    case plain
    case S256
}

public struct TrackerAuthenticationDescriptor: Codable, Hashable, Sendable {
    public var mode: TrackerAuthenticationMode
    public var authorizationURL: URL?
    public var tokenURL: URL?
    public var callbackScheme: String?
    public var callbackURL: URL?
    public var clientID: String?
    public var clientIDInfoPlistKey: String?
    public var responseType: String?
    public var scopes: [String]?
    public var pkceMethod: TrackerOAuthPKCEMethod?
    public var authorizationParameters: [String: String]?
    public var tokenParameters: [String: String]?
    public var form: ExtensionFormSchema?

    public init(
        mode: TrackerAuthenticationMode,
        authorizationURL: URL? = nil,
        tokenURL: URL? = nil,
        callbackScheme: String? = nil,
        callbackURL: URL? = nil,
        clientID: String? = nil,
        clientIDInfoPlistKey: String? = nil,
        responseType: String? = nil,
        scopes: [String]? = nil,
        pkceMethod: TrackerOAuthPKCEMethod? = nil,
        authorizationParameters: [String: String]? = nil,
        tokenParameters: [String: String]? = nil,
        form: ExtensionFormSchema? = nil
    ) {
        self.mode = mode
        self.authorizationURL = authorizationURL
        self.tokenURL = tokenURL
        self.callbackScheme = callbackScheme
        self.callbackURL = callbackURL
        self.clientID = clientID
        self.clientIDInfoPlistKey = clientIDInfoPlistKey
        self.responseType = responseType
        self.scopes = scopes
        self.pkceMethod = pkceMethod
        self.authorizationParameters = authorizationParameters
        self.tokenParameters = tokenParameters
        self.form = form
    }
}

public protocol TrackerAuthenticationProviding: TrackerProvider {
    func authentication() async throws -> TrackerAuthenticationDescriptor
}

public struct TrackerCollection: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var items: [TrackerMatch]

    public init(id: String, title: String, items: [TrackerMatch]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

public protocol TrackerCollectionProviding: TrackerProvider {
    func collections(cursor: SourceCursor?) async throws -> SourcePage<TrackerCollection>
}
