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

enum ExtensionCoverMediaTypePolicy {
    nonisolated static func allows(_ value: String?) -> Bool {
        guard let mediaType = value?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        // The MIME declaration is only the first gate. ImageIO still has to
        // decode the bytes before either covers or repository icons are used.
        // This permits valid formats such as SVG without accepting generic
        // binary or HTML payloads.
        return mediaType.hasPrefix("image/") && mediaType.count > "image/".count
    }
}

/// A small latest-request-wins gate for view-owned asynchronous work. Starting
/// or invalidating an operation makes every older completion ineligible to
/// mutate presentation state, even when an underlying API ignores cancellation.
struct LatestOperationGate: Sendable {
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func accepts(_ candidate: UInt64) -> Bool {
        candidate == generation
    }
}

struct SourceIndexReconciliation: Equatable {
    var sources: [SourceDescriptor]
    var sourceOptions: [String: [String: String]]
    var restoredCount: Int
    var updatedCount: Int
    var removedDuplicateCount: Int

    var changed: Bool {
        restoredCount > 0 || updatedCount > 0 || removedDuplicateCount > 0
    }
}

enum SourceIndexReconciler {
    static func reconcile(
        sources: [SourceDescriptor],
        sourceOptions: [String: [String: String]],
        installedSources: [InstalledRepositorySource],
        repositories: [RepositoryRecord]
    ) -> SourceIndexReconciliation {
        let visibleInstallations = installedSources
            .filter { !($0.entryType == .mangoReaderExtension && ($0.kind == .tracker || $0.connectorKind != nil)) }
            .map { installed in
                var installed = installed
                if !installed.isRuntimeCompatible { installed.descriptor.isEnabled = false }
                return installed
            }
            .sorted {
                if $0.installedAt != $1.installedAt { return $0.installedAt < $1.installedAt }
                let comparison = $0.descriptor.name.localizedStandardCompare($1.descriptor.name)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
        let installedByDescriptorID = Dictionary(
            uniqueKeysWithValues: visibleInstallations.map { ($0.descriptor.id, $0) }
        )
        let connectorDescriptorIDs = Set(installedSources.filter { $0.connectorKind != nil }.map { $0.descriptor.id })
        var seenDescriptorIDs: Set<SourceID> = []
        var reconciledSources: [SourceDescriptor] = []
        var updatedCount = 0
        var removedDuplicateCount = 0

        for source in sources {
            if connectorDescriptorIDs.contains(source.id) { updatedCount += 1; continue }
            guard seenDescriptorIDs.insert(source.id).inserted else {
                removedDuplicateCount += 1
                continue
            }
            if let installed = installedByDescriptorID[source.id] {
                reconciledSources.append(installed.descriptor)
                if source != installed.descriptor { updatedCount += 1 }
            } else {
                reconciledSources.append(source)
            }
        }

        var restoredCount = 0
        for installed in visibleInstallations where seenDescriptorIDs.insert(installed.descriptor.id).inserted {
            reconciledSources.append(installed.descriptor)
            restoredCount += 1
        }

        let repositoryByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
        var reconciledOptions = sourceOptions
        for installed in visibleInstallations where installed.entryType == .connectorPreset {
            let descriptorID = installed.descriptor.id.rawValue
            guard reconciledOptions[descriptorID] == nil,
                  let entry = repositoryByID[installed.repositoryID]?
                    .manifest.sources.first(where: { $0.id == installed.sourceID }),
                  let preset = entry.connectorPreset
            else { continue }
            reconciledOptions[descriptorID] = preset.options
            updatedCount += 1
        }

        return SourceIndexReconciliation(
            sources: reconciledSources,
            sourceOptions: reconciledOptions,
            restoredCount: restoredCount,
            updatedCount: updatedCount,
            removedDuplicateCount: removedDuplicateCount
        )
    }
}

struct SourceHealthState: Equatable {
    var packageIssues: [RepositorySourceHealthIssue] = []
    var repairFailures: [RepositorySourceHealthIssue] = []

    static func repairableIssues(
        _ issues: [RepositorySourceHealthIssue],
        installations: [InstalledRepositorySource]
    ) -> [RepositorySourceHealthIssue] {
        let incompatibleIDs = Set(installations.filter { !$0.isRuntimeCompatible }.map(\.id))
        return issues.filter { !incompatibleIDs.contains($0.id) }
    }

    var issues: [RepositorySourceHealthIssue] {
        let failureByID = Dictionary(uniqueKeysWithValues: repairFailures.map { ($0.id, $0) })
        return packageIssues.map { failureByID[$0.id] ?? $0 }
    }

    var needsAttention: Bool { !issues.isEmpty }

    var summary: String {
        let count = issues.count
        guard count > 0 else { return "All installed sources are ready." }
        let noun = count == 1 ? "source needs" : "sources need"
        return "\(count) \(noun) repair"
    }

    var detail: String? {
        guard let issue = issues.first else { return nil }
        if issues.count == 1 { return "\(issue.sourceName): \(issue.message)" }
        return "\(issue.sourceName): \(issue.message)"
    }
}

enum RemoteSearchOutcome: Sendable {
    case success(sourceID: SourceID, page: SourcePage<Work>)
    case verificationRequired(sourceID: SourceID)
    case failure(sourceID: SourceID, failure: SearchSourceFailure)
}
