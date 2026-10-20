import Nuke
import NukeUI
import MangoReaderSources
import SwiftUI

public enum PublicationImageCache {
    public static func clearMemory() { ImageCache.shared.removeAll() }
#if DEBUG
    @_spi(Testing) @MainActor public static var fixtureClient: HTTPClient?
#endif
}

public enum PublicationImagePlaceholderPhase {
    case loading
    case unavailable
}

/// The shared remote-image surface used for covers and other streamed artwork.
/// Nuke bounds decoded images; originals share the app's disposable disk budget.
public struct PublicationRemoteImage<Placeholder: View>: View {
    private let request: ImageRequest?
    private let placeholder: Placeholder
    private var unavailable: Placeholder?

    /// Supplies distinct loading and missing/failed states without placing a
    /// fallback behind successfully loaded artwork.
    public init(
        url: URL?,
        cacheScope: String = "public-artwork",
        persists: Bool = true,
        networkPolicy: ExtensionNetworkPolicy? = nil,
        @ViewBuilder placeholder: (PublicationImagePlaceholderPhase) -> Placeholder
    ) {
        self.init(url: url, cacheScope: cacheScope, persists: persists, networkPolicy: networkPolicy) {
            placeholder(.loading)
        }
        unavailable = placeholder(.unavailable)
    }

    public init(
        url: URL?,
        cacheScope: String = "public-artwork",
        persists: Bool = true,
        networkPolicy: ExtensionNetworkPolicy? = nil,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        if let url {
            var client = HTTPClient()
            var persists = persists
#if DEBUG
            if let fixtureClient = PublicationImageCache.fixtureClient {
                client = fixtureClient
                persists = false
            }
#endif
            let imageClient = client
            let storesImage = persists
            let key = ContentCache.key([cacheScope, "artwork", url.absoluteString])
            var request = ImageRequest(id: key, data: {
                try networkPolicy?.validate(url)
                if url.isFileURL { return try Data(contentsOf: url, options: .mappedIfSafe) }
                if storesImage, let cached = await ContentCache.shared.entry(for: key) { return cached.data }
                let token = await ContentCache.shared.writeToken()
                let response = try await imageClient.response(for: HTTPRequest(url: url,
                    usesConditionalCache: false, networkPolicy: networkPolicy,
                    maximumResponseBytes: 16 * 1_024 * 1_024))
                let data = response.data
                guard await ImagePageDecoder.isValidImageData(data) else { throw URLError(.cannotDecodeContentData) }
                if storesImage { await ContentCache.shared.store(data, for: key, mediaType: response.header("Content-Type"), token: token) }
                return data
            })
            request.thumbnail = ImageRequest.ThumbnailOptions(
                size: CGSize(width: 512, height: 768),
                unit: .pixels,
                contentMode: .aspectFit
            )
            self.request = request
        } else {
            request = nil
        }
        self.placeholder = placeholder()
    }

    @ViewBuilder
    public var body: some View {
        if let request {
            LazyImage(request: request) { state in
                if let image = state.image {
                    image.resizable()
                } else if state.error != nil {
                    if let unavailable { unavailable } else { Color.clear }
                } else {
                    placeholder
                }
            }
            .pipeline(ImagePipeline.shared)
        } else {
            if let unavailable { unavailable } else { Color.clear }
        }
    }
}

public extension PublicationRemoteImage where Placeholder == EmptyView {
    init(url: URL?) {
        self.init(url: url) {
            EmptyView()
        }
    }
}
