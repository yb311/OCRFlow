import AppKit

/// OCRFlow's own ordinary windows — the main window, the settings — put out
/// of the way while it works over other apps, and back where they were in
/// the stack afterwards.
///
/// Activating an app brings its main window forward. A save panel or an
/// alert has to activate OCRFlow, and without this the main window would
/// come up over whatever the user was capturing.
@MainActor
struct OwnWindows {
    private var tucked: [(window: NSWindow, below: Int?)] = []
    private var previousApp: NSRunningApplication?

    /// Takes them off screen, remembering which window was just above each.
    static func tuck() -> OwnWindows {
        var own = OwnWindows()
        let front = NSWorkspace.shared.frontmostApplication
        own.previousApp = front == .current ? nil : front
        let windows = NSApp.orderedWindows.filter { $0.isVisible && !($0 is NSPanel) }
        own.tucked = windows.map { ($0, windowAbove($0)) }
        windows.forEach { $0.orderOut(nil) }
        return own
    }

    /// Whether OCRFlow was the app in front when they were tucked away.
    var wasInFront: Bool { previousApp == nil }

    /// Back where they were, back to front, and the app that was in front in
    /// front again.
    func restore() {
        for (window, below) in tucked.reversed() {
            if let below { window.order(.below, relativeTo: below) } else { window.orderFront(nil) }
        }
        if let previousApp { Activation.handOver(to: previousApp) }
    }

    /// Runs something modal — a save panel, an alert — with OCRFlow in front
    /// but its windows out of the way.
    static func whileModal<T>(_ body: () -> T) -> T {
        let own = tuck()
        NSApp.activate()
        defer { own.restore() }
        return body()
    }

    /// The ordinary window, of any app, just above `window`.
    private static func windowAbove(_ window: NSWindow) -> Int? {
        let list = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, CGWindowID(window.windowNumber))
            as? [[String: Any]] ?? []
        // Listed front to back: the last ordinary one is the nearest.
        return list.last { $0[kCGWindowLayer as String] as? Int == 0 }?[kCGWindowNumber as String] as? Int
    }
}

/// Bringing another app to the front, as macOS asks since 14: activation is
/// cooperative. The app in front hands it over — `yieldActivation(to:)` —
/// and the other takes it, `activate(from:options:)`; an app that is not in
/// front can only ask, and the system decides.
@MainActor
enum Activation {
    /// Asks for `app` to come to the front, handing over OCRFlow's place
    /// when OCRFlow has it.
    static func handOver(to app: NSRunningApplication) {
        guard !app.isActive else { return }
        if NSApp.isActive {
            NSApp.yieldActivation(to: app)
            app.activate(from: .current, options: [])
        } else {
            app.activate()
        }
    }

    /// The same, and waits until it is in front — or a second has gone by.
    /// True when it is.
    @discardableResult
    static func bringForward(_ app: NSRunningApplication) async -> Bool {
        handOver(to: app)
        for _ in 0..<50 where !app.isActive {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return app.isActive
    }
}
