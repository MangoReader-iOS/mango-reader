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

extension AppModel {
    func storeTrackerOAuthCredentials(
        for installed: InstalledRepositorySource,
        accessToken: String,
        refreshToken: String?,
        tokenType: String?,
        expiresAt: Date?
    ) async throws {
        try Task.checkCancellation()
        guard let extensionRuntimeRegistry else { throw SourceError.transport("Tracker services are still starting.") }
        guard sourcesModel.isCurrentInstallation(installed) else {
            throw SourceError.transport("This tracker is no longer installed.")
        }
        let trackerID = trackingModel.trackerID(for: installed)
        try await trackingModel.beginAccountChange(trackerID: trackerID)
        defer { trackingModel.finishAccountChange(trackerID: trackerID) }
        do {
            // Beginning the lease is synchronous with the current-installation
            // check on MainActor. Removal first detaches the installation, then
            // waits on this lease before deleting its shared state namespace.
            let lease = sourcesModel.trackerCredentialWriteFence.begin(sourceID: installed.id)
            defer { sourcesModel.trackerCredentialWriteFence.finish(lease) }
            try await extensionRuntimeRegistry.storeTrackerOAuthCredentials(
                for: installed,
                accessToken: accessToken,
                refreshToken: refreshToken,
                tokenType: tokenType,
                expiresAt: expiresAt
            )
            // OAuth browser sessions can outlive the row that launched them.
            // If removal won while the secure-state write was suspended, erase
            // the stale completion while cleanup is fenced behind this scope.
            guard sourcesModel.isCurrentInstallation(installed) else {
                try? await extensionRuntimeRegistry.signOutTracker(installed)
                throw SourceError.transport("This tracker was removed before sign-in finished.")
            }
            if Task.isCancelled {
                try await extensionRuntimeRegistry.signOutTracker(installed)
                throw CancellationError()
            }
        }
        await trackingModel.refreshTrackerQueueStatus()
    }

    func resetAllSources() async {
        guard !sourcesModel.isResettingSources, !sourcesModel.isCheckingSources, let repositoryStore else { return }
        sourcesModel.isResettingSources = true
        defer { sourcesModel.isResettingSources = false }

        let repositories = await repositoryStore.repositories()
        for repository in repositories {
            await removeRepository(repository)
        }
        let orphanedInstallations = await repositoryStore.installedSources()
        for installed in orphanedInstallations {
            await removeInstalledRepositorySource(installed)
        }
        let manualSources = sourcesModel.sources
        for source in manualSources {
            await removeSource(source)
        }
        let remainingCredentials = sourcesModel.sourceCredentialAccounts
        for (sourceID, account) in remainingCredentials {
            let cleanup = PendingManualSourceCleanup(
                sourceID: sourceID,
                credentialAccount: account
            )
            sourcesModel.pendingManualSourceCleanups.removeAll { $0.id == cleanup.id }
            sourcesModel.pendingManualSourceCleanups.append(cleanup)
            sourcesModel.sourceCredentialAccounts.removeValue(forKey: sourceID)
            sourcesModel.savePendingManualSourceCleanups()
            await sourcesModel.performManualSourceCleanup(cleanup, announcesFailure: false)
        }

        sourcesModel.sourceRepositories = await repositoryStore.repositories()
        sourcesModel.installedRepositorySources = await repositoryStore.installedSources()
        sourcesModel.sourceOptions.removeAll()
        sourcesModel.sourceSearchExclusions.removeAll()
        sourcesModel.saveSources()
        await sourcesModel.refreshSourceHealth()
        feedback.showStatus(
            "Sources reset. Your library and reading data were preserved.",
            systemImage: "checkmark.circle.fill"
        )
    }

    /// Fetches and validates a repository for an external-link review without
    /// changing persistence or the visible repository catalog.
    func previewRepositoryLink(at url: URL) async throws -> RepositoryRecord {
        guard let repositoryClient else {
            throw SourceError.transport("Repository storage is still starting. Try again in a moment.")
        }
        let record = try await SourcesModel.fetchRepositoryLinkPreview(at: url, client: repositoryClient)
        try validateRepositoryLinkIdentity(record)
        return record
    }

    func validatedRepositoryLinkEntries(
        in record: RepositoryRecord,
        sourceIDs: [String]
    ) throws -> [SourceRepositoryEntry] {
        try validateRepositoryLinkIdentity(record)
        return try sourceIDs.map { sourceID in
            guard let entry = record.manifest.sources.first(where: { $0.id == sourceID }) else {
                throw RepositoryLinkReviewError.sourceMissing(sourceID)
            }
            guard entry.entryType == .mangoReaderExtension,
                  entry.mangoReaderExtension?.isExecutable == true
            else {
                throw RepositoryLinkReviewError.sourceNotInstallable(sourceID)
            }
            guard entry.availability == .available else {
                throw RepositoryLinkReviewError.sourceUnavailable(sourceID)
            }
            return entry
        }
    }

    /// Persists a link preview only after the confirmation action has fired.
    @discardableResult
    func persistRepositoryLinkPreview(_ record: RepositoryRecord) async throws -> RepositoryRecord {
        guard let repositoryStore else {
            throw SourceError.transport("Repository storage is still starting. Try again in a moment.")
        }
        try validateRepositoryLinkIdentity(record)
        try await repositoryStore.upsert(record)
        sourcesModel.sourceRepositories = await repositoryStore.repositories()
        sourcesModel.installedRepositorySources = await repositoryStore.installedSources()
        sourcesModel.reconcileInstalledSourceIndex()
        await sourcesModel.refreshSourceHealth()
        return await repositoryStore.repository(id: record.id) ?? record
    }

    func validateRepositoryLinkIdentity(_ record: RepositoryRecord) throws {
        guard !record.isBlocked else { throw RepositoryLinkReviewError.repositoryBlocked }
        guard let existing = sourcesModel.sourceRepositories.first(where: { $0.id == record.id }) else { return }
        let existingURL = existing.repositoryURL.absoluteURL.standardized
        let incomingURL = record.repositoryURL.absoluteURL.standardized
        guard existingURL != incomingURL else { return }
        throw RepositoryLinkReviewError.repositoryIdentityCollision(
            name: record.manifest.repository.name,
            existingHost: existingURL.host ?? existingURL.absoluteString,
            incomingHost: incomingURL.host ?? incomingURL.absoluteString
        )
    }

    func removeInstalledRepositorySource(_ installed: InstalledRepositorySource) async {
        guard let repositoryStore else { return }
        do {
            let cleanup = try await repositoryStore.scheduleSourceRemoval(id: installed.id)
            sourcesModel.sourceRepositories = await repositoryStore.repositories()
            sourcesModel.installedRepositorySources = await repositoryStore.installedSources()
            sourcesModel.detachInstalledSourcesFromBrowse(cleanup.installedSources)
            await performRepositoryCleanup(cleanup, announcesFailure: true)
        } catch {
            sourcesModel.show(error, title: "Couldn’t remove source")
        }
    }

    func removeRepository(_ record: RepositoryRecord) async {
        guard let repositoryStore else { return }
        do {
            let cleanup = try await repositoryStore.scheduleRepositoryRemoval(id: record.id)
            sourcesModel.sourceRepositories = await repositoryStore.repositories()
            sourcesModel.installedRepositorySources = await repositoryStore.installedSources()
            sourcesModel.invalidateRepositoryIcons(for: [record.id])
            sourcesModel.detachInstalledSourcesFromBrowse(cleanup.installedSources)
            await performRepositoryCleanup(cleanup, announcesFailure: true)
        } catch {
            sourcesModel.show(error, title: "Couldn’t remove repository")
        }
    }

    func resumePendingRepositoryCleanups() async {
        guard let repositoryStore else { return }
        for cleanup in await repositoryStore.pendingCleanups() {
            sourcesModel.detachInstalledSourcesFromBrowse(cleanup.installedSources)
            await performRepositoryCleanup(cleanup, announcesFailure: false)
        }
    }

    func performRepositoryCleanup(
        _ cleanup: PendingRepositoryCleanup,
        announcesFailure: Bool
    ) async {
        guard let repositoryStore, let extensionRuntimeRegistry else { return }
        let signpostID = OSSignpostID(log: SourcesModel.sourceManagementLog)
        os_signpost(.begin, log: SourcesModel.sourceManagementLog, name: "Source Cleanup", signpostID: signpostID)
        do {
            let removedNamespaces = Set(cleanup.installedSources.map { installed in
                sourcesModel.runtimeNamespace(
                    repositoryID: installed.repositoryID,
                    sourceID: installed.sourceID
                )
            })
            try await downloadCoordinator?.invalidateVerificationSessions(
                namespaces: removedNamespaces
            )
            if let downloadCoordinator {
                transfersModel.downloads = await downloadCoordinator.snapshots()
            }
            await sourcesModel.trackerCredentialWriteFence.wait(for: Set(cleanup.installedSources.map(\.id)))
            for installed in cleanup.installedSources {
                try await extensionRuntimeRegistry.remove(installed)
                try await CloudflareWebsiteDataStore.remove(
                    for: sourcesModel.runtimeNamespace(
                        repositoryID: installed.repositoryID,
                        sourceID: installed.sourceID
                    )
                )
            }
            if cleanup.scope == .repository {
                let retainedSources = await repositoryStore.installedSources()
                try await extensionRuntimeRegistry.finalizeRepositoryRemoval(
                    removed: cleanup.installedSources,
                    preserving: retainedSources
                )
            }
            try await discardTrackerUpdatesForCleanup(cleanup.installedSources)
            for installed in cleanup.installedSources {
                let descriptorID = installed.descriptor.id.rawValue
                if let account = sourcesModel.sourceCredentialAccounts[descriptorID] {
                    try await sourcesModel.credentialStore.remove(account: account)
                    sourcesModel.sourceCredentialAccounts.removeValue(forKey: descriptorID)
                }
                sourcesModel.sourceOptions.removeValue(forKey: descriptorID)
                sourcesModel.sourceSearchExclusions.removeValue(forKey: descriptorID)
                sourcesModel.sources.removeAll { $0.id == installed.descriptor.id }
            }
            sourcesModel.clearVerificationRequests(for: cleanup.installedSources)
            sourcesModel.saveSources()
            try await repositoryStore.completeCleanup(id: cleanup.id)
            os_signpost(.end, log: SourcesModel.sourceManagementLog, name: "Source Cleanup", signpostID: signpostID, "success")
        } catch {
            try? await repositoryStore.recordCleanupFailure(id: cleanup.id)
            os_signpost(.end, log: SourcesModel.sourceManagementLog, name: "Source Cleanup", signpostID: signpostID, "failure")
            if announcesFailure {
                feedback.showStatus(
                    "The source was removed. Some local cleanup will retry automatically.",
                    systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
                )
            }
        }
        sourcesModel.sourceRepositories = await repositoryStore.repositories()
        sourcesModel.installedRepositorySources = await repositoryStore.installedSources()
        sourcesModel.reconcileInstalledSourceIndex()
        if !sourcesModel.isResettingSources {
            await sourcesModel.refreshSourceHealth()
        }
    }

    func discardTrackerUpdatesForCleanup(
        _ installedSources: [InstalledRepositorySource]
    ) async throws {
        let trackerIDs = Set(installedSources.compactMap { installed -> TrackerID? in
            guard installed.entryType == .mangoReaderExtension, installed.kind == .tracker else { return nil }
            return TrackerID(rawValue: "repository.\(installed.repositoryID).\(installed.sourceID)")
        })
        guard !trackerIDs.isEmpty else { return }
        var fenced: [TrackerID] = []
        defer { for trackerID in fenced { trackingModel.finishAccountChange(trackerID: trackerID) } }
        for trackerID in trackerIDs {
            try await trackingModel.beginAccountChange(trackerID: trackerID)
            fenced.append(trackerID)
        }
        if let database {
            for trackerID in trackerIDs { try await database.deleteTrackerLinks(trackerID: trackerID) }
            trackingModel.trackerLinksByWork = trackingModel.trackerLinksByWork.mapValues { links in
                links.filter { !trackerIDs.contains($0.trackerID) }
            }
        }
    }

    func removeSources(at offsets: IndexSet) {
        let removed = offsets.compactMap { index in
            sourcesModel.sources.indices.contains(index) ? sourcesModel.sources[index] : nil
        }
        for descriptor in removed {
            Task { await removeSource(descriptor) }
        }
    }

    func removeSource(_ descriptor: SourceDescriptor) async {
        if let installed = sourcesModel.installedRepositorySources.first(where: { $0.descriptor.id == descriptor.id }) {
            await removeInstalledRepositorySource(installed)
            return
        }
        guard let index = sourcesModel.sources.firstIndex(where: { $0.id == descriptor.id }) else { return }
        let cleanup = PendingManualSourceCleanup(
            sourceID: descriptor.id.rawValue,
            credentialAccount: sourcesModel.sourceCredentialAccounts[descriptor.id.rawValue]
        )
        sourcesModel.pendingManualSourceCleanups.removeAll { $0.id == cleanup.id }
        sourcesModel.pendingManualSourceCleanups.append(cleanup)
        sourcesModel.savePendingManualSourceCleanups()
        sourcesModel.sources.remove(at: index)
        sourcesModel.sourceCredentialAccounts.removeValue(forKey: descriptor.id.rawValue)
        sourcesModel.sourceOptions.removeValue(forKey: descriptor.id.rawValue)
        sourcesModel.sourceSearchExclusions.removeValue(forKey: descriptor.id.rawValue)
        sourcesModel.saveSources()
        await sourcesModel.performManualSourceCleanup(cleanup, announcesFailure: true)
    }

    @discardableResult
    func completeCloudflareHandoff(
        _ request: CloudflareHandoffRequest,
        result: CloudflareHandoffResult,
        verifiedWebView: WKWebView? = nil,
        onFailure: ((String) -> Void)? = nil
    ) async -> Bool {
        guard sourcesModel.pendingCloudflareHandoff?.id == request.id else { return false }
        let approvedCookies = CloudflareHandoffPolicy.approvedCookies(
            result.cookies,
            for: result.canonicalHTTPSOrigin,
            requestPath: request.url.path
        )
        guard result.websiteDataStoreIdentifier == CloudflareWebsiteDataStore.identifier(
            for: request.namespace
        ),
            CloudflareHandoffPolicy.canonicalHTTPSOrigin(for: result.canonicalHTTPSOrigin)
                == CloudflareHandoffPolicy.canonicalHTTPSOrigin(for: request.url),
            CloudflareHandoffPolicy.containsApplicableClearance(
                in: approvedCookies,
                for: result.canonicalHTTPSOrigin,
                requestPath: request.url.path
            ),
            !result.userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            let message = "Cloudflare clearance was not completed for this source and browser identity. Reload verification to try again."
            if let onFailure { onFailure(message) }
            else { feedback.alert = AppAlert(title: "Verification incomplete", message: message) }
            return false
        }
#if DEBUG
        if CloudflareUITestFixture.isEnabled,
           request.namespace == CloudflareUITestFixture.namespace
        {
            await CloudflareUITestRecoveryOperation.shared.accept(result)
            _ = sourcesModel.cloudflareRecoveryCoordinator.complete(namespace: request.namespace)
            sourcesModel.dismissCloudflareHandoff(request)
            sourcesModel.cloudflareVerificationRevision &+= 1
            feedback.showStatus("Source verified securely. Retrying once…", systemImage: "checkmark.shield.fill")
            return true
        }
#endif
        guard let extensionRuntimeRegistry else {
            let message = "Source verification storage is still starting. Try saving again."
            if let onFailure { onFailure(message) }
            else { feedback.alert = AppAlert(title: "Couldn’t save verification", message: message) }
            return false
        }
        do {
            _ = try await extensionRuntimeRegistry.completeCloudflareHandoff(
                namespace: request.namespace,
                origin: result.canonicalHTTPSOrigin,
                verificationURL: request.url,
                userAgent: result.userAgent,
                cookies: approvedCookies
            )
            guard sourcesModel.pendingCloudflareHandoff?.id == request.id,
                  sourcesModel.isInstalledExtensionNamespace(request.namespace)
            else {
                sourcesModel.cloudflareRecoveryCoordinator.cancel(namespace: request.namespace)
                return false
            }
            if let verifiedWebView {
                ExtensionVerifiedBrowserSessionPool.store(
                    webView: verifiedWebView,
                    namespace: request.namespace,
                    canonicalHTTPSOrigin: result.canonicalHTTPSOrigin,
                    userAgent: result.userAgent
                )
            }
            let resumesBackgroundWork = sourcesModel.cloudflareRecoveryCoordinator.complete(
                namespace: request.namespace
            )
            sourcesModel.dismissCloudflareHandoff(request)
            sourcesModel.cloudflareVerificationRevision &+= 1
            feedback.showStatus("Source verified securely. Retrying once…", systemImage: "checkmark.shield.fill")
            if resumesBackgroundWork {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await LibraryAutomationHandoff.shared.perform(.manual)
                    await self.trackingModel.deliverRepositoryTrackerQueue(mode: .foreground)
                    await self.resumeDownloadsRequiringVerification(
                        namespace: request.namespace
                    )
                    self.sourcesModel.cloudflareRecoveryCoordinator.finishBoundedBackgroundRetry(
                        namespace: request.namespace
                    )
                    await self.synchronizeAfterProcessAutomation(refreshesContent: true)
                    do {
                        try await self.sourcesModel.restorePendingCloudflareVerificationRequirements()
                    } catch {
                        self.sourcesModel.show(error, title: "Couldn’t resume source verification")
                    }
                }
            }
            return true
        } catch {
            if let onFailure { onFailure(error.localizedDescription) }
            else { sourcesModel.show(error, title: "Couldn’t save verification") }
            return false
        }
    }

    func resumeDownloadsRequiringVerification(namespace: String) async {
        guard let downloadCoordinator else { return }
        let snapshots = await downloadCoordinator.snapshots()
        let activeRecoveryIDs = Set(transfersModel.downloadVerificationRecoveryTasks.keys)
        let transferIDs: [UUID] = snapshots.compactMap { snapshot -> UUID? in
            guard snapshot.verificationRequirement?.namespace == namespace,
                  !activeRecoveryIDs.contains(snapshot.id)
            else { return nil }
            return snapshot.id
        }
        for transferID in transferIDs {
            do {
                try await downloadCoordinator.retryAfterVerification(transferID)
            } catch {
                sourcesModel.show(error, title: "Couldn’t resume verified download")
            }
        }
        transfersModel.downloads = await downloadCoordinator.snapshots()
    }

    /// Compatibility entry point retained for focused tests and older call
    /// sites. The automatic verifier supplies the captured WebKit identity via
    /// `CloudflareHandoffResult`.
    func completeCloudflareHandoff(
        _ request: CloudflareHandoffRequest,
        cookies: [ExtensionHTTPStateCookie]
    ) async {
        guard let profile = request.seed.profile else {
            feedback.alert = AppAlert(
                title: "Verification incomplete",
                message: "Cloudflare clearance and the verified browser identity are both required."
            )
            return
        }
        await completeCloudflareHandoff(
            request,
            result: CloudflareHandoffResult(
                canonicalHTTPSOrigin: profile.canonicalHTTPSOrigin,
                userAgent: profile.userAgent,
                cookies: cookies,
                websiteDataStoreIdentifier: CloudflareWebsiteDataStore.identifier(
                    for: request.namespace
                )
            )
        )
    }
}
