import AppKit

/// The windows on screen, as the window server lists them: front to back,
/// in event coordinates.
struct ScreenWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String?
    let frame: CGRect
    /// 0 for an ordinary window; menus, the menu bar, pop-ups sit higher.
    let layer: Int

    var place: WindowPlace {
        WindowPlace(bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                    appName: appName, title: title, frame: frame)
    }
}

extension WindowPlace {
    /// The app a menu, the menu bar or a pop-up belongs to.
    static func floating(of window: ScreenWindow) -> WindowPlace {
        // The menu bar is drawn by the system, but its menus are the app's
        // in front.
        if window.place.bundleID == nil, let app = NSWorkspace.shared.frontmostApplication {
            return WindowPlace(bundleID: app.bundleIdentifier, appName: app.localizedName ?? "", title: nil, frame: .zero)
        }
        return WindowPlace(bundleID: window.place.bundleID, appName: window.appName, title: nil, frame: .zero)
    }
}

@MainActor
enum ScreenWindows {
    /// Every other app's window on screen, frontmost first.
    static func all() -> [ScreenWindow] {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width > 1, frame.height > 1,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            let title = info[kCGWindowName as String] as? String
            return ScreenWindow(id: id, pid: pid, appName: info[kCGWindowOwnerName as String] as? String ?? "",
                                title: title?.isEmpty == false ? title : nil, frame: frame,
                                layer: info[kCGWindowLayer as String] as? Int ?? 0)
        }
    }

    /// The window under a point: an ordinary one, or a menu or pop-up over
    /// it. Not a see-through layer over a whole display, which some parts of
    /// the system keep in front of everything without drawing in it.
    static func at(_ point: CGPoint) -> ScreenWindow? {
        let displays = NSScreen.screens.map { screen in
            CGRect(x: screen.frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.frame.maxY,
                   width: screen.frame.width, height: screen.frame.height)
        }
        return all().first { window in
            guard window.layer < 1000, window.frame.contains(point) else { return false }
            guard window.layer != 0 else { return true }
            return !displays.contains { display in
                let covered = window.frame.intersection(display)
                return !covered.isNull && covered.width * covered.height >= display.width * display.height * 0.9
            }
        }
    }

    /// The ordinary window under a point: what a position is measured from.
    static func ordinary(at point: CGPoint) -> ScreenWindow? {
        guard let window = at(point), window.layer == 0 else { return nil }
        return window
    }

    /// The frontmost ordinary window of the app in front.
    static func frontWindow() -> ScreenWindow? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return all().first { $0.pid == pid && $0.layer == 0 }
    }

    /// The app in front and its front window: where keys go. Only the app
    /// when it has no window open.
    static func frontPlace() -> WindowPlace? {
        if let window = frontWindow() { return window.place }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return WindowPlace(bundleID: app.bundleIdentifier, appName: app.localizedName ?? "", title: nil, frame: .zero)
    }

    /// The window a step happened in, as it is now: the app's window with the
    /// same title, or else its frontmost one. Nil when the app has none open.
    static func find(_ place: WindowPlace) -> ScreenWindow? {
        guard !place.isFloating else { return nil }
        let pids: Set<pid_t>
        if let bundleID = place.bundleID {
            pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        } else {
            pids = Set(NSWorkspace.shared.runningApplications.filter { $0.localizedName == place.appName }
                .map(\.processIdentifier))
        }
        let windows = all().filter { pids.contains($0.pid) && $0.layer == 0 }
        if let title = place.title, let same = windows.first(where: { $0.title == title }) { return same }
        // Of the rest, one the same size is likely the same window.
        return windows.first { abs($0.frame.width - place.frame.width) < 2 && abs($0.frame.height - place.frame.height) < 2 }
            ?? windows.first
    }

    /// A rectangle in event coordinates as a capture target: the display it
    /// is mostly on, and where on it.
    static func target(for rect: CGRect) -> CaptureTarget? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return nil }
        let best = displays.prefix(Int(count)).max { lhs, rhs in
            area(rect.intersection(CGDisplayBounds(lhs))) < area(rect.intersection(CGDisplayBounds(rhs)))
        }
        guard let display = best else { return nil }
        let bounds = CGDisplayBounds(display)
        let inside = rect.intersection(bounds)
        guard !inside.isNull, inside.width >= 1, inside.height >= 1 else { return nil }
        return .region(display: display, rect: inside.offsetBy(dx: -bounds.minX, dy: -bounds.minY))
    }

    /// The whole display a point is on.
    static func display(at point: CGPoint) -> CaptureTarget {
        var display = CGMainDisplayID(), found: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(point, 1, &found, &count) == .success, count > 0 { display = found }
        let bounds = CGDisplayBounds(display)
        return .region(display: display, rect: CGRect(origin: .zero, size: bounds.size))
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
