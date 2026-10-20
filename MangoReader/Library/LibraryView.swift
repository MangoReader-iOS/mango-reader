import MangoReaderDomain
import MangoReaderReaders
import MangoReaderSources
import MangoReaderSync
import SwiftUI
import UIKit

/// Selection survives changes between a navigation destination and an inspector.
@Observable
final class LibraryDetailPresentation {
    enum Layout { case compact, regular }

    var selectedWorkID: WorkID? {
        didSet {
            if oldValue != selectedWorkID { presentationID = UUID() }
        }
    }
    private(set) var layout = Layout.compact
    private var presentationID = UUID()

    func adapt(to layout: Layout) {
        guard self.layout != layout else { return }
        self.layout = layout
        presentationID = UUID()
    }

    func isPresented(in layout: Layout) -> Binding<Bool> {
        let presentationID = presentationID
        return Binding(
            get: { self.layout == layout && self.selectedWorkID != nil },
            set: { isPresented in
                // SwiftUI may finish dismissing the old presentation after a resize.
                guard !isPresented,
                      self.layout == layout,
                      self.presentationID == presentationID else { return }
                self.selectedWorkID = nil
            }
        )
    }
}

struct LibraryInspectorVisibilityPreference: PreferenceKey {
    nonisolated static let defaultValue = false

    nonisolated static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct LibraryScene: View {
    @Binding var isSelectingTitles: Bool
    let openBrowse: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var detailPresentation = LibraryDetailPresentation()
    @State private var selectedWorkSnapshot: Work?

    private var selectedWorkID: WorkID? { detailPresentation.selectedWorkID }

    private var selectedWork: Work? {
        guard let selectedWorkID else { return nil }
        return model.libraryModel.library.first { $0.id == selectedWorkID }
            ?? selectedWorkSnapshot.flatMap { $0.id == selectedWorkID ? $0 : nil }
    }

    var body: some View {
        @Bindable var detailPresentation = detailPresentation
        let showsInspector = detailPresentation.layout == .regular && selectedWork != nil
        NavigationStack {
            LibraryCollectionView(
                selectedWorkID: $detailPresentation.selectedWorkID,
                selectionMode: $isSelectingTitles,
                openBrowse: openBrowse
            )
                .inspector(isPresented: detailPresentation.isPresented(in: .regular)) {
                    NavigationStack {
                        if showsInspector, let work = selectedWork {
                            WorkDetailView(work: work)
                                .id(work.id)
                                .toolbarVisibility(.visible, for: .navigationBar)
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        FixedNavigationChrome {
                                            Button {
                                                detailPresentation.selectedWorkID = nil
                                            } label: {
                                                Label("Close", systemImage: "xmark")
                                            }
                                            .accessibilityIdentifier("library-detail-close")
                                        }
                                    }
                                }
                        }
                    }
                    .appFeedbackOverlay()
                    .inspectorColumnWidth(min: 320, ideal: 420, max: 560)
                    .accessibilityIdentifier("library-detail-inspector")
                }
                .navigationDestination(isPresented: detailPresentation.isPresented(in: .compact)) {
                    if let work = selectedWork {
                        WorkDetailView(work: work)
                            .id(work.id)
                            .toolbarVisibility(.visible, for: .navigationBar)
                    }
                }
                .toolbarRole(.browser)
        }
        .preference(key: LibraryInspectorVisibilityPreference.self, value: showsInspector)
        .transformPreference(WorkDetailAccessoryPreference.self) {
            $0 = $0 || showsInspector
        }
        .onChange(of: horizontalSizeClass, initial: true) { _, sizeClass in
            detailPresentation.adapt(to: sizeClass == .regular ? .regular : .compact)
        }
        .onChange(of: selectedWorkID) { _, selectedWorkID in
            guard let selectedWorkID else {
                selectedWorkSnapshot = nil
                return
            }
            if let work = model.libraryModel.library.first(where: { $0.id == selectedWorkID }) {
                selectedWorkSnapshot = work
            }
        }
        #if DEBUG
        .task(id: horizontalSizeClass) {
            guard MangoReaderScreenshotMode.scene == "details" else { return }
            // Register the native presentation before selecting its initial book.
            await Task.yield()
            guard !Task.isCancelled, let work = model.libraryModel.library.first else { return }
            detailPresentation.selectedWorkID = work.id
        }
        #endif
        .onChange(of: model.libraryModel.library.map(\.id)) { _, visibleWorkIDs in
            guard
                let selectedWorkID,
                !visibleWorkIDs.contains(selectedWorkID)
            else { return }

            // Remote unsaving only removes Library membership, so its open detail remains
            // available from the retained snapshot. A local title can be filtered out by
            // category, but its detail closes once the underlying Library entry is deleted.
            if selectedWorkSnapshot == nil
                || (selectedWorkSnapshot?.sourceID == .local
                    && model.libraryModel.libraryEntries[selectedWorkID] == nil) {
                detailPresentation.selectedWorkID = nil
            }
        }
    }
}

private struct LibraryCollectionView: View {
    @State private var didInitializeFilters = false
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(ReaderPresentationCoordinator.self) private var readerCoordinator
    @Environment(WorkDetailReaderPreparation.self) private var readerPreparation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var selectedWorkID: WorkID?
    @Binding var selectionMode: Bool
    let openBrowse: () -> Void

    @State private var selectedIDs: Set<WorkID> = []
    @State private var searchText = ""
    @State private var isSearchFocused = false
    @State private var bulkSourceMigrationRoute: BulkSourceMigrationRoute?
    @State private var isConfirmingBulkRemoval = false
    @State private var contextRemovalWork: Work?
    @State private var showsSelectionReview = false
    @State private var showsFileSyncSettings = false
    @State private var downloadsWork: Work?
    @State private var selectionSnapshots: [LibrarySelectionSnapshot] = []
    @State private var isLoadingSelection = false
    @State private var selectionLoadID = UUID()
    @State private var readingAction: TitleReadingAction?
    @State private var pendingRemoval: [Work] = []
    @State private var batchResult: LibrarySelectionBatchResult?
    @State private var snapshotError: String?
    @State private var selectionTask: Task<Void, Never>?

    private var selectionIsBusy: Bool {
        model.libraryModel.isPerformingSelectionAction || model.libraryModel.isApplyingBulkSourceMigration
    }
    private var migrationCandidates: [Work] {
        LibrarySelectionPolicy.migrationCandidates(selectedWorks, sources: model.sourcesModel.sources)
    }
    private var unpinnedIDs: Set<WorkID> { selectedIDs.subtracting(model.libraryModel.pinnedWorkIDs) }
    private var pinnedIDs: Set<WorkID> { selectedIDs.intersection(model.libraryModel.pinnedWorkIDs) }
    private var filteredWorks: [Work] {
        model.libraryModel.filteredLibrary(matching: searchText)
    }

    private var selectedWorks: [Work] {
        model.libraryModel.library.filter { selectedIDs.contains($0.id) }
    }

    private var selectedLocalImportCount: Int {
        selectedWorks.count { $0.sourceID == .local }
    }

    private var selectedRemoteCount: Int {
        selectedWorks.count - selectedLocalImportCount
    }

    private var listSelection: Binding<Set<WorkID>> {
        Binding(
            get: {
                selectionMode ? selectedIDs : Set(selectedWorkID.map { [$0] } ?? [])
            },
            set: { ids in
                if selectionMode {
                    withAnimation(AppSelectionTransition.animation(reduceMotion: accessibilityReduceMotion)) {
                        selectedIDs = LibrarySelectionPolicy.updatingVisibleSelection(selected: selectedIDs, visible: filteredWorks, newSelection: ids)
                    }
                } else {
                    let previous = Set(selectedWorkID.map { [$0] } ?? [])
                    selectedWorkID = ids.subtracting(previous).first ?? ids.first
                }
            }
        )
    }

    var body: some View {
        libraryContent
            .screenHeaderBar { libraryHeader }
            .transaction { $0.animation = nil }
            .navigationTitle(libraryNavigationTitle)
            .toolbarTitleDisplayMode(selectionMode ? .inline : .inlineLarge)
            .appNativeNavigationChrome()
            .toolbarVisibility(.visible, for: .navigationBar)
            .nativeScreenHeader(isEditing: selectionMode, minimizesOnScroll: false)
            .onChange(of: selectionMode) { _, _ in
                isSearchFocused = false
            }
            .appBackground()
            .toolbar { libraryToolbar }
            .librarySelectionTabBarVisibility(isSelecting: selectionMode)
            .sheet(item: $bulkSourceMigrationRoute) { route in
                BulkSourceMigrationSheet(works: route.works) {}
            }
            .sheet(item: $downloadsWork) { TitleFileAvailabilitySheet(work: $0) }
            .sheet(isPresented: $showsSelectionReview) { selectionReview }
            .sheet(isPresented: $showsFileSyncSettings) {
                NavigationStack {
                    SyncBackupSettingsView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { FixedNavigationChrome { Button("Done") { showsFileSyncSettings = false } } } }
                }
                .appFeedbackOverlay()
            }
            .modifier(TitleReadingConfirmation(action: $readingAction) { action in
                selectionTask = Task {
                    showBatchResult(await model.markSelection(action.snapshots, asRead: action.asRead))
                    await refreshSelectionSnapshots()
                }
            })
            .alert("Selection Results", isPresented: Binding(get: { batchResult != nil }, set: { if !$0 { batchResult = nil } })) {
                Button("OK") { batchResult = nil }
            } message: {
                Text(batchResultMessage)
            }
            .confirmationDialog(
                bulkRemovalTitle,
                isPresented: $isConfirmingBulkRemoval,
                titleVisibility: .visible
            ) {
                bulkRemovalConfirmationButton
                Button("Review Selected Titles") { showsSelectionReview = true }
            } message: {
                Text(bulkRemovalMessage)
            }
            .confirmationDialog(
                contextRemovalTitle,
                isPresented: Binding(
                    get: { contextRemovalWork != nil },
                    set: { if !$0 { contextRemovalWork = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let work = contextRemovalWork {
                    Button(
                        work.sourceID == .local ? "Delete Import" : "Remove from Library",
                        role: work.sourceID == .local ? .destructive : nil
                    ) {
                        removeContextWork(work)
                    }
                }
            } message: {
                Text(contextRemovalMessage)
            }
            .accessibilityAction(named: "Check for Updates") {
                Task { _ = await model.refreshLibraryFromSources() }
            }
            .onChange(of: model.libraryModel.library.map(\.id)) { _, visibleWorkIDs in
                selectedIDs.formIntersection(Set(visibleWorkIDs))
            }
            .task(id: selectedWorks) { await refreshSelectionSnapshots() }
            .onChange(of: selectionMode) { _, isSelecting in
                if !isSelecting { selectedIDs.removeAll() }
            }
            .task(id: model.isReadyForInteraction) {
                guard model.isReadyForInteraction, !didInitializeFilters else { return }
                didInitializeFilters = true
                if model.libraryModel.libraryCategoryScope != .all
                    || model.libraryModel.activeSavedFilterID != nil {
                    model.libraryModel.clearLibraryFilter()
                }
            }
            .onDisappear { readerPreparation.cancel() }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if SourceSkeletonVisibilityPolicy.shouldShow(isLoading: model.libraryModel.isLoading, contentCount: model.libraryModel.library.count) {
            libraryScrollView {
                AppContentSkeleton(kind: model.settingsSyncModel.layoutMode == .grid ? .grid : .rows)
                    .padding(PublicationGridLayout.contentMargin)
            }
        } else if model.libraryModel.library.isEmpty {
            emptyState
        } else {
            libraryItems(filteredWorks)
                .overlay {
                    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       filteredWorks.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .allowsHitTesting(false)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
        }
    }

    private var libraryHeader: some View {
        GlassCapsuleGroup {
            VStack(alignment: .leading, spacing: 12) {
                CompactHeaderSearchField(
                    text: $searchText,
                    isFocused: $isSearchFocused,
                    prompt: String(localized: "Search Library"),
                    accessibilityIdentifier: "library-search-field",
                    onSubmit: { isSearchFocused = false }
                )
                .frame(height: AppDynamicTypeSizing.navigationSearchHeight)

                libraryControls
                if selectionMode { selectionFeedback }
            }
            .padding(.horizontal, AppLayout.pageMargin)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(LibraryHeaderSurface())
        }
    }

    private func libraryScrollView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                content()
            }
        }
    }

    private var libraryControls: some View {
        LibraryLayoutControlsRow(
            sort: Binding(
                get: { model.settingsSyncModel.librarySort },
                set: { model.setSort($0) }
            ),
            layout: Binding(
                get: { model.settingsSyncModel.layoutMode },
                set: { model.setLayout($0) }
            )
        )
        .appFixedNavigationChrome()
    }

    @ViewBuilder
    private func libraryItems(_ works: [Work]) -> some View {
        if model.settingsSyncModel.layoutMode == .grid {
            if horizontalSizeClass == .regular {
                regularLibraryGrid(works)
            } else {
                libraryScrollView {
                    LazyVGrid(
                        columns: PublicationGridLayout.columns(
                            for: dynamicTypeSize,
                            horizontalSizeClass: horizontalSizeClass
                        ),
                        alignment: .leading,
                        spacing: PublicationGridLayout.verticalSpacing
                    ) {
                        ForEach(works) { work in
                            gridItem(for: work) {
                                LibraryGridCell(
                                    work: work,
                                    isBulkSelected: selectedIDs.contains(work.id),
                                    isDetailSelected: !selectionMode && selectedWorkID == work.id
                                )
                                .animation(AppSelectionTransition.animation(reduceMotion: accessibilityReduceMotion),
                                           value: selectedIDs.contains(work.id))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PublicationGridLayout.contentMargin)
                    .animation(accessibilityReduceMotion ? nil : .smooth(duration: 0.35, extraBounce: 0),
                               value: model.libraryModel.pinOrderRevision)
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting { isSearchFocused = false }
                }
                .accessibilityIdentifier("library-grid-scroll")
                .refreshable { await refreshLibraryFromSources() }
            }
        } else {
            List(selection: listSelection) {
                Section {
                    ForEach(works) { work in
                        Group {
                            if selectionMode {
                                LibraryListCell(work: work)
                            } else {
                                Button { selectDetail(work) } label: {
                                    LibraryListCell(work: work)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { titleContextMenu(for: work) }
                            }
                        }
                            .tag(work.id)
                            .listRowBackground(Color.clear)
                            .appFullWidthListSeparator()
                    }
                }
                .textCase(nil)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { isSearchFocused = false }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(selectionMode ? .active : .inactive))
            .disabled(selectionMode && selectionIsBusy)
            .accessibilityIdentifier("library-list-scroll")
            .animation(accessibilityReduceMotion ? nil : .smooth(duration: 0.35, extraBounce: 0),
                       value: model.libraryModel.pinOrderRevision)
            .refreshable { await refreshLibraryFromSources() }
        }
    }

    private func regularLibraryGrid(_ works: [Work]) -> some View {
        NativeLibraryGrid(
            works: works,
            selection: listSelection,
            isSelecting: selectionMode,
            isSelectionEnabled: !selectionMode || !selectionIsBusy,
            textSize: dynamicTypeSize,
            showsHeader: false,
            animatesChanges: !accessibilityReduceMotion,
            onBeginDragging: { isSearchFocused = false },
            contextMenu: { nativeTitleContextMenu(for: $0) },
            card: { work in
                regularGridCard(for: work)
                    .environment(model)
                    .environment(readerPreparation)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
            },
            header: { EmptyView() }
        )
        .refreshable { await refreshLibraryFromSources() }
    }

    @ViewBuilder
    private func regularGridCard(for work: Work) -> some View {
        let card = LibraryGridCell(
            work: work,
            isBulkSelected: selectionMode && selectedIDs.contains(work.id),
            isDetailSelected: !selectionMode && selectedWorkID == work.id
        )
        .accessibilityIdentifier("library-grid-cell-\(work.id)")
        if selectionMode {
            card
                .accessibilityLabel(selectedIDs.contains(work.id) ? "Deselect \(work.title)" : "Select \(work.title)")
                .accessibilityValue((selectedIDs.contains(work.id) ? "Selected" : "Not selected")
                    + (model.libraryModel.pinnedWorkIDs.contains(work.id) ? ", Pinned" : ""))
                .disabled(selectionIsBusy)
        } else {
            card
                .accessibilityHint("Shows title details")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        GeometryReader { geometry in
            libraryScrollView {
                ContentUnavailableView {
                    if dynamicTypeSize.isAccessibilitySize {
                        Text("Start Your Library")
                    } else {
                        Label("Start Your Library", systemImage: "books.vertical")
                    }
                } description: {
                    Text("Import books and comics from Files, or browse your sources to find something to read.")
                } actions: {
                    Button("Import Files", systemImage: "square.and.arrow.down") {
                        model.transfersModel.isImporting = true
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColors.actionFill)
                        .foregroundStyle(AppColors.onAction)
                        .accessibilityIdentifier("library-empty-import")

                    Button("Browse Sources", action: openBrowse)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("library-empty-browse")
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await refreshLibraryFromSources() }
        }
    }

    private func refreshLibraryFromSources() async {
        _ = await model.refreshLibraryFromSources()
    }

    private var libraryNavigationTitle: Text {
        if !selectionMode {
            Text("Library")
        } else if selectedIDs.isEmpty {
            Text("Select Titles")
        } else {
            Text("\(selectedIDs.count) Selected")
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if selectionMode {
            ToolbarItem(placement: .principal) {
                FixedNavigationChrome {
                    Button(action: reviewSelectedTitles) { libraryNavigationTitle }
                        .font(.headline)
                        .accessibilityHint("Reviews all selected titles, including other searches")
                        .accessibilityIdentifier("library-selection-count")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { FixedNavigationChrome { selectionMenu } }
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .confirmationAction) {
                FixedNavigationChrome {
                    Button("Done") { finishSelection() }
                        .disabled(selectionIsBusy)
                        .accessibilityIdentifier("done-selecting-titles")
                }
            }
            selectionToolbar
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                FixedNavigationChrome {
                    Button {
                        model.transfersModel.isImporting = true
                    } label: {
                        Label("Import Files", systemImage: "square.and.arrow.down")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("library-import-files")
                }
            }
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                FixedNavigationChrome {
                    Button("Select") { beginSelection() }
                        .accessibilityIdentifier("select-titles")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        if #available(iOS 26.0, macOS 26.0, *) {
            ToolbarItemGroup(placement: .bottomBar) {
                selectionDownloadButton
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                FixedNavigationChrome {
                    selectionMoreMenu
                }
            }
        } else {
            ToolbarItemGroup(placement: .bottomBar) {
                selectionDownloadButton
                Spacer()
                selectionMoreMenu
            }
        }
    }

    private var selectionDownloadButton: some View {
        Menu {
            NavigationMenuContent {
                Button("Download All") { downloadSelectedTitles(unreadOnly: false, imported: false) }
                    .disabled(!selectionSnapshots.contains { $0.work.sourceID != .local && !$0.missingInstallments.isEmpty })
                Button("Download Unread") { downloadSelectedTitles(unreadOnly: true, imported: false) }
                    .disabled(!selectionSnapshots.contains { $0.work.sourceID != .local && !$0.missingUnreadInstallments.isEmpty })
            }
        } label: { Label("Downloads", systemImage: "arrow.down").labelStyle(.iconOnly) }
        .disabled(selectedIDs.isEmpty || isLoadingSelection || snapshotError != nil || selectionIsBusy || model.transfersModel.isQueuingDownloads)
        .accessibilityIdentifier("selection-download")
        .appFixedNavigationChrome()
    }

    private var selectionMoreMenu: some View {
        Menu {
            NavigationMenuContent {
                bulkSelectionMenu
            }
        } label: { Label("Actions", systemImage: "ellipsis").labelStyle(.iconOnly) }
            .disabled(selectedIDs.isEmpty || selectionIsBusy)
            .accessibilityIdentifier("selection-more")
            .appFixedNavigationChrome()
    }

    @ViewBuilder
    private var bulkSelectionMenu: some View {
        Button("Mark as Read") { confirmReadingAction(for: selectedWorks, asRead: true) }
            .disabled(model.settingsSyncModel.incognitoMode)
        Button("Mark as Unread") { confirmReadingAction(for: selectedWorks, asRead: false) }
            .disabled(model.settingsSyncModel.incognitoMode)
        if model.settingsSyncModel.incognitoMode { Text("Turn off Incognito to change reading progress.") }
        if selectedLocalImportCount > 0 {
            Divider()
            Button("Make Available on This Device") { downloadSelectedTitles(unreadOnly: false, imported: true) }
                .disabled(isLoadingSelection || snapshotError != nil || !selectionSnapshots.contains { $0.work.sourceID == .local && $0.allowsImportedFileSync && !$0.missingInstallments.isEmpty })
            Button("File Sync Settings") { showsFileSyncSettings = true }
        }
        Divider()
        if !unpinnedIDs.isEmpty {
            Button("Pin") { setSelectedTitlesPinned(true) }
        }
        if !pinnedIDs.isEmpty {
            Button("Unpin") { setSelectedTitlesPinned(false) }
        }
        if !migrationCandidates.isEmpty {
            Button("Migrate Sources (\(migrationCandidates.count) titles)") { beginBulkSourceMigration() }
                .disabled(migrationCandidates.count > 50)
            if migrationCandidates.count > 50 { Text("Select no more than 50 eligible titles to migrate.") }
            if migrationCandidates.count < selectedWorks.count {
                Text("\(selectedWorks.count - migrationCandidates.count) imports or titles without another source will be excluded.")
            }
        }
        Divider()
        Button(bulkRemovalActionTitle, systemImage: selectedLocalImportCount > 0 ? "trash" : "bookmark.slash",
               role: selectedLocalImportCount > 0 ? .destructive : nil) {
            pendingRemoval = selectedWorks
            isConfirmingBulkRemoval = true
        }
    }

    @ViewBuilder
    private func gridItem<Label: View>(for work: Work, @ViewBuilder label: () -> Label) -> some View {
        if selectionMode {
            Button {
                withAnimation(AppSelectionTransition.animation(reduceMotion: accessibilityReduceMotion)) {
                    if !selectedIDs.insert(work.id).inserted { selectedIDs.remove(work.id) }
                }
            } label: { label() }
                .buttonStyle(.plain)
                .disabled(selectionIsBusy)
                .accessibilityLabel(selectedIDs.contains(work.id) ? "Deselect \(work.title)" : "Select \(work.title)")
                .accessibilityValue((selectedIDs.contains(work.id) ? "Selected" : "Not selected") + (model.libraryModel.pinnedWorkIDs.contains(work.id) ? ", Pinned" : ""))
                .accessibilityAddTraits(selectedIDs.contains(work.id) ? .isSelected : [])
                .accessibilityIdentifier("library-grid-cell-\(work.id)")
        } else {
            Button { selectDetail(work) } label: { label() }
                .buttonStyle(.plain)
                .contextMenu { titleContextMenu(for: work) }
                .accessibilityHint("Shows title details")
                .accessibilityAddTraits(selectedWorkID == work.id ? .isSelected : [])
                .accessibilityIdentifier("library-grid-cell-\(work.id)")
        }
    }

    @ViewBuilder
    private func titleContextMenu(for work: Work) -> some View {
        if model.libraryModel.continueReadingItemsByWorkID[work.id] != nil {
            Button("Continue Reading", systemImage: "play.fill") { resume(work) }
                .disabled(readerPreparation.isPreparing && readerPreparation.workID == work.id)
        }

        Button("Select") {
            beginSelection(with: [work.id])
        }

        Divider()

        Button(model.libraryModel.pinnedWorkIDs.contains(work.id) ? "Unpin" : "Pin") {
            togglePinned(work)
        }.disabled(selectionIsBusy)

        if work.sourceID == .local {
            Button("File Availability", systemImage: "arrow.down") { downloadsWork = work }
                .disabled(selectionIsBusy)
        } else {
            TitleDownloadMenu(work: work)
        }

        Button("Mark as Read") { confirmReadingAction(for: [work], asRead: true) }
            .disabled(selectionIsBusy || model.settingsSyncModel.incognitoMode)
        Button("Mark as Unread") { confirmReadingAction(for: [work], asRead: false) }
            .disabled(selectionIsBusy || model.settingsSyncModel.incognitoMode)
        if model.settingsSyncModel.incognitoMode { Text("Turn off Incognito to change reading progress.") }

        Divider()

        Button(
            work.sourceID == .local ? "Delete Import" : "Remove from Library",
            systemImage: work.sourceID == .local ? "trash" : "bookmark.slash",
            role: .destructive
        ) {
            contextRemovalWork = work
        }
    }

    private func nativeTitleContextMenu(for work: Work) -> UIMenu {
        var navigation: [UIMenuElement] = []
        if model.libraryModel.continueReadingItemsByWorkID[work.id] != nil {
            navigation.append(UIAction(title: String(localized: "Continue Reading"), image: UIImage(systemName: "play.fill"),
                attributes: readerPreparation.isPreparing && readerPreparation.workID == work.id ? .disabled : []) { _ in resume(work) })
        }
        navigation.append(UIAction(title: String(localized: "Select")) { _ in beginSelection(with: [work.id]) })

        let busy: UIMenuElement.Attributes = selectionIsBusy ? .disabled : []
        var actions: [UIMenuElement] = [UIAction(
            title: model.libraryModel.pinnedWorkIDs.contains(work.id) ? String(localized: "Unpin") : String(localized: "Pin"),
            attributes: busy) { _ in togglePinned(work) }]
        if work.sourceID == .local {
            actions.append(UIAction(title: String(localized: "File Availability"), image: UIImage(systemName: "arrow.down"),
                attributes: busy) { _ in downloadsWork = work })
        } else {
            let disabled: UIMenuElement.Attributes = selectionIsBusy || model.transfersModel.isQueuingDownloads ? .disabled : []
            actions.append(UIMenu(title: String(localized: "Downloads"), image: UIImage(systemName: "arrow.down"), children: [
                UIAction(title: String(localized: "Download All"), attributes: disabled) { _ in
                    Task { model.showSelectionResult(await model.downloadTitle(work, unreadOnly: false)) }
                },
                UIAction(title: String(localized: "Download Unread"), attributes: disabled) { _ in
                    Task { model.showSelectionResult(await model.downloadTitle(work, unreadOnly: true)) }
                }
            ]))
        }
        let progressDisabled: UIMenuElement.Attributes = selectionIsBusy || model.settingsSyncModel.incognitoMode ? .disabled : []
        actions.append(UIMenu(
            title: model.settingsSyncModel.incognitoMode ? String(localized: "Turn off Incognito to change reading progress.") : "",
            options: .displayInline, children: [
                UIAction(title: String(localized: "Mark as Read"), attributes: progressDisabled) { _ in
                    confirmReadingAction(for: [work], asRead: true)
                },
                UIAction(title: String(localized: "Mark as Unread"), attributes: progressDisabled) { _ in
                    confirmReadingAction(for: [work], asRead: false)
                }
            ]))
        let removal = UIAction(
            title: work.sourceID == .local ? String(localized: "Delete Import") : String(localized: "Remove from Library"),
            image: UIImage(systemName: work.sourceID == .local ? "trash" : "bookmark.slash"), attributes: .destructive
        ) { _ in contextRemovalWork = work }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: navigation),
            UIMenu(options: .displayInline, children: actions),
            UIMenu(options: .displayInline, children: [removal])
        ])
    }

    private func togglePinned(_ work: Work) {
        let pinned = !model.libraryModel.pinnedWorkIDs.contains(work.id)
        Task {
            showBatchResult(await model.runSelectionBatch(works: [work]) { work in
                await model.libraryModel.setPinned(pinned, for: [work.id]) ? .completed : .failed("Couldn’t update pin status.")
            })
        }
    }

    private func resume(_ work: Work) {
        if work.kind == .lightNovel || work.kind == .book {
            readerPreparation.cancel()
            readerCoordinator.open(.init(work: work, target: .continuation(chapters: nil)))
            return
        }
        readerPreparation.start(workID: work.id, installmentID: nil) {
            guard let item = await model.libraryModel.continueReadingItem(for: work) else {
                guard !Task.isCancelled else { return nil }
                model.feedback.alert = AppAlert(
                    title: "Nothing to continue",
                    message: "No readable chapter could be found for this title."
                )
                return nil
            }
            guard !Task.isCancelled else { return nil }
            return await model.prepareToResume(item)
        } present: { prepared in
            readerCoordinator.present(prepared)
        }
    }

    private func beginSelection(with initialSelection: Set<WorkID> = []) {
        isSearchFocused = false
        selectedWorkID = nil
        selectedIDs = initialSelection
        selectionMode = true
    }

    private func beginBulkSourceMigration() {
        guard !selectedIDs.isEmpty else { return }
        bulkSourceMigrationRoute = BulkSourceMigrationRoute(
            works: migrationCandidates
        )
    }

    private func downloadSelectedTitles(unreadOnly: Bool, imported: Bool) {
        guard !selectionIsBusy else { return }
        let snapshot = selectionSnapshots.filter {
            ($0.work.sourceID == .local) == imported && (!imported || $0.allowsImportedFileSync)
        }
        selectionTask = Task {
            showBatchResult(await model.downloadSelection(snapshot, unreadOnly: unreadOnly, imported: imported))
            await refreshSelectionSnapshots()
        }
    }

    private func confirmReadingAction(for works: [Work], asRead: Bool) {
        Task { readingAction = await model.prepareTitleReadingAction(works: works, asRead: asRead) }
    }

    private func setSelectedTitlesPinned(_ isPinned: Bool) {
        let ids = isPinned ? unpinnedIDs : pinnedIDs
        let works = selectedWorks.filter { ids.contains($0.id) }
        selectionTask = Task { showBatchResult(await model.pinSelection(works, isPinned: isPinned)) }
    }

    private func showBatchResult(_ result: LibrarySelectionBatchResult?) {
        guard let result else { return }
        if result.failures.isEmpty { model.feedback.showStatus(result.summary) }
        else { model.feedback.alert = nil; batchResult = result }
    }

    private var batchResultMessage: String {
        guard let batchResult else { return "" }
        return batchResult.summary + "\n" + batchResult.failures.sorted { $0.key.description < $1.key.description }.map { id, message in
            "\(model.libraryModel.library.first { $0.id == id }?.title ?? "Title"): \(message)"
        }.joined(separator: "\n")
    }

    private func refreshSelectionSnapshots() async {
        let works = selectedWorks
        let loadID = UUID()
        selectionLoadID = loadID
        isLoadingSelection = true
        defer { if selectionLoadID == loadID { isLoadingSelection = false } }
        do {
            let snapshots = try await model.selectionSnapshots(for: works)
            guard !Task.isCancelled, Set(works.map(\.id)) == selectedIDs else { return }
            selectionSnapshots = snapshots
            snapshotError = nil
        } catch is CancellationError { }
        catch {
            guard selectionLoadID == loadID else { return }
            selectionSnapshots = []; snapshotError = error.localizedDescription
        }
    }

    private var selectionMenu: some View {
        Menu {
            NavigationMenuContent {
                Button("Select All") {
                    withAnimation(AppSelectionTransition.animation(reduceMotion: accessibilityReduceMotion)) {
                        selectedIDs = LibrarySelectionPolicy.selectingAllResults(selected: selectedIDs, visible: filteredWorks)
                    }
                }
                .disabled(filteredWorks.isEmpty || selectionIsBusy)
                .accessibilityIdentifier("library-select-all")
                Button("Deselect All") {
                    withAnimation(AppSelectionTransition.animation(reduceMotion: accessibilityReduceMotion)) { selectedIDs.removeAll() }
                }
                .disabled(selectedIDs.isEmpty || selectionIsBusy)
                .accessibilityIdentifier("library-deselect-all")
                Divider()
                Button("Review Selected Titles", action: reviewSelectedTitles)
                    .disabled(selectedIDs.isEmpty)
            }
        } label: { Text("Selection") }
        .accessibilityIdentifier("library-selection-menu")
    }

    private func reviewSelectedTitles() {
        showsSelectionReview = true
    }

    private var selectionFeedback: some View {
        VStack(alignment: .leading, spacing: 8) {
            if selectionIsBusy {
                let progressLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout())
                progressLayout {
                    ProgressView("Applying selection action…")
                    if selectionTask != nil { Button("Cancel") { selectionTask?.cancel() } }
                }
            }
            if let snapshotError {
                Text(snapshotError).font(.footnote).foregroundStyle(.secondary)
                Button("Retry") { Task { await refreshSelectionSnapshots() } }
            }
        }
    }

    private var selectionReview: some View {
        NavigationStack {
            List {
                ForEach(selectedWorks) { work in
                    HStack {
                        Text(work.title)
                        Spacer()
                        Button("Deselect", systemImage: "minus.circle") { selectedIDs.remove(work.id) }
                            .labelStyle(.iconOnly).accessibilityLabel("Deselect \(work.title)")
                            .disabled(selectionIsBusy)
                    }
                }
            }
            .overlay { if selectedWorks.isEmpty { ContentUnavailableView("No Selected Titles", systemImage: "checklist") } }
            .navigationTitle("Selected Titles")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    FixedNavigationChrome {
                        Button("Deselect All") { selectedIDs.removeAll() }.disabled(selectionIsBusy || selectedIDs.isEmpty)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { FixedNavigationChrome { Button("Done") { showsSelectionReview = false } } }
            }
        }
        .appFeedbackOverlay()
    }

    private func finishSelection() {
        isSearchFocused = false
        selectedIDs.removeAll()
        selectionMode = false
    }

    private var bulkRemovalActionTitle: String {
        if selectedLocalImportCount == 0 { return "Remove from Library" }
        if selectedRemoteCount == 0 { return "Delete Imports" }
        return "Remove and Delete"
    }

    private var removalLocalCount: Int { pendingRemoval.count { $0.sourceID == .local } }
    private var removalRemoteCount: Int { pendingRemoval.count - removalLocalCount }

    private var bulkRemovalTitle: String {
        if removalLocalCount == 0 { return "Remove selected titles from Library?" }
        if removalRemoteCount == 0 { return "Delete selected imports?" }
        return "Remove remote titles and delete imports?"
    }

    private var bulkRemovalMessage: String {
        if removalLocalCount == 0 {
            return "\(removalRemoteCount) remote titles selected. Reading data, annotations, tracking, and downloads will be kept. You can add these titles again at any time."
        }
        if removalRemoteCount == 0 {
            return "\(removalLocalCount) imports selected. This permanently deletes their imported files, reading progress, annotations, downloads, and other saved data."
        }
        return "\(removalRemoteCount) remote titles will keep their reading data and downloads. \(removalLocalCount) imported files and all their saved data will be permanently deleted."
    }

    @ViewBuilder
    private var bulkRemovalConfirmationButton: some View {
        if removalLocalCount > 0 {
            Button(
                removalRemoteCount == 0
                    ? "Delete \(removalLocalCount) Imports"
                    : "Remove and Delete \(pendingRemoval.count) Titles",
                role: .destructive,
                action: performBulkRemoval
            )
        } else {
            Button("Remove \(removalRemoteCount) Titles", action: performBulkRemoval)
        }
    }

    private func performBulkRemoval() {
        let works = pendingRemoval
        selectionTask = Task {
            let result = await model.runSelectionBatch(works: works) { work in
                await model.removeFromLibrary(workIDs: [work.id]) ? .completed : .failed("Couldn’t remove this title. Retry.")
            }
            if let result { selectedIDs.subtract(result.completed) }
            showBatchResult(result)
        }
    }

    private var contextRemovalTitle: String {
        guard let work = contextRemovalWork else { return "Remove title?" }
        return work.sourceID == .local ? "Delete \(work.title)?" : "Remove \(work.title) from Library?"
    }

    private var contextRemovalMessage: String {
        guard contextRemovalWork?.sourceID == .local else {
            return "Reading data, annotations, tracking, and downloads will be kept. You can add this title again at any time."
        }
        return "This permanently deletes the imported files, reading progress, annotations, downloads, and other saved data for this title."
    }

    private func removeContextWork(_ work: Work) {
        contextRemovalWork = nil
        Task {
            let result = await model.runSelectionBatch(works: [work]) { work in
                await model.removeFromLibrary(workIDs: [work.id]) ? .completed : .failed("Couldn’t remove this title.")
            }
            if result?.completed.contains(work.id) == true, selectedWorkID == work.id { selectedWorkID = nil }
            showBatchResult(result)
        }
    }

    private func selectDetail(_ work: Work) {
        selectedWorkID = work.id
    }
}

private extension View {
    @ViewBuilder
    func librarySelectionTabBarVisibility(isSelecting: Bool) -> some View {
#if targetEnvironment(macCatalyst)
        self
#else
        toolbarVisibility(isSelecting ? .hidden : .automatic, for: .tabBar)
#endif
    }
}

extension LibrarySort {
    var displayName: String {
        switch self {
        case .title: "Title"
        case .recentlyAdded: "Recently Added"
        case .recentlyRead: "Recently Read"
        case .unread: "Unread"
        case .lastUpdated: "Last Updated"
        }
    }
}

extension ContentKind {
    var displayName: String {
        switch self {
        case .manga: "Manga"
        case .comic: "Comic"
        case .lightNovel: "Light Novel"
        case .book: "Book"
        }
    }
}

struct LibrarySelectionSnapshot: Sendable {
    let work: Work
    let installments: [Installment]
    let unreadIDs: Set<InstallmentID>
    let missingIDs: Set<InstallmentID>
    let allowsImportedFileSync: Bool

    var missingInstallments: [Installment] { installments.filter { missingIDs.contains($0.id) } }
    var missingUnreadInstallments: [Installment] { missingInstallments.filter { unreadIDs.contains($0.id) } }
}

enum LibrarySelectionPolicy {
    static func updatingVisibleSelection(selected: Set<WorkID>, visible: [Work], newSelection: Set<WorkID>) -> Set<WorkID> {
        let visibleIDs = Set(visible.map(\.id))
        return selected.subtracting(visibleIDs).union(newSelection.intersection(visibleIDs))
    }
    static func selectingAllResults(selected: Set<WorkID>, visible: [Work]) -> Set<WorkID> {
        selected.union(visible.map(\.id))
    }
    static func migrationCandidates(_ works: [Work], sources: [SourceDescriptor]) -> [Work] {
        works.filter { work in
            work.sourceID != .local && sources.contains {
                $0.isEnabled && $0.kind != .local && $0.id != work.sourceID
            }
        }
    }
}

struct LibrarySelectionBatchResult: Sendable {
    var completed: Set<WorkID> = []
    var skipped: Set<WorkID> = []
    var failures: [WorkID: String] = [:]
    var summary: String { "\(completed.count) completed · \(skipped.count) skipped · \(failures.count) failed" }
}

enum LibrarySelectionOutcome {
    case completed, skipped, failed(String)
}

extension AppModel {
    func selectionSnapshots(for works: [Work]) async throws -> [LibrarySelectionSnapshot] {
        guard let database else { throw WorkDetailLoadError.storageUnavailable }
        var snapshots: [LibrarySelectionSnapshot] = []
        for work in works {
            try Task.checkCancellation()
            let installments = try await database.installments(for: work.id)
            let completed = Set(try await database.progresses(for: work.id)
                .filter { $0.highestProgression >= 1 }.map(\.installmentID))
            let unread = Set(installments.map(\.id)).subtracting(completed)
            var missing: Set<InstallmentID> = []
            for installment in installments {
                try Task.checkCancellation()
                if let url = installment.acquisitionURL, url.isFileURL,
                   FileManager.default.fileExists(atPath: url.path) { continue }
                if work.sourceID == .local, let importedOriginalCloudOrchestrator,
                   (try? await importedOriginalCloudOrchestrator.localFileURL(for: installment)) != nil { continue }
                missing.insert(installment.id)
            }
            let policy = try await database.libraryEntry(for: work.id)?.cloudFilePolicy ?? .inheritGlobal
            snapshots.append(LibrarySelectionSnapshot(
                work: work, installments: installments, unreadIDs: unread,
                missingIDs: missing,
                allowsImportedFileSync: ImportedOriginalCloudPolicyResolver.shouldSync(
                    globalImportedFileSyncEnabled: settingsSyncModel.syncImportedFiles, titlePolicy: policy
                )
            ))
        }
        return snapshots
    }

    /// The shared gate covers title context menus and Library batches, including await suspension.
    func runSelectionBatch(
        works: [Work],
        finalize: @MainActor (LibrarySelectionBatchResult) async -> Void = { _ in },
        operation: @MainActor (Work) async -> LibrarySelectionOutcome
    ) async -> LibrarySelectionBatchResult? {
        guard !libraryModel.isPerformingSelectionAction,
              !libraryModel.isApplyingBulkSourceMigration else { return nil }
        libraryModel.isPerformingSelectionAction = true
        defer { libraryModel.isPerformingSelectionAction = false }
        var result = LibrarySelectionBatchResult()
        for work in works {
            guard !Task.isCancelled else {
                result.failures[work.id] = "Cancelled before this title was processed."
                continue
            }
            switch await operation(work) {
            case .completed: result.completed.insert(work.id)
            case .skipped: result.skipped.insert(work.id)
            case let .failed(message): result.failures[work.id] = message
            }
        }
        await finalize(result)
        return result
    }

    func downloadSelection(_ snapshots: [LibrarySelectionSnapshot], unreadOnly: Bool, imported: Bool) async -> LibrarySelectionBatchResult? {
        guard !transfersModel.isQueuingDownloads else { return nil }
        return await runSelectionBatch(works: snapshots.map(\.work)) { work in
            guard let snapshot = snapshots.first(where: { $0.work.id == work.id }),
                  (work.sourceID == .local) == imported else { return .skipped }
            let items = unreadOnly ? snapshot.missingUnreadInstallments : snapshot.missingInstallments
            guard !items.isEmpty else { return .skipped }
            if imported {
                guard snapshot.allowsImportedFileSync else { return .failed("Imported-file sync is off. Open File Sync Settings or this title’s Original File options.") }
                for installment in items {
                    guard !Task.isCancelled else { return .failed("Cancelled. Completed files remain available.") }
                    guard await self.prepareImportedBook(work: work, installment: installment, announcesFailure: false) != nil else {
                        return .failed(self.importedFileAvailability[installment.id]?.title ?? "File preparation failed. Try again.")
                    }
                }
                return .completed
            }
            let result = await self.downloadAll(work, installments: items)
            if !result.isSuccessful { return .failed("Some chapters could not be queued. Retry the title; available chapters will be skipped.") }
            return result.queuedCount > 0 ? .completed : .skipped
        }
    }

    func prepareTitleReadingAction(works: [Work], asRead: Bool) async -> TitleReadingAction? {
        guard !libraryModel.isPerformingSelectionAction, !libraryModel.isApplyingBulkSourceMigration,
              !settingsSyncModel.incognitoMode else { return nil }
        libraryModel.isPerformingSelectionAction = true
        defer { libraryModel.isPerformingSelectionAction = false }
        do {
            let snapshots = try await selectionSnapshots(for: works)
            let count = snapshots.reduce(0) { $0 + (asRead ? $1.unreadIDs.count : $1.installments.count) }
            guard count > 0 else {
                feedback.showStatus(asRead ? "No unread stored chapters in these titles." : "No stored chapters in these titles.")
                return nil
            }
            return TitleReadingAction(snapshots: snapshots, asRead: asRead)
        } catch is CancellationError { return nil }
        catch {
            feedback.alert = AppAlert(title: "Couldn’t load chapters", message: error.localizedDescription)
            return nil
        }
    }

    func markSelection(_ snapshots: [LibrarySelectionSnapshot], asRead: Bool) async -> LibrarySelectionBatchResult? {
        if asRead { return await markSelectionRead(snapshots) }
        guard !settingsSyncModel.incognitoMode else { return nil }
        return await runSelectionBatch(works: snapshots.map(\.work), finalize: { _ in
            await self.libraryModel.refreshLibrary(showsLoadingIndicator: false)
            await self.libraryModel.refreshHistory()
        }) { work in
            guard let snapshot = snapshots.first(where: { $0.work.id == work.id }), !snapshot.installments.isEmpty else { return .skipped }
            return await self.resetReadingProgress(work: work, installments: snapshot.installments, announces: false)
                ? .completed : .failed("Couldn’t mark this title as unread. Retry this title.")
        }
    }

    func pinSelection(_ works: [Work], isPinned: Bool) async -> LibrarySelectionBatchResult? {
        guard !libraryModel.isPerformingSelectionAction, !libraryModel.isApplyingBulkSourceMigration else { return nil }
        libraryModel.isPerformingSelectionAction = true
        defer { libraryModel.isPerformingSelectionAction = false }
        let ids = Set(works.map(\.id))
        guard !Task.isCancelled else { return LibrarySelectionBatchResult(failures: Dictionary(uniqueKeysWithValues: ids.map { ($0, "Cancelled before pin status changed.") })) }
        guard !ids.isEmpty else { return LibrarySelectionBatchResult() }
        if await libraryModel.setPinned(isPinned, for: ids) { return LibrarySelectionBatchResult(completed: ids) }
        return LibrarySelectionBatchResult(failures: Dictionary(uniqueKeysWithValues: ids.map { ($0, "Couldn’t update pin status.") }))
    }

    func downloadTitle(_ work: Work, unreadOnly: Bool) async -> LibrarySelectionBatchResult? {
        guard !libraryModel.isPerformingSelectionAction, !libraryModel.isApplyingBulkSourceMigration,
              !transfersModel.isQueuingDownloads else { return nil }
        libraryModel.isPerformingSelectionAction = true
        let snapshots: [LibrarySelectionSnapshot]
        do { snapshots = try await selectionSnapshots(for: [work]) }
        catch {
            libraryModel.isPerformingSelectionAction = false
            feedback.alert = AppAlert(title: "Couldn’t load chapters", message: error.localizedDescription)
            return nil
        }
        libraryModel.isPerformingSelectionAction = false
        return await downloadSelection(snapshots, unreadOnly: unreadOnly, imported: false)
    }

    func showSelectionResult(_ result: LibrarySelectionBatchResult?) {
        guard let result else { return }
        if result.failures.isEmpty { feedback.showStatus(result.summary) }
        else { feedback.alert = AppAlert(title: "Selection Results", message: result.summary + "\n" + result.failures.values.sorted().joined(separator: "\n")) }
    }

    func markSelectionRead(_ snapshots: [LibrarySelectionSnapshot]) async -> LibrarySelectionBatchResult? {
        guard !settingsSyncModel.incognitoMode else { return nil }
        let result = await runSelectionBatch(works: snapshots.map(\.work), finalize: { result in
            await self.libraryModel.refreshLibrary()
            await self.libraryModel.refreshHistory()
            if !result.completed.isEmpty, self.settingsSyncModel.automationRules.deletesCompletedDownloads {
                await self.performReadingCompletedLibraryMaintenance()
            }
        }) { work in
            guard let snapshot = snapshots.first(where: { $0.work.id == work.id }) else { return .skipped }
            let unread = snapshot.installments.filter { snapshot.unreadIDs.contains($0.id) }
            guard !unread.isEmpty else { return .skipped }
            var didFail = false
            for installment in unread {
                guard !Task.isCancelled else { return .failed("Cancelled. Retry to mark the remaining chapters.") }
                if !self.settingsSyncModel.incognitoMode,
                   await self.markRead(work: work, installment: installment, announces: false, runsAutomation: false) {
                    continue
                }
                didFail = true
            }
            return didFail ? .failed("Some chapters could not be marked read. Retry this title.") : .completed
        }
        guard let result else { return nil }
        return result
    }
}

struct TitleReadingAction {
    let snapshots: [LibrarySelectionSnapshot]
    let asRead: Bool
    var chapterCount: Int { snapshots.reduce(0) { $0 + (asRead ? $1.unreadIDs.count : $1.installments.count) } }
}

struct TitleReadingConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var action: TitleReadingAction?
    let confirm: (TitleReadingAction) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            action?.asRead == false ? "Mark titles as unread?" : "Mark titles as read?",
            isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }),
            titleVisibility: .visible
        ) {
            if let pending = action {
                Button("Mark \(pending.chapterCount) Chapters as \(pending.asRead ? "Read" : "Unread")") {
                    action = nil
                    confirm(pending)
                }
            }
        } message: {
            if let pending = action {
                Text(pending.asRead
                    ? "\(pending.snapshots.count) titles · \(pending.chapterCount) unread stored chapters. Unloaded chapters are excluded."
                        + (model.settingsSyncModel.automationRules.deletesCompletedDownloads ? " Completed-download cleanup is enabled and may delete downloaded chapters." : "")
                    : "\(pending.snapshots.count) titles · \(pending.chapterCount) stored chapters will reset to the beginning. Downloads, bookmarks, notes, and reading history will be kept.")
            }
        }
    }
}

struct TitleDownloadMenu: View {
    @Environment(AppModel.self) private var model
    let work: Work
    var usesHeaderStyle = false

    var body: some View {
        Menu {
            NavigationMenuContent {
                Button("Download All") { download(unreadOnly: false) }
                Button("Download Unread") { download(unreadOnly: true) }
            }
        } label: {
            if usesHeaderStyle { WorkDetailHeaderIconLabel(systemImage: "arrow.down") }
            else { Label("Downloads", systemImage: "arrow.down") }
        }
        .disabled(model.libraryModel.isPerformingSelectionAction || model.libraryModel.isApplyingBulkSourceMigration || model.transfersModel.isQueuingDownloads)
        .accessibilityLabel("Downloads")
        .accessibilityIdentifier("title-download-menu")
    }

    private func download(unreadOnly: Bool) {
        Task { model.showSelectionResult(await model.downloadTitle(work, unreadOnly: unreadOnly)) }
    }
}

/// Shared by title details and Library context menus; original files never use the source downloader.
struct TitleFileAvailabilitySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let work: Work
    @State private var snapshots: [LibrarySelectionSnapshot] = []
    @State private var isLoading = true
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    @State private var isWorking = false
    @State private var failedDownload = false
    @State private var lastUnreadOnly = false

    private var availability: ImportedFileAvailability? {
        if isWorking { return .checking }
        if failedDownload, let message { return .failed(message) }
        guard let snapshot = snapshots.first, !snapshot.installments.isEmpty else { return nil }
        if snapshot.missingIDs.isEmpty { return .ready }
        guard work.sourceID == .local else { return nil }
        return snapshot.allowsImportedFileSync ? .waitingForCloud : .syncDisabled
    }

    private var availabilityExplanation: String? {
        if let explanation = availability?.explanation { return explanation }
        if let message { return message }
        if snapshots.first?.installments.isEmpty == true {
            return "No stored chapters. Open this title to load its chapters."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(work.title).font(.headline) }
                Section {
                    if isLoading {
                        ProgressView("Checking files…")
                    } else if let availability {
                        ImportedFileStatusLabel(state: availability)
                    } else if snapshots.first?.installments.isEmpty == true {
                        Label("No stored chapters", systemImage: "doc")
                    } else if snapshots.first != nil {
                        Label("Some chapters aren’t downloaded", systemImage: "arrow.down.circle")
                    }
                    if isWorking {
                        Button("Cancel") { operation?.cancel() }
                            .accessibilityIdentifier("imported-file-cancel")
                    } else if failedDownload || (message != nil && snapshots.isEmpty) {
                        Button("Retry") {
                            if failedDownload { download(unreadOnly: lastUnreadOnly) }
                            else { Task { await reload() } }
                        }
                        .disabled(isLoading || model.libraryModel.isPerformingSelectionAction)
                        .accessibilityIdentifier("imported-file-retry")
                    } else if let snapshot = snapshots.first,
                              work.sourceID == .local,
                              snapshot.allowsImportedFileSync,
                              !snapshot.missingIDs.isEmpty {
                        Button("Make Available on This Device") { download(unreadOnly: false) }
                            .disabled(isLoading || model.libraryModel.isPerformingSelectionAction)
                            .accessibilityIdentifier("imported-file-download")
                    }
                } header: {
                    Text("Availability")
                } footer: {
                    if let explanation = availabilityExplanation { Text(explanation) }
                }
                if work.sourceID == .local {
                    ImportedFileSyncSection(work: work, isBusy: isWorking || isLoading) {
                        message = nil
                        failedDownload = false
                        await reload()
                    }
                }
            }
            .formStyle(.grouped)
            .accessibilityIdentifier("title-file-availability-form")
            .navigationTitle("File Availability")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar { ToolbarItem(placement: .confirmationAction) { FixedNavigationChrome { Button("Done") { dismiss() } } } }
        }
        .appFeedbackOverlay()
        .task { await reload() }
        .onDisappear { operation?.cancel() }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            snapshots = try await model.selectionSnapshots(for: [work])
            if !failedDownload { message = nil }
        }
        catch { message = error.localizedDescription }
    }
    private func download(unreadOnly: Bool) {
        guard !isWorking else { return }
        isWorking = true
        lastUnreadOnly = unreadOnly
        let snapshot = snapshots
        operation = Task {
            defer { isWorking = false; operation = nil }
            if let result = await model.downloadSelection(snapshot, unreadOnly: unreadOnly, imported: work.sourceID == .local) {
                failedDownload = !result.failures.isEmpty
                message = result.summary + (result.failures[work.id].map { "\n" + $0 } ?? "")
            }
            await reload()
        }
    }
}


struct LibraryLayoutControlsRow: View {
    @Binding var sort: LibrarySort
    @Binding var layout: AppModel.LayoutMode

    var body: some View {
        HStack(spacing: 12) {
            NativeMenuPicker(
                title: String(localized: "Sort Library"),
                selection: $sort,
                options: LibrarySort.allCases.map { ($0.displayName, $0) },
                visibleTitle: nil
            )
            .accessibilityIdentifier("library-sort-menu")
            .padding(.horizontal, 12)
            .modifier(LibrarySortCapsule())
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Library Layout", selection: $layout) {
                Label("Grid", systemImage: "square.grid.2x2")
                    .labelStyle(.iconOnly).tag(AppModel.LayoutMode.grid)
                Label("List", systemImage: "list.bullet")
                    .labelStyle(.iconOnly).tag(AppModel.LayoutMode.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Library Layout")
            .accessibilityValue(layout == .grid ? Text("Grid") : Text("List"))
            .tint(.primary)
            .frame(width: AppDynamicTypeSizing.navigationLayoutPickerWidth)
            .accessibilityIdentifier("library-layout-picker")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appFixedNavigationChrome()
    }
}

private struct LibrarySortCapsule: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
#if !targetEnvironment(macCatalyst)
        if reduceTransparency {
            content.background(AppColors.background, in: Capsule())
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
#else
        content.background(
            reduceTransparency ? AnyShapeStyle(AppColors.background) : AnyShapeStyle(Material.regular),
            in: Capsule()
        )
#endif
    }
}

private struct LibraryHeaderSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
#if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            content
        } else {
            content.screenHeaderSurface()
        }
#else
        content.screenHeaderSurface()
#endif
    }
}
