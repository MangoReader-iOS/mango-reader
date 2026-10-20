import MangoReaderDomain
import SwiftUI

struct WeeklyHistoryEntry: Identifiable, Hashable, Sendable {
    struct ID: Hashable, Sendable {
        let workID: WorkID
        let weekStart: Date
    }

    let id: ID
    let session: ReadingSession
    let effectiveDate: Date
}

enum HistoryAgeSection: Int, CaseIterable, Identifiable, Sendable {
    case thisWeek
    case overAWeekAgo
    case overAMonthAgo

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .thisWeek: "This Week"
        case .overAWeekAgo: "Over a Week Ago"
        case .overAMonthAgo: "Over a Month Ago"
        }
    }
}

struct HistoryPresentationSection: Identifiable, Hashable, Sendable {
    let id: HistoryAgeSection
    let entries: [WeeklyHistoryEntry]
}

enum HistoryPresentation {
    static func weeklyEntries(
        sessions: [ReadingSession],
        calendar: Calendar
    ) -> [WeeklyHistoryEntry] {
        var newestByWeek: [WeeklyHistoryEntry.ID: ReadingSession] = [:]

        for session in sessions {
            let effectiveDate = session.endedAt ?? session.startedAt
            guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: effectiveDate)?.start else {
                continue
            }
            let id = WeeklyHistoryEntry.ID(workID: session.workID, weekStart: weekStart)
            if let existing = newestByWeek[id] {
                let existingDate = existing.endedAt ?? existing.startedAt
                if effectiveDate < existingDate
                    || (effectiveDate == existingDate && session.id.uuidString < existing.id.uuidString)
                {
                    continue
                }
            }
            newestByWeek[id] = session
        }

        return newestByWeek.map { id, session in
            WeeklyHistoryEntry(
                id: id,
                session: session,
                effectiveDate: session.endedAt ?? session.startedAt
            )
        }
        .sorted {
            if $0.effectiveDate == $1.effectiveDate {
                return $0.id.workID.rawValue.uuidString < $1.id.workID.rawValue.uuidString
            }
            return $0.effectiveDate > $1.effectiveDate
        }
    }

    static func sections(
        sessions: [ReadingSession],
        calendar: Calendar,
        now: Date
    ) -> [HistoryPresentationSection] {
        let entries = weeklyEntries(sessions: sessions, calendar: calendar)
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        let monthCutoff = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        let grouped = Dictionary(grouping: entries) { entry -> HistoryAgeSection in
            if let currentWeekStart,
               calendar.isDate(entry.id.weekStart, inSameDayAs: currentWeekStart)
            {
                return .thisWeek
            }
            return entry.effectiveDate >= monthCutoff ? .overAWeekAgo : .overAMonthAgo
        }

        return HistoryAgeSection.allCases.compactMap { section in
            guard let entries = grouped[section], !entries.isEmpty else { return nil }
            return HistoryPresentationSection(id: section, entries: entries)
        }
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(ReaderPresentationCoordinator.self) private var readerCoordinator
    @Environment(WorkDetailReaderPreparation.self) private var readerPreparation
    @State private var isConfirmingClear = false
    @State private var isClearingHistory = false

    private var sections: [HistoryPresentationSection] {
        HistoryPresentation.sections(
            sessions: model.libraryModel.sessions,
            calendar: .autoupdatingCurrent,
            now: .now
        )
    }

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(section.id.title) {
                    ForEach(section.entries) { entry in
                        if let work = model.libraryModel.historyWorks[entry.session.workID] {
                            Button {
                                resume(entry.session, work: work)
                            } label: {
                                HStack {
                                    HistoryRow(
                                        work: work,
                                        installment: model.libraryModel.historyInstallments[entry.session.installmentID]
                                    )
                                    if readerPreparation.isPreparing, readerPreparation.workID == work.id {
                                        ProgressView().controlSize(.small).accessibilityLabel("Preparing reader")
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(readerPreparation.isPreparing && readerPreparation.workID == work.id)
                            .appFullWidthListSeparator()
                            .accessibilityIdentifier("resume-history-\(entry.id.workID.rawValue.uuidString)-\(entry.id.weekStart.timeIntervalSince1970)")
                            .accessibilityHint("Resumes the latest installment read this week")
                            .contextMenu {
                                NavigationLink(value: work) {
                                    Text("View Title")
                                }
                            }
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationDestination(for: Work.self) { work in
            WorkDetailView(work: work)
        }
        .screenTitle(Text("History"), presentation: .navigation)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .softScreenHeaderEdge()
        .appBackground()
        .overlay {
            if model.libraryModel.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Reading History", systemImage: model.settingsSyncModel.incognitoMode ? "eye.slash" : "clock")
                } description: {
                    if model.settingsSyncModel.incognitoMode {
                        Text("Reading sessions aren’t added to History while Incognito Reading is on. Turn it off in Settings to keep a reading history.")
                    } else {
                        Text("Titles you read appear here so you can pick up where you left off.")
                    }
                }
                .accessibilityIdentifier("history-empty-guidance")
            }
        }
        .refreshable { await model.libraryModel.refreshHistory() }
        .onDisappear { readerPreparation.cancel() }
        .toolbar {
            if !model.libraryModel.sessions.isEmpty {
                Button("Clear", role: .destructive) {
                    isConfirmingClear = true
                }
                .disabled(isClearingHistory)
                .accessibilityIdentifier("clear-reading-history")
                .appFixedNavigationChrome()
            }
        }
        .alert("Clear Reading History?", isPresented: $isConfirmingClear) {
            Button("Clear History", role: .destructive) {
                Task {
                    isClearingHistory = true
                    _ = await model.clearHistory()
                    isClearingHistory = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears reading sessions and recalculates Stats. Reading progress, ratings, bookmarks, annotations, downloads, and library titles are preserved.")
        }
    }

    private func resume(_ session: ReadingSession, work: Work) {
        if work.kind == .lightNovel || work.kind == .book {
            readerPreparation.cancel()
            readerCoordinator.open(.init(work: work, target: .history(session)))
            return
        }
        readerPreparation.start(workID: work.id, installmentID: session.installmentID) {
            await model.prepareToResume(session: session, work: work)
        } present: { readable in
            readerCoordinator.present(readable)
        }
    }
}

private struct HistoryRow: View {
    let work: Work
    let installment: Installment?

    private var installmentTitle: String {
        installment?.title ?? String(localized: "Installment unavailable")
    }

    var body: some View {
        ActivityReadingRow(work: work, chapterTitle: installmentTitle)
    }
}
