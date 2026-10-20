import Foundation
import ImageIO
import MangoReaderDomain
import UniformTypeIdentifiers

/// Extracts a bounded baseline cover from an app-managed local publication.
/// Failures intentionally resolve to `nil` so artwork generation can never
/// prevent an otherwise valid import from reaching the library.
public actor LocalPublicationCoverService {
    private let readiumService: ReadiumPublicationService
    private let cbzService: CBZPublicationService
    private let maximumDimension: Int

    public init(
        maximumDimension: Int = 1_600,
        readiumService: ReadiumPublicationService = ReadiumPublicationService(),
        cbzService: CBZPublicationService = CBZPublicationService()
    ) {
        self.maximumDimension = max(1, maximumDimension)
        self.readiumService = readiumService
        self.cbzService = cbzService
    }

    public func coverData(at url: URL, format: PublicationFormat) async -> Data? {
        do {
            switch format {
            case .epub, .pdf:
                return try await readiumService.coverData(
                    url: url,
                    format: format,
                    maximumDimension: maximumDimension
                )

            case .cbz:
                let publication = try await cbzService.open(url: url)
                let firstPage = try await publication.pageData(at: 0)
                return Self.downsampledJPEG(
                    from: firstPage,
                    maximumDimension: maximumDimension
                )

            case .remoteImageSequence:
                return nil
            }
        } catch {
            return nil
        }
    }

    private nonisolated static func downsampledJPEG(
        from data: Data,
        maximumDimension: Int
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }
}
