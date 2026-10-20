import CoreGraphics
import UIKit

/// Scene-local geometry. A division can exist even when the inner display is flat.
public struct ReaderViewport: Hashable, Sendable {
    public var size: CGSize
    public var division: CGRect?
    public var occlusions: [CGRect]
    public var divisionIsActive: Bool

    public init(size: CGSize, division: CGRect? = nil, divisionIsActive: Bool = false, occlusions: [CGRect] = []) {
        self.size = size
        self.division = division
        self.divisionIsActive = divisionIsActive
        self.occlusions = occlusions
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(size.width); hasher.combine(size.height)
        hasher.combine(division?.minX); hasher.combine(division?.minY)
        hasher.combine(division?.width); hasher.combine(division?.height)
        hasher.combine(divisionIsActive)
        for rect in occlusions {
            hasher.combine(rect.minX); hasher.combine(rect.minY)
            hasher.combine(rect.width); hasher.combine(rect.height)
        }
    }

    public var isExpanded: Bool { division != nil }
    public var supportsSpread: Bool {
        guard let division, division.height > division.width else { return false }
        return division.minX >= 280 && size.width - division.maxX >= 280
    }
    public var bounds: CGRect { CGRect(origin: .zero, size: size) }
    public var unobscuredBounds: CGRect { avoidingOcclusions(bounds) }
    public var readingRegion: CGRect {
        guard let division else { return unobscuredBounds }
        if division.height > division.width {
            return avoidingOcclusions(CGRect(x: division.maxX, y: 0, width: max(0, size.width - division.maxX), height: size.height))
        }
        // A horizontal fold leaves the upper region available for reading.
        return avoidingOcclusions(CGRect(x: 0, y: 0, width: size.width, height: max(0, division.minY)))
    }
    public var companionRegion: CGRect {
        guard let division, supportsSpread else { return bounds }
        return avoidingOcclusions(CGRect(x: 0, y: 0, width: division.minX, height: size.height))
    }

    public func avoidingOcclusions(_ rect: CGRect) -> CGRect {
        occlusions.reduce(rect) { available, occlusion in
            let intersection = available.intersection(occlusion)
            guard !intersection.isNull, !intersection.isEmpty else { return available }
            let candidates = [
                CGRect(x: available.minX, y: available.minY, width: available.width, height: intersection.minY - available.minY),
                CGRect(x: available.minX, y: intersection.maxY, width: available.width, height: available.maxY - intersection.maxY),
                CGRect(x: available.minX, y: available.minY, width: intersection.minX - available.minX, height: available.height),
                CGRect(x: intersection.maxX, y: available.minY, width: available.maxX - intersection.maxX, height: available.height)
            ]
            return candidates.max { $0.width * $0.height < $1.width * $1.height } ?? available
        }
    }

    @MainActor static func measure(_ view: UIView) -> Self {
        var result = Self(size: view.bounds.size)
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            result.occlusions = view.reservedRegions(kind: .occlusion).map(\.frame)
            if let region = view.reservedRegions(kind: .division, options: .includeInactive).first {
                // A split-view window may not span the hinge at all.
                let frame = region.frame
                let vertical = frame.height > frame.width
                if vertical ? (frame.minX > 0 && frame.maxX < view.bounds.width)
                    : (frame.minY > 0 && frame.maxY < view.bounds.height) {
                    result.division = frame
                    result.divisionIsActive = region.isActive
                }
            }
        }
        #endif
        return result
    }
}
