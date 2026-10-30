import AppKit
import ApplicationServices

/// Controls and windows of other apps, through the Accessibility interface —
/// the one VoiceOver uses. It lets a recorded click go to "the Next button"
/// rather than to a position, and puts a window back where it was.
///
/// Nothing here knows any app: every app that works with VoiceOver describes
/// its controls the same way. Each call waits on the other app, so none is
/// made on the main thread.
enum ElementLocator {
    /// Controls a click is aimed at, rather than at whatever is under it.
    static let controlRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXMenuItem", "AXMenuBarItem", "AXLink", "AXDisclosureTriangle", "AXTabButton",
    ]

    /// The control at a point on screen, if there is one with something to
    /// tell it by. `origin` is the top-left of the window it is in.
    static func describe(at point: CGPoint, windowOrigin origin: CGPoint) -> ElementDescription? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        // A click lands on a button's label or icon more often than on the
        // button itself.
        for _ in 0..<5 {
            if let role = string(element, kAXRoleAttribute), controlRoles.contains(role) { break }
            guard let parent: AXUIElement = value(element, kAXParentAttribute) else { return nil }
            element = parent
        }
        guard let role = string(element, kAXRoleAttribute), controlRoles.contains(role),
              let frame = frame(of: element) else { return nil }
        let description = ElementDescription(
            role: role, subrole: string(element, kAXSubroleAttribute),
            title: string(element, kAXTitleAttribute), label: string(element, kAXDescriptionAttribute),
            identifier: string(element, kAXIdentifierAttribute),
            center: CGPoint(x: frame.midX - origin.x, y: frame.midY - origin.y))
        return description.name == nil ? nil : description
    }

    /// Whether a click on this is better aimed at the control than at the
    /// position: a button keeps its name while it moves about. A link with a
    /// long name is more likely an item in a list, which the next round means
    /// to be the next one along.
    static func prefersElement(_ description: ElementDescription) -> Bool {
        guard let name = description.name else { return false }
        return description.role != "AXLink" || description.identifier != nil || name.count <= 24
    }

    enum Found: Equatable {
        /// Its centre, to click.
        case point(CGPoint)
        /// It was out of sight, and pressed through Accessibility instead.
        case pressed
    }

    /// Looks for the control in the app's window at `window` (its frame now),
    /// or anywhere in the app. Of several that fit, the one nearest where it
    /// was.
    static func find(_ description: ElementDescription, pid: pid_t, window: CGRect?) -> Found? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var roots: [AXUIElement] = []
        if let window, let match = self.window(of: app, at: window) { roots = [match] }
        // Menus and open pop-ups belong to the app, not to a window.
        if roots.isEmpty || description.role.hasPrefix("AXMenu") { roots.append(app) }

        let expected = CGPoint(x: (window?.minX ?? 0) + description.center.x,
                               y: (window?.minY ?? 0) + description.center.y)
        var best: (element: AXUIElement, frame: CGRect, distance: CGFloat)?
        let deadline = Date().addingTimeInterval(1.5)
        var queue = roots, next = 0
        while next < queue.count, next < 8000, Date() < deadline {
            let element = queue[next]
            next += 1
            if matches(element, description), let frame = frame(of: element), frame.width > 0, frame.height > 0 {
                let distance = hypot(frame.midX - expected.x, frame.midY - expected.y)
                if distance < best?.distance ?? .infinity { best = (element, frame, distance) }
            }
            if let children: [AXUIElement] = value(element, kAXChildrenAttribute) { queue += children }
        }
        guard let best else { return nil }
        let center = CGPoint(x: best.frame.midX, y: best.frame.midY)
        if let window, !window.insetBy(dx: -1, dy: -1).contains(center) {
            return AXUIElementPerformAction(best.element, kAXPressAction as CFString) == .success ? .pressed : nil
        }
        return .point(center)
    }

    /// Moves and sizes the app's window that is at `current` to `frame`.
    /// False when it could not be found or will not move.
    @discardableResult
    static func move(windowOf pid: pid_t, at current: CGRect, to frame: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let window = window(of: app, at: current) else { return false }
        var origin = frame.origin, size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return false }
        // Size first: a window too large to move further sometimes refuses.
        let sized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        return sized == .success || moved == .success
    }

    // MARK: - Reading

    private static func matches(_ element: AXUIElement, _ description: ElementDescription) -> Bool {
        guard string(element, kAXRoleAttribute) == description.role else { return false }
        if let identifier = description.identifier, !identifier.isEmpty {
            return string(element, kAXIdentifierAttribute) == identifier
        }
        if let title = description.title, !title.isEmpty, string(element, kAXTitleAttribute) != title { return false }
        if let label = description.label, !label.isEmpty, string(element, kAXDescriptionAttribute) != label { return false }
        return true
    }

    /// The window of `app` that sits at `frame`, give or take a few points.
    private static func window(of app: AXUIElement, at frame: CGRect) -> AXUIElement? {
        guard let windows: [AXUIElement] = value(app, kAXWindowsAttribute) else { return nil }
        return windows.min { lhs, rhs in
            distance(self.frame(of: lhs), frame) < distance(self.frame(of: rhs), frame)
        }.flatMap { distance(self.frame(of: $0), frame) < 8 ? $0 : nil }
    }

    private static func distance(_ a: CGRect?, _ b: CGRect) -> CGFloat {
        guard let a else { return .infinity }
        return abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// In event coordinates, as Accessibility reports it.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = value(element, kAXPositionAttribute),
              let size: AXValue = value(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        let text: String? = value(element, attribute)
        return text?.isEmpty == false ? text : nil
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
