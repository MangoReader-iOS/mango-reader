import Foundation

public struct WorkID: RawRepresentable, Codable, Hashable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct InstallmentID: RawRepresentable, Codable, Hashable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct SourceID: RawRepresentable, Codable, Hashable, Sendable, Identifiable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public var id: String { rawValue }
    public var description: String { rawValue }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }

    public static let local: Self = "local"
    public static let opds: Self = "opds"
    public static let komga: Self = "komga"
    public static let kavita: Self = "kavita"
    public static let suwayomi: Self = "suwayomi"
}

public struct TrackerID: RawRepresentable, Codable, Hashable, Sendable, Identifiable, ExpressibleByStringLiteral {
    public let rawValue: String
    public var id: String { rawValue }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }
}

