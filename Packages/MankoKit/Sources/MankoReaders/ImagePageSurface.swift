import CoreGraphics
import SwiftUI
import UIKit
import VisionKit

enum ReaderDynamicTypeSizing {
    static let minimumControlDimension: CGFloat = 44
    static let maximumControlDimension: CGFloat = 72
    static let iconControlDimension: CGFloat = 48

    nonisolated static func controlDimension(scaledDimension: CGFloat) -> CGFloat {
        min(
            max(scaledDimension, minimumControlDimension),
            maximumControlDimension
        )
    }
}

public enum ImageLiveTextSupport {
    public static var isAvailable: Bool {
        ImageAnalyzer.isSupported
    }
}

@MainActor
struct ReaderImageSurface: UIViewRepresentable {
    let image: CGImage
    let cropInsets: NormalizedPageInsets
    let liveTextEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ImageAnalysisContainerView {
        ImageAnalysisContainerView()
    }

    func updateUIView(_ view: ImageAnalysisContainerView, context: Context) {
        context.coordinator.render(
            image,
            cropInsets: cropInsets,
            liveTextEnabled: liveTextEnabled,
            in: view
        )
    }

    static func dismantleUIView(_ view: ImageAnalysisContainerView, coordinator: Coordinator) {
        coordinator.stop()
        if let interaction = coordinator.interaction { view.imageView.removeInteraction(interaction) }
    }

    @MainActor
    final class Coordinator {
        private(set) var interaction: ImageAnalysisInteraction?

        private var analyzer: ImageAnalyzer?
        private var analysisTask: Task<Void, Never>?
        private var analysisID: UUID?
        private var displayedKey: RenderKey?
        private var analyzedKey: RenderKey?

        deinit {
            analysisTask?.cancel()
        }

        func render(
            _ sourceImage: CGImage,
            cropInsets: NormalizedPageInsets,
            liveTextEnabled: Bool,
            layoutAspectRatio: Double? = nil,
            in container: ImageAnalysisContainerView
        ) {
            container.setLayoutAspectRatio(layoutAspectRatio)
            let key = RenderKey(image: sourceImage, cropInsets: cropInsets)
            if displayedKey != key || container.imageView.image == nil {
                analysisTask?.cancel()
                analysisTask = nil
                analysisID = nil
                interaction?.analysis = nil
                analyzedKey = nil

                let cropRect = cropInsets.cropRect(
                    pixelWidth: sourceImage.width,
                    pixelHeight: sourceImage.height
                )
                let renderedImage = cropInsets.isZero
                    ? sourceImage
                    : (sourceImage.cropping(to: cropRect) ?? sourceImage)
                container.setImage(UIImage(cgImage: renderedImage))
                displayedKey = key
            }

            guard liveTextEnabled, ImageAnalyzer.isSupported else {
                disableLiveText(in: container)
                return
            }

            container.imageView.isUserInteractionEnabled = true
            let interaction: ImageAnalysisInteraction
            if let existing = self.interaction {
                interaction = existing
            } else {
                interaction = ImageAnalysisInteraction()
                self.interaction = interaction
                container.imageView.addInteraction(interaction)
            }
            interaction.preferredInteractionTypes = .automaticTextOnly
            guard analyzedKey != key, analysisTask == nil,
                  let renderedImage = container.imageView.image?.cgImage
            else {
                return
            }

            analysisTask?.cancel()
            let analyzer = analyzer ?? ImageAnalyzer()
            self.analyzer = analyzer
            let id = UUID()
            analysisID = id
            analysisTask = Task { [weak self] in
                do {
                    let configuration = ImageAnalyzer.Configuration(.text)
                    let analysis = try await analyzer.analyze(
                        renderedImage,
                        orientation: .up,
                        configuration: configuration
                    )
                    try Task.checkCancellation()
                    guard let self, self.displayedKey == key, analysisID == id else { return }
                    interaction.analysis = analysis
                    analyzedKey = key
                    analysisTask = nil
                    analysisID = nil
                } catch is CancellationError {
                    guard let self, analysisID == id else { return }
                    analysisTask = nil
                    analysisID = nil
                } catch {
                    guard let self, analysisID == id else { return }
                    self.interaction?.analysis = nil
                    analysisTask = nil
                    analysisID = nil
                }
            }
        }

        func stop() {
            analysisTask?.cancel()
            analysisTask = nil
            analysisID = nil
            interaction?.analysis = nil
            analyzedKey = nil
            analyzer = nil
        }

        private func disableLiveText(in container: ImageAnalysisContainerView) {
            stop()
            if let interaction { container.imageView.removeInteraction(interaction) }
            interaction = nil
            container.imageView.isUserInteractionEnabled = false
        }
    }
}

@MainActor
private struct RenderKey: Hashable {
    let imageIdentity: ObjectIdentifier
    let cropInsets: NormalizedPageInsets

    init(image: CGImage, cropInsets: NormalizedPageInsets) {
        imageIdentity = ObjectIdentifier(image)
        self.cropInsets = cropInsets
    }
}

@MainActor
final class ImageAnalysisContainerView: UIView {
    let imageView = UIImageView()
    private var layoutAspectRatio: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        imageView.backgroundColor = .clear
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setImage(_ image: UIImage) {
        imageView.image = image
        setNeedsLayout()
    }

    /// The bitmap may be a small preview; page metadata owns its display geometry.
    func setLayoutAspectRatio(_ ratio: Double?) {
        let value = ratio.flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil }
        guard layoutAspectRatio != value else { return }
        layoutAspectRatio = value
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0
        else {
            imageView.frame = bounds
            return
        }

        let imageAspectRatio = layoutAspectRatio ?? size.width / size.height
        let boundsAspectRatio = bounds.width / bounds.height
        let fittedSize: CGSize
        if imageAspectRatio > boundsAspectRatio {
            fittedSize = CGSize(width: bounds.width, height: bounds.width / imageAspectRatio)
        } else {
            fittedSize = CGSize(width: bounds.height * imageAspectRatio, height: bounds.height)
        }
        imageView.frame = CGRect(
            x: bounds.midX - fittedSize.width / 2,
            y: bounds.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}

@MainActor
public struct ImageReaderPageControls: View {
    @State private var showsPageEntry = false
    let currentPageIndex: Int
    let pageCount: Int
    let isAtBeginning: Bool
    let isAtEnd: Bool
    let direction: ImageReadingDirection
    let layout: ImageReaderLayout
    let moveBackward: () -> Void
    let moveForward: () -> Void
    let usesPositions: Bool
    let showsTotal: Bool
    let canSeek: Bool
    let seek: ((Int) -> Void)?
    let onSelectionChanged: ((Bool) -> Void)?

    public init(
        currentPageIndex: Int,
        pageCount: Int,
        isAtBeginning: Bool,
        isAtEnd: Bool,
        direction: ImageReadingDirection,
        layout: ImageReaderLayout,
        usesPositions: Bool = false,
        showsTotal: Bool = true,
        canSeek: Bool = true,
        seek: ((Int) -> Void)? = nil,
        onSelectionChanged: ((Bool) -> Void)? = nil,
        moveBackward: @escaping () -> Void,
        moveForward: @escaping () -> Void
    ) {
        self.currentPageIndex = currentPageIndex
        self.pageCount = pageCount
        self.isAtBeginning = isAtBeginning
        self.isAtEnd = isAtEnd
        self.direction = direction
        self.layout = layout
        self.usesPositions = usesPositions
        self.showsTotal = showsTotal
        self.canSeek = canSeek
        self.seek = seek
        self.onSelectionChanged = onSelectionChanged
        self.moveBackward = moveBackward
        self.moveForward = moveForward
    }

    public var body: some View {
        let motions = ImagePageMotion.controls(for: layout)
        HStack(spacing: 8) {
            pageMotionButton(motions.first)
            if seek != nil {
                Button {
                    onSelectionChanged?(true)
                    showsPageEntry = true
                } label: {
                    pageLabel.frame(minHeight: 48).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSeek)
                .accessibilityHint(usesPositions ? "Enter a position to jump to" : "Enter a page to jump to")
                .accessibilityIdentifier("reader-page-entry-button")
                .popover(isPresented: $showsPageEntry, arrowEdge: .bottom) {
                    ReaderPageEntryView(currentPageIndex: currentPageIndex, pageCount: pageCount,
                        usesPositions: usesPositions, onCancel: { showsPageEntry = false }, onGo: { index in
                            commit(index)
                            showsPageEntry = false
                        })
                        .presentationCompactAdaptation(.sheet)
                }
            } else {
                pageLabel
            }
            pageMotionButton(motions.second)
        }
        .foregroundStyle(.white)
        .modifier(ImageReaderControlsStyle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-page-controls")
        .onChange(of: showsPageEntry) { _, presented in
            if !presented { onSelectionChanged?(false) }
        }
        .onChange(of: canSeek) { _, enabled in
            if !enabled {
                showsPageEntry = false
                onSelectionChanged?(false)
            }
        }
        .onDisappear {
            showsPageEntry = false
            onSelectionChanged?(false)
        }
    }

    private var pageLabel: some View {
        Text(showsTotal ? "\(currentPageIndex + 1) / \(pageCount)" : "\(currentPageIndex + 1)")
            .font(.callout.monospacedDigit())
            .frame(minWidth: 56)
            .dynamicTypeSize(.large)
            .accessibilityLabel(!showsTotal ? "Position \(currentPageIndex + 1)" : usesPositions
                ? "Position \(currentPageIndex + 1) of \(pageCount)"
                : "Page \(currentPageIndex + 1) of \(pageCount)")
    }

    private func commit(_ index: Int) {
        guard canSeek, index != currentPageIndex, (0..<pageCount).contains(index) else { return }
        seek?(index)
    }

    private func pageMotionButton(_ motion: ImagePageMotion) -> some View {
        let action = motion.action(for: direction)
        return Button {
            perform(action)
        } label: {
            Image(systemName: motion.systemImage)
                .readerControlHitTarget()
        }
        .disabled(motion.isDisabled(
            for: direction,
            isAtBeginning: isAtBeginning,
            isAtEnd: isAtEnd
        ))
        .accessibilityLabel(action.accessibilityPageLabel)
    }

    private func perform(_ action: ReaderTapAction) {
        switch action {
        case .previousPage:
            moveBackward()
        case .nextPage:
            moveForward()
        case .none, .scrollBackward, .scrollForward, .toggleControls:
            break
        }
    }
}

enum ReaderPageSelection {
    static func destination(for text: String, pageCount: Int) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy(\.isNumber),
              let number = Int(value), number >= 1, number <= pageCount else { return nil }
        return number - 1
    }
}

struct ReaderPageEntryView: View {
    let currentPageIndex: Int
    let pageCount: Int
    let usesPositions: Bool
    let onCancel: () -> Void
    let onGo: (Int) -> Void
    @Environment(\.dynamicTypeSize) private var contentTextSize
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(currentPageIndex: Int, pageCount: Int, usesPositions: Bool,
         onCancel: @escaping () -> Void, onGo: @escaping (Int) -> Void) {
        self.currentPageIndex = currentPageIndex
        self.pageCount = pageCount
        self.usesPositions = usesPositions
        self.onCancel = onCancel
        self.onGo = onGo
        _text = State(initialValue: String(currentPageIndex + 1))
    }

    private var destination: Int? { ReaderPageSelection.destination(for: text, pageCount: pageCount) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(usesPositions ? "Position" : "Page") {
                        TextField(usesPositions ? "Position number" : "Page number", text: $text)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($isFocused)
                            .submitLabel(.go)
                            .onSubmit(submit)
                            .accessibilityLabel(usesPositions ? "Position number" : "Page number")
                            .accessibilityIdentifier("reader-page-entry-field")
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(usesPositions ? "Positions: 1–\(pageCount)" : "Pages: 1–\(pageCount)")
                        if usesPositions { Text("Positions are approximate text locations, not screen pages.") }
                        if destination == nil {
                            Text("Enter a whole number between 1 and \(pageCount).")
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("reader-page-entry-error")
                        }
                    }
                }
            }
            .environment(\.dynamicTypeSize, contentTextSize)
            .navigationTitle(usesPositions ? "Go to Position" : "Go to Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel).dynamicTypeSize(.large) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go", action: submit)
                        .disabled(destination == nil)
                        .accessibilityIdentifier("reader-page-entry-go")
                        .dynamicTypeSize(.large)
                }
            }
        }
        .dynamicTypeSize(.large)
        .foregroundStyle(Color.primary)
        .frame(idealWidth: 360, idealHeight: usesPositions ? 300 : 260)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { isFocused = true }
    }

    private func submit() { if let destination { onGo(destination) } }
}

enum ImagePageMotion: Equatable, Sendable {
    case left
    case right
    case up
    case down

    static func controls(for layout: ImageReaderLayout) -> (first: Self, second: Self) {
        switch layout {
        case .paged:
            (.left, .right)
        case .vertical, .webtoon, .verticalPaged:
            (.up, .down)
        }
    }

    func action(for direction: ImageReadingDirection) -> ReaderTapAction {
        switch (self, direction) {
        case (.left, .leftToRight), (.right, .rightToLeft):
            .previousPage
        case (.right, .leftToRight), (.left, .rightToLeft):
            .nextPage
        case (.up, _):
            .previousPage
        case (.down, _):
            .nextPage
        }
    }

    func isDisabled(
        for direction: ImageReadingDirection,
        isAtBeginning: Bool,
        isAtEnd: Bool
    ) -> Bool {
        switch action(for: direction) {
        case .previousPage:
            isAtBeginning
        case .nextPage:
            isAtEnd
        case .none, .scrollBackward, .scrollForward, .toggleControls:
            true
        }
    }

    var systemImage: String {
        switch self {
        case .left:
            "chevron.left"
        case .right:
            "chevron.right"
        case .up:
            "chevron.up"
        case .down:
            "chevron.down"
        }
    }
}

private extension ReaderTapAction {
    var accessibilityPageLabel: String {
        switch self {
        case .previousPage:
            "Previous page"
        case .nextPage:
            "Next page"
        case .none, .scrollBackward, .scrollForward, .toggleControls:
            ""
        }
    }
}

struct ReaderControlHitTarget: ViewModifier {
    func body(content: Content) -> some View {
        content
            .dynamicTypeSize(.large)
            .frame(
                width: ReaderDynamicTypeSizing.iconControlDimension,
                height: ReaderDynamicTypeSizing.iconControlDimension
            )
            .contentShape(Rectangle())
    }
}

extension View {
    func readerControlHitTarget() -> some View {
        modifier(ReaderControlHitTarget())
    }
}

private struct ImageReaderControlsStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background(.black.opacity(reduceTransparency ? 1 : 0.84), in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }
}
