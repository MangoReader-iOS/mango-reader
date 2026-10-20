import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSources
import Observation
import PhotosUI
import SwiftUI

enum WorkDetailInstallmentOrder: Sendable, Equatable {
    case latestFirst
    case oldestFirst

    mutating func toggle() {
        self = self == .latestFirst ? .oldestFirst : .latestFirst
    }

    var buttonTitle: LocalizedStringKey {
        switch self {
        case .latestFirst: "Highest First"
        case .oldestFirst: "Lowest First"
        }
    }

    var systemImage: String {
        switch self {
        case .latestFirst: "arrow.down"
        case .oldestFirst: "arrow.up"
        }
    }

    var accessibilityValue: LocalizedStringKey {
        switch self {
        case .latestFirst: "Highest first"
        case .oldestFirst: "Lowest first"
        }
    }

    var accessibilityHint: LocalizedStringKey {
        switch self {
        case .latestFirst: "Switches to lowest first"
        case .oldestFirst: "Switches to highest first"
        }
    }
}

struct WorkDetailInstallmentPresentation: Sendable {
    let latestFirst: [Installment]
    let oldestFirst: [Installment]

    var primaryInstallment: Installment? { oldestFirst.first }

    init(installments: [Installment]) {
        oldestFirst = ReaderChapterPolicy.ordered(installments)
        latestFirst = Array(oldestFirst.reversed())
    }

    func installments(for order: WorkDetailInstallmentOrder) -> [Installment] {
        switch order {
        case .latestFirst: latestFirst
        case .oldestFirst: oldestFirst
        }
    }

}

struct WorkDetailInstallmentOrderButton: View {
    @Binding var order: WorkDetailInstallmentOrder
    var usesChapterNumbers = true

    var body: some View {
        Button {
            order.toggle()
        } label: {
            ViewThatFits(in: .horizontal) {
                Label(usesChapterNumbers ? order.buttonTitle : (order == .latestFirst ? "Latest" : "Oldest"), systemImage: order.systemImage)
                Image(systemName: order.systemImage)
            }
            .font(.subheadline.weight(.semibold))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Installment order")
        .accessibilityValue(Text(order.accessibilityValue))
        .accessibilityHint(Text(order.accessibilityHint))
        .accessibilityIdentifier("installment-order-toggle")
    }
}

struct WorkDetailInstallmentSectionHeader: View {
    @Binding var order: WorkDetailInstallmentOrder
    var usesChapterNumbers = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text("Installments").fixedSize()
                    .accessibilityIdentifier("installment-section-title")
                Spacer()
                orderButton
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Installments").fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("installment-section-title")
                orderButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var orderButton: some View {
        WorkDetailInstallmentOrderButton(order: $order, usesChapterNumbers: usesChapterNumbers)
    }
}

struct InstallmentRow: View {
    let installment: Installment
    let progress: ReadingProgress?
    let download: DownloadSnapshot?
    let isLocalWork: Bool
    var isAddedSinceLastVisit = false

    private var statusText: String? {
        WorkDetailInstallmentStatus.text(
            highestProgression: progress?.highestProgression,
            currentProgression: progress?.currentProgression,
            locator: progress?.locator,
            format: installment.format,
            pageCount: installment.pageCount,
            downloadState: download?.state,
            completedBytes: download?.completedBytes ?? 0,
            totalBytes: download?.totalBytes,
            isStoredLocally: installment.acquisitionURL?.isFileURL == true,
            isLocalWork: isLocalWork
        )
    }

    private var hasArrivalDot: Bool { isAddedSinceLastVisit && (progress?.highestProgression ?? 0) < 1 }
    private var caption: String? {
        let components = [WorkDetailInstallmentDate.text(installment.publishedAt), statusText].compactMap { $0 }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(installment.title)
                    .font(.headline)
                    .foregroundStyle((progress?.highestProgression ?? 0) >= 1 ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if hasArrivalDot {
                    Spacer(minLength: 8)
                    Circle().fill(.cyan).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(download?.state == .failed ? AppColors.warning : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(hasArrivalDot ? Text("Added since your last visit") : Text(""))
    }
}

enum WorkDetailInstallmentDate {
    nonisolated static func text(_ date: Date?, now: Date = .now, calendar: Calendar = .current,
                                locale: Locale = .current) -> String? {
        guard let date, date.timeIntervalSince1970.isFinite else { return nil }
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return String(localized: "Yesterday") }
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "dMMM" : "dMMMy")
        return formatter.string(from: date)
    }
}

enum WorkDetailInstallmentStatus {
    nonisolated static func text(
        highestProgression: Double?,
        currentProgression: Double? = nil,
        locator: ReadingLocator? = nil,
        format: PublicationFormat? = nil,
        pageCount: Int? = nil,
        downloadState: DownloadState?,
        completedBytes: Int64,
        totalBytes: Int64?,
        isStoredLocally: Bool,
        isLocalWork: Bool
    ) -> String? {
        var components: [String] = []
        if let highestProgression {
            if highestProgression >= 1 {
                components.append("Completed")
            } else if let locator, case let .image(page, total, _) = locator {
                let maximum = [pageCount, total].compactMap { $0 }.filter { $0 > 0 }.min()
                let bounded = maximum.map { min(max(0, page), max(0, $0 - 1)) } ?? max(0, page)
                if bounded < Int.max { components.append("Page \(bounded + 1)") }
            } else if format == .pdf, let locator, case let .publication(json) = locator,
                      let position = (try? PersistedReadiumLocator(jsonData: json).makeLocator())?.locations.position, position > 0 {
                components.append("Page \(pageCount.map { min(position, max(1, $0)) } ?? position)")
            } else if highestProgression > 0 {
                components.append("\(Int((min(1, max(0, currentProgression ?? highestProgression)) * 100).rounded()))%")
            }
        }

        switch downloadState {
        case .queued:
            components.append("Queued")
        case .downloading:
            if let totalBytes, totalBytes > 0 {
                let fraction = min(1, max(0, Double(completedBytes) / Double(totalBytes)))
                components.append("Downloading \(Int((fraction * 100).rounded()))%")
            } else {
                components.append("Downloading")
            }
        case .paused:
            components.append("Paused")
        case .completed:
            if !isLocalWork {
                components.append("Downloaded")
            }
        case .failed:
            components.append("Download Failed")
        case .cancelled:
            break
        case nil:
            if isStoredLocally, !isLocalWork {
                components.append("Downloaded")
            }
        }

        return components.isEmpty ? nil : components.joined(separator: " · ")
    }
}

struct DownloadContextActions: View {
    @Environment(AppModel.self) private var model
    let snapshot: DownloadSnapshot

    var body: some View {
        switch snapshot.state {
        case .queued, .downloading:
            Button("Pause Download", systemImage: "pause.circle") {
                Task { await model.transfersModel.pauseDownload(snapshot) }
            }
            Button("Cancel Download", systemImage: "xmark.circle", role: .destructive) {
                Task { await model.transfersModel.cancelDownload(snapshot) }
            }
        case .paused:
            Button("Resume Download", systemImage: "play.circle") {
                Task { await model.transfersModel.resumeDownload(snapshot) }
            }
            Button("Cancel Download", systemImage: "xmark.circle", role: .destructive) {
                Task { await model.transfersModel.cancelDownload(snapshot) }
            }
        case .failed, .cancelled:
            Button("Retry Download", systemImage: "arrow.clockwise.circle") {
                Task { await model.transfersModel.retryDownload(snapshot) }
            }
        case .completed:
            Button("Remove Download", systemImage: "trash", role: .destructive) {
                Task { await model.removeDownload(snapshot) }
            }
        }
    }
}

extension PublicationFormat {
    var displayName: String {
        switch self {
        case .remoteImageSequence: "Image sequence"
        case .cbz: "CBZ"
        case .epub: "EPUB"
        case .pdf: "PDF"
        }
    }

    var symbol: String {
        switch self {
        case .remoteImageSequence, .cbz: "photo.on.rectangle.angled"
        case .epub: "text.book.closed"
        case .pdf: "doc.richtext"
        }
    }

    var preferredFileExtension: String {
        switch self {
        case .remoteImageSequence: "zip"
        case .cbz: "cbz"
        case .epub: "epub"
        case .pdf: "pdf"
        }
    }
}
