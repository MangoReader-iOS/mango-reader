import CoreGraphics
import Foundation
import ImageIO
import OSLog

/// Decodes page bytes off the main actor for both archive and streamed readers.
public enum ImagePageDecoder {
    private static let maximumWidth = 2_560.0
    private static let maximumPixelCount = 16_000_000.0

    /// Reject error documents before treating a successful HTTP body as an
    /// image or persisting it. This only inspects headers, without decoding.
    @concurrent
    public static func isValidImageData(_ data: Data) async -> Bool {
        guard !Task.isCancelled, let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
    }

    @concurrent
    static func headerDimensions(_ data: Data) async -> ImagePageDimensions? {
        guard !Task.isCancelled else { return nil }
        // ImageIO waits for the first IDAT chunk before exposing PNG properties.
        // IHDR already contains the original dimensions, without any pixel data.
        let header = [UInt8](data.prefix(33))
        if header.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) {
            guard header.count == 33,
                  Array(header[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82] else { return nil }
            func dimension(at offset: Int) -> Int {
                header[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            }
            let width = dimension(at: 16), height = dimension(at: 20)
            guard width > 0, height > 0, width <= Int32.max, height <= Int32.max,
                  header[26] == 0, header[27] == 0, header[28] <= 1,
                  !Task.isCancelled else { return nil }
            return ImagePageDimensions(width: width, height: height)
        }
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, !Task.isCancelled else { return nil }
        return ImagePageDimensions(width: width, height: height)
    }

    @concurrent
    static func progressivePreview(_ data: Data) async -> DecodedImagePage? {
        guard !Task.isCancelled else { return nil }
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let jfif = properties[kCGImagePropertyJFIFDictionary] as? [CFString: Any],
              jfif[kCGImagePropertyJFIFIsProgressive] as? Bool == true,
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: min(1_024, max(width, height)),
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary), !Task.isCancelled else { return nil }
        return .init(image: image, width: width, height: height, detectedCropInsets: nil)
    }

    @concurrent
    static func cachedPreviewData(_ decoded: DecodedImagePage) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let scale = min(1, 512 / Double(decoded.image.width), sqrt(1_000_000 / Double(decoded.image.width * decoded.image.height)))
        let width = max(1, Int(Double(decoded.image.width) * scale)), height = max(1, Int(Double(decoded.image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(decoded.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return try? JSONEncoder().encode(CachedImagePagePreview(data: bytes as Data, width: decoded.width,
            height: decoded.height, crop: decoded.detectedCropInsets))
    }

    @concurrent
    static func decodeCachedPreview(_ data: Data) async -> DecodedImagePage? {
        guard let value = try? JSONDecoder().decode(CachedImagePagePreview.self, from: data),
              let source = CGImageSourceCreateWithData(value.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), !Task.isCancelled else { return nil }
        return .init(image: image, width: value.width, height: value.height, detectedCropInsets: value.crop)
    }

    @concurrent
    static func decode(_ data: Data, id: String, downsample: Bool = true) async throws -> DecodedImagePage {
        try Task.checkCancellation()
        let log = OSLog(subsystem: "com.k800k.manko", category: "ReaderPerformance")
        let signpost = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Image Decode", signpostID: signpost)
        defer { os_signpost(.end, log: log, name: "Image Decode", signpostID: signpost) }
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { throw ReaderError.imageDecodeFailed(id) }
        let scale = min(1, (downsample ? maximumWidth : Double(width)) / Double(width),
            sqrt(maximumPixelCount / (Double(width) * Double(height))))
        let image: CGImage?
        if scale < 1 {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, Int(Double(max(width, height)) * scale)),
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            )
        }
        guard let image else { throw ReaderError.imageDecodeFailed(id) }
        try Task.checkCancellation()
        return DecodedImagePage(
            image: image,
            width: width,
            height: height,
            detectedCropInsets: ImageAutomaticCropDetector.detect(in: image)
        )
    }

}

private struct CachedImagePagePreview: Codable {
    let data: Data
    let width: Int
    let height: Int
    let crop: NormalizedPageInsets?
}

struct ImagePageDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
}

struct DecodedImagePage: @unchecked Sendable {
    let image: CGImage
    let width: Int
    let height: Int
    let detectedCropInsets: NormalizedPageInsets?
}

private enum ImageAutomaticCropDetector {
    private struct Pixel {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int
    }

    static func detect(in image: CGImage) -> NormalizedPageInsets? {
        let longestSide = max(image.width, image.height)
        guard longestSide > 0 else { return nil }

        let sampleScale = min(1, 160 / Double(longestSide))
        let width = max(1, Int((Double(image.width) * sampleScale).rounded()))
        let height = max(1, Int((Double(image.height) * sampleScale).rounded()))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue

        let didDraw = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }

        func pixel(x: Int, y: Int) -> Pixel {
            let offset = y * bytesPerRow + x * 4
            return Pixel(
                red: Int(pixels[offset]),
                green: Int(pixels[offset + 1]),
                blue: Int(pixels[offset + 2]),
                alpha: Int(pixels[offset + 3])
            )
        }

        func average(_ samples: [Pixel]) -> Pixel {
            let count = max(1, samples.count)
            return Pixel(
                red: samples.reduce(0) { $0 + $1.red } / count,
                green: samples.reduce(0) { $0 + $1.green } / count,
                blue: samples.reduce(0) { $0 + $1.blue } / count,
                alpha: samples.reduce(0) { $0 + $1.alpha } / count
            )
        }

        let cornerDepth = min(3, max(1, min(width, height) / 12))
        func cornerSamples(xRange: Range<Int>, yRange: Range<Int>) -> [Pixel] {
            yRange.flatMap { y in xRange.map { x in pixel(x: x, y: y) } }
        }
        let leadingRange = 0..<cornerDepth
        let trailingRange = max(0, width - cornerDepth)..<width
        let topRange = 0..<cornerDepth
        let bottomRange = max(0, height - cornerDepth)..<height
        let topReference = average(
            cornerSamples(xRange: leadingRange, yRange: topRange)
                + cornerSamples(xRange: trailingRange, yRange: topRange)
        )
        let bottomReference = average(
            cornerSamples(xRange: leadingRange, yRange: bottomRange)
                + cornerSamples(xRange: trailingRange, yRange: bottomRange)
        )
        let leadingReference = average(
            cornerSamples(xRange: leadingRange, yRange: topRange)
                + cornerSamples(xRange: leadingRange, yRange: bottomRange)
        )
        let trailingReference = average(
            cornerSamples(xRange: trailingRange, yRange: topRange)
                + cornerSamples(xRange: trailingRange, yRange: bottomRange)
        )

        func matches(_ candidate: Pixel, _ reference: Pixel) -> Bool {
            if reference.alpha < 32 {
                return candidate.alpha < 48
            }
            let red = candidate.red - reference.red
            let green = candidate.green - reference.green
            let blue = candidate.blue - reference.blue
            return red * red + green * green + blue * blue <= 24 * 24 * 3
                && abs(candidate.alpha - reference.alpha) <= 24
        }

        func rowMatches(_ y: Int, reference: Pixel) -> Bool {
            let matching = (0..<width).reduce(into: 0) { count, x in
                if matches(pixel(x: x, y: y), reference) { count += 1 }
            }
            return Double(matching) / Double(width) >= 0.97
        }

        func columnMatches(_ x: Int, reference: Pixel) -> Bool {
            let matching = (0..<height).reduce(into: 0) { count, y in
                if matches(pixel(x: x, y: y), reference) { count += 1 }
            }
            return Double(matching) / Double(height) >= 0.97
        }

        let maximumTopBottom = max(0, Int(Double(height) * 0.12))
        let maximumLeadingTrailing = max(0, Int(Double(width) * 0.12))
        var top = 0
        while top < maximumTopBottom, rowMatches(top, reference: topReference) { top += 1 }
        var bottom = 0
        while bottom < maximumTopBottom,
              rowMatches(height - bottom - 1, reference: bottomReference)
        {
            bottom += 1
        }
        var leading = 0
        while leading < maximumLeadingTrailing,
              columnMatches(leading, reference: leadingReference)
        {
            leading += 1
        }
        var trailing = 0
        while trailing < maximumLeadingTrailing,
              columnMatches(width - trailing - 1, reference: trailingReference)
        {
            trailing += 1
        }

        func normalized(_ pixels: Int, dimension: Int) -> Double {
            let fraction = Double(pixels) / Double(max(1, dimension))
            return fraction >= 0.005 ? fraction : 0
        }
        let insets = NormalizedPageInsets(
            top: normalized(top, dimension: height),
            leading: normalized(leading, dimension: width),
            bottom: normalized(bottom, dimension: height),
            trailing: normalized(trailing, dimension: width)
        )
        return insets.isZero ? nil : insets
    }
}
