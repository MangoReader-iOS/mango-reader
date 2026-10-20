import MangoReaderDomain
import MangoReaderReaders
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PDFThumbnailRail: View {
    let controller: ReadiumReaderController
    let onClose: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Label("Pages", systemImage: "rectangle.grid.1x2")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .appIconControlFrame(dimension: 48)
                }
                .accessibilityLabel("Hide page thumbnails")
                .accessibilityIdentifier("reader-pdf-thumbnails-close")
            }
            .padding(.horizontal, 12)

            PDFThumbnailNavigationView(controller: controller)
                .frame(height: 108)
        }
        .frame(maxWidth: 760)
        .padding(.top, 4)
        .readerOverlayPanel()
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-pdf-thumbnail-rail")
    }
}

struct PublicationOutlineSheet: View {
    @Environment(\.dismiss) private var dismiss
    let controller: ReadiumReaderController

    var body: some View {
        NavigationStack {
            Group {
                switch controller.outlinePhase {
                case .idle, .loading:
                    AppContentSkeleton(kind: .chapters, count: 3, label: String(localized: "Loading contents…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .ready where controller.outline.isEmpty:
                    ContentUnavailableView(
                        "No Contents",
                        systemImage: "list.bullet.indent"
                    )

                case .ready:
                    List(controller.outline) { item in
                        Button {
                            controller.navigate(to: item)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .foregroundStyle(.primary)
                                if !item.href.hasPrefix("block-") {
                                    Text(item.href)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, CGFloat(min(item.depth, 4)) * 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .appFullWidthListSeparator()
                        .accessibilityLabel("Level \(item.depth + 1), \(item.title)")
                        .accessibilityHint("Opens this section")
                    }

                case let .failed(message):
                    ContentUnavailableView(
                        "Contents Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    FixedNavigationChrome {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }
}

struct PublicationSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let controller: ReadiumReaderController
    @State private var query: String

    init(controller: ReadiumReaderController) {
        self.controller = controller
        _query = State(initialValue: controller.searchQuery)
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "Search This Publication",
                        systemImage: "text.magnifyingglass"
                    )
                } else if controller.searchResults.isEmpty {
                    emptyResults
                } else {
                    resultsList
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    FixedNavigationChrome {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                controller.cancelSearch(clearResults: true)
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(280))
                try Task.checkCancellation()
                controller.search(trimmed)
            } catch {
                return
            }
        }
        .onDisappear {
            controller.cancelSearch(clearResults: false)
        }
    }

    @ViewBuilder
    private var emptyResults: some View {
        switch controller.searchPhase {
        case .searching, .receiving:
            AppContentSkeleton(kind: .textRows, count: 3, label: String(localized: "Searching publication…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .failed(message):
            ContentUnavailableView(
                "Search Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )

        case .complete:
            ContentUnavailableView.search(text: query)

        case .idle:
            EmptyView()
        }
    }

    private var resultsList: some View {
        List {
            ForEach(controller.searchResults) { result in
                Button {
                    controller.navigate(to: result)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        if let title = result.title, !title.isEmpty {
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        (
                            Text(verbatim: result.before)
                                + Text(verbatim: result.match).bold().foregroundColor(.accentColor)
                                + Text(verbatim: result.after)
                        )
                        .foregroundStyle(.primary)
                        .lineLimit(4)

                        if let progression = result.totalProgression {
                            Text(progression, format: .percent.precision(.fractionLength(0)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .appFullWidthListSeparator()
                .accessibilityLabel(result.accessibilityExcerpt)
                .accessibilityHint("Opens this result in the reader")
            }

            if controller.searchPhase.isSearching {
                HStack {
                    Spacer()
                    AppContentSkeleton(kind: .textRows, count: 2, label: String(localized: "Searching for more results"))
                    Spacer()
                }
                .appFullWidthListSeparator()
            }
        }
    }
}

struct PublicationTTSControls: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let controller: ReadiumReaderController

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 14))

        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.ttsState == .paused ? "Text to Speech Paused" : "Reading Aloud")
                    .font(.caption.weight(.semibold))
                Text(controller.ttsExcerpt ?? "Preparing the next passage…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(controller.ttsExcerpt ?? "Preparing the next passage")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button {
                    controller.previousTTSUtterance()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .appIconControlFrame(dimension: 48)
                }
                .accessibilityLabel("Previous passage")

                Button {
                    controller.toggleTTS()
                } label: {
                    Image(systemName: controller.ttsState == .speaking ? "pause.fill" : "play.fill")
                        .appIconControlFrame(dimension: 48)
                }
                .accessibilityLabel(controller.ttsState == .speaking ? "Pause text to speech" : "Resume text to speech")

                Button {
                    controller.nextTTSUtterance()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .appIconControlFrame(dimension: 48)
                }
                .accessibilityLabel("Next passage")

                Button(role: .cancel) {
                    controller.stopTTS()
                } label: {
                    Image(systemName: "xmark")
                        .appIconControlFrame(dimension: 48)
                }
                .accessibilityLabel("Stop text to speech")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .readerOverlayPanel()
    }
}

struct ReaderOrientationControl: UIViewControllerRepresentable {
    let orientation: String
    func makeUIViewController(context: Context) -> ReaderOrientationViewController { ReaderOrientationViewController() }
    func updateUIViewController(_ controller: ReaderOrientationViewController, context: Context) { controller.orientation = orientation; controller.apply() }
    static func dismantleUIViewController(_ controller: ReaderOrientationViewController, coordinator: ()) { controller.releaseOrientation() }
}

final class ReaderOrientationViewController: UIViewController {
    var orientation = "device"
    private weak var readerWindow: UIWindow?
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); apply() }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.apply() }
    }
    func apply() {
        guard UIDevice.current.userInterfaceIdiom == .phone, let window = view.window, let scene = window.windowScene else { return }
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *), !view.reservedRegions(kind: .division, options: .includeInactive).isEmpty {
            releaseOrientation()
            return
        }
        #endif
        readerWindow = window
        let mask: UIInterfaceOrientationMask = switch orientation { case "portrait": .portrait; case "landscape": .landscape; default: .allButUpsideDown }
        MangoReaderAppDelegate.readerOrientations[ObjectIdentifier(window)] = mask
        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        window.rootViewController?.presentedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
    func releaseOrientation() {
        guard let window = readerWindow else { return }
        MangoReaderAppDelegate.readerOrientations.removeValue(forKey: ObjectIdentifier(window))
        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}


/// Header and feedback share layout, while the reading surface keeps its full viewport.
struct ReaderTopChrome<Header: View, Status: View>: View {
    let showsControls: Bool
    @ViewBuilder var header: () -> Header
    @ViewBuilder var status: () -> Status

    var body: some View {
        VStack(spacing: 8) {
            if showsControls { header() }
            status()
        }
    }
}

/// Keeps custom reader chrome within a usable region without changing reader identity.
struct ReaderExpandedChrome: ViewModifier {
    let alignment: Alignment

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
        #else
        if #available(iOS 27.1, *) {
            GeometryReader { proxy in
                let bounds = CGRect(origin: .zero, size: proxy.size)
                let division = proxy.reservedRegions(kind: .division, options: .includeInactive,
                    layoutDirectionBehavior: .fixed).first?.frame
                let viewport = ReaderViewport(size: proxy.size, occlusions: proxy.reservedRegions(kind: .occlusion,
                    layoutDirectionBehavior: .fixed).map(\.frame))
                let region = viewport.avoidingOcclusions(chromeRegion(bounds: bounds, division: division))
                content
                    .frame(width: region.width)
                    .frame(height: region.height, alignment: alignment)
                    .position(x: region.midX, y: region.midY)
            }
        } else { content }
        #endif
    }

    private func chromeRegion(bounds: CGRect, division: CGRect?) -> CGRect {
        guard let division else { return bounds }
        if division.height > division.width, division.maxX > 0, division.maxX < bounds.width {
            return CGRect(x: division.maxX, y: 0, width: bounds.width - division.maxX, height: bounds.height)
        }
        if division.maxY > 0, division.maxY < bounds.height {
            if alignment == .bottom {
                return CGRect(x: 0, y: division.maxY, width: bounds.width, height: bounds.height - division.maxY)
            }
            return CGRect(x: 0, y: 0, width: bounds.width, height: division.minY)
        }
        return bounds
    }
}
