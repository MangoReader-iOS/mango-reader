import Foundation
import MangoReaderDomain

public enum RepositoryInstallError: Error, Equatable, Sendable, LocalizedError {
    case sourceNotFound
    case repositoryBlocked
    case unavailable(ExtensionAvailability)
    case duplicateSource

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound: "The selected source is no longer in this repository."
        case .repositoryBlocked: "This repository is blocked on this device."
        case let .unavailable(availability): "This extension is \(availability.rawValue) and cannot execute."
        case .duplicateSource: "This source is already installed."
        }
    }
}

public actor RepositoryInstaller {
    private let client: SourceRepositoryClient
    private let store: SourceRepositoryStore
    private let packageStore: ExtensionPackageStore
    private let runtimeRegistry: ExtensionRuntimeRegistry
    private let verifier: RepositoryVerifier

    public init(
        client: SourceRepositoryClient,
        store: SourceRepositoryStore,
        packageStore: ExtensionPackageStore,
        runtimeRegistry: ExtensionRuntimeRegistry,
        verifier: RepositoryVerifier = RepositoryVerifier()
    ) {
        self.client = client
        self.store = store
        self.packageStore = packageStore
        self.runtimeRegistry = runtimeRegistry
        self.verifier = verifier
    }

    public func installBatch(
        sourceIDs: [String],
        from record: RepositoryRecord,
        approvals: [String: ExtensionAccessGrant] = [:]
    ) async -> ([InstalledRepositorySource], [RepositoryInstallResult]) {
        var installed: [InstalledRepositorySource] = []
        var results: [RepositoryInstallResult] = []
        let existingSources = await store.installedSources()
        for sourceID in sourceIDs.prefix(SourceRepositoryLimits.selectedEntries) {
            let entry = record.manifest.sources.first { $0.id == sourceID }
            let previous = existingSources.first { $0.repositoryID == record.id && $0.sourceID == sourceID }
            do {
                guard let entry else { throw RepositoryInstallError.sourceNotFound }
                let source = try await install(entry, from: record, approval: approvals[sourceID])
                installed.append(source)
                let message: String
                if let previous {
                    if previous.version != source.version {
                        message = "Updated from \(previous.version) to \(source.version)"
                    } else if previous.isEnabled == source.isEnabled {
                        message = "Already installed"
                    } else {
                        message = "Restored"
                    }
                } else if source.availability != .available {
                    message = "Added as disabled metadata; \(source.availability.rawValue)"
                } else {
                    message = "Installed"
                }
                results.append(.init(sourceID: entry.id, sourceName: entry.name, installed: true, message: message))
            } catch {
                results.append(.init(
                    sourceID: sourceID,
                    sourceName: entry?.name ?? sourceID,
                    installed: false,
                    message: error.localizedDescription
                ))
            }
        }
        return (installed, results)
    }

    public func diagnoseInstalledSources() async -> RepositorySourceHealthReport {
        let installedSources = await store.installedSources()
        var checkedCount = 0
        var issues: [RepositorySourceHealthIssue] = []
        for installed in installedSources where !installed.isRuntimeCompatible {
            checkedCount += 1
            issues.append(.init(installedSourceID: installed.id, sourceName: installed.descriptor.name,
                message: "This installation is incompatible. Select Update when a WASM replacement is available."))
        }

        for installed in installedSources where installed.entryType == .mangoReaderExtension
            && installed.availability == .available
            && installed.isRuntimeCompatible
        {
            checkedCount += 1
            let isValid: Bool
            if let expectedSHA256 = installed.scriptSHA256 {
                isValid = (try? await packageStore.activeScriptIsValid(
                    repositoryID: installed.repositoryID,
                    sourceID: installed.sourceID,
                    version: installed.version,
                    expectedSHA256: expectedSHA256
                )) == true
            } else {
                isValid = false
            }
            if !isValid {
                issues.append(.init(
                    installedSourceID: installed.id,
                    sourceName: installed.descriptor.name,
                    message: "The installed package is missing or damaged."
                ))
            }
        }

        return RepositorySourceHealthReport(checkedCount: checkedCount, issues: issues)
    }

    public func repairInstalledSources() async -> RepositorySourceRepairReport {
        let installedSources = await store.installedSources()
        let repositories = Dictionary(
            uniqueKeysWithValues: await store.repositories().map { ($0.id, $0) }
        )
        var checkedCount = 0
        var repairedSourceIDs: Set<String> = []
        var failures: [RepositorySourceHealthIssue] = []
        for installed in installedSources where !installed.isRuntimeCompatible {
            checkedCount += 1
            failures.append(.init(installedSourceID: installed.id, sourceName: installed.descriptor.name,
                message: "A WASM update requires your explicit Update action; repair cannot migrate this installation."))
        }

        for installed in installedSources where installed.entryType == .mangoReaderExtension
            && installed.availability == .available
            && installed.isRuntimeCompatible
        {
            checkedCount += 1
            let isValid: Bool
            if let expectedSHA256 = installed.scriptSHA256 {
                isValid = (try? await packageStore.activeScriptIsValid(
                    repositoryID: installed.repositoryID,
                    sourceID: installed.sourceID,
                    version: installed.version,
                    expectedSHA256: expectedSHA256
                )) == true
            } else {
                isValid = false
            }
            guard !isValid else { continue }

            guard let repository = repositories[installed.repositoryID],
                  let entry = repository.manifest.sources.first(where: { $0.id == installed.sourceID })
            else {
                await disableAfterFailedRepair(installed)
                failures.append(.init(
                    installedSourceID: installed.id,
                    sourceName: installed.descriptor.name,
                    message: "The source is no longer available in its repository."
                ))
                continue
            }
            guard RepositoryVersion.compare(entry.version, installed.version) != .orderedAscending else {
                await disableAfterFailedRepair(installed)
                failures.append(.init(
                    installedSourceID: installed.id,
                    sourceName: installed.descriptor.name,
                    message: "The repository no longer publishes a compatible package version."
                ))
                continue
            }

            do {
                _ = try await install(entry, from: repository, approval: installed.accessGrant)
                repairedSourceIDs.insert(installed.id)
            } catch {
                await disableAfterFailedRepair(installed)
                failures.append(.init(
                    installedSourceID: installed.id,
                    sourceName: installed.descriptor.name,
                    message: error.localizedDescription
                ))
            }
        }

        return RepositorySourceRepairReport(
            checkedCount: checkedCount,
            repairedSourceIDs: repairedSourceIDs,
            failures: failures
        )
    }

    public func install(
        _ entry: SourceRepositoryEntry,
        from record: RepositoryRecord,
        approval: ExtensionAccessGrant? = nil
    ) async throws -> InstalledRepositorySource {
        try await store.assertInstallationAllowed(repositoryID: record.id, sourceID: entry.id)
        let existing = await store.installedSources().first {
            $0.repositoryID == record.id && $0.sourceID == entry.id
        }
        if let existing,
           RepositoryVersion.compare(entry.version, existing.version) == .orderedAscending {
            return existing
        }

        var approval = approval
        if let existing, existing.isRuntimeCompatible, let old = existing.accessGrant,
           approval == nil || approval == old,
           old.repositoryID == record.id, old.sourceID == entry.id, old.repositoryURL == record.repositoryURL,
           old.policyDigest == (try? ExtensionAccessGrant.digest(entry)) {
            approval = try ExtensionAccessGrant(entry: entry, record: record)
        }
        guard let live = await store.repository(id: record.id), live.hasSameCatalog(as: record),
              let approval, approval.matches(entry, record: record) else { throw ExtensionSecurityError.approvalRequired }
        if let existing, existing.version == entry.version, existing.scriptSHA256 != entry.mangoReaderExtension?.sha256.lowercased() {
            throw ExtensionSecurityError.artifactChanged
        }
        let sourceID = SourceID(rawValue: "repository.\(record.id).\(entry.id)")
        let sourceCapabilities = Set(entry.capabilities.compactMap(\.sourceCapability))
        switch entry.entryType {
        case .connectorPreset:
            throw RepositoryVerificationError.invalidEntry(entry.id)

        case .mangoReaderExtension:
            guard entry.mangoReaderExtension?.isExecutable == true else {
                throw RepositoryVerificationError.unsupportedAPI(entry.mangoReaderExtension?.apiVersion ?? "unknown")
            }
            guard let payload = entry.mangoReaderExtension, let kind = entry.kind else {
                throw RepositoryVerificationError.invalidEntry(entry.id)
            }
            let shouldActivate = verifier.isExecutable(entry: entry, in: record)
                && entry.availability == .available
            let shouldEnable = shouldActivate && (existing?.isEnabled ?? true)
            let descriptor = SourceDescriptor(
                id: sourceID,
                name: entry.name,
                kind: .mangoReaderExtension,
                languageCodes: entry.languages,
                capabilities: payload.connectorKind == nil ? sourceCapabilities.union([.browse, .search, .imageSequence]) : sourceCapabilities,
                isEnabled: shouldEnable
            )
            var installed = InstalledRepositorySource(
                repositoryID: record.id,
                sourceID: entry.id,
                descriptor: descriptor,
                entryType: .mangoReaderExtension,
                kind: kind,
                availability: entry.availability,
                version: entry.version,
                apiVersion: payload.apiVersion,
                scriptSHA256: payload.sha256.lowercased(),
                capabilities: entry.capabilities,
                allowedHTTPSHosts: payload.allowedHTTPSHosts,
                authenticationModes: payload.authenticationModes,
                permissions: entry.permissions,
                installedAt: existing?.installedAt ?? .now,
                isEnabled: shouldEnable,
                connectorKind: payload.connectorKind
            )
            installed.accessGrant = approval
            installed.accountPolicy = payload.accountPolicy
            guard shouldActivate else {
                installed.isEnabled = false
                installed.descriptor.isEnabled = false
                try await store.install(installed, reviewedRepository: record)
                if let existing { await runtimeRegistry.invalidate(installedSourceID: existing.id) }
                return installed
            }
            let activePackageIsValid: Bool
            if let existing, let expectedSHA256 = existing.scriptSHA256 {
                activePackageIsValid = (try? await packageStore.activeScriptIsValid(
                    repositoryID: record.id,
                    sourceID: entry.id,
                    version: existing.version,
                    expectedSHA256: expectedSHA256
                )) == true
            } else {
                activePackageIsValid = false
            }
            if let existing,
               existing.version == installed.version,
               existing.scriptSHA256 == installed.scriptSHA256,
               activePackageIsValid {
                try await store.install(installed, reviewedRepository: record)
                await runtimeRegistry.invalidate(installedSourceID: existing.id)
                return installed
            }
            if let existing, existing.accountPolicy != installed.accountPolicy {
                try await runtimeRegistry.signOutTracker(existing)
            }
            let script = try await client.fetchScript(for: entry, in: record)
            let staged = try await packageStore.stage(
                script: script,
                repositoryID: record.id,
                sourceID: entry.id,
                version: entry.version,
                expectedSHA256: payload.sha256,
                expectedSize: payload.size
            )
            var activation: ExtensionPackageStore.ActivationReceipt?
            do {
                let stagedRuntime = try await runtimeRegistry.makeStagedRuntime(for: installed, scriptURL: staged.url)
                do {
                    try await stagedRuntime.initialize()
                    try await stagedRuntime.discardPersistentState()
                } catch {
                    try? await stagedRuntime.discardPersistentState()
                    throw error
                }
                // Repository removal can race the download and staged runtime.
                // Recheck immediately before package activation; store.install
                // performs the same actor-isolated check after activation.
                try await store.assertInstallationAllowed(repositoryID: record.id, sourceID: entry.id)
                guard await store.repository(id: record.id)?.hasSameCatalog(as: record) == true else { throw ExtensionSecurityError.approvalRequired }
                activation = try await packageStore.activate(staged)
                try await store.install(installed, reviewedRepository: record)
                if let existing {
                    await runtimeRegistry.invalidate(installedSourceID: existing.id)
                }
                try? await packageStore.removeLegacyPackages(repositoryID: record.id, sourceID: entry.id)
                if let activation { try? await packageStore.commit(activation) }
                return installed
            } catch {
                if let activation {
                    try? await packageStore.rollback(activation)
                    if existing == nil {
                        // A first install has no previous package to preserve.
                        // Remove bytes moved out of staging if persistence lost
                        // a race with repository removal or otherwise failed.
                        try? await packageStore.remove(
                            repositoryID: record.id,
                            sourceID: entry.id
                        )
                    }
                }
                await packageStore.discard(staged)
                throw error
            }
        }
    }

    private func disableAfterFailedRepair(_ installed: InstalledRepositorySource) async {
        _ = try? await store.setInstalledSourceEnabled(id: installed.id, isEnabled: false)
        await runtimeRegistry.invalidate(installedSourceID: installed.id)
    }
}
