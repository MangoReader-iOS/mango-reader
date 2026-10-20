import Foundation

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct AppStatusMessage: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let systemImage: String
}

enum SourceMigrationApplicationError: LocalizedError {
    case sameSource
    case unsupportedLocalSource
    case sourceUnavailable
    case libraryUnavailable
    case inconsistentWork
    case notInLibrary
    case ambiguousMatches(Int)
    case alreadyApplying
    case noReadyMigrations
    case invalidBulkPreview

    var errorDescription: String? {
        switch self {
        case .sameSource:
            "Choose a different source for this title."
        case .unsupportedLocalSource:
            "Source migration is available only between configured remote sources."
        case .sourceUnavailable:
            "The selected source is disabled or no longer configured."
        case .libraryUnavailable:
            "The local library is not ready yet."
        case .inconsistentWork:
            "The migration preview no longer matches this title. Create a new preview and try again."
        case .notInLibrary:
            "Add this title to the library before migrating it."
        case let .ambiguousMatches(count):
            "Resolve the \(count) ambiguous installment match\(count == 1 ? "" : "es") before migrating."
        case .alreadyApplying:
            "Another bulk source migration is still being applied."
        case .noReadyMigrations:
            "No titles have a unique, safe migration match to apply."
        case .invalidBulkPreview:
            "The migration preview is inconsistent. Create a new preview and try again."
        }
    }
}
