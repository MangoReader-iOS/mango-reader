import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSources
import Observation
import PhotosUI
import SwiftUI

@MainActor @Observable
final class TrackerStatusEditState {
    private(set) var value: TrackerReadingStatus?
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var revision = 0
    private var persisted: TrackerReadingStatus?

    func load(_ value: TrackerReadingStatus?, expectedRevision: Int? = nil) {
        guard !isSaving, expectedRevision == nil || expectedRevision == revision else { return }
        self.value = value
        persisted = value
    }

    @discardableResult
    func choose(
        _ value: TrackerReadingStatus?,
        save: @escaping @MainActor (TrackerReadingStatus?) async -> Bool
    ) -> Task<Void, Never>? {
        guard !isSaving, self.value != value else { return nil }
        self.value = value
        revision &+= 1
        isSaving = true
        errorMessage = nil
        return Task {
            if await save(value) {
                persisted = value
            } else {
                self.value = persisted
                errorMessage = "Couldn’t save reading status. Try again."
            }
            isSaving = false
        }
    }
}

enum TrackerMatchSearchState {
    case searching
    case results([TrackerMatch])
    case failed(String)

    var isSearching: Bool {
        if case .searching = self { true } else { false }
    }

    static func load(
        _ search: @MainActor () async throws -> [TrackerMatch]
    ) async -> Self? {
        do {
            let matches = try await search()
            guard !Task.isCancelled else { return nil }
            return .results(matches)
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            return .failed(error.localizedDescription)
        }
    }
}

struct TrackerTitleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let work: Work
    let installments: [Installment]

    @State private var links: [TrackerLink] = []
    @State private var isSyncing = false
    @State private var isSearching = false
    @State private var searchTracker: InstalledRepositorySource?
    @State private var syncMessage: String?
    @State private var statusEdit = TrackerStatusEditState()
    @State private var ratingSave = RatingSaveState()
    @State private var titleState: UserTitleState?
    @State private var ratingError: String?
    @State private var dateOrderError: String?
    @State private var workingTrackerIDs: Set<String> = []
    @State private var importPreview: TrackerImportPreview?
    @State private var isShowingProgressReview = false
    @State private var progressReviewError: String?
    @State private var selectedDetent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        RemoteCover(work: work)
                            .frame(width: 44, height: 66)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(work.title).font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Your reading, across your trackers")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                }
                Section("Your Reading") {
                    Picker("Status", selection: Binding(
                        get: { statusEdit.value },
                        set: { value in
                            guard !model.settingsSyncModel.incognitoMode else { return }
                            var start = titleState?.startDate
                            var finish = titleState?.finishDate
                            if value != statusEdit.value {
                                if (value == .reading || value == .rereading), start == nil { start = TrackerDate(.now) }
                                if value == .completed, finish == nil { finish = TrackerDate(.now) }
                            }
                            guard TrackerDate.areOrdered(start: start, finish: finish) else {
                                dateOrderError = String(localized: "Finish date must be on or after start date. Edit your reading dates before changing status.")
                                return
                            }
                            dateOrderError = nil
                            statusEdit.choose(value) { status in
                                guard await model.prepareTitleTracking(work: work, installments: installments) else { return false }
                                let saved = await model.updateReadingStatus(for: work.id, status: status)
                                await reload()
                                return saved
                            }
                        }
                    )) {
                        Text("Not Set").tag(Optional<TrackerReadingStatus>.none)
                        ForEach(TrackerReadingStatus.allCases, id: \.self) { value in
                            Text(value.displayName).tag(Optional(value))
                        }
                    }
                    .disabled(model.settingsSyncModel.incognitoMode || statusEdit.isSaving || ratingSave.isSaving)
                    Menu {
                        Picker("Score", selection: scoreSelection) {
                            Text("Unrated").tag(Optional<Int>.none)
                            ForEach(1 ... 10, id: \.self) { Text("\($0) / 10").tag(Optional($0)) }
                        }
                    } label: {
                        LabeledContent("Score", value: ratingSave.selectedRating.map { "\($0) / 10" } ?? String(localized: "Unrated"))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.settingsSyncModel.incognitoMode || statusEdit.isSaving)
                    .accessibilityIdentifier("tracking-score-picker")
                    dateLink(.startDate)
                    dateLink(.finishDate)
                    if statusEdit.isSaving || ratingSave.isSaving { ProgressView("Saving tracking…") }
                    if let ratingError { Text(ratingError).foregroundStyle(.secondary) }
                    if let dateOrderError { Text(dateOrderError).foregroundStyle(.red) }
                    if let message = statusEdit.errorMessage {
                        Label(message, systemImage: "exclamationmark.circle")
                            .foregroundStyle(AppColors.warning)
                    }
                    if model.settingsSyncModel.incognitoMode {
                        Text("Turn off Incognito Reading in Settings to change status, find matches, or sync trackers.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = model.trackingModel.trackerSyncErrors[work.id] {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(AppColors.warning)
                    }
                }

                if model.trackingModel.enabledTrackerInstallations.isEmpty {
                    ContentUnavailableView(
                        "No Trackers Enabled",
                        systemImage: "link.badge.plus",
                        description: Text("Install and enable an AniList or MAL tracker extension in Settings.")
                    )
                    NavigationLink("Set Up Trackers") { TrackerSettingsView() }
                }

                if !links.isEmpty {
                    Section {
                        Button("Sync All", systemImage: "arrow.trianglehead.2.clockwise.rotate.90", action: syncAll)
                            .disabled(isSyncing || !workingTrackerIDs.isEmpty || model.settingsSyncModel.incognitoMode)
                        if isSyncing { ProgressView("Syncing trackers…") }
                        if let syncMessage { Text(syncMessage).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                ForEach(model.trackingModel.enabledTrackerInstallations) { installed in
                    trackerSection(installed)
                }
            }
            .appInsetGroupedList()
            .navigationTitle("Tracking")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    FixedNavigationChrome {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .navigationDestination(isPresented: $isSearching) {
                if let installed = searchTracker {
                    TrackerMatchSearchView(work: work, installments: installments, installed: installed) {
                        isSearching = false
                        await reload()
                    }
                }
            }
            .task { await reload() }
            .navigationDestination(isPresented: $isShowingProgressReview) {
                if let importPreview {
                    TrackerImportReviewView(work: work, preview: importPreview) {
                        isShowingProgressReview = false
                        await reload()
                    }
                }
            }

        }
        .presentationDetents(isSearching ? [.large] : [.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func trackerSection(_ installed: InstalledRepositorySource) -> some View {
        let trackerID = model.trackingModel.trackerID(for: installed)
        let link = links.first { $0.trackerID == trackerID }
        Section(installed.descriptor.name) {
            if let link {
                VStack(alignment: .leading, spacing: 5) {
                    Text(link.remoteTitle).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if link.conflicts.isEmpty {
                        Label(linkState(link).displayName, systemImage: "link")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Needs attention")
                            .font(.caption).foregroundStyle(AppColors.danger)
                    }
                }
                if let remote = link.lastRemote {
                    LabeledContent("Status", value: remote.status?.displayName ?? String(localized: "Not Set"))
                    LabeledContent("Chapters", value: progressText(remote.chapter, total: remote.totalChapters))
                    if remote.volume != nil || remote.totalVolumes != nil {
                        LabeledContent("Volumes", value: progressText(remote.volume, total: remote.totalVolumes))
                    }
                    DisclosureGroup("Tracker Details") {
                        LabeledContent("Score", value: remote.score.map { "\($0.formatted()) / 10" } ?? String(localized: "Unrated"))
                        LabeledContent("Start Date", value: remote.startDate?.displayText ?? String(localized: "Not Set"))
                        LabeledContent("Finish Date", value: remote.finishDate?.displayText ?? String(localized: "Not Set"))
                        if link.supportsDateUpdates != true {
                            Text("Date sync unavailable").font(.footnote).foregroundStyle(.secondary)
                        }
                        if let lastPulledAt = link.lastPulledAt {
                            LabeledContent("Last Fetched", value: lastPulledAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                } else {
                    Text("Sync to load tracker details.").foregroundStyle(.secondary)
                }
                Menu("Tracker Actions", systemImage: "ellipsis.circle") {
                    Button("Unlink", systemImage: "link.badge.minus", role: .destructive) {
                        workingTrackerIDs.insert(installed.id)
                        Task {
                            defer { workingTrackerIDs.remove(installed.id) }
                            await model.trackingModel.removeTrackerLink(workID: work.id, trackerID: trackerID)
                            await reload()
                        }
                    }
                    .disabled(model.settingsSyncModel.incognitoMode || isSyncing || workingTrackerIDs.contains(installed.id))
                }
                if workingTrackerIDs.contains(installed.id) { ProgressView("Loading tracker…") }
                if let progressReviewError { Text(progressReviewError).font(.footnote).foregroundStyle(AppColors.warning) }
                ForEach(link.conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(conflict.field == .chapter || conflict.field == .volume
                            ? "Review Progress" : "\(conflict.field.displayName) conflict", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppColors.warning)
                        LabeledContent("Mango Reader", value: conflict.mangoReaderValue.displayText)
                        LabeledContent(installed.descriptor.name, value: conflict.trackerValue.displayText)
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                useMangoReaderButton(link: link, conflict: conflict)
                                    .fixedSize(horizontal: true, vertical: false)
                                Spacer()
                                useTrackerButton(
                                    installed: installed,
                                    link: link,
                                    conflict: conflict
                                )
                                .fixedSize(horizontal: true, vertical: false)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                useMangoReaderButton(link: link, conflict: conflict)
                                useTrackerButton(
                                    installed: installed,
                                    link: link,
                                    conflict: conflict
                                )
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                Button {
                    searchTracker = installed
                    selectedDetent = .large
                    isSearching = true
                } label: {
                    HStack {
                        Label("Find Title", systemImage: "magnifyingglass")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .disabled(model.settingsSyncModel.incognitoMode)

            }
        }
    }

    private var scoreSelection: Binding<Int?> {
        Binding(
            get: { ratingSave.selectedRating },
            set: { value in
                guard !model.settingsSyncModel.incognitoMode else { return }
                ratingError = nil
                ratingSave.choose(value) {
                    await model.prepareTitleTracking(work: work, installments: installments)
                } save: { rating in
                    let saved = await model.updateRating(for: work.id, rating: rating.flatMap(TenPointRating.init(rawValue:)))
                    if !saved { ratingError = String(localized: "Couldn’t save score. Try again.") }
                    await reload()
                    return saved
                }
            }
        )
    }

    private func dateLink(_ field: TrackerSyncField) -> some View {
        NavigationLink {
            TrackerDateEditor(
                work: work, installments: installments, field: field,
                value: field == .startDate ? titleState?.startDate : titleState?.finishDate,
                otherDate: field == .startDate ? titleState?.finishDate : titleState?.startDate
            ) { await reload() }
        } label: {
            LabeledContent(field == .startDate ? "Start Date" : "Finish Date",
                           value: (field == .startDate ? titleState?.startDate : titleState?.finishDate)?.displayText ?? String(localized: "Not Set"))
        }
        .disabled(model.settingsSyncModel.incognitoMode || statusEdit.isSaving || ratingSave.isSaving)
        .accessibilityIdentifier(field == .startDate ? "tracking-start-date" : "tracking-finish-date")
    }

    private func progressText(_ progress: Double?, total: Int?) -> String {
        let value = progress?.formatted() ?? "—"
        guard let total, total > 0 else { return value + " / " + String(localized: "Unknown") }
        return "\(value) / \(total.formatted())"
    }

    private func useMangoReaderButton(
        link: TrackerLink,
        conflict: TrackerFieldConflict
    ) -> some View {
        Button(conflict.field == .chapter || conflict.field == .volume ? "Update Tracker" : "Use Mango Reader") {
            resolve(link: link, conflict: conflict, useTrackerValue: false)
        }
        .disabled(model.settingsSyncModel.incognitoMode || isSyncing ||
            ((conflict.field == .chapter || conflict.field == .volume) && !conflict.isForwardLocalProgress))
    }

    private func useTrackerButton(
        installed: InstalledRepositorySource,
        link: TrackerLink,
        conflict: TrackerFieldConflict
    ) -> some View {
        Button(conflict.field == .chapter || conflict.field == .volume ? "Review Progress" : "Use \(installed.descriptor.name)") {
            if conflict.field == .chapter || conflict.field == .volume {
                reviewProgress(link: link, installed: installed)
            } else {
                resolve(link: link, conflict: conflict, useTrackerValue: true)
            }
        }
        .disabled(model.settingsSyncModel.incognitoMode || conflict.hasUnrepresentableRating || isSyncing || workingTrackerIDs.contains(installed.id))
    }

    private func reviewProgress(link: TrackerLink, installed: InstalledRepositorySource) {
        guard !workingTrackerIDs.contains(installed.id) else { return }
        workingTrackerIDs.insert(installed.id); progressReviewError = nil
        Task {
            defer { workingTrackerIDs.remove(installed.id) }
            do {
                #if DEBUG
                if MangoReaderScreenshotMode.isEnabled {
                    importPreview = try await model.trackerImportPreview(work: work, link: link)
                } else {
                    importPreview = try await model.prepareTrackerImport(work: work, link: link)
                }
                #else
                importPreview = try await model.prepareTrackerImport(work: work, link: link)
                #endif
                selectedDetent = .large
                isShowingProgressReview = true
            } catch { progressReviewError = error.localizedDescription }
        }
    }

    private func reload() async {
        let statusRevision = statusEdit.revision
        let ratingRevision = ratingSave.revision
        links = await model.trackingModel.trackerLinks(for: work.id, reload: true)
        titleState = await model.libraryModel.titleState(for: work.id, reload: true)
        ratingSave.load(titleState?.rating?.rawValue, expectedRevision: ratingRevision)
        statusEdit.load(
            titleState?.status,
            expectedRevision: statusRevision
        )
    }

    private func syncAll() {
        guard !isSyncing, !model.settingsSyncModel.incognitoMode else { return }
        isSyncing = true
        syncMessage = nil
        Task {
            defer { isSyncing = false }
            await model.syncTrackerLinks(work: work, installments: installments, force: true)
            await reload()
            syncMessage = model.trackingModel.trackerSyncErrors[work.id] ?? String(localized: "Trackers are up to date.")
        }
    }

    private func linkState(_ link: TrackerLink) -> TrackerLinkSyncState {
        if model.trackingModel.trackerSyncErrors[work.id] != nil { return .error }
        if !link.conflicts.isEmpty { return .conflict }
        return model.trackingModel.trackerPendingUpdates.contains {
            $0.progress.trackerID == link.trackerID && $0.progress.remoteWorkID == link.remoteWorkID
        } ? .pending : .synced
    }

    private func resolve(
        link: TrackerLink,
        conflict: TrackerFieldConflict,
        useTrackerValue: Bool
    ) {
        Task {
            _ = await model.resolveTrackerConflict(
                work: work,
                installments: installments,
                link: link,
                conflict: conflict,
                useTrackerValue: useTrackerValue
            )
            await reload()
        }
    }
}

private extension TrackerFieldConflict {
    var isForwardLocalProgress: Bool {
        guard case let .number(local) = mangoReaderValue, local.isFinite, local >= 0 else { return false }
        if case let .number(remote) = trackerValue { return local > remote }
        return trackerValue == .none
    }
}

struct TrackerImportReviewView: View {
    @Environment(AppModel.self) private var model
    let work: Work
    let preview: TrackerImportPreview
    let onFinish: () async -> Void
    @State private var isApplying = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Tracker Chapter", value: preview.remote.chapter?.formatted() ?? "—")
                if preview.remote.chapter == nil {
                    LabeledContent("Tracker Volume", value: preview.remote.volume?.formatted() ?? "—")
                }
                Text("\(preview.affectedIDs.count) chapters will be marked complete. Your saved page positions and reading history are preserved.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let continuation = preview.continuation {
                    LabeledContent("Continue With", value: continuation.title)
                } else { Text("All available chapters are complete.").foregroundStyle(.secondary) }
            }
            Section("Chapters to Mark Complete") {
                if preview.affectedIDs.isEmpty { Text("No chapters need to change.").foregroundStyle(.secondary) }
                ForEach(ReaderChapterPolicy.ordered(preview.chapters).filter { preview.affectedIDs.contains($0.id) }) { chapter in
                    Text(chapter.title).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                Button("Apply Progress") {
                    guard !isApplying else { return }
                    isApplying = true; errorMessage = nil
                    Task {
                        defer { isApplying = false }
                        if await model.applyTrackerImport(work: work, preview: preview) { await onFinish() }
                        else { errorMessage = model.trackingModel.trackerSyncErrors[work.id] ?? "Progress could not be applied. Review the latest values and try again." }
                    }
                }
                .disabled(isApplying || model.settingsSyncModel.incognitoMode)
                .accessibilityIdentifier("tracker-import-apply")
                Button("Not Now") { Task { await onFinish() } }
                    .disabled(isApplying)
                if isApplying { ProgressView("Applying progress…") }
                if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(AppColors.warning) }
            }
        }
        .appInsetGroupedList()
        .navigationTitle("Review Progress")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .accessibilityIdentifier("tracker-import-review")
    }
}

extension TrackerReadingStatus {
    var displayName: String {
        switch self {
        case .planning: String(localized: "Planning")
        case .reading: String(localized: "Reading")
        case .completed: String(localized: "Completed")
        case .paused: String(localized: "Paused")
        case .dropped: String(localized: "Dropped")
        case .rereading: String(localized: "Rereading")
        }
    }
}

private extension TrackerSyncField {
    var displayName: String {
        switch self {
        case .rating: "Rating"
        case .chapter: "Chapter Progress"
        case .volume: "Volume Progress"
        case .status: "Reading Status"
        case .startDate: "Start Date"
        case .finishDate: "Finish Date"
        }
    }
}

private extension TrackerFieldConflict {
    var hasUnrepresentableRating: Bool {
        guard field == .rating, case let .number(value) = trackerValue else { return false }
        return value.rounded() != value || !(1 ... 10).contains(value)
    }
}

private extension TrackerSyncValue {
    var displayText: String {
        switch self {
        case let .number(value): value.formatted()
        case let .status(value): value.displayName
        case let .date(value): value.displayText
        case .none: String(localized: "Not Set")
        }
    }
}

private struct TrackerDateEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let work: Work
    let installments: [Installment]
    let field: TrackerSyncField
    let value: TrackerDate?
    let otherDate: TrackerDate?
    let didSave: @MainActor () async -> Void
    @State private var selection = Date.now
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var hasChanged = false

    private var selectedDate: TrackerDate { TrackerDate(selection) }
    private var isOrdered: Bool {
        TrackerDate.areOrdered(start: field == .startDate ? selectedDate : otherDate,
                               finish: field == .finishDate ? selectedDate : otherDate)
    }

    var body: some View {
        Form {
            Section {
                DatePicker(field == .startDate ? "Start Date" : "Finish Date", selection: $selection, displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                    .onChange(of: selection) { hasChanged = true }
                    .accessibilityIdentifier("tracking-date-picker")
                if let value, value.completeDate == nil {
                    Text("Current date: \(value.displayText). Saving replaces it with a complete date.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !isOrdered {
                    Text("Finish date must be on or after start date.").foregroundStyle(.red)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                if isSaving { ProgressView("Saving date…") }
            }
            if value != nil {
                Button("Clear Date", role: .destructive) { save(nil) }
                    .disabled(isSaving || model.settingsSyncModel.incognitoMode)
                    .accessibilityIdentifier("tracking-clear-date")
            }
        }
        .navigationTitle(field == .startDate ? "Start Date" : "Finish Date")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { FixedNavigationChrome { Button("Cancel") { dismiss() }.disabled(isSaving) } }
            ToolbarItem(placement: .confirmationAction) {
                FixedNavigationChrome {
                    Button("Save") { save(selectedDate) }
                        .disabled(!isOrdered || isSaving || model.settingsSyncModel.incognitoMode)
                }
            }
        }
        .interactiveDismissDisabled(isSaving || hasChanged)
        .task {
            if let value, let year = value.year, let month = value.month, let day = value.day {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .current
                selection = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .now
            }
            hasChanged = false
        }
    }

    private func save(_ date: TrackerDate?) {
        guard !isSaving, !model.settingsSyncModel.incognitoMode else { return }
        isSaving = true
        errorMessage = nil
        Task {
            let dates = TrackerDateUpdates(startDate: field == .startDate ? date : nil,
                                           finishDate: field == .finishDate ? date : nil, fields: [field])
            guard await model.prepareTitleTracking(work: work, installments: installments),
                  await model.updateTrackingDates(for: work.id, dates: dates) else {
                errorMessage = String(localized: "Couldn’t save date. Check the date order and try again.")
                isSaving = false
                return
            }
            await didSave()
            isSaving = false
            dismiss()
        }
    }
}

extension TrackerDate {
    var displayText: String {
        if let date = completeDate {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: calendar, timeZone: calendar.timeZone))
        }
        return [year.map { String($0) }, month.map { String(format: "%02d", $0) }, day.map { String(format: "%02d", $0) }]
            .map { $0 ?? "?" }.joined(separator: "-")
    }
}

@MainActor @Observable
final class TrackerSearchSession {
    private(set) var state: TrackerMatchSearchState?
    private(set) var submittedQuery = ""
    private(set) var isLinking = false
    private(set) var linkError: String?
    private var revision = 0
    private var task: Task<Void, Never>?

    @discardableResult
    func search(_ query: String, using search: @escaping @MainActor (String) async throws -> [TrackerMatch]) -> Task<Void, Never>? {
        cancel()
        submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        linkError = nil
        guard !submittedQuery.isEmpty else { return nil }
        state = .searching
        let requestRevision = revision
        let title = submittedQuery
        let operation = Task {
            let result = await TrackerMatchSearchState.load { try await search(title) }
            guard requestRevision == revision, !Task.isCancelled else { return }
            state = result
            task = nil
        }
        task = operation
        return operation
    }

    func cancel() {
        revision &+= 1
        task?.cancel()
        task = nil
        state = nil
    }

    func link(using operation: @MainActor () async -> Bool) async -> Bool {
        guard !isLinking else { return false }
        isLinking = true
        linkError = nil
        defer { isLinking = false }
        let saved = await operation()
        if !saved { linkError = String(localized: "Couldn’t link this title. Check your tracker account and try again.") }
        return saved
    }
}

struct TrackerMatchSearchView: View {
    @Environment(AppModel.self) private var model
    let work: Work
    let installments: [Installment]
    let installed: InstalledRepositorySource
    let didLink: @MainActor () async -> Void
    @State private var query: String
    @State private var search = TrackerSearchSession()
    @State private var didSearch = false
    @State private var isSearchPresented = false

    init(work: Work, installments: [Installment], installed: InstalledRepositorySource,
         didLink: @escaping @MainActor () async -> Void) {
        self.work = work
        self.installments = installments
        self.installed = installed
        self.didLink = didLink
        _query = State(initialValue: work.title)
    }

    var body: some View {
        List {
            if model.settingsSyncModel.incognitoMode {
                ContentUnavailableView("Incognito Reading Is On", systemImage: "eye.slash",
                    description: Text("Turn off Incognito Reading in Settings to find and link titles."))
            } else {
                results
            }
            if search.isLinking { ProgressView("Linking title…") }
            if let error = search.linkError {
                Section {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(AppColors.warning)
                    accountLink
                }
            }
        }
        .appInsetGroupedList()
        .navigationTitle(installed.descriptor.name)
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .searchable(text: $query, isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .always), prompt: "Search titles")
        .onSubmit(of: .search, submit)
        .onChange(of: query) { _, _ in search.cancel() }
        .onChange(of: model.settingsSyncModel.incognitoMode) { _, enabled in
            if enabled { search.cancel() }
        }
        .disabled(search.isLinking)
        .navigationBarBackButtonHidden(search.isLinking)
        .interactiveDismissDisabled(search.isLinking)
        .task {
            guard !didSearch else { return }
            didSearch = true
            submit()
        }
        .onDisappear { search.cancel() }
    }

    @ViewBuilder private var results: some View {
        switch search.state {
        case .searching:
            ProgressView("Searching titles…")
                .frame(maxWidth: .infinity).padding()
        case let .results(matches):
            if matches.isEmpty {
                ContentUnavailableView("No Titles Found", systemImage: "magnifyingglass",
                    description: Text("No matches for “\(search.submittedQuery)”. Try another title or spelling."))
            } else {
                Section {
                    ForEach(matches) { match in
                        TrackerMatchRow(match: match, allowedHosts: installed.isRuntimeCompatible ? Set(installed.allowedHTTPSHosts) : []) { link(match) }
                    }
                } header: {
                    Text("Results for “\(search.submittedQuery)”")
                }
            }
        case let .failed(message):
            Section {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(AppColors.warning)
                Button("Try Again", action: submit)
                accountLink
            }
        case nil:
            ContentUnavailableView("Find a Title", systemImage: "magnifyingglass",
                description: Text("Enter a title and tap Search. You can try an alternate name or spelling."))
        }
    }

    private var accountLink: some View {
        NavigationLink("Tracker Account") {
            InstalledSourceDetailView(installed: installed,
                entry: repository?.manifest.sources.first { $0.id == installed.sourceID },
                repository: repository)
        }
    }

    private var repository: RepositoryRecord? {
        model.sourcesModel.sourceRepositories.first { $0.id == installed.repositoryID }
    }

    private func submit() {
        guard !model.settingsSyncModel.incognitoMode, !search.isLinking else { return }
        search.search(query) { title in
            try await model.trackingModel.trackerMatches(for: work, using: installed, query: title)
        }
    }

    private func link(_ match: TrackerMatch) {
        guard !model.settingsSyncModel.incognitoMode, !search.isLinking else { return }
        Task {
            if await search.link(using: {
                await model.confirmTrackerLink(work: work, installments: installments, installed: installed, match: match)
            }) {
                isSearchPresented = false
                await didLink()
            }
        }
    }
}

struct TrackerMatchRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let match: TrackerMatch
    var allowedHosts: Set<String> = []
    let link: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PublicationRemoteImage(url: match.coverURL, networkPolicy: ExtensionNetworkPolicy(hosts: allowedHosts)) {
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "book.closed").foregroundStyle(.secondary) }
            }
            .frame(width: 42, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(match.title).font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(match.mediaKind.displayName).font(.caption).foregroundStyle(.secondary)
                if dynamicTypeSize.isAccessibilitySize { linkButton }
            }
            Spacer(minLength: 0)
            if !dynamicTypeSize.isAccessibilitySize { linkButton }
        }
        .padding(.vertical, 4)
    }

    private var linkButton: some View {
        styledLinkButton
            .buttonBorderShape(.capsule)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Link \(match.title)")
            .accessibilityIdentifier("tracker-match-link-\(match.id)")
    }

    @ViewBuilder
    private var styledLinkButton: some View {
#if targetEnvironment(macCatalyst)
        linkAction.buttonStyle(.bordered)
#else
        if #available(iOS 26.0, *), !reduceTransparency {
            linkAction.buttonStyle(.glass)
        } else {
            linkAction.buttonStyle(.bordered)
        }
#endif
    }

    private var linkAction: some View {
        Button(action: link) {
            Text("Link")
                .fixedSize()
        }
    }
}
