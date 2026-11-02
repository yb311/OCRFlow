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

    /// Every display as it is now, at full resolution, without the pointer
    /// and without OCRFlow's own windows other than `kept`.
    static func displays(keeping kept: [CGWindowID]) async throws -> [CGDirectDisplayID: CGImage] {
        let content = try await shareableContent()
        var shots: [CGDirectDisplayID: CGImage] = [:]
        for display in content.displays {
            shots[display.displayID] = try await image(of: filter(display, in: content, keeping: kept), rect: nil)
        }
        return shots
    }

    /// The same place again, as it is now, at its own size. `maxWidth` makes
    /// a smaller picture, for looking at rather than keeping. Over a region,
    /// OCRFlow's own windows other than `kept` are left out, as from
    /// `displays(keeping:)`.
    static func capture(_ target: CaptureTarget, keeping kept: [CGWindowID] = [],
                        maxWidth: Int? = nil) async throws -> CGImage {
        let content = try await shareableContent()
        switch target {
        case let .region(displayID, rect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw Failure.gone
            }
            return try await image(of: filter(display, in: content, keeping: kept), rect: rect, maxWidth: maxWidth)
        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw Failure.gone
            }
            // By the window's own size: what the filter reports wavers by a
            // point or so from one capture to the next, and the picture with it.
            return try await image(of: SCContentFilter(desktopIndependentWindow: window), rect: nil,
                                   size: window.frame.size, maxWidth: maxWidth)
        }
    }

    /// The display without OCRFlow's windows other than `kept`: left out as
    /// one app's, so that any shown as the picture is taken are too.
    private static func filter(_ display: SCDisplay, in content: SCShareableContent,
                               keeping kept: [CGWindowID]) -> SCContentFilter {
        let own = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let app = content.applications.filter { $0.processID == getpid() }
        return app.isEmpty
            ? SCContentFilter(display: display, excludingWindows: own.filter { !kept.contains($0.windowID) })
            : SCContentFilter(display: display, excludingApplications: app,
                              exceptingWindows: own.filter { kept.contains($0.windowID) })
    }

    /// Every window, not only those on screen: asked for those on screen
    /// only, ScreenCaptureKit leaves out OCRFlow's windows shown a moment
    /// before — the dimming round an area, say — and OCRFlow with them, so
    /// nothing of OCRFlow's would be left out of the picture.
    private static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch let error as NSError where error.domain == SCStreamErrorDomain
                    && error.code == SCStreamError.Code.userDeclined.rawValue {
            throw Failure.notAllowed
        }
    }

    /// `rect` is in points from the top-left of what the filter shows; nil
    /// takes all of it. The picture is drawn to the size asked for: given
    /// any other than the place's own, it would be scaled.
    private static func image(of filter: SCContentFilter, rect: CGRect?, size: CGSize? = nil,
                              maxWidth: Int? = nil) async throws -> CGImage {
        let size = rect?.size ?? size ?? filter.contentRect.size
        var scale = CGFloat(filter.pointPixelScale)
        if let maxWidth, size.width * scale > CGFloat(maxWidth) { scale = CGFloat(maxWidth) / max(size.width, 1) }
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
