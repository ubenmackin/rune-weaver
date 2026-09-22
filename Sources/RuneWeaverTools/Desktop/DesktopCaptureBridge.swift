// Rune Weaver Tools — Desktop screen and window capture bridge for macOS.
//
// Encapsulates ScreenCaptureKit image capture with in-memory downscaling via
// ImageIO. Returns a bounded JPEG data URL and coordinate scale metadata
// so `desktop.action` can translate LLM-inferred pixel positions back to the
// native display coordinate space.

import Foundation
import RuneWeaverCore

#if canImport(ScreenCaptureKit) && canImport(CoreGraphics) && canImport(ImageIO) && canImport(AppKit)
    import AppKit
    import CoreGraphics
    import ImageIO
    import ScreenCaptureKit
#endif

// MARK: - Capture result

/// Result of a desktop capture: downscaled JPEG plus coordinate metadata.
public struct DesktopCaptureResult: Sendable, Equatable {
    /// Data URL of the downscaled JPEG (`data:image/jpeg;base64,...`).
    public let screenshotDataURL: String
    /// SHA-256 content hash for the audit trail.
    public let screenshotHash: String
    /// Original display width in points before downscaling.
    public let originalWidth: Int
    /// Original display height in points before downscaling.
    public let originalHeight: Int
    /// Width of the downscaled image in pixels.
    public let scaledWidth: Int
    /// Height of the downscaled image in pixels.
    public let scaledHeight: Int
    /// Horizontal scale factor: `originalWidth / scaledWidth`.
    public let scaleX: Double
    /// Vertical scale factor: `originalHeight / scaledHeight`.
    public let scaleY: Double
    /// Display index captured (0 for main).
    public let displayIndex: Int
    /// Name of the target application when a window capture was used.
    public let targetApp: String?
}

// MARK: - Window info

/// Lightweight description of a visible window on screen.
public struct DesktopWindowInfo: Sendable, Codable, Equatable {
    /// Application name owning the window.
    public let appName: String
    /// Window title, when available.
    public let windowTitle: String?
    /// Window bounds in screen coordinates.
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    /// Whether this is the frontmost application.
    public let isFrontmost: Bool
}

// MARK: - Capture errors

/// Errors specific to desktop capture.
public enum DesktopCaptureError: Error, Sendable, Equatable {
    /// macOS Screen Recording permission has not been granted.
    case screenRecordingPermissionDenied
    /// The requested display index does not exist.
    case displayNotFound(index: Int)
    /// The requested application has no visible windows.
    case windowNotFound(appName: String)
    /// Image capture or encoding failed.
    case captureFailed(reason: String)
    /// The platform does not support desktop capture.
    case unsupportedPlatform
}

// MARK: - Capture protocol

/// Protocol for desktop capture so tests can inject a stub.
public protocol DesktopCapturing: Sendable {
    /// Captures the specified display.
    func captureDisplay(
        displayIndex: Int,
        maxDimension: Int,
        jpegQuality: Double
    ) async throws -> DesktopCaptureResult

    /// Captures a specific application's frontmost window.
    func captureWindow(
        appName: String,
        maxDimension: Int,
        jpegQuality: Double
    ) async throws -> DesktopCaptureResult

    /// Lists currently visible windows across all displays.
    func listWindows() async -> [DesktopWindowInfo]
}

// MARK: - Live capture bridge

/// Live desktop capture using macOS ScreenCaptureKit and ImageIO downscaling.
public struct DesktopCaptureBridge: DesktopCapturing, Sendable {
    public init() {}

    public func captureDisplay(
        displayIndex: Int,
        maxDimension: Int,
        jpegQuality: Double
    ) async throws -> DesktopCaptureResult {
        #if canImport(ScreenCaptureKit) && canImport(CoreGraphics) && canImport(ImageIO) && canImport(AppKit)
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                throw DesktopCaptureError.screenRecordingPermissionDenied
            }
            guard displayIndex >= 0, displayIndex < content.displays.count else {
                throw DesktopCaptureError.displayNotFound(index: displayIndex)
            }
            let display = content.displays[displayIndex]
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let streamConfig = SCStreamConfiguration()
            streamConfig.width = display.width
            streamConfig.height = display.height
            streamConfig.showsCursor = true

            let cgImage: CGImage
            do {
                cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: streamConfig)
            } catch {
                throw DesktopCaptureError.captureFailed(reason: error.localizedDescription)
            }

            return try encodeCapture(
                cgImage: cgImage,
                maxDimension: maxDimension,
                jpegQuality: jpegQuality,
                displayIndex: displayIndex,
                targetApp: nil
            )
        #else
            throw DesktopCaptureError.unsupportedPlatform
        #endif
    }

    public func captureWindow(
        appName: String,
        maxDimension: Int,
        jpegQuality: Double
    ) async throws -> DesktopCaptureResult {
        #if canImport(ScreenCaptureKit) && canImport(CoreGraphics) && canImport(ImageIO) && canImport(AppKit)
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                throw DesktopCaptureError.screenRecordingPermissionDenied
            }
            let lowered = appName.lowercased()
            guard let window = content.windows.first(where: {
                guard let owner = $0.owningApplication?.applicationName.lowercased() else { return false }
                return owner == lowered || owner.contains(lowered)
            }) else {
                throw DesktopCaptureError.windowNotFound(appName: appName)
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let streamConfig = SCStreamConfiguration()
            // Window frames are in points; the display path captures in
            // pixels, so scale by the backing factor to keep one pixel-space
            // contract for originalWidth/Height and scaleX/scaleY.
            let pixelScale = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor ?? 2.0
            streamConfig.width = max(1, Int((window.frame.width * pixelScale).rounded()))
            streamConfig.height = max(1, Int((window.frame.height * pixelScale).rounded()))
            streamConfig.showsCursor = false

            let cgImage: CGImage
            do {
                cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: streamConfig)
            } catch {
                throw DesktopCaptureError.captureFailed(reason: error.localizedDescription)
            }

            return try encodeCapture(
                cgImage: cgImage,
                maxDimension: maxDimension,
                jpegQuality: jpegQuality,
                displayIndex: 0,
                targetApp: window.owningApplication?.applicationName ?? appName
            )
        #else
            throw DesktopCaptureError.unsupportedPlatform
        #endif
    }

    public func listWindows() async -> [DesktopWindowInfo] {
        #if canImport(ScreenCaptureKit) && canImport(AppKit)
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName
                return content.windows.compactMap { window in
                    guard let appName = window.owningApplication?.applicationName,
                          window.frame.width > 10, window.frame.height > 10
                    else { return nil }
                    return DesktopWindowInfo(
                        appName: appName,
                        windowTitle: window.title,
                        x: Int(window.frame.origin.x),
                        y: Int(window.frame.origin.y),
                        width: Int(window.frame.width),
                        height: Int(window.frame.height),
                        isFrontmost: appName == frontApp
                    )
                }
            } catch {
                return []
            }
        #else
            return []
        #endif
    }
}

// MARK: - Private helpers

#if canImport(CoreGraphics) && canImport(ImageIO)

    extension DesktopCaptureBridge {
        /// Downscales a captured CGImage and encodes it as a JPEG data URL.
        private func encodeCapture(
            cgImage: CGImage,
            maxDimension: Int,
            jpegQuality: Double,
            displayIndex: Int,
            targetApp: String?
        ) throws -> DesktopCaptureResult {
            let originalWidth = cgImage.width
            let originalHeight = cgImage.height

            // Compute scaled dimensions preserving aspect ratio
            let longest = max(originalWidth, originalHeight)
            let scale: Double
            let scaledWidth: Int
            let scaledHeight: Int
            if longest > maxDimension {
                scale = Double(maxDimension) / Double(longest)
                scaledWidth = max(1, Int((Double(originalWidth) * scale).rounded()))
                scaledHeight = max(1, Int((Double(originalHeight) * scale).rounded()))
            } else {
                scaledWidth = originalWidth
                scaledHeight = originalHeight
                scale = 1.0
            }

            // Render into a new bitmap at the target size
            guard let context = CGContext(
                data: nil,
                width: scaledWidth,
                height: scaledHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                throw DesktopCaptureError.captureFailed(reason: "Could not create bitmap context for downscaling")
            }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))

            guard let scaledImage = context.makeImage() else {
                throw DesktopCaptureError.captureFailed(reason: "Could not render downscaled image")
            }

            // Encode to JPEG with decreasing quality until within budget
            let maxBytes = BrowserScreenshotPolicy.maxByteCount
            let qualities: [Float] = [Float(jpegQuality), 0.6, 0.45, 0.3]
            for quality in qualities {
                let outputData = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    outputData,
                    "public.jpeg" as CFString,
                    1,
                    nil
                ) else {
                    throw DesktopCaptureError.captureFailed(reason: "Could not create JPEG destination")
                }
                let options: [CFString: Any] = [
                    kCGImageDestinationLossyCompressionQuality: quality
                ]
                CGImageDestinationAddImage(destination, scaledImage, options as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { continue }
                let result = outputData as Data
                if result.count <= maxBytes {
                    let base64 = result.base64EncodedString()
                    let dataURL = "data:image/jpeg;base64," + base64
                    let hash = BrowserScreenshotPolicy.auditHash(for: result)
                    return DesktopCaptureResult(
                        screenshotDataURL: dataURL,
                        screenshotHash: hash,
                        originalWidth: originalWidth,
                        originalHeight: originalHeight,
                        scaledWidth: scaledWidth,
                        scaledHeight: scaledHeight,
                        scaleX: Double(originalWidth) / Double(scaledWidth),
                        scaleY: Double(originalHeight) / Double(scaledHeight),
                        displayIndex: displayIndex,
                        targetApp: targetApp
                    )
                }
            }
            throw DesktopCaptureError.captureFailed(
                reason: "Could not compress screenshot within \(maxBytes) byte budget"
            )
        }
    }

#endif
