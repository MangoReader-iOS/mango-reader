import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSources
import Observation
import PhotosUI
import SwiftUI

struct WorkDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(ReaderPresentationCoordinator.self) private var readerCoordinator
    let work: Work
    @State private var isConfirmingRemoval = false
    @State private var selectedCoverItem: PhotosPickerItem?
    @State private var isShowingCoverPicker = false
    @State private var isUpdatingCover = false
    @State private var isShowingSourceMigration = false
    @State private var showsFileAvailability = false
    @State private var readingAction: TitleReadingAction?
    @State private var detailSnapshot: WorkDetailSnapshot?
    @State private var detailRequestGate = LatestOperationGate()
    @Environment(WorkDetailReaderPreparation.self) private var readerPreparation
    @State private var isLoadingDetail = false
    @State private var didStartPerformance = false
    @State private var detailLoadError: String?
    @State private var isUpdatingLibraryMembership = false
    @State private var optimisticLibraryMembership: Bool?
    @State private var isAboutExpanded = true
    @State private var isTagsExpanded = true
    @State private var installmentOrder: WorkDetailInstallmentOrder = .latestFirst
    @State private var installmentPresentation = WorkDetailInstallmentPresentation(installments: [])
    @State private var headerHasScrolledContent = false
    @State private var isVisible = false
    @State private var acknowledgedChapterIDs: Set<InstallmentID>?
    @State private var hasLoadedChapterVisit = false
    @State private var continuationInstallment: Installment?
    @State private var metadataSearchRoute: SourceMetadataSearchRoute?

    private var openSourceMetadataSearch: OpenSourceMetadataSearchAction {
        OpenSourceMetadataSearchAction { route in
            metadataSearchRoute = SourceMetadataSearchRoute(
                source: route.source,
                query: route.query,
                selections: route.selections
            )
        }
    }

    private var isInLibrary: Bool {
        WorkDetailLibraryMembershipPolicy.displayedMembership(
            persisted: detailSnapshot?.isInLibrary
                ?? model.libraryModel.library.contains { $0.id == work.id },
            optimistic: optimisticLibraryMembership
        )
    }
    private var detailInstallments: [Installment] {
        detailSnapshot?.installments ?? []
    }
    private var displayedInstallments: [Installment] {
        installmentPresentation.installments(for: installmentOrder)
    }
    private var primaryInstallment: Installment? {
        installmentPresentation.primaryInstallment
    }
    private var displayedWork: Work {
        detailSnapshot?.work ?? work
    }
    var body: some View {
        let hasCustomCover = displayedWork.customCoverPath != nil
        let authorItems = WorkMetadataSearchPolicy.authorItems(
            for: displayedWork,
            sources: model.sourcesModel.sources
        )
        let tagGroups = WorkMetadataSearchPolicy.tagGroups(
            for: displayedWork,
            sources: model.sourcesModel.sources
        )
        List {
            Section {
                WorkDetailHeader(
                    work: displayedWork,
                    authorItems: authorItems,
                    isInLibrary: isInLibrary,
                    canRead: primaryInstallment != nil,
                    isLoadingInstallments: isLoadingDetail && primaryInstallment == nil,
                    isUpdatingCover: isUpdatingCover,
                    isPreparingReader: readerPreparation.isPreparing && readerPreparation.installmentID == nil,
                    isUpdatingLibraryMembership: isUpdatingLibraryMembership,
                    continuationTitle: continuationInstallment?.title,
                    onRead: openContinuation,
                    onToggleLibrary: updateLibraryMembership
                ) {
                    if displayedWork.sourceID != .local { TitleDownloadMenu(work: displayedWork, usesHeaderStyle: true) }
                    titleOptionsMenu(hasCustomCover: hasCustomCover)
                }
                .padding(.bottom, 8)
                .workDetailFlatListRow()
                TitleTrackingSection(work: displayedWork, installments: detailInstallments)
                    .workDetailFlatListRow()
                if displayedWork.sourceID == .local, let primaryInstallment,
                   let state = model.importedFileAvailability[primaryInstallment.id] {
                    ImportedFileSummaryRow(
                        state: state,
                        showDetails: { showsFileAvailability = true },
                        cancel: readerPreparation.cancel
                    )
                        .workDetailFlatListRow()
                }
            }

            if !displayedWork.summary.isEmpty {
                Section(isExpanded: $isAboutExpanded) {
                    Text(displayedWork.summary)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("about-summary-text")
                        .workDetailFlatListRow()
                } header: {
                    WorkDetailDisclosureHeader(
                        "About",
                        isExpanded: $isAboutExpanded,
                        accessibilityIdentifier: "work-detail-about-disclosure"
                    )
                }
            }

            if !authorItems.isEmpty || !tagGroups.isEmpty {
                Section(isExpanded: $isTagsExpanded) {
                    WorkMetadataTagsView(
                        authors: authorItems,
                        groups: tagGroups,
                        openSearch: openSourceMetadataSearch
                    )
                    .workDetailFlatListRow()
                } header: {
                    WorkDetailDisclosureHeader(
                        "Tags",
                        isExpanded: $isTagsExpanded,
                        accessibilityIdentifier: "work-detail-tags-disclosure"
                    )
                }
            }

            Section {
                ForEach(displayedInstallments) { installment in
                    Button {
                        openReader(installment)
                    } label: {
                        HStack(spacing: 12) {
                            InstallmentRow(
                                installment: installment,
                                progress: detailSnapshot?.progressByInstallmentID[installment.id],
                                download: model.transfersModel.downloadSnapshot(for: installment.id),
                                isLocalWork: displayedWork.sourceID == .local,
                                isAddedSinceLastVisit: acknowledgedChapterIDs.map { !$0.contains(installment.id) } ?? false
                            )
                            if (readerPreparation.isPreparing && readerPreparation.installmentID == installment.id)
                                || model.transfersModel.preparingDownloadInstallmentIDs.contains(installment.id) {
                                ProgressView().controlSize(.small)
                                    .accessibilityLabel(model.transfersModel.preparingDownloadInstallmentIDs.contains(installment.id) ? "Preparing download" : "Preparing reader")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled((readerPreparation.isPreparing && readerPreparation.installmentID == installment.id)
                              || model.transfersModel.preparingDownloadInstallmentIDs.contains(installment.id))
                    .contextMenu {
                        if installment.acquisitionURL?.isFileURL != true {
                            Button("Download", systemImage: "arrow.down.circle") {
                                Task {
                                    await model.enqueueDownload(
                                        work: displayedWork,
                                        installment: installment
                                    )
                                }
                            }
                        }
                        if let download = model.transfersModel.downloadSnapshot(for: installment.id) {
                            DownloadContextActions(snapshot: download)
                        }
                        Section {
                            Button("Mark as Read") {
                                Task {
                                    guard await model.markRead(
                                        work: displayedWork,
                                        installment: installment
                                    ) else { return }
                                    await reloadDetail()
                                }
                            }
                            .disabled(model.settingsSyncModel.incognitoMode || model.libraryModel.isPerformingSelectionAction)
                            Button("Mark as Unread") {
                                Task {
                                    guard await model.markUnread(work: displayedWork, installment: installment) else { return }
                                    await reloadDetail()
                                }
                            }
                            .disabled(model.settingsSyncModel.incognitoMode || model.libraryModel.isPerformingSelectionAction)
                        }
                    }
                    .accessibilityHint("Opens this installment in the reader")
                    .workDetailInstallmentListRow()
                }

                if isLoadingDetail, detailInstallments.isEmpty {
                    SourceInstallmentSkeletonContent()
                        .sourceSkeletonContainer(accessibilityLabel: "Loading installments")
                        .workDetailInstallmentListRow()
                } else if let detailLoadError {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(detailLoadError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppColors.warning)
                        Button("Try Again") {
                            Task { await reloadDetail(refreshRemote: true) }
                        }
                        .buttonStyle(.bordered)
                    }
                    .workDetailInstallmentListRow()
                } else if detailInstallments.isEmpty {
                    ContentUnavailableView(
                        "No installments",
                        systemImage: "doc"
                    )
                    .workDetailInstallmentListRow()
                }
            } header: {
                WorkDetailInstallmentSectionHeader(order: $installmentOrder,
                    usesChapterNumbers: detailInstallments.contains { $0.number != nil })
            }

        }
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(AppColors.background.ignoresSafeArea())
        .listStyle(.plain)
        .listSectionSpacing(.compact)
        .softScreenHeaderEdge()
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 8
        } action: { _, isScrolled in
            headerHasScrolledContent = isScrolled
        }
        .screenHeaderBackground(isScrolled: headerHasScrolledContent)
        .accessibilityIdentifier("work-detail-canvas")
        .preference(key: WorkDetailAccessoryPreference.self, value: isVisible)
        .sourcePerformanceMarker("details")
        .navigationTitle(displayedWork.title)
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .navigationDestination(item: $metadataSearchRoute) { route in
            SourceCatalogView(
                source: route.source,
                initialQuery: route.query,
                initialSelections: route.selections
            )
            .id(route.requestID)
        }
        .toolbar {
            if let shareURL = WorkDetailSourceLinkPolicy.shareURL(
                for: displayedWork,
                source: model.sourcesModel.sources.first { $0.id == displayedWork.sourceID }
            ) {
                ToolbarItem(placement: .topBarTrailing) {
                    FixedNavigationChrome {
                        ShareLink(item: shareURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityHint("Shares this title’s source website link")
                        .disabled(model.isPrivate)
                        .accessibilityIdentifier("work-detail-share")
                    }
                }
            }
        }
        .task(id: work.id) {
            readerPreparation.cancel()
            installmentOrder = .latestFirst
            installmentPresentation = WorkDetailInstallmentPresentation(installments: [])
            isAboutExpanded = true
            isTagsExpanded = true
            hasLoadedChapterVisit = false
            acknowledgedChapterIDs = nil
            await reloadDetail()
            if work.sourceID == .local {
                if let primaryInstallment { await model.inspectImportedBookAvailability(primaryInstallment) }
            }
        }
        .onChange(of: model.trackingModel.progressRevision) { _, _ in
            Task { await reloadDetail(refreshSource: false) }
        }
        .onChange(of: work.modifiedAt) { _, _ in
            Task { await reloadDetail() }
        }
        .onChange(of: model.sourcesModel.contentCacheActivationRevision) { _, _ in
            Task { await reloadDetail() }
        }
        .onChange(of: readerCoordinator.dismissalRevision) { _, _ in
            guard readerCoordinator.lastDismissedWorkID == displayedWork.id else { return }
            Task {
                await reloadDetail()
                if let primaryInstallment {
                    await model.inspectImportedBookAvailability(primaryInstallment, refresh: true)
                }
            }
        }
        .onChange(of: selectedCoverItem) { _, item in
            guard let item else { return }
            Task { await importCustomCover(item) }
        }
        .photosPicker(
            isPresented: $isShowingCoverPicker,
            selection: $selectedCoverItem,
            matching: .images
        )
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            detailRequestGate.invalidate()
            readerPreparation.cancel()
        }
        .sheet(isPresented: $showsFileAvailability, onDismiss: {
            Task {
                await reloadDetail()
                if let primaryInstallment {
                    await model.inspectImportedBookAvailability(primaryInstallment, refresh: true)
                }
            }
        }) { TitleFileAvailabilitySheet(work: displayedWork) }
        .modifier(TitleReadingConfirmation(action: $readingAction) { action in
            Task {
                model.showSelectionResult(await model.markSelection(action.snapshots, asRead: action.asRead))
                await reloadDetail()
            }
        })
        .sheet(isPresented: $isShowingSourceMigration, onDismiss: {
            Task { await reloadDetail() }
        }) {
            SourceMigrationSheet(work: displayedWork)
        }
        .confirmationDialog(
            "Delete \(work.title)?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Delete Import", role: .destructive) {
                Task {
                    isUpdatingLibraryMembership = true
                    defer { isUpdatingLibraryMembership = false }
                    if await model.removeFromLibrary(workIDs: [displayedWork.id]) {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the imported file, reading progress, annotations, downloads, and other saved data for this title.")
        }
    }

    private func titleOptionsMenu(hasCustomCover: Bool) -> some View {
        Menu {
            if isInLibrary {
                let isPinned = model.libraryModel.pinnedWorkIDs.contains(work.id)
                Button(isPinned ? "Unpin" : "Pin") {
                    Task {
                        let result = await model.runSelectionBatch(works: [displayedWork]) { work in
                            await model.libraryModel.setPinned(!isPinned, for: [work.id]) ? .completed : .failed("Couldn’t update pin status.")
                        }
                        if let result { model.feedback.showStatus(result.summary) }
                    }
                }.disabled(model.libraryModel.isPerformingSelectionAction)
            }

            Button(hasCustomCover ? "Replace Custom Cover" : "Choose Custom Cover") {
                isShowingCoverPicker = true
            }
            .disabled(isUpdatingCover)
            if hasCustomCover {
                Button("Restore Source Cover") {
                    guard !isUpdatingCover else { return }
                    isUpdatingCover = true
                    Task {
                        _ = await model.removeCustomCover(for: work.id)
                        isUpdatingCover = false
                        await reloadDetail()
                    }
                }
                .disabled(isUpdatingCover)
            }

            if displayedWork.sourceID != .local,
               model.sourcesModel.sources.contains(where: {
                   $0.isEnabled && $0.kind != .local && $0.id != displayedWork.sourceID
               })
            {
                Button("Migrate Source") {
                    isShowingSourceMigration = true
                }
            }

            Divider()
            Button("Mark as Read") { prepareReadingAction(asRead: true) }
                .disabled(model.settingsSyncModel.incognitoMode || model.libraryModel.isPerformingSelectionAction)
            Button("Mark as Unread") { prepareReadingAction(asRead: false) }
                .disabled(model.settingsSyncModel.incognitoMode || model.libraryModel.isPerformingSelectionAction)
            Divider()
            if displayedWork.sourceID == .local {
                Button("File Availability", systemImage: "arrow.down") { showsFileAvailability = true }
                    .disabled(model.libraryModel.isPerformingSelectionAction)
            }

            if displayedWork.sourceID == .local {
                if isInLibrary {
                    Divider()
                    Button("Delete Import", systemImage: "trash", role: .destructive) {
                        isConfirmingRemoval = true
                    }
                }
            }
        } label: {
            WorkDetailHeaderIconLabel(systemImage: "ellipsis")
        }
        .accessibilityLabel("Manage title")
        .accessibilityHint("Shows title actions")
        .accessibilityIdentifier("work-detail-manage")
    }

    private func prepareReadingAction(asRead: Bool) {
        Task { readingAction = await model.prepareTitleReadingAction(works: [displayedWork], asRead: asRead) }
    }

    private func reloadDetail(refreshRemote: Bool = false, refreshSource: Bool = true) async {
#if DEBUG
        if !didStartPerformance {
            didStartPerformance = true
            SourcePerformanceAudit.shared.begin("details", key: work.remoteID ?? work.title)
        }
#endif
        model.sourcesModel.recordCacheVisit(sourceID: work.sourceID, work: work)
        let requestGeneration = detailRequestGate.begin()
        isLoadingDetail = true
        detailLoadError = nil
        defer {
            if detailRequestGate.accepts(requestGeneration) {
                isLoadingDetail = false
            }
        }

        do {
            if !hasLoadedChapterVisit, let database = model.database {
                acknowledgedChapterIDs = try await database.acknowledgedChapters(workID: work.id, sourceID: work.sourceID)
                hasLoadedChapterVisit = true
            }
            let cached = try await model.libraryModel.cachedWorkDetailSnapshot(for: work)
            guard !Task.isCancelled, detailRequestGate.accepts(requestGeneration) else { return }
            if let cached { applyDetailSnapshot(cached) }
            if refreshRemote || cached == nil || (refreshSource && work.sourceID != .local) {
                let refreshed = try await model.libraryModel.refreshWorkDetailSnapshot(for: work, invalidateSourceCache: refreshRemote) { metadata in
                    guard !Task.isCancelled, detailRequestGate.accepts(requestGeneration) else { return }
                    if var snapshot = detailSnapshot {
                        snapshot.work = metadata
                        detailSnapshot = snapshot
                    } else {
                        detailSnapshot = WorkDetailSnapshot(work: metadata, installments: [], isInLibrary: isInLibrary, progressByInstallmentID: [:])
                    }
                }
                guard !Task.isCancelled, detailRequestGate.accepts(requestGeneration) else { return }
                applyDetailSnapshot(refreshed)
            }
            if let snapshot = detailSnapshot, let database = model.database {
                let sessions = try await database.sessions(for: work.id)
                guard !Task.isCancelled, detailRequestGate.accepts(requestGeneration) else { return }
                continuationInstallment = ContinueReadingPolicy.item(work: snapshot.work, sessions: sessions,
                    installments: snapshot.installments, progresses: Array(snapshot.progressByInstallmentID.values),
                    fallsBackToOldest: true)?.installment
                if !settingsArePrivate, isVisible,
                   await model.prepareTitleTracking(work: snapshot.work, installments: snapshot.installments),
                   !Task.isCancelled, detailRequestGate.accepts(requestGeneration), isVisible, !settingsArePrivate {
                    try await database.acknowledgeChapters(workID: work.id, sourceID: work.sourceID,
                        ids: Set(snapshot.installments.map(\.id)))
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard detailRequestGate.accepts(requestGeneration) else { return }
            detailLoadError = error.localizedDescription
        }
    }

    private var settingsArePrivate: Bool { model.isPrivate || model.settingsSyncModel.incognitoMode }

    private func applyDetailSnapshot(_ snapshot: WorkDetailSnapshot) {
        installmentPresentation = WorkDetailInstallmentPresentation(installments: snapshot.installments)
        detailSnapshot = snapshot
#if DEBUG
        if !snapshot.installments.isEmpty {
            SourcePerformanceAudit.shared.details(snapshot.work.remoteID ?? snapshot.work.title)
        }
#endif
    }

    private func openReader(_ installment: Installment) {
#if DEBUG
        SourcePerformanceAudit.shared.begin("reader", key: installment.remoteID ?? installment.title)
#endif
        let work = displayedWork
        let installments = detailInstallments
        if installment.format == .epub {
            readerPreparation.cancel()
            readerCoordinator.open(.init(work: work, target: .installment(installment, chapters: installments)))
            return
        }
        readerPreparation.start(workID: work.id, installmentID: installment.id) {
            await model.prepareToRead(
                work: work,
                installment: installment,
                installments: installments
            )
        } present: { prepared in
            readerCoordinator.present(prepared)
        }
    }

    private func openContinuation() {
#if DEBUG
        SourcePerformanceAudit.shared.begin("reader", key: continuationInstallment?.remoteID ?? primaryInstallment?.remoteID ?? displayedWork.title)
#endif
        let work = displayedWork
        let installments = detailInstallments
        if let continuationInstallment, work.kind != .lightNovel && work.kind != .book {
            openReader(continuationInstallment)
            return
        }
        if work.kind == .lightNovel || work.kind == .book {
            readerPreparation.cancel()
            readerCoordinator.open(.init(work: work, target: .continuation(chapters: installments)))
            return
        }
        readerPreparation.start(workID: work.id, installmentID: nil) {
            await model.prepareToContinue(work: work, installments: installments)
        } present: { prepared in
            readerCoordinator.present(prepared)
        }
    }

    private func updateLibraryMembership() {
        guard
            !isUpdatingLibraryMembership,
            displayedWork.sourceID != .local
        else { return }

        let persistedMembership = detailSnapshot?.isInLibrary
            ?? model.libraryModel.library.contains { $0.id == displayedWork.id }
        let targetMembership = !isInLibrary
        optimisticLibraryMembership = targetMembership
        isUpdatingLibraryMembership = true

        Task {
            let didUpdate: Bool
            if targetMembership {
                didUpdate = await model.libraryModel.addToLibrary(
                    displayedWork,
                    knownInstallments: detailInstallments
                )
            } else {
                didUpdate = await model.removeFromLibrary(workIDs: [displayedWork.id])
            }

            detailSnapshot?.isInLibrary = WorkDetailLibraryMembershipPolicy.resolvedMembership(
                persisted: persistedMembership,
                optimistic: targetMembership,
                succeeded: didUpdate
            )
            if didUpdate {
                await reloadDetail()
            }
            optimisticLibraryMembership = nil
            isUpdatingLibraryMembership = false
        }
    }

    private func importCustomCover(_ item: PhotosPickerItem) async {
        guard !isUpdatingCover else { return }
        isUpdatingCover = true
        defer {
            selectedCoverItem = nil
            isUpdatingCover = false
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            _ = await model.setCustomCover(data, for: work.id)
            await reloadDetail()
        } catch {
            if (error as NSError).code != NSUserCancelledError {
                model.feedback.alert = AppAlert(
                    title: "Couldn’t open selected image",
                    message: error.localizedDescription
                )
            }
        }
    }
}

enum WorkDetailSourceLinkPolicy {
    nonisolated static func shareURL(for work: Work, source: SourceDescriptor?) -> URL? {
        guard work.sourceID != .local else { return nil }
        let sourceURL = source?.id == work.sourceID ? source?.baseURL : nil
        return [work.shareURL, sourceURL].compactMap { $0 }.first { url in
            ["https", "http"].contains(url.scheme?.lowercased() ?? "")
                && url.host?.isEmpty == false
                && url.user == nil && url.password == nil
        }
    }
}

enum WorkDetailLibraryMembershipPolicy {
    nonisolated static func displayedMembership(
        persisted: Bool,
        optimistic: Bool?
    ) -> Bool {
        optimistic ?? persisted
    }

    nonisolated static func resolvedMembership(
        persisted: Bool,
        optimistic: Bool,
        succeeded: Bool
    ) -> Bool {
        succeeded ? optimistic : persisted
    }
}
