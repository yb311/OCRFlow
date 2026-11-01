import AppKit
import UniformTypeIdentifiers

/// Capturing the screen, from asking for permission to the finished picture.
@MainActor
enum ScreenCapture {
    /// Holds the screen still and lets the user choose a part of it or a
    /// window. Nil when cancelled, or when it could not be taken — the user
    /// has been told why. The app that was in front is in front again
    /// afterwards. `lingering`: the held screen stays until what comes next
    /// shows — see `CaptureOverlay.closeLingering()`.
    static func choose(lingering: Bool = false) async -> (image: CGImage, target: CaptureTarget)? {
        guard isAllowed() else { return nil }
        do {
            let shots = try await screens()
            switch await CaptureOverlay.choose(from: shots, lingering: lingering) {
            case nil:
                return nil
            case let .region(target, image):
                return (image, target)
            case let .window(id):
                return (try await ScreenGrabber.capture(.window(id)), .window(id))
            }
        } catch {
            // Not over the alert.
            CaptureOverlay.closeLingering()
            report(error)
            return nil
        }
    }

    /// Every display as it is now, to choose from.
    static func screens() async throws -> [CGDirectDisplayID: CGImage] {
        try await ScreenGrabber.displays(keeping: ownOrdinaryWindows)
    }

    /// The place as it is now, with no flash and no message if it fails.
    /// `like` keeps the size of an earlier picture of the same place, for
    /// pictures to be joined.
    static func grab(_ target: CaptureTarget, maxWidth: Int? = nil, like earlier: CGSize? = nil) async throws -> CGImage {
        try await ScreenGrabber.capture(target, keeping: ownOrdinaryWindows, maxWidth: maxWidth, like: earlier)
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

    private static func askForPermission() {
        let alert = NSAlert()
        alert.messageText = String(localized: "OCRFlow needs permission to record the screen")
        alert.informativeText = String(localized: "Turn on OCRFlow in Privacy & Security → Screen & System Audio Recording, then reopen it. Screenshots are read on this Mac and never leave it.")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if OwnWindows.whileModal({ alert.runModal() }) == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func report(_ error: Error) {
        if case ScreenGrabber.Failure.notAllowed = error { return askForPermission() }
        let alert = NSAlert()
        alert.messageText = String(localized: "The screen could not be captured")
        alert.informativeText = error.localizedDescription
        OwnWindows.whileModal { _ = alert.runModal() }
    }

    // MARK: - Flash

    /// A brief flash over what was taken: a capture made without the
    /// crosshair otherwise gives no sign that it happened.
    static func flash(_ target: CaptureTarget) {
        guard let rect = frame(of: target) else { return }
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.hasShadow = false
        panel.backgroundColor = NSColor.white.withAlphaComponent(0.45)
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }
        Task {
            try? await Task.sleep(for: .seconds(0.4))
            panel.orderOut(nil)
        }
    }

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

    var pathExtension: String { type.preferredFilenameExtension ?? rawValue }

    /// Written as this kind of file. JPEG keeps no transparency, so what is
    /// see-through — a window's rounded corners — is white, not black.
    nonisolated func write(_ image: CGImage, to url: URL) -> Bool {
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
        let options = self == .png ? nil : [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination)
    }
}
