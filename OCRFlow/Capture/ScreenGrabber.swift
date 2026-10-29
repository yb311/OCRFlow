import AppKit
import ScreenCaptureKit

/// A place on screen that was captured, so the same place can be taken again
/// without choosing it.
enum CaptureTarget: Equatable, Sendable {
    /// Part of one display, in points from its top-left corner.
    case region(display: CGDirectDisplayID, rect: CGRect)
    /// One window by itself, whatever is in front of it.
    case window(CGWindowID)
}

/// Takes pictures of the screen with ScreenCaptureKit.
///
/// Its objects are not sendable, so each function does all of its work with
/// them itself and hands back only images.
enum ScreenGrabber {
    enum Failure: Error {
        /// The user has not allowed the app to record the screen.
        case notAllowed
        /// The display or window is no longer there.
        case gone
    }

    /// Every display as it is now, at full resolution, without the given
    /// windows and without the pointer.
    static func displays(excluding windowIDs: [CGWindowID]) async throws -> [CGDirectDisplayID: CGImage] {
        let content = try await shareableContent()
        let excluded = content.windows.filter { windowIDs.contains($0.windowID) }
        var shots: [CGDirectDisplayID: CGImage] = [:]
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            shots[display.displayID] = try await image(of: filter, rect: nil)
        }
        return shots
    }

    /// The same place again, as it is now.
    static func capture(_ target: CaptureTarget, excluding windowIDs: [CGWindowID]) async throws -> CGImage {
        let content = try await shareableContent()
        switch target {
        case let .region(displayID, rect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw Failure.gone
            }
            let excluded = content.windows.filter { windowIDs.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            return try await image(of: filter, rect: rect)
        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw Failure.gone
            }
            return try await image(of: SCContentFilter(desktopIndependentWindow: window), rect: nil)
        }
    }

    private static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch let error as NSError where error.domain == SCStreamErrorDomain
                    && error.code == SCStreamError.Code.userDeclined.rawValue {
            throw Failure.notAllowed
        }
    }

    /// `rect` is in points from the top-left of what the filter shows; nil
    /// takes all of it.
    private static func image(of filter: SCContentFilter, rect: CGRect?) async throws -> CGImage {
        let scale = CGFloat(filter.pointPixelScale)
        let size = rect?.size ?? filter.contentRect.size
        let config = SCStreamConfiguration()
        if let rect { config.sourceRect = rect }
        config.width = max(1, Int((size.width * scale).rounded()))
        config.height = max(1, Int((size.height * scale).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
