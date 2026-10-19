import Foundation

/// An explicit field operation used by bulk metadata edits. `preserve` keeps
/// the stored value, while `set` also permits intentional empty arrays.
public enum BulkMetadataFieldUpdate<Value>: Codable, Hashable, Sendable
where Value: Codable & Hashable & Sendable {
    case preserve
    case set(Value)

    private enum CodingKeys: String, CodingKey {
        case operation
        case value
    }

    private enum Operation: String, Codable {
        case preserve
        case set
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Operation.self, forKey: .operation) {
        case .preserve:
            self = .preserve
        case .set:
            self = .set(try container.decode(Value.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .preserve:
            try container.encode(Operation.preserve, forKey: .operation)
        case let .set(value):
            try container.encode(Operation.set, forKey: .operation)
            try container.encode(value, forKey: .value)
        }
    }
}

public enum BulkMetadataEditableField: String, Codable, CaseIterable, Sendable {
    case contentKind
    case workStatus
    case authors
    case tags
}

/// Fixed limits keep user-authored metadata bounded before it reaches SQLite,
/// FTS, backups, or cloud synchronization.
public enum BulkMetadataInputLimits {
    public static let maximumAuthors = 64
    public static let maximumTags = 128
    public static let maximumCharactersPerValue = 200
    public static let maximumUTF8BytesPerValue = 1_024
    public static let maximumAuthorCharacters = 4_096
    public static let maximumTagCharacters = 8_192
}

public enum BulkMetadataPatchValidationError: Error, Equatable, Sendable, LocalizedError {
    case noFieldsSelected
    case tooManyValues(field: BulkMetadataEditableField, count: Int, maximum: Int)
    case valueTooLong(
        field: BulkMetadataEditableField,
        index: Int,
        characterCount: Int,
        maximum: Int
    )
    case valueTooLarge(
        field: BulkMetadataEditableField,
        index: Int,
        byteCount: Int,
        maximumBytes: Int
    )
    case totalTextTooLong(
        field: BulkMetadataEditableField,
        characterCount: Int,
        maximum: Int
    )
    case unsupportedControlCharacter(field: BulkMetadataEditableField, index: Int)

    public var errorDescription: String? {
        switch self {
        case .noFieldsSelected:
            "Choose at least one metadata field to edit."
        case let .tooManyValues(field, count, maximum):
            "The \(field.displayName) list has \(count) values; the maximum is \(maximum)."
        case let .valueTooLong(field, index, characterCount, maximum):
            "Value \(index + 1) in \(field.displayName) has \(characterCount) characters; the maximum is \(maximum)."
        case let .valueTooLarge(field, index, byteCount, maximumBytes):
            "Value \(index + 1) in \(field.displayName) uses \(byteCount) bytes; the maximum is \(maximumBytes)."
        case let .totalTextTooLong(field, characterCount, maximum):
            "The \(field.displayName) list has \(characterCount) characters; the maximum is \(maximum)."
        case let .unsupportedControlCharacter(field, index):
            "Value \(index + 1) in \(field.displayName) contains an unsupported control character."
        }
    }
}

public extension BulkMetadataEditableField {
    var displayName: String {
        switch self {
        case .contentKind: "content kind"
        case .workStatus: "work status"
        case .authors: "authors"
        case .tags: "tags"
        }
    }
}

/// A validated, Codable description of one bulk edit. Every field records an
/// explicit operation so audit/export code never has to infer whether a value
/// was intentionally cleared or merely omitted.
public struct BulkWorkMetadataPatch: Codable, Hashable, Sendable {
    public let contentKind: BulkMetadataFieldUpdate<ContentKind>
    public let workStatus: BulkMetadataFieldUpdate<WorkStatus>
    public let authors: BulkMetadataFieldUpdate<[String]>
    public let tags: BulkMetadataFieldUpdate<[String]>

    public init(
        contentKind: BulkMetadataFieldUpdate<ContentKind> = .preserve,
        workStatus: BulkMetadataFieldUpdate<WorkStatus> = .preserve,
        authors: BulkMetadataFieldUpdate<[String]> = .preserve,
        tags: BulkMetadataFieldUpdate<[String]> = .preserve
    ) throws {
        guard [
            contentKind.isSet,
            workStatus.isSet,
            authors.isSet,
            tags.isSet,
        ].contains(true) else {
            throw BulkMetadataPatchValidationError.noFieldsSelected
        }

        self.contentKind = contentKind
        self.workStatus = workStatus
        self.authors = try Self.normalizedList(
            authors,
            field: .authors,
            maximumCount: BulkMetadataInputLimits.maximumAuthors,
            maximumTotalCharacters: BulkMetadataInputLimits.maximumAuthorCharacters
        )
        self.tags = try Self.normalizedList(
            tags,
            field: .tags,
            maximumCount: BulkMetadataInputLimits.maximumTags,
            maximumTotalCharacters: BulkMetadataInputLimits.maximumTagCharacters
        )
    }

    public var changedFields: [BulkMetadataEditableField] {
        var result: [BulkMetadataEditableField] = []
        if contentKind.isSet { result.append(.contentKind) }
        if workStatus.isSet { result.append(.workStatus) }
        if authors.isSet { result.append(.authors) }
        if tags.isSet { result.append(.tags) }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case contentKind
        case workStatus
        case authors
        case tags
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            contentKind: try container.decodeIfPresent(
                BulkMetadataFieldUpdate<ContentKind>.self,
                forKey: .contentKind
            ) ?? .preserve,
            workStatus: try container.decodeIfPresent(
                BulkMetadataFieldUpdate<WorkStatus>.self,
                forKey: .workStatus
            ) ?? .preserve,
            authors: try container.decodeIfPresent(
                BulkMetadataFieldUpdate<[String]>.self,
                forKey: .authors
            ) ?? .preserve,
            tags: try container.decodeIfPresent(
                BulkMetadataFieldUpdate<[String]>.self,
                forKey: .tags
            ) ?? .preserve
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contentKind, forKey: .contentKind)
        try container.encode(workStatus, forKey: .workStatus)
        try container.encode(authors, forKey: .authors)
        try container.encode(tags, forKey: .tags)
    }

    private static func normalizedList(
        _ operation: BulkMetadataFieldUpdate<[String]>,
        field: BulkMetadataEditableField,
        maximumCount: Int,
        maximumTotalCharacters: Int
    ) throws -> BulkMetadataFieldUpdate<[String]> {
        guard case let .set(values) = operation else { return .preserve }
        guard values.count <= maximumCount else {
            throw BulkMetadataPatchValidationError.tooManyValues(
                field: field,
                count: values.count,
                maximum: maximumCount
            )
        }

        var normalizedValues: [String] = []
        var seenKeys: Set<String> = []
        var totalCharacters = 0

        for (index, value) in values.enumerated() {
            let inputByteCount = value.utf8.count
            guard inputByteCount <= BulkMetadataInputLimits.maximumUTF8BytesPerValue else {
                throw BulkMetadataPatchValidationError.valueTooLarge(
                    field: field,
                    index: index,
                    byteCount: inputByteCount,
                    maximumBytes: BulkMetadataInputLimits.maximumUTF8BytesPerValue
                )
            }
            let normalized = value
                .precomposedStringWithCanonicalMapping
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !normalized.isEmpty else { continue }
            guard !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw BulkMetadataPatchValidationError.unsupportedControlCharacter(
                    field: field,
                    index: index
                )
            }

            let characterCount = normalized.count
            guard characterCount <= BulkMetadataInputLimits.maximumCharactersPerValue else {
                throw BulkMetadataPatchValidationError.valueTooLong(
                    field: field,
                    index: index,
                    characterCount: characterCount,
                    maximum: BulkMetadataInputLimits.maximumCharactersPerValue
                )
            }

            let deduplicationKey = normalized
                .precomposedStringWithCompatibilityMapping
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                .lowercased()
            guard seenKeys.insert(deduplicationKey).inserted else { continue }

            totalCharacters += characterCount
            guard totalCharacters <= maximumTotalCharacters else {
                throw BulkMetadataPatchValidationError.totalTextTooLong(
                    field: field,
                    characterCount: totalCharacters,
                    maximum: maximumTotalCharacters
                )
            }
            normalizedValues.append(normalized)
        }

        return .set(normalizedValues)
    }
}

public struct BulkMetadataUpdateResult: Codable, Hashable, Sendable {
    public let updatedIDs: [WorkID]
    public let missingIDs: [WorkID]

    public init(updatedIDs: [WorkID], missingIDs: [WorkID]) {
        self.updatedIDs = updatedIDs.sorted(by: Self.areOrdered)
        self.missingIDs = missingIDs.sorted(by: Self.areOrdered)
    }

    private enum CodingKeys: String, CodingKey {
        case updatedIDs
        case missingIDs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            updatedIDs: try container.decode([WorkID].self, forKey: .updatedIDs),
            missingIDs: try container.decode([WorkID].self, forKey: .missingIDs)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(updatedIDs, forKey: .updatedIDs)
        try container.encode(missingIDs, forKey: .missingIDs)
    }

    private static func areOrdered(_ lhs: WorkID, _ rhs: WorkID) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

private extension BulkMetadataFieldUpdate {
    var isSet: Bool {
        if case .set = self { true } else { false }
    }
}
