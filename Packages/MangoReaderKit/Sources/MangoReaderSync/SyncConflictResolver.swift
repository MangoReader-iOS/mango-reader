import Foundation
import MangoReaderDomain

public struct SyncValue<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var id: UUID
    public var value: Value
    public var modifiedAt: Date
    public var deviceID: String

    public init(id: UUID, value: Value, modifiedAt: Date, deviceID: String) {
        self.id = id
        self.value = value
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
    }
}

public enum SyncConflictResolver {
    public static func latest<Value>(_ lhs: SyncValue<Value>, _ rhs: SyncValue<Value>) -> SyncValue<Value> {
        precondition(lhs.id == rhs.id)
        if lhs.modifiedAt == rhs.modifiedAt {
            return lhs.deviceID >= rhs.deviceID ? lhs : rhs
        }
        return lhs.modifiedAt > rhs.modifiedAt ? lhs : rhs
    }

    public static func readingProgress(_ lhs: ReadingProgress, _ rhs: ReadingProgress) -> ReadingProgress {
        lhs.merging(rhs)
    }

    public static func annotation(_ lhs: Annotation, _ rhs: Annotation) -> Annotation {
        precondition(lhs.id == rhs.id)
        return lhs.modifiedAt >= rhs.modifiedAt ? lhs : rhs
    }

    public static func shouldDelete(modifiedAt: Date, tombstone: Tombstone) -> Bool {
        tombstone.deletedAt >= modifiedAt
    }
}
