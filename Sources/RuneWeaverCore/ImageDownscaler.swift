// Rune Weaver Core — Image downscaling and optimization for vision payloads.

import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO)
    import CoreGraphics
    import ImageIO
#endif

/// High-performance native image downscaling and compression helper.
public enum ImageDownscaler: Sendable {
    /// Longest edge cap matching `BrowserScreenshotPolicy.maxDimension`.
    public static let defaultMaxDimension: Int = 1280
    /// Target byte budget matching `BrowserScreenshotPolicy.maxByteCount`.
    public static let defaultMaxBytes: Int = 500 * 1024

    /// Downscales an image payload to the target dimension and encodes it as JPEG.
    /// - Parameters:
    ///   - data: Raw image bytes (PNG, JPEG, HEIC, WebP, GIF, etc.).
    ///   - maxDimension: Maximum length of the longest edge in pixels.
    ///   - maxBytes: Upper bound for the compressed JPEG output.
    /// - Returns: Compressed JPEG data fitting the budget, or `nil` if decoding fails.
    ///   Platforms without ImageIO fail closed (`nil`) since pixel dimensions
    ///   cannot be verified there, keeping the longest-edge cap intact.
    public static func downscaleToBudget(
        data: Data,
        maxDimension: Int = defaultMaxDimension,
        maxBytes: Int = defaultMaxBytes
    ) -> Data? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }
            guard CGImageSourceGetCount(source) > 0 else {
                return nil
            }

            // Downscale with aspect ratio preserved
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                return nil
            }

            // Try encoding with decreasing quality until within maxBytes budget
            let qualities: [Float] = [0.8, 0.65, 0.5, 0.35]
            for quality in qualities {
                let outputData = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    outputData,
                    "public.jpeg" as CFString,
                    1,
                    nil
                ) else {
                    return nil
                }
                let options: [CFString: Any] = [
                    kCGImageDestinationLossyCompressionQuality: quality
                ]
                CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    continue
                }
                let result = outputData as Data
                if result.count <= maxBytes {
                    return result
                }
            }
            return nil
        #else
            // Fail closed without ImageIO: byte size alone cannot prove the
            // longest edge fits the dimension cap (a small file can still hide
            // thousands of pixels), so refuse rather than pass through
            // unverified pixels and break the 1280px/500KB contract.
            return nil
        #endif
    }

    /// Downscales image bytes and formats as a standard `data:image/jpeg;base64,...` data URL.
    /// - Parameters:
    ///   - data: Raw image data.
    ///   - maxDimension: Maximum pixel length for the longest edge.
    ///   - maxBytes: Maximum size for the compressed output.
    /// - Returns: Data URL string, or `nil` if downscaling fails or exceeds budget.
    public static func downscaledDataURL(
        for data: Data,
        maxDimension: Int = defaultMaxDimension,
        maxBytes: Int = defaultMaxBytes
    ) -> String? {
        guard let compressed = downscaleToBudget(data: data, maxDimension: maxDimension, maxBytes: maxBytes) else {
            return nil
        }
        return "data:image/jpeg;base64," + compressed.base64EncodedString()
    }
}
