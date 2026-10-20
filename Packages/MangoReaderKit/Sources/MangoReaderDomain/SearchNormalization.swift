import Foundation

public extension String {
    var mangoReaderSearchNormalized: String {
        let compatibility = precomposedStringWithCompatibilityMapping
        return compatibility
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? compatibility.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

