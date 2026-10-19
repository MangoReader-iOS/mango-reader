import Foundation
import ImageIO
import MankoData
import MankoDomain
import MankoExtensions
import MankoReaders
import MankoSources
import MankoSync
import Observation
import OSLog
import SwiftUI
import WebKit

@MainActor
@Observable
final class AppFeedback {


    var alert: AppAlert?

    var statusMessage: AppStatusMessage?

    @ObservationIgnored var statusDismissTask: Task<Void, Never>?

    @ObservationIgnored private var announcedStatusID: UUID?

    func claimStatusAnnouncement(_ id: UUID) -> Bool {
        guard announcedStatusID != id else { return false }
        announcedStatusID = id
        return true
    }

    func showStatus(_ message: String, systemImage: String = "checkmark.circle.fill") {
        statusDismissTask?.cancel()
        let status = AppStatusMessage(message: message, systemImage: systemImage)
        statusMessage = status
        statusDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self?.statusMessage?.id == status.id else { return }
            self?.statusMessage = nil
        }
    }
}
