import CoreTransferable
import MangoReaderDomain
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ReadingShareImage: Transferable, Sendable {
    let data: Data

    var pasteboardItem: [String: Data] { [UTType.png.identifier: data] }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
    }
}

struct ReadingShareDraft: Identifiable {
    let id = UUID()
    let range: ReadingStatsRange
}

enum ReadingSharePeriod: Hashable {
    case thisMonth, lastMonth, thisYear, lastYear, allTime
    case custom(DateInterval)

    static let presets: [Self] = [.thisMonth, .lastMonth, .thisYear, .lastYear, .allTime]

    init(range: ReadingStatsRange) {
        switch range {
        case .thisMonth: self = .thisMonth
        case .thisYear: self = .thisYear
        case .allTime: self = .allTime
        case let .custom(interval): self = .custom(interval)
        }
    }

    var displayName: String {
        switch self {
        case .thisMonth: String(localized: "This Month")
        case .lastMonth: String(localized: "Last Month")
        case .thisYear: String(localized: "This Year")
        case .lastYear: String(localized: "Last Year")
        case .allTime: String(localized: "All Time")
        case let .custom(interval): ReadingStatsRange.custom(interval).displayName
        }
    }

    func range(now: Date = .now, calendar: Calendar = .current) -> ReadingStatsRange {
        switch self {
        case .thisMonth: return .thisMonth
        case .thisYear: return .thisYear
        case .allTime: return .allTime
        case let .custom(interval): return .custom(interval)
        case .lastMonth, .lastYear:
            let component: Calendar.Component = self == .lastMonth ? .month : .year
            let previous = calendar.date(byAdding: component, value: -1, to: now) ?? now
            let interval = calendar.dateInterval(of: component, for: previous)
                ?? DateInterval(start: previous, end: now)
            return .custom(interval)
        }
    }
}

enum ReadingShareViewMode: String, CaseIterable, Hashable {
    case currentlyReading, favourites, recentReads

    var displayName: String {
        switch self {
        case .currentlyReading: String(localized: "Currently Reading")
        case .favourites: String(localized: "My Favourites")
        case .recentReads: String(localized: "Recent Reads")
        }
    }
}

struct ReadingShareSelection: Hashable {
    var period: ReadingSharePeriod
    var mode: ReadingShareViewMode = .currentlyReading

    var range: ReadingStatsRange { mode == .recentReads ? period.range() : .allTime }
    var graphicPeriod: String? {
        guard mode == .recentReads else { return nil }
        return period == .allTime ? String(localized: "Lifetime") : period.displayName
    }
}

struct ReadingShareSlots: Hashable {
    static let count = 6
    private(set) var ids: [WorkID?]

    init(_ ids: [WorkID?] = []) {
        var seen = Set<WorkID>()
        self.ids = (0 ..< Self.count).map { index in
            guard index < ids.count, let id = ids[index], seen.insert(id).inserted else { return nil }
            return id
        }
    }

    var isEmpty: Bool { ids.allSatisfy { $0 == nil } }

    @discardableResult
    mutating func replace(at index: Int, with id: WorkID?) -> Bool {
        guard ids.indices.contains(index),
              id == nil || !ids.enumerated().contains(where: { $0.offset != index && $0.element == id })
        else { return false }
        ids[index] = id
        return true
    }

    func resolving(available: Set<WorkID>) -> Self {
        Self(ids.map { id in id.flatMap { available.contains($0) ? $0 : nil } })
    }
}

struct ReadingShareFavouriteStore {
    let defaults: UserDefaults
    private let key = "readingShareFavouriteSlots"

    func load() -> ReadingShareSlots {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([WorkID?].self, from: data)
        else { return ReadingShareSlots() }
        return ReadingShareSlots(decoded)
    }

    func save(_ slots: ReadingShareSlots) {
        defaults.set(try? JSONEncoder().encode(slots.ids), forKey: key)
    }
}

struct ReadingShareCandidate: Identifiable {
    var id: WorkID { work.id }
    let work: Work
    let titleState: UserTitleState?
    let lastReadAt: Date?

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.lastReadAt != rhs.lastReadAt { return (lhs.lastReadAt ?? .distantPast) > (rhs.lastReadAt ?? .distantPast) }
        let order = lhs.work.title.localizedCaseInsensitiveCompare(rhs.work.title)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }

    static func matches(_ candidate: Self, query: String) -> Bool {
        let text = ([candidate.work.title] + candidate.work.authors).joined(separator: " ").mangoReaderSearchNormalized
        return query.mangoReaderSearchNormalized.split(whereSeparator: \.isWhitespace).allSatisfy { text.contains($0) }
    }
}

struct ReadingShareCatalog {
    let history: [ReadingShareCandidate]
    let current: [ReadingShareCandidate]
    let candidates: [WorkID: ReadingShareCandidate]
    var favouriteSlots = ReadingShareSlots()

    init(history: [ReadingShareCandidate], current: [ReadingShareCandidate], candidates: [WorkID: ReadingShareCandidate]) {
        self.history = history.sorted(by: ReadingShareCandidate.precedes)
        self.current = current.sorted(by: ReadingShareCandidate.precedes)
        self.candidates = candidates
    }

    init(snapshot: ReadingStatsSnapshot) {
        let history = snapshot.titles.map { title in
            ReadingShareCandidate(work: title.work, titleState: title.titleState,
                                  lastReadAt: title.latestSession.endedAt ?? title.latestSession.startedAt)
        }
        self.init(history: history, current: history.filter { candidate in
            if let status = candidate.titleState?.status { return status == .reading || status == .rereading }
            return snapshot.titles.first { $0.id == candidate.id }.map { $0.latestSession.endProgression < 1 } ?? false
        }, candidates: Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) }))
    }

    func suggestions(for mode: ReadingShareViewMode) -> ReadingShareSlots {
        switch mode {
        case .currentlyReading: ReadingShareSlots(current.prefix(6).map { Optional($0.id) })
        case .recentReads: ReadingShareSlots(history.prefix(6).map { Optional($0.id) })
        case .favourites: favouriteSlots.resolving(available: Set(candidates.keys))
        }
    }

    static func isCurrentlyReading(
        work: Work, state: UserTitleState?, latestSession: ReadingSession?,
        installments: [Installment], progresses: [ReadingProgress]
    ) -> Bool {
        if let status = state?.status { return status == .reading || status == .rereading }
        let reset = progresses.compactMap(\.resetAt).max()
        let session = latestSession.flatMap { value in
            reset.map { (value.endedAt ?? value.startedAt) <= $0 } == true ? nil : value
        }
        let activeProgress = progresses.filter { $0.highestProgression > 0 }
        guard session != nil || !activeProgress.isEmpty,
              let item = ContinueReadingPolicy.item(work: work, sessions: session.map { [$0] } ?? [],
                  installments: installments, progresses: progresses, fallsBackToOldest: false)
        else { return false }
        if item.isUpNext { return session != nil }
        let progression = max(
            activeProgress.first { $0.installmentID == item.installment.id }?.highestProgression ?? 0,
            session?.installmentID == item.installment.id ? session?.endProgression ?? 0 : 0
        )
        return progression < 1
    }
}

extension LibraryModel {
    /// Read-only composer data; the complete snapshot includes history beyond the displayed cache.
    func readingShareCatalog(range: ReadingStatsRange) async throws -> ReadingShareCatalog {
        guard let database else { throw CocoaError(.fileReadUnknown) }
        let snapshot = try await readingStatsSnapshot(range: range)
        var catalog = ReadingShareCatalog(snapshot: snapshot)
        guard range == .allTime else { return catalog }
        let works = try await database.library(sort: .recentlyRead)
        let states = try await database.titleStates(workIDs: Set(works.map(\.id)))
        let statesByID = Dictionary(uniqueKeysWithValues: states.map { ($0.workID, $0) })
        let progresses = try await database.progresses()
        let progressByID = Dictionary(grouping: progresses, by: \.workID)
        let statsByID = Dictionary(uniqueKeysWithValues: snapshot.titles.map { ($0.id, $0) })
        var candidates = catalog.candidates
        var current: [ReadingShareCandidate] = []
        for work in works {
            try Task.checkCancellation()
            let state = statesByID[work.id]
            let latest = statsByID[work.id]?.latestSession
            let progress = progressByID[work.id, default: []]
            let lastRead = ([latest.map { $0.endedAt ?? $0.startedAt }] + progress.map { Optional($0.modifiedAt) })
                .compactMap { $0 }.max()
            let candidate = ReadingShareCandidate(work: work, titleState: state, lastReadAt: lastRead)
            candidates[work.id] = candidate
            // Explicit tracker statuses need no chapter lookup.
            let installments = state?.status == nil && (latest != nil || !progress.isEmpty)
                ? try await database.installments(for: work.id) : []
            if ReadingShareCatalog.isCurrentlyReading(work: work, state: state, latestSession: latest,
                                                       installments: installments, progresses: progress) {
                current.append(candidate)
            }
        }
        catalog = ReadingShareCatalog(history: catalog.history, current: current, candidates: candidates)
        return catalog
    }
}

struct ReadingSharePayload {
    let selection: ReadingShareSelection
    let requestedSlots: ReadingShareSlots?
    let catalog: ReadingShareCatalog
    let slots: ReadingShareSlots
    var covers: [WorkID: UIImage] = [:]
    var titles: [ReadingShareCandidate] { slots.ids.compactMap { $0.flatMap { catalog.candidates[$0] } } }

    init(catalog: ReadingShareCatalog, selection: ReadingShareSelection, slots: ReadingShareSlots? = nil) {
        self.catalog = catalog
        self.selection = selection
        requestedSlots = slots
        self.slots = (slots ?? catalog.suggestions(for: selection.mode)).resolving(available: Set(catalog.candidates.keys))
    }

    init(snapshot: ReadingStatsSnapshot, selection: ReadingShareSelection) {
        self.init(catalog: ReadingShareCatalog(snapshot: snapshot), selection: selection)
    }

    var title: String { (["Mango Reader", selection.mode.displayName] + [selection.graphicPeriod].compactMap { $0 }).joined(separator: " · ") }
    var caption: String {
        ([title] + titles.map { candidate in
            candidate.work.title + (candidate.titleState?.rating.map { " · ★ \($0.rawValue)/10" } ?? "")
        }).joined(separator: "\n")
    }
}

struct ReadingSharePreparedImage {
    let payload: ReadingSharePayload
    let image: UIImage
    let pngData: Data
}

@MainActor @Observable
final class ReadingSharePreparation {
    private(set) var prepared: ReadingSharePreparedImage?
    private(set) var isPreparing = false
    private(set) var isEmpty = false
    private(set) var errorMessage: String?
    private var generation = UUID()

    func invalidate() {
        generation = UUID()
        prepared = nil
        isPreparing = false
        isEmpty = false
        errorMessage = nil
    }

    func prepare(
        selection: ReadingShareSelection, slots: ReadingShareSlots? = nil,
        loadCatalog: @MainActor (ReadingStatsRange) async throws -> ReadingShareCatalog,
        loadCover: @MainActor (Work) async -> UIImage? = { _ in nil },
        render: @MainActor (ReadingSharePayload) -> UIImage? = ReadingShareRenderer.render,
        encode: @MainActor (UIImage) -> Data? = { $0.pngData() }
    ) async {
        guard !Task.isCancelled else { return }
        invalidate()
        let request = generation
        isPreparing = true
        defer { if generation == request { isPreparing = false } }
        do {
            let catalog = try await loadCatalog(selection.range)
            try Task.checkCancellation()
            guard generation == request else { return }
            var payload = ReadingSharePayload(catalog: catalog, selection: selection, slots: slots)
            isEmpty = payload.slots.isEmpty
            for candidate in payload.titles {
                let image = await loadCover(candidate.work)
                try Task.checkCancellation()
                guard generation == request else { return }
                payload.covers[candidate.id] = image
            }
            await Task.yield()
            try Task.checkCancellation()
            guard generation == request else { return }
            guard let image = render(payload) else {
                errorMessage = "Couldn’t render image"
                return
            }
            guard let data = encode(image) else {
                errorMessage = "Couldn’t encode image"
                return
            }
            prepared = ReadingSharePreparedImage(payload: payload, image: image, pngData: data)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == request else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private struct ReadingSharePickerDraft: Hashable {
    let id = UUID()
    let index: Int
    let slots: ReadingShareSlots
    let history: [ReadingShareCandidate]
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ReadingShareComposerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: ReadingShareSelection
    @State private var edits: [ReadingShareViewMode: ReadingShareSlots] = [:]
    @State private var catalogs: [ReadingStatsRange: ReadingShareCatalog] = [:]
    @State private var preparation = ReadingSharePreparation()
    @State private var imageCopied = false
    @State private var isShowingCustomRange = false
    @State private var retryID = UUID()
    @State private var picker: ReadingSharePickerDraft?

    init(draft: ReadingShareDraft) {
        _selection = State(initialValue: ReadingShareSelection(period: ReadingSharePeriod(range: draft.range)))
    }

    private struct Request: Hashable {
        let selection: ReadingShareSelection
        let slots: ReadingShareSlots?
        let retryID: UUID
    }
    private var request: Request { Request(selection: selection, slots: edits[selection.mode], retryID: retryID) }
    private var prepared: ReadingSharePreparedImage? {
        guard let prepared = preparation.prepared, prepared.payload.selection == selection,
              prepared.payload.requestedSlots == edits[selection.mode] else { return nil }
        return prepared
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppLayout.sectionSpacing) {
                    ReadingShareControls(selection: $selection) { isShowingCustomRange = true }
                    preview.frame(maxWidth: .infinity)
                    ReadingShareActions(prepared: prepared, imageCopied: $imageCopied, isPrivate: model.isPrivate)
                }
                .padding(AppLayout.pageMargin)
            }
            .appBackground()
            .navigationTitle("Share Books")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    FixedNavigationChrome {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("reading-share-close")
                    }
                }
            }
            .navigationDestination(item: $picker) { draft in
                ReadingShareHistoryPicker(history: draft.history, slots: draft.slots, index: draft.index) { id in
                    replaceSlot(draft.index, with: id, slots: draft.slots)
                }
            }
            .sheet(isPresented: $isShowingCustomRange) {
                CustomReadingRangeSheet { selection.period = .custom($0) }
            }
            .onChange(of: selection.period) { edits[.recentReads] = nil }
            .onChange(of: request) {
                preparation.invalidate()
                imageCopied = false
            }
            .task(id: request) {
                let current = request
                await preparation.prepare(selection: current.selection, slots: current.slots) { range in
                    var catalog: ReadingShareCatalog
                    if let cached = catalogs[range] {
                        catalog = cached
                    } else {
                        catalog = try await model.libraryModel.readingShareCatalog(range: range)
                        try Task.checkCancellation()
                        catalogs[range] = catalog
                    }
                    catalog.favouriteSlots = ReadingShareFavouriteStore(defaults: model.libraryModel.defaults).load()
                    return catalog
                } loadCover: { work in
                    guard let data = await model.libraryModel.shareCoverData(for: work),
                          let cover = await CoverImageDecoder.decode(data, maximumPixelDimension: 512)
                    else { return nil }
                    return UIImage(cgImage: cover)
                }
            }
        }
    }

    private func replaceSlot(_ index: Int, with id: WorkID?, slots: ReadingShareSlots) {
        var next = slots
        guard next.replace(at: index, with: id) else { return }
        if selection.mode == .favourites {
            ReadingShareFavouriteStore(defaults: model.libraryModel.defaults).save(next)
        }
        edits[selection.mode] = next
    }

    @ViewBuilder
    private var preview: some View {
        if let prepared {
            TransparencyPreview {
                ReadingShareEditablePreview(prepared: prepared) { index in
                    picker = ReadingSharePickerDraft(index: index, slots: prepared.payload.slots,
                                                     history: prepared.payload.catalog.history)
                } remove: { index in
                    replaceSlot(index, with: nil, slots: prepared.payload.slots)
                }
            }
        } else if preparation.errorMessage != nil {
            ContentUnavailableView {
                Label("Couldn’t prepare image", systemImage: "photo.badge.exclamationmark")
            } actions: {
                Button("Retry") {
                    catalogs[selection.range] = nil
                    retryID = UUID()
                }.readingShareButtonStyle()
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 260).accessibilityLabel("Preparing image")
        }
    }
}

struct ReadingShareHistoryPicker: View {
    @Environment(\.dismiss) private var dismiss
    let history: [ReadingShareCandidate]
    let slots: ReadingShareSlots
    let index: Int
    let select: (WorkID?) -> Void
    @State private var query = ""

    private var matches: [ReadingShareCandidate] { history.filter { ReadingShareCandidate.matches($0, query: query) } }
    private func isOccupied(_ id: WorkID) -> Bool {
        slots.ids.enumerated().contains { $0.offset != index && $0.element == id }
    }

    var body: some View {
        List {
            ForEach(matches) { candidate in
                Button {
                    select(candidate.id)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        RemoteCover(work: candidate.work, style: .miniPlayer, animatesLoadingPlaceholder: false)
                            .frame(width: 40, height: 60)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.work.title).foregroundStyle(.primary)
                            if !candidate.work.authors.isEmpty {
                                Text(candidate.work.authors.joined(separator: ", "))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if slots.ids.contains(candidate.id) { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isOccupied(candidate.id))
                .accessibilityLabel(candidate.work.title)
                .accessibilityValue(isOccupied(candidate.id) ? "Already added" : slots.ids[index] == candidate.id ? "Selected" : "")
                .accessibilityIdentifier("reading-share-book-\(candidate.id)")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .appBackground()
        .navigationTitle("Choose Book")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .searchable(text: $query, prompt: "Search History")
        .overlay {
            if matches.isEmpty {
                ContentUnavailableView(history.isEmpty ? "No Reading History" : "No Results", systemImage: "books.vertical")
            }
        }
        .toolbar {
            if slots.ids[index] != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    FixedNavigationChrome {
                        Button("Remove Book", systemImage: "trash", role: .destructive) {
                            select(nil)
                            dismiss()
                        }.labelStyle(.iconOnly)
                    }
                }
            }
        }
    }
}

struct ReadingShareControls: View {
    @Binding var selection: ReadingShareSelection
    let showCustomRange: () -> Void

    var body: some View {
        GlassCapsuleGroup(spacing: 12) {
            HStack(spacing: 12) {
                if selection.mode == .recentReads {
                    Menu {
                        Picker("Period", selection: $selection.period) {
                            ForEach(ReadingSharePeriod.presets, id: \.self) { period in Text(period.displayName).tag(period) }
                            if case .custom = selection.period { Text(selection.period.displayName).tag(selection.period) }
                        }
                        Button("Custom Range", action: showCustomRange)
                    } label: {
                        Label(selection.period.displayName, systemImage: "calendar")
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .readingShareButtonStyle()
                    .accessibilityLabel("Period").accessibilityValue(selection.period.displayName)
                    .accessibilityIdentifier("reading-share-period")
                    .accessibilitySortPriority(8)
                }
                Spacer(minLength: 0)
                Menu {
                    Picker("Shelf", selection: $selection.mode) {
                        ForEach(ReadingShareViewMode.allCases, id: \.self) { mode in Text(mode.displayName).tag(mode) }
                    }
                } label: {
                    Label(selection.mode.displayName, systemImage: "chevron.down").lineLimit(2)
                }
                .readingShareButtonStyle()
                .layoutPriority(1)
                .accessibilityLabel("Reading shelf").accessibilityValue(selection.mode.displayName)
                .accessibilityIdentifier("reading-share-view")
                .accessibilitySortPriority(7)
            }.controlSize(.large)
        }
    }
}

struct ReadingShareActions: View {
    let prepared: ReadingSharePreparedImage?

    private var shareable: ReadingSharePreparedImage? {
        prepared.flatMap { $0.payload.slots.isEmpty ? nil : $0 }
    }
    @Binding var imageCopied: Bool
    var isPrivate = false

    var body: some View {
        GlassCapsuleGroup(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { buttons }
                    .fixedSize(horizontal: true, vertical: true)
                VStack(spacing: 12) { buttons }
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button {
            guard let prepared = shareable else { return }
            UIPasteboard.general.setItems([ReadingShareImage(data: prepared.pngData).pasteboardItem])
            imageCopied = true
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Image copied."))
        } label: {
            Label(imageCopied ? "Image Copied" : "Copy Image", systemImage: imageCopied ? "checkmark" : "doc.on.doc")
        }
        .readingShareButtonStyle(prominent: true)
        .disabled(isPrivate || shareable == nil)
        .accessibilityIdentifier("reading-share-copy-image")

        if let prepared = shareable {
            ShareLink(
                item: ReadingShareImage(data: prepared.pngData),
                subject: Text(prepared.payload.title),
                message: Text(prepared.payload.caption),
                preview: SharePreview(prepared.payload.title, image: Image(uiImage: prepared.image))
            ) {
                Label("Share Image", systemImage: "square.and.arrow.up")
            }
            .readingShareButtonStyle()
            .disabled(isPrivate)
            .accessibilityIdentifier("reading-share-image")
        } else {
            Button {} label: {
                Label("Share Image", systemImage: "square.and.arrow.up")
            }
            .readingShareButtonStyle()
            .disabled(true)
            .disabled(isPrivate)
            .accessibilityIdentifier("reading-share-image")
        }
    }
}

/// Both the bitmap and its button overlays use these exact logical coordinates.
enum ReadingShareLayout {
    static let width: CGFloat = 360
    static let padding: CGFloat = 24
    static let spacing: CGFloat = 12
    static let coverWidth: CGFloat = 96
    static let coverHeight: CGFloat = 144
    static let gridTop: CGFloat = 114
    static let height: CGFloat = gridTop + 2 * coverHeight + spacing + padding

    static func slotRect(_ index: Int) -> CGRect {
        CGRect(x: padding + CGFloat(index % 3) * (coverWidth + spacing),
               y: gridTop + CGFloat(index / 3) * (coverHeight + spacing),
               width: coverWidth, height: coverHeight)
    }
}

@MainActor
enum ReadingShareRenderer {
    static let logicalWidth = ReadingShareLayout.width
    static let scale: CGFloat = 3
    static let coverWidth = ReadingShareLayout.coverWidth

    static func render(payload: ReadingSharePayload) -> UIImage? {
        let renderer = ImageRenderer(content: ReadingShareAsset(payload: payload))
        renderer.proposedSize = ProposedViewSize(width: logicalWidth, height: ReadingShareLayout.height)
        renderer.scale = scale
        renderer.isOpaque = false
        guard let image = renderer.uiImage, image.cgImage?.width == Int(logicalWidth * scale),
              image.cgImage?.height == Int(ReadingShareLayout.height * scale) else { return nil }
        return image
    }
}

struct ReadingShareAsset: View {
    let payload: ReadingSharePayload

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Mango Reader").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    .frame(height: 22, alignment: .leading)
                HStack(alignment: .center, spacing: 8) {
                    Text(payload.selection.mode.displayName)
                        .font(.system(size: 32, weight: .medium, design: .serif))
                        .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
                    if let period = payload.selection.graphicPeriod {
                        Spacer(minLength: 0)
                        Text(period).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.trailing).lineLimit(2).frame(maxWidth: 96)
                    }
                }.frame(height: 44, alignment: .leading)
            }
            .frame(width: ReadingShareLayout.width - 2 * ReadingShareLayout.padding, alignment: .leading)
            .shareOverlayTextShadow()
            .offset(x: ReadingShareLayout.padding, y: ReadingShareLayout.padding)
            ForEach(0 ..< ReadingShareSlots.count, id: \.self) { index in
                if let id = payload.slots.ids[index], let candidate = payload.catalog.candidates[id] {
                    let rect = ReadingShareLayout.slotRect(index)
                    ReadingShareCover(title: candidate, image: payload.covers[id])
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
        .frame(width: ReadingShareLayout.width, height: ReadingShareLayout.height, alignment: .topLeading)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(.large)
    }
}

struct ReadingShareCover: View {
    let title: ReadingShareCandidate
    let image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { CoverPlaceholder(work: title.work) }
        }
        .frame(width: ReadingShareLayout.coverWidth, height: ReadingShareLayout.coverHeight)
        .clipped().clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .topTrailing) {
            if let rating = title.titleState?.rating {
                Label("\(rating.rawValue)/10", systemImage: "star.fill")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 4)
                    .background(.black.opacity(0.8), in: Capsule()).padding(3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.work.title)
        .accessibilityValue(title.titleState?.rating.map { "Rated \($0.rawValue) out of 10" } ?? "")
    }
}

struct ReadingShareEditablePreview: View {
    let prepared: ReadingSharePreparedImage
    let choose: (Int) -> Void
    let remove: (Int) -> Void

    var body: some View {
        ZStack {
            Image(uiImage: prepared.image).resizable().scaledToFit().accessibilityHidden(true)
            GeometryReader { geometry in
                let scale = geometry.size.width / ReadingShareLayout.width
                ForEach(0 ..< ReadingShareSlots.count, id: \.self) { index in
                    let rect = ReadingShareLayout.slotRect(index)
                    let candidate = prepared.payload.slots.ids[index].flatMap { prepared.payload.catalog.candidates[$0] }
                    Button { choose(index) } label: {
                        ZStack {
                            Color.clear
                            if candidate == nil {
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(.white.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                                Image(systemName: "plus").font(.title2).foregroundStyle(.white.opacity(0.85))
                            }
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityRepresentation {
                        Button(candidate.map { "Replace \($0.work.title)" } ?? "Add Book") { choose(index) }
                            .frame(width: rect.width * scale, height: rect.height * scale)
                            .accessibilityValue("Row \(index / 3 + 1), column \(index % 3 + 1)" +
                                (candidate?.titleState?.rating.map { ", rated \($0.rawValue) out of 10" } ?? ""))
                            .accessibilityIdentifier("reading-share-slot-\(index)")
                            .accessibilitySortPriority(Double(ReadingShareSlots.count - index))
                            .accessibilityActions {
                                if candidate != nil { Button("Remove Book") { remove(index) } }
                            }
                    }
                    .frame(width: rect.width * scale, height: rect.height * scale)
                    .position(x: rect.midX * scale, y: rect.midY * scale)
                    .contextMenu {
                        if candidate != nil { Button("Remove Book", systemImage: "trash", role: .destructive) { remove(index) } }
                    }
                }
            }
        }
        .aspectRatio(ReadingShareLayout.width / ReadingShareLayout.height, contentMode: .fit)
    }
}

private struct TransparencyPreview<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let tile: CGFloat = 14
                for row in 0 ..< Int(ceil(size.height / tile)) {
                    for column in 0 ..< Int(ceil(size.width / tile)) {
                        let shade = (row + column).isMultiple(of: 2) ? 0.24 : 0.27
                        context.fill(Path(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile,
                                                 width: tile, height: tile)), with: .color(Color(white: shade)))
                    }
                }
            }
            content.padding(12)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private extension View {
    @ViewBuilder
    func readingShareButtonStyle(prominent: Bool = false) -> some View {
#if targetEnvironment(macCatalyst)
        if prominent { buttonStyle(.borderedProminent) }
        else { buttonStyle(.bordered) }
#else
        if #available(iOS 26, *) {
            if prominent { buttonStyle(.glassProminent) }
            else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) }
            else { buttonStyle(.bordered) }
        }
#endif
    }

    func shareOverlayTextShadow() -> some View {
        shadow(color: .black.opacity(0.7), radius: 2, x: 0, y: 1)
    }
}

extension ReadingStatsRange {
    var displayName: String {
        switch self {
        case .thisMonth: String(localized: "This Month")
        case .thisYear: String(localized: "This Year")
        case .allTime: String(localized: "All Time")
        case let .custom(interval):
            "\(interval.start.formatted(date: .abbreviated, time: .omitted)) – \(interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))"
        }
    }
}

extension TimeInterval {
    var statsDuration: String {
        let duration = max(0, self)
        let formatter = DateComponentsFormatter()
        formatter.calendar = .autoupdatingCurrent
        formatter.allowedUnits = duration >= 3_600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        if duration > 0, duration < 60 { return "< 1 min" }
        return formatter.string(from: duration) ?? "0 min"
    }
}
