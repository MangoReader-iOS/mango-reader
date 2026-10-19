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

struct RepositoryIconFlight {
    let id: UUID
    let task: Task<RepositoryIconContent, Error>
    let signpostID: OSSignpostID
    var waiters: Set<UUID>
}

struct PendingManualSourceCleanup: Codable, Hashable, Sendable, Identifiable {
    var sourceID: String
    var credentialAccount: String?

    var id: String { sourceID }
}

/// Keeps removal cleanup behind credential writes that started while an
/// installation was still current. Extension state is namespaced by source ID,
/// so a stale OAuth completion must be drained before that namespace can be
/// removed and made available to a later reinstall.

/// Results survive review and retry; successful entries are never reinstalled.
struct RepositoryLinkInstallProgress {
    var entries: [SourceRepositoryEntry] = []
    private(set) var results: [RepositoryInstallResult] = []

    var pendingEntries: [SourceRepositoryEntry] {
        let installedIDs = Set(results.filter(\.installed).map(\.sourceID))
        return entries.filter { !installedIDs.contains($0.id) }
    }

    var hasInstalledContent: Bool {
        let installedIDs = Set(results.filter(\.installed).map(\.sourceID))
        return entries.contains { $0.kind == .content && installedIDs.contains($0.id) }
    }

    mutating func merge(_ incoming: [RepositoryInstallResult]) {
        var byID = Dictionary(uniqueKeysWithValues: results.map { ($0.sourceID, $0) })
        for result in incoming where byID[result.sourceID]?.installed != true {
            byID[result.sourceID] = result
        }
        results = entries.compactMap { byID[$0.id] }
    }
}
