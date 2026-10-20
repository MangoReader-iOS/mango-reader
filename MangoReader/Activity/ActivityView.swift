import MangoReaderDomain
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ReadingStatsView()
            .appBackground()
            .screenTitle(Text("Activity"), presentation: .expanded)
            .toolbar {
                if model.settingsSyncModel.incognitoMode {
                    ToolbarItem(placement: .topBarTrailing) {
                        FixedNavigationChrome {
                            IncognitoStatusIndicator()
                        }
                    }
                }
            }
    }
}

private struct ReadingStatsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var scaledCoverWidth: CGFloat = 112
    @State private var isShowingCustomRange = false
    @State private var shareDraft: ReadingShareDraft?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                rangeControls

                if model.libraryModel.isLoadingInsights, model.libraryModel.readingStats != nil {
                    ProgressView("Updating stats…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = model.libraryModel.readingStatsError {
                    AppInlineStatus(
                        title: "Couldn’t update stats",
                        message: error,
                        systemImage: "exclamationmark.circle",
                        actionTitle: "Try Again"
                    ) { Task { _ = await model.libraryModel.loadReadingStats() } }
                }

                if let snapshot = model.libraryModel.readingStats {
                    statsContent(snapshot)
                } else if model.libraryModel.isLoadingInsights {
                    AppContentSkeleton(kind: .metrics, label: String(localized: "Calculating stats…"))
                        .frame(maxWidth: .infinity, minHeight: 260)
                }

                recentlyReadCarousel(
                    titles: ActivityRecentlyReadPolicy.titles(
                        from: model.libraryModel.readingStats?.titles ?? []
                    )
                )
            }
            .padding(AppLayout.pageMargin)
        }
        .softScreenHeaderEdge()
        .appBackground()
        .refreshable { _ = await model.libraryModel.loadReadingStats() }
        .task {
            _ = await model.libraryModel.loadReadingStats()
        }
        .sheet(isPresented: $isShowingCustomRange) {
            CustomReadingRangeSheet { interval in
                Task { _ = await model.libraryModel.loadReadingStats(range: .custom(interval)) }
            }
        }
        .sheet(item: $shareDraft) { draft in
            ReadingShareComposerView(draft: draft)
        }
        .navigationDestination(for: Work.self) { work in
            WorkDetailView(work: work)
        }
    }

    private var rangeControls: some View {
        GlassCapsuleGroup(spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    rangeMenu
                        .frame(maxWidth: .infinity, alignment: .leading)
                    statsActions
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: 12) {
                    rangeMenu
                    Spacer()
                    statsActions
                }
            }
        }
    }

    private var rangeMenu: some View {
        NativeMenuPicker(
            title: "Date range",
            selection: Binding<ReadingStatsRange?>(
                get: {
                    let range = model.libraryModel.readingStatsRange
                    if case .custom = range { return nil }
                    return range
                },
                set: { range in
                    if let range {
                        Task { _ = await model.libraryModel.loadReadingStats(range: range) }
                    } else {
                        isShowingCustomRange = true
                    }
                }
            ),
            options: [
                ("This Month", .thisMonth),
                ("This Year", .thisYear),
                ("All Time", .allTime),
                ("Custom Range", nil)
            ]
        )
        .padding(.horizontal, 12)
        .modifier(ActivityControlCapsule())
        .accessibilityIdentifier("reading-stats-range")
    }

    private var statsActions: some View {
        Button {
            shareDraft = ReadingShareDraft(range: model.libraryModel.readingStatsRange)
        } label: {
            Image(systemName: "square.and.arrow.up").appIconControlFrame()
        }
        .modifier(ActivityControlCapsule())
        .accessibilityLabel("Share books")
        .accessibilityIdentifier("reading-stats-share")
    }

    @ViewBuilder
    private func statsContent(_ snapshot: ReadingStatsSnapshot) -> some View {
        metrics(snapshot)
        ReadingActivityHeatmap(snapshot: snapshot)
    }

    private func metrics(_ snapshot: ReadingStatsSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                metric(
                    title: "Pages",
                    value: ReadingStatsPresentation.pages(
                        snapshot.estimatedPagesRead,
                        sessionCount: snapshot.insights.sessionCount
                    ),
                    usesIdealWidth: true
                )
                metric(
                    title: "Sessions",
                    value: snapshot.insights.sessionCount.formatted(),
                    usesIdealWidth: true
                )
                metric(
                    title: "Time",
                    value: snapshot.insights.totalSeconds.statsDuration,
                    usesIdealWidth: true
                )
            }

            VStack(alignment: .leading, spacing: 14) {
                metric(
                    title: "Pages",
                    value: ReadingStatsPresentation.pages(
                        snapshot.estimatedPagesRead,
                        sessionCount: snapshot.insights.sessionCount
                    )
                )
                metric(
                    title: "Sessions",
                    value: snapshot.insights.sessionCount.formatted()
                )
                metric(
                    title: "Time",
                    value: snapshot.insights.totalSeconds.statsDuration
                )
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("reading-stats-metrics")
    }

    private func metric(
        title: String,
        value: String,
        usesIdealWidth: Bool = false
    ) -> some View {
        ReadingSummaryMetric(title: title, value: value)
            .fixedSize(horizontal: usesIdealWidth, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentlyReadCarousel(
        titles: [ReadingTitleStats]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let headerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(spacing: 12))
            headerLayout {
                Text("Recently Read")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                NavigationLink {
                    HistoryView()
                } label: {
                    Text("See All")
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("See all reading history")
                .accessibilityIdentifier("activity-see-all-history")
            }

            if !titles.isEmpty {
                recentlyReadShelf(titles: titles)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentlyReadShelf(titles: [ReadingTitleStats]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(titles) { total in
                    NavigationLink(value: total.work) {
                        RecentlyReadTile(work: total.work)
                    }
                    .buttonStyle(.plain)
                    .containerRelativeFrame(.horizontal, alignment: .topLeading) { width, _ in
                        ActivityRecentlyReadPolicy.coverWidth(
                            availableWidth: width,
                            scaledWidth: scaledCoverWidth,
                            itemCount: titles.count
                        )
                    }
                    .accessibilityIdentifier(
                        "recently-read-\(total.work.id.rawValue.uuidString)"
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

}

private struct ActivityControlCapsule: ViewModifier {
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

enum ActivityRecentlyReadPolicy {
    static func coverWidth(availableWidth: CGFloat, scaledWidth: CGFloat, itemCount: Int) -> CGFloat {
        let preferredWidth = min(max(scaledWidth, 112), 180)
        return min(preferredWidth, AllSourceSearchShelfLayoutPolicy.shelfLayout(
            availableWidth: availableWidth,
            minimumCoverWidth: preferredWidth,
            itemCount: itemCount,
            spacing: 14
        ).coverWidth)
    }

    static func titles(
        from titles: [ReadingTitleStats]
    ) -> [ReadingTitleStats] {
        titles.sorted {
            let lhsDate = $0.latestSession.endedAt ?? $0.latestSession.startedAt
            let rhsDate = $1.latestSession.endedAt ?? $1.latestSession.startedAt
            if lhsDate == rhsDate {
                return $0.work.title.localizedCaseInsensitiveCompare($1.work.title)
                    == .orderedAscending
            }
            return lhsDate > rhsDate
        }
    }
}

enum ReadingActivityLevel: Int, CaseIterable, Equatable, Sendable {
    case none
    case light
    case moderate
    case high
    case veryHigh

    init(secondsRead: TimeInterval) {
        switch secondsRead {
        case ...0: self = .none
        case ..<900: self = .light
        case ..<1_800: self = .moderate
        case ..<3_600: self = .high
        default: self = .veryHigh
        }
    }

    var color: Color {
        switch self {
        case .none: AppColors.tertiaryFill
        case .light: AppColors.information.opacity(0.24)
        case .moderate: AppColors.information.opacity(0.4)
        case .high: AppColors.information.opacity(0.58)
        case .veryHigh: AppColors.information.opacity(0.78)
        }
    }
}

enum ReadingStatsPresentation {
    static func pages(_ estimatedPagesRead: Double) -> String {
        guard estimatedPagesRead.isFinite, estimatedPagesRead >= 1 else { return "—" }
        return "\(Int(estimatedPagesRead.rounded()))"
    }

    static func pages(_ estimatedPagesRead: Double, sessionCount: Int) -> String {
        guard sessionCount > 0 else { return "0" }
        return pages(estimatedPagesRead)
    }
}

private struct ReadingSummaryMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct RecentlyReadTile: View {
    let work: Work

    var body: some View {
        PublicationCardLayout(title: work.title, cover: RemoteCover(work: work)) {
            EmptyView()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(work.title)
        .accessibilityHint("Opens title details")
    }

}

struct ActivityReadingRow: View {
    let work: Work
    let chapterTitle: String

    var body: some View {
        PublicationRowLayout(
            title: work.title,
            cover: RemoteCover(work: work),
            metadata: { Text(chapterTitle) },
            trailing: { EmptyView() }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(work.title), \(chapterTitle)")
    }
}

struct ReadingHeatmapWeek: Identifiable {
    let start: Date
    let days: [ReadingActivityDay?]

    var id: Date { start }
}

struct ReadingHeatmapLayout {
    let weeks: [ReadingHeatmapWeek]

    init(days: [ReadingActivityDay], calendar: Calendar) {
        guard let first = days.first, let last = days.last else {
            weeks = []
            return
        }

        let valuesByDate = Dictionary(uniqueKeysWithValues: days.map {
            (calendar.startOfDay(for: $0.date), $0)
        })
        let firstDate = calendar.startOfDay(for: first.date)
        let lastDate = calendar.startOfDay(for: last.date)
        let firstWeekStart = Self.mondayStart(containing: firstDate, calendar: calendar)
        let lastWeekStart = Self.mondayStart(containing: lastDate, calendar: calendar)

        var result: [ReadingHeatmapWeek] = []
        var weekStart = firstWeekStart
        while weekStart <= lastWeekStart {
            let weekDays = (0 ..< 7).map { offset -> ReadingActivityDay? in
                guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart),
                      date >= firstDate,
                      date <= lastDate
                else { return nil }
                return valuesByDate[date]
            }
            result.append(ReadingHeatmapWeek(start: weekStart, days: weekDays))
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart),
                  next > weekStart
            else { break }
            weekStart = next
        }
        weeks = result
    }

    func monthMarkerDate(forWeekAt index: Int, calendar: Calendar) -> Date? {
        guard weeks.indices.contains(index) else { return nil }
        let dates = weeks[index].days.compactMap { $0?.date }
        if let firstOfMonth = dates.first(where: {
            calendar.component(.day, from: $0) == 1
        }) {
            return firstOfMonth
        }
        return index == 0 ? dates.first : nil
    }

    private static func mondayStart(containing date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: date) ?? date
    }
}

struct ReadingHeatmapSizing: Equatable {
    let cellSize: CGFloat
    let gridWidth: CGFloat
    let height: CGFloat
    let spacing: CGFloat = 3

    init(availableWidth: CGFloat, weekCount: Int, labelWidth: CGFloat = 18, headerHeight: CGFloat = 13) {
        let count = max(0, weekCount)
        let columnGaps = CGFloat(max(0, count - 1)) * spacing
        if availableWidth.isFinite, availableWidth >= 600, count > 0 {
            let fittedSize = (availableWidth - labelWidth - spacing - columnGaps) / CGFloat(count)
            cellSize = min(28, max(11, fittedSize))
        } else {
            cellSize = 11
        }
        gridWidth = CGFloat(count) * cellSize + columnGaps
        // Seven gaps include the one between the month header and the first row.
        height = headerHeight + cellSize * 7 + spacing * 7
    }

    func columnOffset(at index: Int) -> CGFloat {
        CGFloat(index) * (cellSize + spacing)
    }
}

struct ReadingHeatmapMonthMarker: Identifiable {
    let weekIndex: Int
    let label: String
    let offset: CGFloat

    var id: Int { weekIndex }
}

struct ReadingHeatmapMonthPlacement: Identifiable, Equatable {
    let id: Int
    let x: CGFloat
    let width: CGFloat

    static func visible(markers: [ReadingHeatmapMonthMarker], widths: [Int: CGFloat],
                        scrollOffset: CGFloat, viewportWidth: CGFloat) -> [Self] {
        guard viewportWidth > 0, !markers.isEmpty else { return [] }
        let offset = max(0, scrollOffset)
        let first = markers.lastIndex(where: { $0.offset <= offset }) ?? 0
        var result: [Self] = []
        var previousLabelEnd: CGFloat = -3
        // Keep the month covering the left edge readable until its marker passes.
        for marker in markers[first...] {
            guard marker.offset < offset + viewportWidth,
                  let measuredWidth = widths[marker.id], measuredWidth > 0 else { continue }
            let width = min(measuredWidth, viewportWidth)
            let x = min(max(0, marker.offset - offset), viewportWidth - width)
            guard x >= previousLabelEnd + 3 else { continue }
            result.append(Self(id: marker.id, x: x, width: width))
            previousLabelEnd = x + width
        }
        return result
    }
}

struct ReadingHeatmapMonthHeader: View {
    let markers: [ReadingHeatmapMonthMarker]
    let scrollOffset: CGFloat?
    let gridWidth: CGFloat
    @State private var labelWidths: [Int: CGFloat] = [:]

    var body: some View {
        GeometryReader { geometry in
            let placements = ReadingHeatmapMonthPlacement.visible(
                markers: markers, widths: labelWidths,
                scrollOffset: scrollOffset ?? max(0, gridWidth - geometry.size.width),
                viewportWidth: geometry.size.width
            )
            ZStack(alignment: .topLeading) {
                ForEach(placements) { placement in
                    if let marker = markers.first(where: { $0.id == placement.id }) {
                        Text(marker.label)
                            .frame(width: placement.width, alignment: .leading)
                            .offset(x: placement.x)
                            .accessibilityIdentifier("reading-heatmap-month-\(marker.id)")
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background {
            ZStack {
                ForEach(markers) { marker in
                    Text(marker.label)
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                            labelWidths[marker.id] = $0
                        }
                }
            }
            .hidden()
            .accessibilityHidden(true)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct ReadingActivityHeatmap: View {
    private let calendar = Calendar.autoupdatingCurrent
    @State private var availableWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat?
    @ScaledMetric(relativeTo: .caption2) private var scaledLabelWidth: CGFloat = 18
    @ScaledMetric(relativeTo: .caption2) private var scaledHeaderHeight: CGFloat = 13
    private let layout: ReadingHeatmapLayout

    let snapshot: ReadingStatsSnapshot

    init(snapshot: ReadingStatsSnapshot) {
        self.snapshot = snapshot
        layout = ReadingHeatmapLayout(days: snapshot.activityDays, calendar: .autoupdatingCurrent)
    }

    private var labelWidth: CGFloat { min(scaledLabelWidth, 36) }
    private var headerHeight: CGFloat { min(scaledHeaderHeight, 26) }
    private var sizing: ReadingHeatmapSizing {
        ReadingHeatmapSizing(
            availableWidth: availableWidth, weekCount: layout.weeks.count,
            labelWidth: labelWidth, headerHeight: headerHeight
        )
    }
    private var cellSize: CGFloat { sizing.cellSize }
    private var spacing: CGFloat { sizing.spacing }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Reading Activity")
                    .font(.headline)
                if let interval = snapshot.activityInterval {
                    Text(activityRangeLabel(interval))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            heatmapStrip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reading activity heatmap")
        .accessibilityHint(accessibilitySummary)
        .accessibilityIdentifier("reading-activity-heatmap")
    }

    private var heatmapStrip: some View {
        HStack(alignment: .top, spacing: spacing) {
            VStack(alignment: .leading, spacing: spacing) {
                Color.clear
                    .frame(width: labelWidth, height: headerHeight)
                    .accessibilityHidden(true)
                ForEach(0 ..< 7, id: \.self) { dayIndex in
                    Text(weekdayLabel(for: dayIndex))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: labelWidth, height: cellSize, alignment: .leading)
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: spacing) {
                ReadingHeatmapMonthHeader(markers: monthMarkers, scrollOffset: scrollOffset, gridWidth: gridWidth)
                    .frame(height: headerHeight)
                    .accessibilityHidden(true)
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: spacing) {
                        ForEach(0 ..< 7, id: \.self) { dayIndex in
                            HStack(spacing: spacing) {
                                ForEach(layout.weeks) { week in
                                    heatmapCell(week.days[dayIndex])
                                }
                            }
                        }
                    }
                    .frame(width: gridWidth, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.trailing, for: .initialOffset)
                .defaultScrollAnchor(.leading, for: .alignment)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, min(geometry.contentOffset.x + geometry.contentInsets.leading,
                               geometry.contentSize.width - geometry.containerSize.width))
                } action: { _, offset in
                    scrollOffset = offset
                }
                .id(snapshot.activityInterval)
            }
            .onChange(of: snapshot.activityInterval) { _, _ in scrollOffset = nil }
        }
        .frame(height: heatmapHeight)
        .dynamicTypeSize(AppDynamicTypeSizing.compactChromeRange)
    }

    private var monthMarkers: [ReadingHeatmapMonthMarker] {
        layout.weeks.indices.compactMap { index in
            let label = monthLabel(for: index)
            guard !label.isEmpty else { return nil }
            return ReadingHeatmapMonthMarker(weekIndex: index, label: label, offset: sizing.columnOffset(at: index))
        }
    }

    @ViewBuilder
    private func heatmapCell(_ day: ReadingActivityDay?) -> some View {
        if let day {
            RoundedRectangle(cornerRadius: cellSize * 0.25, style: .continuous)
                .fill(ReadingActivityLevel(secondsRead: day.secondsRead).color)
                .frame(width: cellSize, height: cellSize)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
                .accessibilityValue(day.secondsRead > 0 ? day.secondsRead.statsDuration : "No reading")
        } else {
            Color.clear
                .frame(width: cellSize, height: cellSize)
                .accessibilityHidden(true)
        }
    }

    private var gridWidth: CGFloat {
        sizing.gridWidth
    }

    private var heatmapHeight: CGFloat {
        sizing.height
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return ["M", "T", "W", "T", "F", "S", "S"] }
        return Array(symbols[1...]) + [symbols[0]]
    }

    private func weekdayLabel(for dayIndex: Int) -> String {
        weekdaySymbols[dayIndex]
    }

    private func monthLabel(for weekIndex: Int) -> String {
        guard let date = layout.monthMarkerDate(forWeekAt: weekIndex, calendar: calendar) else {
            return ""
        }
        return date.formatted(.dateTime.month(.abbreviated))
    }

    private func activityRangeLabel(_ interval: DateInterval) -> String {
        let finalDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        return "\(interval.start.formatted(date: .abbreviated, time: .omitted)) – \(finalDay.formatted(date: .abbreviated, time: .omitted))"
    }

    private var accessibilitySummary: String {
        guard let busiest = snapshot.activityDays.max(by: { $0.secondsRead < $1.secondsRead }),
              busiest.secondsRead > 0
        else { return "No recorded reading time in the displayed days." }
        return "\(snapshot.activityDays.count) days. Most active was \(busiest.date.formatted(date: .complete, time: .omitted)) with \(busiest.secondsRead.statsDuration)."
    }
}

struct CustomReadingRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onApply: (DateInterval) -> Void

    @State private var start = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var end = Date.now

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Start", selection: $start, in: ...end, displayedComponents: .date)
                    .appListRow()
                DatePicker("End", selection: $end, in: start ... .now, displayedComponents: .date)
                    .appListRow()
                Section {
                    Text("The selected start and end dates are included.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .appListRow()
            }
            .appGroupedForm()
            .navigationTitle("Custom Range")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    FixedNavigationChrome {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    FixedNavigationChrome {
                        Button("Apply") {
                            let calendar = Calendar.autoupdatingCurrent
                            let startDate = calendar.startOfDay(for: start)
                            let endDate = calendar.date(
                                byAdding: .day,
                                value: 1,
                                to: calendar.startOfDay(for: end)
                            ) ?? end
                            onApply(DateInterval(start: startDate, end: endDate))
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
