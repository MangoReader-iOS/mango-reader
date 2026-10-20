import Foundation
import MangoReaderDomain

/// Where a compiled filter is allowed to be selected.
///
/// Configuration values are persisted with a user-added server and become its
/// defaults. Query values are ephemeral and may override those defaults for a
/// single browse/search request. Neither form contains code or an expression
/// language.
public enum SourceFilterScope: String, Codable, Hashable, Sendable {
    case configuration
    case query
    case configurationAndQuery

    fileprivate func includes(_ requested: SourceFilterScope) -> Bool {
        switch (self, requested) {
        case (.configurationAndQuery, .configuration), (.configurationAndQuery, .query):
            true
        default:
            self == requested
        }
    }
}

public enum SourceFilterValueKind: String, Codable, Hashable, Sendable {
    case choice
    case opaqueIdentifier
    case positiveInteger
    case nonnegativeInteger
}

public struct SourceFilterOption: Codable, Hashable, Sendable, Identifiable {
    public var value: String
    public var title: String

    public var id: String { value }

    public init(value: String, title: String) {
        self.value = value
        self.title = title
    }
}

/// A displayable, data-only contract for one setting supported by Mango Reader's
/// compiled source adapters.
public struct SourceFilterDefinition: Codable, Hashable, Sendable, Identifiable {
    public var sourceKind: SourceKind
    public var key: String
    public var title: String
    public var help: String
    public var scope: SourceFilterScope
    public var valueKind: SourceFilterValueKind
    public var options: [SourceFilterOption]
    public var defaultValue: String?
    public var isRequired: Bool

    public var id: String { "\(sourceKind.rawValue).\(key)" }

    public init(
        sourceKind: SourceKind,
        key: String,
        title: String,
        help: String,
        scope: SourceFilterScope,
        valueKind: SourceFilterValueKind,
        options: [SourceFilterOption] = [],
        defaultValue: String? = nil,
        isRequired: Bool = false
    ) {
        self.sourceKind = sourceKind
        self.key = key
        self.title = title
        self.help = help
        self.scope = scope
        self.valueKind = valueKind
        self.options = options
        self.defaultValue = defaultValue
        self.isRequired = isRequired
    }
}

public enum SourceFilterValidationError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedSource(SourceKind)
    case unknownKey(source: SourceKind, key: String)
    case unavailableInScope(source: SourceKind, key: String, scope: SourceFilterScope, title: String)
    case missingRequiredValue(source: SourceKind, key: String, title: String)
    case invalidValue(source: SourceKind, key: String, title: String)
    case tooManySelections(source: SourceKind)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSource(source):
            "\(source.rawValue) does not have compiled remote-source filters."
        case let .unknownKey(source, key):
            "\(source.rawValue) does not support the filter ‘\(key)’."
        case let .unavailableInScope(_, _, _, title):
            title
        case let .missingRequiredValue(_, _, title):
            "Enter \(title.lowercased())."
        case let .invalidValue(_, _, title):
            "Choose a valid value for \(title.lowercased())."
        case let .tooManySelections(source):
            "Too many \(source.rawValue) filter values were supplied."
        }
    }
}

// Strongly typed keys and values keep source request construction independent
// from user-entered strings. Raw values are persisted only for Codable and UI
// interoperability.
public enum OPDSFilterKey: String, Codable, CaseIterable, Sendable {
    case order
}

public enum OPDSCatalogOrder: String, Codable, CaseIterable, Sendable {
    case feed
    case titleAscending
    case titleDescending
}

public enum KomgaFilterKey: String, Codable, CaseIterable, Sendable {
    case libraryID
    case sort
}

public enum KomgaSeriesSort: String, Codable, CaseIterable, Sendable {
    case titleAscending = "metadata.titleSort,asc"
    case titleDescending = "metadata.titleSort,desc"
}

public enum KavitaFilterKey: String, Codable, CaseIterable, Sendable {
    case libraryID
    case sort
}

public enum KavitaSeriesSort: String, Codable, CaseIterable, Sendable {
    case titleAscending
    case titleDescending
}

public enum SuwayomiFilterKey: String, Codable, CaseIterable, Sendable {
    case sourceID
    case listing
}

public enum SuwayomiListing: String, Codable, CaseIterable, Sendable {
    case popular = "POPULAR"
    case latest = "LATEST"
}

enum CompiledSourceFilterApplication {
    /// Applies OPDS ordering to exactly the already-fetched page. It does not
    /// claim to reorder entries across server pagination boundaries.
    static func orderedOPDSPage(_ works: [Work], order: OPDSCatalogOrder) -> [Work] {
        guard order != .feed else { return works }
        return works.enumerated().sorted { left, right in
            let comparison = left.element.title.localizedStandardCompare(right.element.title)
            if comparison == .orderedSame { return left.offset < right.offset }
            return order == .titleAscending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }.map(\.element)
    }
}

/// The complete, auditable source-filter surface shipped in the app binary.
/// User catalogs can select values from this registry; they cannot add fields,
/// scripts, predicates, or provider implementations.
public struct CompiledSourceFilterCatalog: Sendable {
    public static let shared = CompiledSourceFilterCatalog()

    private static let maximumValueLength = 256

    private let definitionsByKind: [SourceKind: [SourceFilterDefinition]]

    public init() {
        definitionsByKind = [
            .opds: [
                SourceFilterDefinition(
                    sourceKind: .opds,
                    key: OPDSFilterKey.order.rawValue,
                    title: "Current page order",
                    help: "Keep the feed order or sort only the current feed page by title on this device.",
                    scope: .configurationAndQuery,
                    valueKind: .choice,
                    options: [
                        SourceFilterOption(value: OPDSCatalogOrder.feed.rawValue, title: "Feed order"),
                        SourceFilterOption(value: OPDSCatalogOrder.titleAscending.rawValue, title: "Title A–Z"),
                        SourceFilterOption(value: OPDSCatalogOrder.titleDescending.rawValue, title: "Title Z–A"),
                    ],
                    defaultValue: OPDSCatalogOrder.feed.rawValue
                ),
            ],
            .komga: [
                SourceFilterDefinition(
                    sourceKind: .komga,
                    key: KomgaFilterKey.libraryID.rawValue,
                    title: "Library ID",
                    help: "Optionally limit this connection to one Komga library identifier.",
                    scope: .configurationAndQuery,
                    valueKind: .opaqueIdentifier
                ),
                SourceFilterDefinition(
                    sourceKind: .komga,
                    key: KomgaFilterKey.sort.rawValue,
                    title: "Series order",
                    help: "Choose the title order sent to Komga.",
                    scope: .configurationAndQuery,
                    valueKind: .choice,
                    options: [
                        SourceFilterOption(value: KomgaSeriesSort.titleAscending.rawValue, title: "Title A–Z"),
                        SourceFilterOption(value: KomgaSeriesSort.titleDescending.rawValue, title: "Title Z–A"),
                    ],
                    defaultValue: KomgaSeriesSort.titleAscending.rawValue
                ),
            ],
            .kavita: [
                SourceFilterDefinition(
                    sourceKind: .kavita,
                    key: KavitaFilterKey.libraryID.rawValue,
                    title: "Library ID",
                    help: "Optionally limit this connection to one numeric Kavita library identifier.",
                    scope: .configurationAndQuery,
                    valueKind: .positiveInteger
                ),
                SourceFilterDefinition(
                    sourceKind: .kavita,
                    key: KavitaFilterKey.sort.rawValue,
                    title: "Series order",
                    help: "Choose the title order sent to Kavita.",
                    scope: .configurationAndQuery,
                    valueKind: .choice,
                    options: [
                        SourceFilterOption(value: KavitaSeriesSort.titleAscending.rawValue, title: "Title A–Z"),
                        SourceFilterOption(value: KavitaSeriesSort.titleDescending.rawValue, title: "Title Z–A"),
                    ],
                    defaultValue: KavitaSeriesSort.titleAscending.rawValue
                ),
            ],
            .suwayomi: [
                SourceFilterDefinition(
                    sourceKind: .suwayomi,
                    key: SuwayomiFilterKey.sourceID.rawValue,
                    title: "Suwayomi source ID",
                    help: "Enter the numeric ID of a source already installed on your server. Mango Reader never downloads or executes server extensions.",
                    scope: .configuration,
                    valueKind: .nonnegativeInteger,
                    isRequired: true
                ),
                SourceFilterDefinition(
                    sourceKind: .suwayomi,
                    key: SuwayomiFilterKey.listing.rawValue,
                    title: "Browse listing",
                    help: "Choose the compiled Suwayomi listing used when browsing without search text.",
                    scope: .configurationAndQuery,
                    valueKind: .choice,
                    options: [
                        SourceFilterOption(value: SuwayomiListing.popular.rawValue, title: "Popular"),
                        SourceFilterOption(value: SuwayomiListing.latest.rawValue, title: "Latest"),
                    ],
                    defaultValue: SuwayomiListing.popular.rawValue
                ),
            ],
        ]
    }

    public func definitions(
        for source: SourceKind,
        scope: SourceFilterScope? = nil
    ) -> [SourceFilterDefinition] {
        let definitions = definitionsByKind[source] ?? []
        guard let scope else { return definitions }
        return definitions.filter { $0.scope.includes(scope) }
    }

    public func defaultSelections(
        for source: SourceKind,
        scope: SourceFilterScope
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: definitions(for: source, scope: scope).compactMap { definition in
            definition.defaultValue.map { (definition.key, $0) }
        })
    }

    /// Validates and canonicalizes a set of data-only selections.
    ///
    /// Unknown keys are rejected instead of being forwarded to a server. Blank
    /// optional identifiers are omitted. Choice matching is case-insensitive,
    /// but the returned value always uses the compiled canonical spelling.
    public func normalize(
        _ selections: [String: String],
        for source: SourceKind,
        scope: SourceFilterScope
    ) throws -> [String: String] {
        guard let allDefinitions = definitionsByKind[source] else {
            throw SourceFilterValidationError.unsupportedSource(source)
        }
        guard selections.count <= allDefinitions.count else {
            throw SourceFilterValidationError.tooManySelections(source: source)
        }

        let indexed = Dictionary(uniqueKeysWithValues: allDefinitions.map { ($0.key, $0) })
        var result: [String: String] = [:]

        for (key, rawValue) in selections {
            guard let definition = indexed[key] else {
                throw SourceFilterValidationError.unknownKey(source: source, key: key)
            }
            guard definition.scope.includes(scope) else {
                throw SourceFilterValidationError.unavailableInScope(
                    source: source,
                    key: key,
                    scope: scope,
                    title: "\(definition.title) cannot be changed for this request."
                )
            }
            if let value = try normalize(rawValue, definition: definition) {
                result[key] = value
            }
        }

        if scope == .configuration {
            for definition in allDefinitions where definition.scope.includes(.configuration) && definition.isRequired {
                guard result[definition.key] != nil else {
                    throw SourceFilterValidationError.missingRequiredValue(
                        source: source,
                        key: definition.key,
                        title: definition.title
                    )
                }
            }
        }
        return result
    }

    public func normalizedQuery(_ query: SourceQuery, for source: SourceKind) throws -> SourceQuery {
        var normalized = query
        normalized.filters = try normalize(query.filters, for: source, scope: .query)
        return normalized
    }

    /// Resolves a query selection over a persisted default, validating both at
    /// their respective scopes. Callers receive only a canonical compiled value.
    public func resolvedValue(
        key: String,
        source: SourceKind,
        querySelections: [String: String],
        configurationSelections: [String: String]
    ) throws -> String? {
        let query = try normalize(querySelections, for: source, scope: .query)
        if let value = query[key] { return value }

        let relevantConfiguration = configurationSelections.filter { candidate, _ in
            definitionsByKind[source]?.contains(where: { $0.key == candidate && $0.scope.includes(.configuration) }) == true
        }
        return try normalize(relevantConfiguration, for: source, scope: .configuration)[key]
    }

    private func normalize(
        _ rawValue: String,
        definition: SourceFilterDefinition
    ) throws -> String? {
        guard rawValue.count <= Self.maximumValueLength else {
            throw invalid(definition)
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            if definition.isRequired { throw missing(definition) }
            return nil
        }

        switch definition.valueKind {
        case .choice:
            guard let option = definition.options.first(where: {
                $0.value.compare(value, options: [.caseInsensitive, .literal]) == .orderedSame
            }) else {
                throw invalid(definition)
            }
            return option.value
        case .opaqueIdentifier:
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:")
            guard value.unicodeScalars.allSatisfy(allowed.contains) else {
                throw invalid(definition)
            }
            return value
        case .positiveInteger, .nonnegativeInteger:
            guard let number = UInt64(value), number <= UInt64(Int.max),
                  definition.valueKind == .nonnegativeInteger || number > 0 else {
                throw invalid(definition)
            }
            return String(number)
        }
    }

    private func invalid(_ definition: SourceFilterDefinition) -> SourceFilterValidationError {
        .invalidValue(source: definition.sourceKind, key: definition.key, title: definition.title)
    }

    private func missing(_ definition: SourceFilterDefinition) -> SourceFilterValidationError {
        .missingRequiredValue(source: definition.sourceKind, key: definition.key, title: definition.title)
    }
}
