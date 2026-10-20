import MangoReaderDomain
import MangoReaderReaders
import MangoReaderSources
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum RemoteCoverStyle {
    case standard
    case miniPlayer

    var cornerRadius: CGFloat {
        switch self {
        case .standard: 12
        case .miniPlayer: 4
        }
    }

    var shadow: (color: Color, radius: CGFloat, y: CGFloat) {
        switch self {
        case .standard: (.black.opacity(0.12), 7, 4)
        case .miniPlayer: (.clear, 0, 0)
        }
    }
}

struct RemoteCover: View {
    @Environment(AppModel.self) private var model
    let work: Work
    var style: RemoteCoverStyle = .standard
    var animatesLoadingPlaceholder = true

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                Group {
                    if let customCoverURL = model.libraryModel.customCoverURL(for: work) {
                        ManagedCoverImage(work: work, url: customCoverURL, animatesLoadingPlaceholder: animatesLoadingPlaceholder)
                    } else if let generatedCoverURL = work.coverURL,
                              generatedCoverURL.isFileURL,
                              model.sourcesModel.sources.first(where: { $0.id == work.sourceID })?.kind == .local
                    {
                        ManagedCoverImage(work: work, url: generatedCoverURL, animatesLoadingPlaceholder: animatesLoadingPlaceholder)
                    } else if model.sourcesModel.isExtensionBacked(work) {
                        ExtensionBrokeredCoverImage(work: work, animatesLoadingPlaceholder: animatesLoadingPlaceholder)
                    } else {
                        PublicationRemoteImage(url: work.coverURL,
                            cacheScope: model.sourcesModel.contentCacheScope(work.sourceID),
                            persists: model.sourcesModel.usesPersistentContentCache) { phase in
                            switch phase {
                            case .loading:
                                RemoteCoverLoadingPlaceholder(animates: animatesLoadingPlaceholder)
                            case .unavailable:
                                CoverPlaceholder(work: work)
                            }
                        }
                    }
                }
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
            .shadow(
                color: style.shadow.color,
                radius: style.shadow.radius,
                y: style.shadow.y
            )
            .accessibilityHidden(true)
    }
}

enum RemoteCoverLoadingPolicy {
    static func shouldShimmer(
        hasURL: Bool,
        hasImage: Bool,
        didFail: Bool
    ) -> Bool {
        hasURL && !hasImage && !didFail
    }
}

private struct RemoteCoverLoadingPlaceholder: View {
    var animates = true

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .systemGray5))
            .overlay {
                Rectangle()
                    .fill(.primary.opacity(0.08))
                    .loadingShimmer(active: animates)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct ExtensionBrokeredCoverImage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let work: Work
    var animatesLoadingPlaceholder = true
    @State private var image: CGImage?
    @State private var preview: CGImage?
    @State private var imageIdentity: ExtensionCoverLoadIdentity?
    @State private var didFail = false
    @State private var requestGate = LatestOperationGate()

    private var loadIdentity: ExtensionCoverLoadIdentity {
        ExtensionCoverLoadIdentity(
            sourceID: work.sourceID, coverURL: work.coverURL,
            revision: model.sourcesModel.contentRevisions[work.sourceID, default: 0],
            workID: work.id, previewURL: work.coverPreviewURL
        )
    }

    private var retainsArtwork: Bool { loadIdentity.canRetainImage(from: imageIdentity) }

    var body: some View {
        let fullImage = (retainsArtwork ? image : nil) ?? model.sourcesModel.coverImageCache.cachedImage(
            for: model.sourcesModel.coverCacheKey(for: work)
        )
        let previewImage = retainsArtwork ? preview : nil
        ZStack {
            if let previewImage {
                Image(decorative: previewImage, scale: 1).resizable()
            }
            if let fullImage {
                Image(decorative: fullImage, scale: 1)
                    .resizable()
                    .transition(.opacity)
                    .sourcePerformanceMarker(work.remoteID ?? work.id.description)
            } else if previewImage == nil {
                if RemoteCoverLoadingPolicy.shouldShimmer(hasURL: work.coverURL != nil, hasImage: false, didFail: didFail) {
                    RemoteCoverLoadingPlaceholder(animates: animatesLoadingPlaceholder)
                } else {
                    CoverPlaceholder(work: work)
                }
            }
        }
        .task(id: loadIdentity) {
            let identity = loadIdentity
            let generation = requestGate.begin()
            if !identity.canRetainImage(from: imageIdentity) { image = nil; preview = nil }
            didFail = false
            guard work.coverURL != nil else { didFail = true; return }
            do {
                let loaded = try await model.sourcesModel.catalogCoverImage(for: work) { loadedPreview in
                    guard requestGate.accepts(generation), !Task.isCancelled, image == nil else { return }
                    preview = loadedPreview
                    imageIdentity = identity
                }
                try Task.checkCancellation()
                guard requestGate.accepts(generation) else { return }
                withAnimation(preview != nil && !reduceMotion ? .easeInOut(duration: 0.2) : nil) {
                    image = loaded
                    imageIdentity = identity
                }
            } catch is CancellationError {
                return
            } catch {
                guard requestGate.accepts(generation) else { return }
                _ = model.sourcesModel.handleCloudflareHandoff(error)
                didFail = true
            }
        }
        .onDisappear { requestGate.invalidate() }
    }
}

struct ExtensionCoverLoadIdentity: Hashable {
    var sourceID: SourceID
    var coverURL: URL?
    var revision: Int = 0
    var workID: WorkID? = nil
    var previewURL: URL? = nil

    func canRetainImage(from previous: Self?) -> Bool {
        guard let previous, coverURL != nil else { return false }
        return sourceID == previous.sourceID && workID == previous.workID
    }
}

extension SourcesModel {
    func catalogCoverImage(
        for work: Work,
        previewOnly: Bool = false,
        onPreview: (CGImage) -> Void = { _ in }
    ) async throws -> CGImage {
        try await coverImageCache.progressiveImage(
            for: coverCacheKey(for: work),
            previewKey: work.coverPreviewURL.map { coverCacheKey(for: work, url: $0) },
            previewOnly: previewOnly,
            previewLoader: { try await self.extensionCoverImageData(for: work, at: work.coverPreviewURL) },
            loader: { try await self.extensionCoverImageData(for: work) },
            onPreview: onPreview
        )
    }
}

enum CoverImageDecoder {
    nonisolated static let maximumPixelDimension = 768

    // ImageIO's AVIF decoder can wait synchronously for its own workers.
    // Keep those waits off Swift's cooperative executor so catalog requests
    // and cancellation can still run while covers are being decoded.
    nonisolated private static let decodingQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Mango Reader cover decoding"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    nonisolated private static func enqueueDecode(
        _ decode: @escaping @Sendable () -> CGImage?
    ) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            decodingQueue.addOperation {
                continuation.resume(returning: decode())
            }
        }
    }

    nonisolated static func decode(
        _ data: Data,
        maximumPixelDimension: Int = CoverImageDecoder.maximumPixelDimension
    ) async -> CGImage? {
        await enqueueDecode {
            guard maximumPixelDimension > 0,
                  let source = CGImageSourceCreateWithData(
                      data as CFData,
                      [kCGImageSourceShouldCache: false] as CFDictionary
                  )
            else { return nil }
            return thumbnail(
                from: source,
                maximumPixelDimension: maximumPixelDimension
            )
        }
    }

    nonisolated static func decode(
        contentsOf url: URL,
        maximumPixelDimension: Int = CoverImageDecoder.maximumPixelDimension
    ) async -> CGImage? {
        await enqueueDecode {
            guard maximumPixelDimension > 0,
                  url.isFileURL,
                  let source = CGImageSourceCreateWithURL(
                      url as CFURL,
                      [kCGImageSourceShouldCache: false] as CFDictionary
                  )
            else { return nil }
            return thumbnail(
                from: source,
                maximumPixelDimension: maximumPixelDimension
            )
        }
    }

    nonisolated static func decodedCost(of image: CGImage) -> Int {
        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(
            by: image.height
        )
        return overflow ? Int.max : cost
    }

    nonisolated private static func thumbnail(
        from source: CGImageSource,
        maximumPixelDimension: Int
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        )
    }
}

@MainActor
final class ExtensionCoverImageCache {
    static let shared = ExtensionCoverImageCache()

    private struct LoadedCover {
        let image: CGImage
        let data: Data
    }

    private struct InFlightLoad {
        var id: UUID
        var task: Task<LoadedCover, Error>
        var waiters: [UUID: CheckedContinuation<CGImage, Error>]
    }

    private let cache = NSCache<NSString, CGImage>()
    private var inFlight: [String: InFlightLoad] = [:]
    private var compressed: [String: Data] = [:]
    private var compressedOrder: [String] = []
    private var compressedBytes = 0
    private let compressedLimit = 64 * 1_024 * 1_024

    func invalidate(sourceID: SourceID) {
        let prefix = "\(sourceID.rawValue)|"
        cache.removeAllObjects()
        for key in compressedOrder where key.hasPrefix(prefix) {
            compressedBytes -= compressed.removeValue(forKey: key)?.count ?? 0
        }
        compressedOrder.removeAll { $0.hasPrefix(prefix) }
        for key in Array(inFlight.keys) where key.hasPrefix(prefix) {
            guard let load = inFlight.removeValue(forKey: key) else { continue }
            load.task.cancel()
            for waiter in load.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
    }

    func removeDecodedImages() { cache.removeAllObjects() }

    func clear() {
        cache.removeAllObjects(); compressed.removeAll(); compressedOrder.removeAll(); compressedBytes = 0
        let loads = inFlight.values; inFlight.removeAll()
        for load in loads {
            load.task.cancel()
            for waiter in load.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
    }

    private func remember(_ data: Data, for key: String) {
        guard data.count <= compressedLimit else { return }
        compressedBytes -= compressed[key]?.count ?? 0
        compressed[key] = data
        compressedBytes += data.count
        compressedOrder.removeAll { $0 == key }
        compressedOrder.append(key)
        while compressedBytes > compressedLimit {
            compressedBytes -= compressed.removeValue(forKey: compressedOrder.removeFirst())?.count ?? 0
        }
    }

    init(countLimit: Int = 80, totalCostLimit: Int = 32 * 1_024 * 1_024) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    func cachedImage(
        for key: String,
        maximumPixelDimension: Int = CoverImageDecoder.maximumPixelDimension
    ) -> CGImage? {
        cache.object(forKey: "\(key)|pixels:\(maximumPixelDimension)" as NSString)
    }

    func storeImage(_ image: CGImage, for key: String) {
        cache.setObject(
            image,
            forKey: "\(key)|pixels:\(CoverImageDecoder.maximumPixelDimension)" as NSString,
            cost: CoverImageDecoder.decodedCost(of: image)
        )
    }

    // Previews and final artwork have distinct URL keys, but all consumers share
    // the existing cancellation-aware loads and source-scoped cache invalidation.
    func progressiveImage(
        for key: String,
        previewKey: String?,
        previewOnly: Bool = false,
        previewLoader: @escaping @MainActor () async throws -> Data?,
        loader: @escaping @MainActor () async throws -> Data?,
        onPreview: (CGImage) -> Void = { _ in }
    ) async throws -> CGImage {
        if cachedImage(for: key) != nil || compressed[key] != nil {
            return try await image(for: key, loader: loader)
        }
        if let previewKey, previewKey != key {
            do {
                let preview = try await image(for: previewKey, loader: previewLoader)
                try Task.checkCancellation()
                onPreview(preview)
                if previewOnly { return preview }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Missing or unsupported previews must not prevent full artwork.
            }
        }
        try Task.checkCancellation()
        return try await image(for: key, loader: loader)
    }

    func image(
        for key: String,
        maximumPixelDimension: Int = CoverImageDecoder.maximumPixelDimension,
        loader: @escaping @MainActor () async throws -> Data?
    ) async throws -> CGImage {
        let cacheKey = "\(key)|pixels:\(maximumPixelDimension)"
        if let cached = cache.object(forKey: cacheKey as NSString) { return cached }
        try Task.checkCancellation()

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if var existing = inFlight[cacheKey] {
                    existing.waiters[waiterID] = continuation
                    inFlight[cacheKey] = existing
                    return
                }

                let loadID = UUID()
                let cachedData = compressed[key]
                let task = Task { @MainActor in
                    let loaded: Data
                    if let cachedData {
                        loaded = cachedData
                    } else {
                        guard let data = try await loader() else { throw SourceError.notFound }
                        loaded = data
                    }
                    try Task.checkCancellation()
                    guard let decoded = await CoverImageDecoder.decode(
                        loaded,
                        maximumPixelDimension: maximumPixelDimension
                    ) else { throw SourceError.unsupportedResponse }
                    try Task.checkCancellation()
                    return LoadedCover(image: decoded, data: loaded)
                }
                inFlight[cacheKey] = InFlightLoad(
                    id: loadID,
                    task: task,
                    waiters: [waiterID: continuation]
                )
                Task { @MainActor [weak self] in
                    self?.complete(
                        await task.result,
                        for: cacheKey,
                        dataKey: key,
                        loadID: loadID
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID, for: cacheKey)
            }
        }
    }

    private func cancelWaiter(_ waiterID: UUID, for key: String) {
        guard var load = inFlight[key], let continuation = load.waiters.removeValue(forKey: waiterID) else {
            return
        }
        if load.waiters.isEmpty {
            inFlight[key] = nil
            load.task.cancel()
        } else {
            inFlight[key] = load
        }
        continuation.resume(throwing: CancellationError())
    }

    private func complete(
        _ result: Result<LoadedCover, Error>,
        for key: String,
        dataKey: String,
        loadID: UUID
    ) {
        guard let load = inFlight[key], load.id == loadID else { return }
        if case let .success(loaded) = result {
            cache.setObject(
                loaded.image,
                forKey: key as NSString,
                cost: CoverImageDecoder.decodedCost(of: loaded.image)
            )
            remember(loaded.data, for: dataKey)
        }
        inFlight[key] = nil
        for continuation in load.waiters.values {
            continuation.resume(with: result.map(\.image))
        }
    }
}

private struct ManagedCoverImage: View {
    @Environment(AppModel.self) private var model
    let work: Work
    let url: URL
    var animatesLoadingPlaceholder = true
    private var cacheKey: String { "local|\(url.absoluteString)" }
    @State private var image: CGImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image = image ?? model.sourcesModel.coverImageCache.cachedImage(for: cacheKey) {
                Image(decorative: image, scale: 1)
                    .resizable()
            } else if RemoteCoverLoadingPolicy.shouldShimmer(
                hasURL: url.isFileURL,
                hasImage: image != nil,
                didFail: didFail
            ) {
                RemoteCoverLoadingPlaceholder(animates: animatesLoadingPlaceholder)
            } else {
                CoverPlaceholder(work: work)
            }
        }
        .task(id: url) {
            image = model.sourcesModel.coverImageCache.cachedImage(for: cacheKey)
            didFail = false
            guard image == nil else { return }
            guard url.isFileURL else {
                didFail = true
                return
            }
            let loaded = await CoverImageDecoder.decode(contentsOf: url)
            guard !Task.isCancelled else { return }
            if let loaded {
                model.sourcesModel.coverImageCache.storeImage(loaded, for: cacheKey)
            }
            image = loaded
            didFail = loaded == nil
        }
    }
}

#if DEBUG
struct CoverPlaceholderVerificationView: View {
    @State private var reduceMotion = false

    init(reduceMotion: Bool = false) {
        _reduceMotion = State(initialValue: reduceMotion)
    }

    private static let book = Work(
        sourceID: "cover-verification",
        title: "The Quiet Atlas",
        authors: ["Placeholder Author"],
        kind: .book
    )
    private static let longTitle = Work(
        sourceID: "cover-verification",
        title: "A Very Long Journey Through the Forgotten Libraries of the World",
        authors: ["Alex Morgan", "Sam Rivera"],
        kind: .lightNovel
    )
    private static let untitled = Work(
        sourceID: "cover-verification",
        title: "   ",
        authors: [" "],
        kind: .manga
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("Reduce Motion", isOn: $reduceMotion)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 18) {
                    sample("Loading", work: Self.book, loading: true)
                    sample("Missing", work: Self.book)
                    sample("Failed", work: Self.book)
                    sample("Loaded", work: Self.book, loaded: true)
                    sample("Long title", work: Self.longTitle)
                    sample("No title or author", work: Self.untitled)
                }
                Text("Row, detail, and mini-player sizes").font(.headline)
                HStack(alignment: .top, spacing: 16) {
                    cover(Self.longTitle).frame(width: 60, height: 90)
                    cover(Self.book).frame(width: 112, height: 168)
                    cover(Self.book, style: .miniPlayer).frame(width: 28, height: 42)
                    cover(Self.book, loading: true, animates: false, style: .miniPlayer)
                        .frame(width: 28, height: 42)
                }
                Text("Library loading stays static").font(.headline)
                cover(Self.book, loading: true, animates: false).frame(width: 112, height: 168)
            }
            .frame(maxWidth: 510)
            .padding(.vertical)
            .frame(maxWidth: .infinity)
        }
    }

    private func sample(_ label: String, work: Work, loading: Bool = false, loaded: Bool = false) -> some View {
        VStack(spacing: 8) {
            cover(work, loading: loading, loaded: loaded)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func cover(
        _ work: Work,
        loading: Bool = false,
        animates: Bool = true,
        loaded: Bool = false,
        style: RemoteCoverStyle = .standard
    ) -> some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                if loading {
                    RemoteCoverLoadingPlaceholder(animates: animates && !reduceMotion)
                } else if loaded {
                    Image("MangoReaderStartupArtwork").resizable().scaledToFill()
                } else {
                    CoverPlaceholder(work: work)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
            .shadow(color: style.shadow.color, radius: style.shadow.radius, y: style.shadow.y)
    }
}

#Preview("Cover placeholders - light") {
    CoverPlaceholderVerificationView().padding().preferredColorScheme(.light)
}

#Preview("Cover placeholders - dark") {
    CoverPlaceholderVerificationView().padding().preferredColorScheme(.dark)
}

#Preview("Cover placeholders - reduced motion and large text") {
    CoverPlaceholderVerificationView(reduceMotion: true).padding().preferredColorScheme(.dark)
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
