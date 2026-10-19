import MankoDomain
import MankoExtensions
import MankoReaders
import MankoSources
import Observation
import PhotosUI
import SwiftUI

@MainActor @Observable
final class RatingSaveState {
    private(set) var selectedRating: Int?
    private(set) var persistedRating: Int?
    private(set) var isSaving = false
    private(set) var revision = 0
    private var task: Task<Void, Never>?

    func load(_ rating: Int?, expectedRevision: Int? = nil) {
        guard !isSaving, expectedRevision.map({ $0 == revision }) ?? (revision == 0) else { return }
        selectedRating = rating
        persistedRating = rating
    }

    // User-requested saves finish after navigation. One worker serializes writes
    // and coalesces any newer taps received while preparation or saving awaits.
    @discardableResult
    func choose(
        _ rating: Int?,
        prepare: @escaping @MainActor () async -> Bool,
        save: @escaping @MainActor (Int?) async -> Bool
    ) -> Task<Void, Never> {
        selectedRating = rating
        revision &+= 1
        if let task { return task }
        isSaving = true
        let operation = Task {
            while true {
                let currentRevision = revision
                let value = selectedRating
                let prepared = await prepare()
                guard currentRevision == revision else { continue }
                let didSave = prepared ? await save(value) : false
                if didSave { persistedRating = value }
                guard currentRevision == revision else { continue }
                if !didSave { selectedRating = persistedRating }
                isSaving = false
                task = nil
                return
            }
        }
        task = operation
        return operation
    }
}

struct TitleTrackingSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let work: Work
    let installments: [Installment]
    @State private var isShowingTrackers = false

    @State private var isLoading = true

    var body: some View {
        Button { isShowingTrackers = true } label: {
            TitleTrackingSummary(
                status: titleState?.status,
                rating: titleState?.rating?.rawValue,
                linkCount: linkCount,
                state: state,
                isLoading: isLoading
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tracker-title-state")
        .accessibilityHint("Opens tracking, title matching, and sync controls")
        .task(id: work.id) {
            isLoading = true
            _ = await model.libraryModel.titleState(for: work.id, reload: true)
            _ = await model.trackingModel.trackerLinks(for: work.id, reload: true)
            guard !Task.isCancelled else { return }
            isLoading = false
        }
        .task(id: installments) {
            guard !installments.isEmpty else { return }
            _ = await model.prepareTitleTracking(work: work, installments: installments)
            await model.syncTrackerLinks(work: work, installments: installments)
        }
        .sheet(isPresented: $isShowingTrackers) {
            TrackerTitleSheet(work: work, installments: installments)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
        }
    }

    private var titleState: UserTitleState? { model.libraryModel.userTitleStates[work.id] }
    private var linkCount: Int { model.trackingModel.trackerLinksByWork[work.id]?.count ?? 0 }
    private var state: TrackerLinkSyncState { model.trackingModel.trackerLinkState(for: work.id) }
}

struct TitleTrackingSummary: View {
    let status: TrackerReadingStatus?
    let rating: Int?
    let linkCount: Int
    let state: TrackerLinkSyncState
    var isLoading = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(isLoading ? String(localized: "Loading Tracking…") : status?.displayName ??
                     (rating == nil && linkCount == 0 ? String(localized: "Set Up Tracking") : String(localized: "Tracking")))
                    .font(.subheadline.weight(.medium))
                if !isLoading {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if isLoading { ProgressView().controlSize(.small) }
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detail: AttributedString {
        var parts: [String] = []
        if let rating { parts.append(String(localized: "Score: \(rating) / 10")) }
        if linkCount > 0 {
            parts.append(linkCount == 1 ? String(localized: "1 tracker") : String(localized: "\(linkCount) trackers"))
            parts.append(state.displayName)
        } else if state == .error {
            parts.append(state.displayName)
        } else {
            parts.append(String(localized: "Track your reading and connect accounts"))
        }
        var detail = AttributedString(parts.joined(separator: " · "))
        if state == .conflict, let range = detail.range(of: state.displayName) {
            detail[range].foregroundColor = AppColors.danger
        }
        return detail
    }
}

extension TrackerLinkSyncState {
    var displayName: String {
        switch self {
        case .notLinked: String(localized: "Not linked")
        case .synced: String(localized: "Synced")
        case .progressAvailable: String(localized: "Progress available")
        case .pending: String(localized: "Pending")
        case .conflict: String(localized: "Needs attention")
        case .error: String(localized: "Sync error")
        }
    }
}

struct WorkDetailDisclosureHeader: View {
    let title: LocalizedStringKey
    @Binding var isExpanded: Bool
    let accessibilityIdentifier: String
    var showsIncognitoStatus = false

    init(
        _ title: LocalizedStringKey,
        isExpanded: Binding<Bool>,
        accessibilityIdentifier: String,
        showsIncognitoStatus: Bool = false
    ) {
        self.title = title
        _isExpanded = isExpanded
        self.accessibilityIdentifier = accessibilityIdentifier
        self.showsIncognitoStatus = showsIncognitoStatus
    }

    var body: some View {
        Button {
            withAnimation {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                if showsIncognitoStatus {
                    IncognitoStatusIndicator()
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(
            showsIncognitoStatus
                ? "\(isExpanded ? "Expanded" : "Collapsed"), Incognito Reading On"
                : (isExpanded ? "Expanded" : "Collapsed")
        )
        .accessibilityHint(isExpanded ? "Collapses this section" : "Expands this section")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
