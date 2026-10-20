import MangoReaderDomain
import MangoReaderReaders
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ReaderToolAvailability: Equatable {
    let canAnnotate: Bool
    let showsContents: Bool
    let showsPDFThumbnails: Bool
    let showsSearch: Bool
    let showsTextToSpeech: Bool
    let showsTypography: Bool
    let showsImageSettings: Bool

    var showsNavigationTools: Bool {
        showsContents || showsPDFThumbnails || showsSearch || showsTextToSpeech
    }

    var showsSettings: Bool {
        showsTypography || showsImageSettings
    }

    static func resolve(
        format: PublicationFormat,
        hasLocator: Bool,
        isPublicationReady: Bool,
        isPDFThumbnailNavigationAvailable: Bool,
        isSearchable: Bool,
        isTTSSupported: Bool
    ) -> Self {
        Self(
            canAnnotate: hasLocator,
            showsContents: isPublicationReady,
            showsPDFThumbnails: format == .pdf && isPDFThumbnailNavigationAvailable,
            showsSearch: isSearchable,
            showsTextToSpeech: isTTSSupported,
            showsTypography: format == .epub && isPublicationReady,
            showsImageSettings: format == .cbz || format == .remoteImageSequence
        )
    }
}

enum ReaderBookmarkTogglePolicy {
    static func bookmark(
        at locator: ReadingLocator?,
        in bookmarks: [Bookmark]
    ) -> Bookmark? {
        guard let locator else { return nil }
        return bookmarks.first { $0.locator == locator }
    }
}

enum ReaderImageTapZonePolicy {
    static func configuration(
        direction: ImageReadingDirection,
        leadingAction: String,
        trailingAction: String
    ) -> TapZoneConfiguration {
        let standard = TapZoneConfiguration.standard(direction: direction)
        return TapZoneConfiguration(
            leading: ReaderTapAction(rawValue: leadingAction) ?? standard.action(for: .middleLeading),
            center: .toggleControls,
            trailing: ReaderTapAction(rawValue: trailingAction) ?? standard.action(for: .middleTrailing)
        )
    }
}

enum ReaderHeaderTitlePolicy {
    nonisolated static func usesCombinedLine(for dynamicTypeSize: DynamicTypeSize) -> Bool {
        switch dynamicTypeSize {
        case .xSmall, .small, .medium, .large:
            false
        default:
            true
        }
    }

    nonisolated static func combinedTitle(workTitle: String, installmentTitle: String) -> String {
        "\(workTitle) — \(installmentTitle)"
    }
}

enum ReaderPublicationRecoveryPresentation: Equatable {
    case missingImport
    case missingDownload
    case streamFailure

    var title: String {
        switch self {
        case .missingImport: "File Not Found"
        case .missingDownload: "Download Missing"
        case .streamFailure: "Unable to Load"
        }
    }

    var message: String? {
        switch self {
        case .missingImport: "Choose the original file to reconnect it."
        case .missingDownload: "Download it again to continue reading."
        case .streamFailure: nil
        }
    }

    var actionTitle: String {
        switch self {
        case .missingImport: "Choose File"
        case .missingDownload: "Download Again"
        case .streamFailure: "Retry"
        }
    }
}

enum ReaderDownloadRecoveryPolicy {
    enum Resolution: Equatable {
        case waiting
        case ready
        case failed
    }

    static func resolution(
        state: DownloadState?,
        downloadedFileExists: Bool
    ) -> Resolution {
        switch state {
        case .completed:
            downloadedFileExists ? .ready : .failed
        case .failed, .cancelled:
            .failed
        case .queued, .downloading, .paused, nil:
            .waiting
        }
    }
}

enum ReaderContentAvailability: Hashable {
    case loading
    case ready
    case unavailable
}

enum ReaderControlsVisibilityPolicy {
    static func mustRemainVisible(
        contentAvailability: ReaderContentAvailability,
        voiceOverEnabled: Bool,
        switchControlEnabled: Bool,
        imageGesturesUnavailable: Bool
    ) -> Bool {
        contentAvailability != .ready || voiceOverEnabled || switchControlEnabled || imageGesturesUnavailable
    }
}
