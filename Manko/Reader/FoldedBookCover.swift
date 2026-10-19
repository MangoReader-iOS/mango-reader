import MankoDomain
import MankoReaders
import MankoSources
import SwiftUI
import UIKit

enum FoldedBookCoverPreferences {
    nonisolated static let enabledKey = "readerShowCoverWhenFolded"
    nonisolated static let pauseSpeechKey = "readerPauseReadAloudWhenFolded"
}

/// Initial attachment to an already-closed device is not a close gesture.
/// Dismissal lasts for the current closed interval, without persisting book history.
struct FoldedBookCoverState {
    enum Posture { case open, closed }
    private(set) var posture: Posture?
    private(set) var isPresented = false

    mutating func observe(_ posture: Posture?, enabled: Bool, canPresent: Bool) {
        let didClose = self.posture == .open && posture == .closed
        self.posture = posture
        if posture != .closed || !enabled || !canPresent {
            isPresented = false
        } else if didClose {
            isPresented = true
        }
    }

    mutating func dismiss() { isPresented = false }

    func countsReadingTime(sceneIsActive: Bool, sessionStarted: Bool, speech: PublicationTTSState) -> Bool {
        sceneIsActive && sessionStarted && (!isPresented || speech == .speaking)
    }

    func shouldPauseSpeech(preference: Bool, speech: PublicationTTSState) -> Bool {
        isPresented && preference && speech == .speaking
    }
}

extension View {
    func observeBookCoverHinge(_ action: @escaping (FoldedBookCoverState.Posture?) -> Void) -> some View {
        background {
            #if !targetEnvironment(macCatalyst)
            if #available(iOS 27.1, *) {
                BookCoverHingeObserver(action: action)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            #endif
        }
    }
}

#if !targetEnvironment(macCatalyst)
@available(iOS 27.1, *)
private struct BookCoverHingeObserver: UIViewRepresentable {
    let action: (FoldedBookCoverState.Posture?) -> Void

    func makeUIView(context: Context) -> HingeView { HingeView(action: action) }
    func updateUIView(_ view: HingeView, context: Context) { view.action = action }

    final class HingeView: UIView {
        var action: (FoldedBookCoverState.Posture?) -> Void

        init(action: @escaping (FoldedBookCoverState.Posture?) -> Void) {
            self.action = action
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            addInteraction(UIHingeInteraction { [weak self] _, update in
                let posture: FoldedBookCoverState.Posture?
                switch update.hinge?.status {
                case .closed: posture = .closed
                case .partiallyOpen, .fullyOpen: posture = .open
                default: posture = nil
                }
                // Hierarchy attachment can happen during a SwiftUI update.
                Task { @MainActor [weak self] in self?.action(posture) }
            })
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
#endif

struct FoldedBookCoverSettingsSection: View {
    @AppStorage(FoldedBookCoverPreferences.enabledKey) private var enabled = false
    @AppStorage(FoldedBookCoverPreferences.pauseSpeechKey) private var pauseSpeech = false

    var body: some View {
        Section {
            Toggle("Show Cover When Folded", isOn: $enabled)
                .accessibilityIdentifier("settings-folded-book-cover")
            if enabled {
                Toggle("Pause Read Aloud When Folded", isOn: $pauseSpeech)
                    .accessibilityIdentifier("settings-folded-book-cover-pause-speech")
            }
        } header: {
            Text("iPhone Duo")
        } footer: {
            Text("Fold shut while reading to show the book cover. Tap the cover or unfold to return to your pages.")
        }
        .appFullWidthListSeparator()
    }
}

struct FoldedBookCoverView<Artwork: View>: View {
    let title: String
    let speech: PublicationTTSState
    let read: () -> Void
    let close: () -> Void
    let toggleSpeech: () -> Void
    @ViewBuilder let artwork: Artwork
    @AccessibilityFocusState private var coverIsFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .appIconControlFrame(dimension: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Book")
                .accessibilityIdentifier("reader-folded-cover-close")
            }

            Button(action: read) {
                artwork
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Read \(title)"))
            .accessibilityHint("Return to your pages on this screen.")
            .accessibilityIdentifier("reader-folded-cover-read")
            .accessibilityFocused($coverIsFocused)

            Text("Tap to read or unfold")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if speech != .idle {
                Button(action: toggleSpeech) {
                    Label(speech == .speaking ? "Pause" : "Play",
                          systemImage: speech == .speaking ? "pause.fill" : "play.fill")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(speech == .speaking ? "Pause Read Aloud" : "Resume Read Aloud")
                .accessibilityIdentifier("reader-folded-cover-speech")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.background.ignoresSafeArea())
        .accessibilityIdentifier("reader-folded-cover")
        .onAppear { coverIsFocused = true }
    }
}

/// Uses the same managed/brokered cover cache and disposable remote-data cache
/// as Library covers, but preserves the artwork's own aspect ratio.
struct FoldedBookCoverArtwork: View {
    @Environment(AppModel.self) private var model
    let work: Work
    @State private var image: CGImage?

    private var localURL: URL? {
        model.libraryModel.customCoverURL(for: work)
            ?? work.coverURL.flatMap { $0.isFileURL ? $0 : nil }
    }
    private var cacheKey: String {
        localURL.map { "local|\($0.absoluteString)" } ?? model.sourcesModel.coverCacheKey(for: work)
    }

    var body: some View {
        Group {
            if let image = image ?? model.sourcesModel.coverImageCache.cachedImage(for: cacheKey) {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                CoverPlaceholder(work: work).aspectRatio(2 / 3, contentMode: .fit)
            }
        }
        .task(id: cacheKey) {
            image = nil
            let key = cacheKey
            if let cached = model.sourcesModel.coverImageCache.cachedImage(for: key) {
                image = cached
                return
            }
            if let url = localURL {
                let decoded = await CoverImageDecoder.decode(contentsOf: url)
                guard !Task.isCancelled else { return }
                if let decoded { model.sourcesModel.coverImageCache.storeImage(decoded, for: key) }
                image = decoded
                return
            }
            do {
                let decoded = try await model.sourcesModel.coverImageCache.image(for: key) {
                    if model.sourcesModel.isExtensionBacked(work) {
                        return try await model.sourcesModel.extensionCoverImageData(for: work)
                    }
                    guard let url = work.coverURL else { return nil }
                    let dataKey = ContentCache.key([model.sourcesModel.contentCacheScope(work.sourceID), "artwork", url.absoluteString])
                    let persists = model.sourcesModel.usesPersistentContentCache
                    if persists, let cached = await model.sourcesModel.contentCache.entry(for: dataKey) { return cached.data }
                    let token = await model.sourcesModel.contentCache.writeToken()
                    let data = try await LibraryModel.readShareCoverData(from: url)
                    guard await ImagePageDecoder.isValidImageData(data) else { throw URLError(.cannotDecodeContentData) }
                    if persists { await model.sourcesModel.contentCache.store(data, for: dataKey, token: token) }
                    return data
                }
                guard !Task.isCancelled else { return }
                image = decoded
            } catch is CancellationError {
                return
            } catch {
                _ = model.sourcesModel.handleCloudflareHandoff(error)
            }
        }
    }
}
