import MankoDomain

/// Loading and initial layout are not reading activity. Ignore callbacks until
/// restoration finishes, including duplicate callbacks for its final locator.
public struct ReaderProgressRestorationGate: Sendable {
    public private(set) var isRestoring = true
    public private(set) var restoredLocator: ReadingLocator?
    private var hasMoved = false

    public init() {}

    public mutating func begin() {
        isRestoring = true
        restoredLocator = nil
        hasMoved = false
    }

    public mutating func complete(at locator: ReadingLocator?) {
        restoredLocator = locator
        isRestoring = false
        hasMoved = false
    }

    public mutating func accepts(_ locator: ReadingLocator) -> Bool {
        guard !isRestoring else { return false }
        guard hasMoved || locator != restoredLocator else { return false }
        hasMoved = true
        return true
    }
}
