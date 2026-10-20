import Foundation
import ImageIO
import MangoReaderData
import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSources
import MangoReaderSync
import Observation
import OSLog
import SwiftUI
import WebKit

enum AppBootstrapPhase: Equatable {
    case idle
    case loading
    case ready
    case failed

    var isReadyForInteraction: Bool {
        self == .ready
    }

    var presentation: AppStartupPresentation {
        switch self {
        case .idle, .loading: .loading
        case .ready: .content
        case .failed: .failure
        }
    }
}

enum AppStartupPresentation: Equatable {
    case loading
    case content
    case failure
}

enum BackupOperation: String {
    case preparingExport = "Preparing backup…"
    case inspecting = "Inspecting backup…"
    case restoring = "Restoring backup…"
}

enum DownloadEnqueueOutcome: Equatable, Sendable {
    case queued
    case alreadyAvailable
    case failed(String)
    case cancelled
}

struct DownloadBatchResult: Equatable, Sendable {
    var queuedCount = 0
    var alreadyAvailableCount = 0
    var failedCount = 0
    var cancelledCount = 0
    var firstFailure: String?

    var isSuccessful: Bool { failedCount == 0 && cancelledCount == 0 }

    mutating func record(_ outcome: DownloadEnqueueOutcome) {
        switch outcome {
        case .queued: queuedCount += 1
        case .alreadyAvailable: alreadyAvailableCount += 1
        case let .failed(message):
            failedCount += 1
            if firstFailure == nil { firstFailure = message }
        case .cancelled: cancelledCount += 1
        }
    }

    var message: String {
        var parts: [String] = []
        if queuedCount > 0 { parts.append("Queued \(queuedCount) installment\(queuedCount == 1 ? "" : "s").") }
        if alreadyAvailableCount > 0 { parts.append("\(alreadyAvailableCount) already offline or queued.") }
        if failedCount > 0 { parts.append("\(failedCount) couldn’t be queued. \(firstFailure ?? "Try again.")") }
        if cancelledCount > 0 { parts.append("Download request cancelled.") }
        return parts.isEmpty ? "No eligible installments to download." : parts.joined(separator: " ")
    }
}
