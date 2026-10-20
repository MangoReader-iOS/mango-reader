import Foundation

/// Stable block indices do not depend on the network chunk boundaries or viewport.
public struct ProgressivePublicationBlock: Codable, Hashable, Sendable, Identifiable {
    public var index: Int
    public var html: String
    public var text: String
    public var heading: String?
    public var id: String { "block-\(index)" }
    public init(index: Int, html: String, text: String, heading: String? = nil) {
        self.index = index; self.html = html; self.text = text; self.heading = heading
    }
}

public struct ProgressivePublicationSnapshot: Codable, Hashable, Sendable {
    public var version = 1
    public var workID: String
    public var volumeID: String
    public var blocks: [ProgressivePublicationBlock]
    public var complete: Bool
    public init(workID: String, volumeID: String, blocks: [ProgressivePublicationBlock], complete: Bool) {
        self.workID = workID; self.volumeID = volumeID; self.blocks = blocks; self.complete = complete
    }
    public func validates(workID: String, volumeID: String) -> Bool {
        version == 1 && self.workID == workID && self.volumeID == volumeID && !blocks.isEmpty
            && blocks.enumerated().allSatisfy { $0.offset == $0.element.index }
    }
}
