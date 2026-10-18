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
    /// data: Raw image bytes (PNG, JPEG, HEIC, WebP, GIF, etc.).
    public static func downscaleToBudget(
        data: Data,
        maxDimension: Int = defaultMaxDimension,
        maxBytes: Int = defaultMaxBytes
    ) -> Data? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
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
            // Fail closed without ImageIO: byte size alone cannot prove the longest edge fits the
            // dimension cap (a small file can still hide thousands of pixels), so refuse rather than
            // pass through unverified pixels and break the 1280px/500KB contract.
            return nil
        #endif
    }

    /// Downscales image bytes and formats as a standard `data:image/jpeg;base64,...` data URL. -
    /// Parameters: - data: Raw image data.
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
