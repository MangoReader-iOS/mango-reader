import Foundation
import MankoDomain
import SwiftUI

public struct LocalCBZReaderView: View {
    @Environment(\.scenePhase) private var scenePhase
    private let suppliedSettings: ImageReaderSettings?
    private let navigationRequestID: UUID?
    private let requestedLocator: ReadingLocator?
    private let navigation: ImageReaderController?
    private let liveTextEnabled: Bool
    private let controlsVisible: Binding<Bool>?
    private let onPhaseChange: (@MainActor (CBZReaderPhase) -> Void)?
    private let onRequestClose: (@MainActor () -> Void)?

    @State private var model: CBZReaderModel

    public init(
        model: CBZReaderModel,
        navigation: ImageReaderController? = nil,
        liveTextEnabled: Bool = false,
        controlsVisible: Binding<Bool>? = nil,
        onPhaseChange: (@MainActor (CBZReaderPhase) -> Void)? = nil,
        onRequestClose: (@MainActor () -> Void)? = nil
    ) {
        _model = State(initialValue: model)
        suppliedSettings = nil
        navigationRequestID = nil
        requestedLocator = nil
        self.navigation = navigation
        self.liveTextEnabled = liveTextEnabled
        self.controlsVisible = controlsVisible
        self.onPhaseChange = onPhaseChange
        self.onRequestClose = onRequestClose
    }

    public init(
        sourceURL: URL,
        settings: ImageReaderSettings = ImageReaderSettings(),
        initialLocator: ReadingLocator? = nil,
        maximumCachedPages: Int = 12,
        navigation: ImageReaderController? = nil,
        liveTextEnabled: Bool = false,
        controlsVisible: Binding<Bool>? = nil,
        service: CBZPublicationService = CBZPublicationService(),
        onPhaseChange: (@MainActor (CBZReaderPhase) -> Void)? = nil,
        onRequestClose: (@MainActor () -> Void)? = nil,
        onLocatorChange: (@MainActor (ReadingLocator) -> Void)? = nil
    ) {
        self.init(sourceURL: sourceURL, settings: settings, initialLocator: initialLocator,
            navigationRequestID: nil, maximumCachedPages: maximumCachedPages, navigation: navigation,
            liveTextEnabled: liveTextEnabled, controlsVisible: controlsVisible, service: service,
            onPhaseChange: onPhaseChange, onRequestClose: onRequestClose, onLocatorChange: onLocatorChange)
    }

    public init(
        sourceURL: URL,
        settings: ImageReaderSettings = ImageReaderSettings(),
        initialLocator: ReadingLocator? = nil,
        navigationRequestID: UUID?,
        maximumCachedPages: Int = 12,
        navigation: ImageReaderController? = nil,
        liveTextEnabled: Bool = false,
        controlsVisible: Binding<Bool>? = nil,
        service: CBZPublicationService = CBZPublicationService(),
        onPhaseChange: (@MainActor (CBZReaderPhase) -> Void)? = nil,
        onRequestClose: (@MainActor () -> Void)? = nil,
        onLocatorChange: (@MainActor (ReadingLocator) -> Void)? = nil
    ) {
        suppliedSettings = settings
        self.navigationRequestID = navigationRequestID
        requestedLocator = initialLocator
        self.navigation = navigation
        self.liveTextEnabled = liveTextEnabled
        self.controlsVisible = controlsVisible
        self.onPhaseChange = onPhaseChange
        self.onRequestClose = onRequestClose
        _model = State(
            initialValue: CBZReaderModel(
                sourceURL: sourceURL,
                settings: settings,
                initialLocator: initialLocator,
                maximumCachedPages: maximumCachedPages,
                service: service,
                onLocatorChange: onLocatorChange
            )
        )
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .idle, .loading:
                ReaderContentSkeleton()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                reader
            case let .failed(message):
                failureView(message: message)
            }
        }
        .foregroundStyle(.white)
        .background(Color.black)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = model.pageErrorMessage {
                pageErrorBanner(message: message, pageIndex: model.pageErrorPageIndex)
            }
        }
        .task {
            if let suppliedSettings, model.state.settings != suppliedSettings {
                model.updateSettings(suppliedSettings)
            }
            model.openIfNeeded()
        }
        .onChange(of: model.phase, initial: true) { _, phase in
            onPhaseChange?(phase)
        }
        .onChange(of: model.pageErrorMessage) { _, message in
            if message != nil { controlsVisible?.wrappedValue = true }
        }
        .onChange(of: suppliedSettings) { _, settings in
            guard let settings, model.state.settings != settings else { return }
            model.updateSettings(settings)
        }
        .onChange(of: navigationRequestID) { _, _ in
            if let requestedLocator { model.navigate(to: requestedLocator) }
        }
        .onDisappear { model.suspend() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.suspend() }
            if phase == .active { model.openIfNeeded() }
        }
    }

    private var reader: some View {
        ImageReaderContent(
            model: model,
            liveTextEnabled: liveTextEnabled,
            controlsVisible: controlsVisible,
            accessibilityLabel: "Comic reader",
            scrollingAccessibilityLabel: "Scrolling comic reader",
            navigation: navigation
        )
    }

    private func failureView(message: String) -> some View {
        ReaderFailureView(
            title: "Unable to Open Comic",
            systemImage: "rectangle.stack",
            message: message,
            retry: { model.retry() },
            returnToTitle: onRequestClose
        )
    }

    private func pageErrorBanner(message: String, pageIndex: Int?) -> some View {
        ReaderErrorBanner(
            message: message,
            retry: pageIndex.map { index in { model.retryPage(at: index) } },
            dismiss: { model.dismissPageError() }
        )
    }
}
