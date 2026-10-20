import Foundation
import MangoReaderDomain
import SwiftUI

public struct RemoteImageReaderView: View {
    @Environment(\.scenePhase) private var scenePhase
    private let suppliedSettings: ImageReaderSettings?
    private let navigationRequestID: UUID?
    private let requestedLocator: ReadingLocator?
    private let navigation: ImageReaderController?
    private let liveTextEnabled: Bool
    private let controlsVisible: Binding<Bool>?
    private let onPhaseChange: (@MainActor (RemoteImageReaderPhase) -> Void)?
    private let onRequestClose: (@MainActor () -> Void)?

    @State private var model: RemoteImageReaderModel

    public init(
        model: RemoteImageReaderModel,
        navigation: ImageReaderController? = nil,
        liveTextEnabled: Bool = false,
        controlsVisible: Binding<Bool>? = nil,
        onPhaseChange: (@MainActor (RemoteImageReaderPhase) -> Void)? = nil,
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
        publication: RemoteImagePublication,
        settings: ImageReaderSettings = ImageReaderSettings(),
        initialLocator: ReadingLocator? = nil,
        navigationRequestID: UUID? = nil,
        maximumCachedPages: Int = 12,
        navigation: ImageReaderController? = nil,
        liveTextEnabled: Bool = false,
        controlsVisible: Binding<Bool>? = nil,
        onPhaseChange: (@MainActor (RemoteImageReaderPhase) -> Void)? = nil,
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
            initialValue: RemoteImageReaderModel(
                publication: publication,
                settings: settings,
                initialLocator: initialLocator,
                maximumCachedPages: maximumCachedPages,
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
                pageErrorBanner(message: message)
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
        .onDisappear {
            model.suspend()
        }
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
            accessibilityLabel: "Streamed comic reader",
            scrollingAccessibilityLabel: "Scrolling streamed comic reader",
            navigation: navigation
        )
    }

    private func failureView(message: String) -> some View {
        ReaderFailureView(
            title: "Unable to Open Streamed Chapter",
            systemImage: "network.slash",
            message: message,
            retry: { model.retry() },
            returnToTitle: onRequestClose
        )
    }

    private func pageErrorBanner(message: String) -> some View {
        ReaderErrorBanner(
            message: message,
            retry: { model.retryPageWindow() },
            dismiss: { model.dismissPageError() }
        )
    }
}
