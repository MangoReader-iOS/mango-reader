import Foundation
import MankoDomain

public enum ReaderError: Error, Hashable, Sendable, LocalizedError {
    case unsupportedFormat(PublicationFormat)
    case missingLocalFile
    case invalidFileURL
    case fileNotFound
    case unreadableFile
    case formatMismatch(expected: PublicationFormat, detected: PublicationFormat?)
    case malformedPublication(String)
    case unsafeArchivePath(String)
    case archiveLimitExceeded(String)
    case noReadableImages
    case pageIndexOutOfRange(Int)
    case emptyImagePage(Int)
    case imagePageTooLarge(Int)
    case imageDecodeFailed(String)
    case unsupportedReadiumLCP
    case unsupportedAdobeDRM
    case passwordProtectedPDF
    case unsupportedProtection(PublicationProtection)
    case invalidLocator
    case readiumOpenFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(format):
            "The \(format.rawValue) format is not supported by this reader."
        case .missingLocalFile:
            "This publication does not have a local file."
        case .invalidFileURL:
            "The publication must be opened from a local file URL."
        case .fileNotFound:
            "The publication file could not be found."
        case .unreadableFile:
            "The publication file could not be read."
        case let .formatMismatch(expected, detected):
            if let detected {
                "Expected \(expected.rawValue), but the file contains \(detected.rawValue) content."
            } else {
                "The file does not contain valid \(expected.rawValue) content."
            }
        case let .malformedPublication(reason):
            "The publication is malformed: \(reason)"
        case let .unsafeArchivePath(path):
            "The publication contains an unsafe archive path: \(path)"
        case let .archiveLimitExceeded(reason):
            "The publication archive exceeds a safety limit: \(reason)"
        case .noReadableImages:
            "The comic archive does not contain any supported images."
        case let .pageIndexOutOfRange(index):
            "Page \(index + 1) is outside this publication."
        case let .emptyImagePage(index):
            "Page \(index + 1) did not contain image data."
        case let .imagePageTooLarge(index):
            "Page \(index + 1) exceeds the reader's image size limit."
        case let .imageDecodeFailed(path):
            "The image at \(path) could not be decoded."
        case .unsupportedReadiumLCP:
            "Readium LCP-protected publications are not supported."
        case .unsupportedAdobeDRM:
            "Adobe DRM-protected publications are not supported."
        case .passwordProtectedPDF:
            "Password-protected PDFs are not supported."
        case let .unsupportedProtection(protection):
            "The publication protection \(protection.rawValue) is not supported."
        case .invalidLocator:
            "The saved reading position is not valid Readium locator JSON."
        case let .readiumOpenFailed(reason):
            "Readium could not open the publication: \(reason)"
        }
    }
}
