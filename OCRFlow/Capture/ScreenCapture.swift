import AppKit
import AudioToolbox
import UniformTypeIdentifiers

/// Capturing the screen, from asking for permission to the finished picture.
@MainActor
enum ScreenCapture {
    /// Holds the screen still and lets the user choose a part of it or a
    /// window. Nil when cancelled, or when it could not be taken — the user
    /// has been told why. The app that was in front stays in front
    /// throughout.
    static func choose() async -> (image: CGImage, target: CaptureTarget)? {
        await choose { $0.chosen } ?? nil
    }

    /// The same, then `then` with the screen it was chosen on, still up
    /// around it — for the bar, or a long screenshot, to go on over. What
    /// was chosen is its `chosen`, which adjusting there changes. It closes
    /// when `then` is done.
    static func choose<T>(then: @MainActor (CaptureOverlay) async -> T) async -> T? {
        guard isAllowed() else { return nil }
        do {
            let screen = CaptureOverlay(shots: try await screens())
            defer { screen.close() }
            guard try await screen.choose() else { return nil }
            return await then(screen)
        } catch {
            // Closed by now: not over the alert.
            report(error)
            return nil
        }
    }

    /// Every display as it is now, to choose from.
    static func screens() async throws -> [CGDirectDisplayID: CGImage] {
        try await ScreenGrabber.displays(keeping: ownOrdinaryWindows)
    }

    /// The place as it is now, with no flash and no message if it fails.
    static func grab(_ target: CaptureTarget, maxWidth: Int? = nil) async throws -> CGImage {
        try await ScreenGrabber.capture(target, keeping: ownOrdinaryWindows, maxWidth: maxWidth)
    }

    /// The app's own ordinary windows — the main window, the settings — are
    /// in the picture like any other app's; the floating button and anything
    /// else of the app's that floats over other windows never is.
    private static var ownOrdinaryWindows: [CGWindowID] {
        NSApp.windows.filter { !($0 is NSPanel) && $0.isVisible }.map { CGWindowID($0.windowNumber) }
    }

    // MARK: - Permission

    private static let requestedKey = "screenCapture.requested"

    /// Whether the screen can be captured, asking — or telling the user how
    /// to allow it — when it cannot.
    static func checkAllowed() -> Bool { isAllowed() }

    private static func isAllowed() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // The first time, the system asks, and offers to reopen the app once
        // it is allowed. After that it no longer asks, so the app does.
        if !UserDefaults.standard.bool(forKey: requestedKey) {
            UserDefaults.standard.set(true, forKey: requestedKey)
            CGRequestScreenCaptureAccess()
        } else {
            askForPermission()
        }
        return false
    }

    /// Told over the app in front — see `ResultChoice.tell`.
    private static func askForPermission() {
        Task {
            await ResultChoice.tell(
                String(localized: "OCRFlow needs permission to record the screen"),
                String(localized: "Turn on OCRFlow in Privacy & Security → Screen & System Audio Recording, then reopen it. Screenshots are read on this Mac and never leave it."),
                action: (String(localized: "Open System Settings"), {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }))
        }
    }

    private static func report(_ error: Error) {
        if case ScreenGrabber.Failure.notAllowed = error { return askForPermission() }
        Task { await ResultChoice.tell(String(localized: "The screen could not be captured"), error.localizedDescription) }
    }

    // MARK: - Where it was taken

    /// Pixels a point where the target is: what a picture of it was taken
    /// at, and the resolution it is saved with.
    static func pixelsPerPoint(of target: CaptureTarget) -> CGFloat {
        guard let frame = frame(of: target) else { return NSScreen.main?.backingScaleFactor ?? 1 }
        return CaptureMarks.backingScale(for: frame)
    }

    /// The sound macOS makes as it takes a screenshot, played the way the
    /// system plays its interface sounds — not at all when the user has
    /// turned those off in Sound settings.
    static func playShutterSound() {
        AudioServicesPlaySystemSound(shutterSound)
    }

    private static let shutterSound: SystemSoundID = {
        var sound: SystemSoundID = 0
        let url = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif")
        AudioServicesCreateSystemSoundID(url as CFURL, &sound)
        return sound
    }()

    /// Where the target is now, in screen coordinates.
    static func frame(of target: CaptureTarget) -> CGRect? {
        switch target {
        case let .region(display, rect):
            guard let screen = NSScreen.screens.first(where: { $0.displayID == display }) else { return nil }
            let frame = screen.frame
            return CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        case let .window(id):
            guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }
    }
}

/// The kind of file a screenshot is saved as.
enum ScreenshotFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg
    case heic

    var id: String { rawValue }

    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }

    /// JPEG as `.jpg`, as macOS names its own screenshots, rather than the
    /// type's preferred `.jpeg`.
    var pathExtension: String { self == .jpeg ? "jpg" : type.preferredFilenameExtension ?? rawValue }

    /// Written as this kind of file, with the resolution it was taken at —
    /// 144 pixels an inch from a Retina screen — so it opens at the size it
    /// was on screen. JPEG keeps no transparency, so what is see-through — a
    /// window's rounded corners — is white, not black.
    nonisolated func write(_ image: CGImage, to url: URL, pixelsPerPoint: CGFloat) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { return false }
        var image = image
        if self == .jpeg, image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast,
           let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(.white)
            context.fill(bounds)
            context.draw(image, in: bounds)
            if let flat = context.makeImage() { image = flat }
        }
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * pixelsPerPoint,
                                           kCGImagePropertyDPIHeight: 72 * pixelsPerPoint]
        if self != .png { properties[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// Pixels a point a picture was saved with — 1 when it does not say.
    nonisolated static func pixelsPerPoint(of url: URL) -> CGFloat {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi > 0 else { return 1 }
        return CGFloat(dpi / 72)
    }
}
