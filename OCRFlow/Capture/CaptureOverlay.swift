import AppKit

/// Holds the screen still and lets the user choose what to capture: drag out
/// a part of it, or click a window. Clicking where there is no window takes
/// the whole display.
///
/// The screens are shown as they were the moment capture started, so menus,
/// tooltips and hover states are kept, and what is cut out is exactly what
/// was seen.
@MainActor
final class CaptureOverlay {
    enum Choice: Sendable {
        /// Cut from the held picture, which is already the result.
        case region(CaptureTarget, CGImage)
        /// Taken by itself afterwards, without what is in front of it.
        case window(CGWindowID)
    }

    /// Nil when the user cancels. `lingering`: once something is chosen,
    /// the held screen stays, dimmed around it, and OCRFlow in front, until
    /// `closeLingering()` — or a moment, unless `keepLingering()` — so what
    /// comes next shows over it with no flash of the live screen between,
    /// and nothing beneath can be clicked meanwhile.
    static func choose(from shots: [CGDirectDisplayID: CGImage], lingering: Bool = false) async -> Choice? {
        let overlay = CaptureOverlay(shots: shots)
        overlay.lingering = lingering
        current = overlay
        return await withCheckedContinuation { continuation in
            overlay.continuation = continuation
            overlay.show()
        }
    }

    /// Kept alive while it waits.
    private static var current: CaptureOverlay?
    /// Still showing after the choice, until what comes next is done.
    private static var lingeringOverlay: CaptureOverlay?

    /// Takes away the held screen kept after a choice.
    ///
    /// OCRFlow stays the active app while it lingers — the bar's keys are
    /// its own, and recognizing opens its window, which an app in the
    /// background may not bring forward. `givingBack`: the app that was in
    /// front gets its place back first, and the held screen stays over the
    /// change — Stage Manager bringing that app's windows back — until it
    /// has come forward, or a moment has passed. Without, OCRFlow stays in
    /// front, for its own window to show.
    static func closeLingering(givingBack: Bool = true) async {
        guard let overlay = lingeringOverlay else { return }
        lingeringOverlay = nil
        if givingBack, let app = overlay.previousApp, !app.isActive {
            await Activation.bringForward(app)
            if UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") == true {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        overlay.panels.forEach { $0.orderOut(nil) }
        overlay.panels.removeAll()
    }

    /// Keeps the held screen up until `closeLingering()`, for as long as it
    /// takes. False when there is none.
    @discardableResult
    static func keepLingering() -> Bool {
        lingeringOverlay?.kept = true
        return lingeringOverlay != nil
    }

    /// What pointing picks out.
    private struct Spot {
        /// The window, when it is a whole window.
        let id: CGWindowID?
        /// An ordinary window, taken by itself; anything else — the menu
        /// bar, its icons, the Dock, a menu — is cut from the held picture.
        let ordinary: Bool
        /// In screen coordinates, as `NSScreen.frame` uses.
        let frame: CGRect
    }

    /// A window on the held screen.
    private struct Layer {
        let id: CGWindowID
        let pid: pid_t
        let ordinary: Bool
        /// In screen coordinates, as `NSScreen.frame` uses.
        let frame: CGRect
    }

    private let shots: [CGDirectDisplayID: CGImage]
    /// Front to back, as they were when the screen was held.
    /// Front to back, as they were when the screen was held.
    private let windows: [Layer]
    /// The last spot found, and where: pointing within it again finds it
    /// again without asking.
    private var lastSpot: (window: CGWindowID, spot: Spot)?
    private var panels: [OverlayWindow] = []
    private var continuation: CheckedContinuation<Choice?, Never>?
    /// Given back its place once the choice is made — or, when the held
    /// screen lingers, once that is taken away: a long screenshot or a
    /// recording happens there.
    private var previousApp: NSRunningApplication?
    private var lingering = false
    /// Not closed after a moment: what came next is up over it.
    private var kept = false
    /// What was chosen, in screen coordinates, shown bright on the held
    /// screen while it lingers. Nothing more can be chosen then.
    private(set) var settled: CGRect?

    /// Where a drag started, and the screen it is kept to.
    private var dragStart: (point: NSPoint, screen: NSScreen)?
    /// Being dragged out, in screen coordinates.
    private(set) var selection: CGRect?
    /// What a click would take.
    private(set) var highlight: CGRect?

    private init(shots: [CGDirectDisplayID: CGImage]) {
        self.shots = shots
        windows = Self.windowsFrontToBack()
    }

    /// Every window on screen below the screen saver's — app windows, menus,
    /// the menu bar and its icons, the Dock's layer — front to back.
    /// OCRFlow's own ordinary windows are among them, as they are in the
    /// held screen; what of it floats over other windows is not.
    private static func windowsFrontToBack() -> [Layer] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        // Window bounds are measured down from the top of the main display.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer < 1000,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID || layer == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 4, rect.height >= 4 else { return nil }
            return Layer(id: id, pid: pid, ordinary: layer == 0,
                         frame: CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height))
        }
    }

    /// What pointing at `point` picks out, the same way for anything on
    /// screen: the app whose window is in front there is asked, through
    /// Accessibility, which of the things it shows is there — its window,
    /// the Dock's bar of icons, the menu bar, a menu — and that is it.
    /// Without an answer, it is the window itself.
    private func spot(at point: CGPoint) -> Spot? {
        let here = windows.filter { NSMouseInRect(point, $0.frame, false) }
        if let lastSpot, here.first?.id == lastSpot.window, NSMouseInRect(point, lastSpot.spot.frame, false) {
            return lastSpot.spot
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in here {
            let spot: Spot?
            if window.pid == ownPID {
                // Its own window, whole: OCRFlow cannot ask itself through
                // Accessibility while it waits on the answer.
                spot = Spot(id: window.id, ordinary: true, frame: window.frame)
            } else if let frame = Self.outermost(at: point, of: window.pid) {
                let whole = abs(frame.minX - window.frame.minX) + abs(frame.minY - window.frame.minY)
                    + abs(frame.width - window.frame.width) + abs(frame.height - window.frame.height) < 4
                spot = Spot(id: whole ? window.id : nil, ordinary: whole && window.ordinary, frame: frame)
            } else {
                // A see-through layer over a whole display, which parts of
                // the system keep in front without drawing in it, is nothing
                // to pick out: what is beneath it is.
                spot = Self.coversADisplay(window.frame) ? nil : Spot(id: window.id, ordinary: window.ordinary, frame: window.frame)
            }
            if let spot {
                lastSpot = (window.id, spot)
                return spot
            }
        }
        return nil
    }

    /// The outermost thing the app shows at `point` — what its topmost
    /// element there belongs to, short of the app itself — in screen
    /// coordinates. Nil without Accessibility, or when the app says
    /// nothing, or only something as large as a whole display.
    private static func outermost(at point: CGPoint, of pid: pid_t) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(top - point.y), &hit) == .success,
              var element = hit else { return nil }
        func role(_ element: AXUIElement) -> String? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
            return value as? String
        }
        func parent(_ element: AXUIElement) -> AXUIElement? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        for _ in 0..<64 {
            guard let up = parent(element), role(up) != kAXApplicationRole as String else { break }
            element = up
        }
        var position: CFTypeRef?, size: CFTypeRef?
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width >= 4, extent.height >= 4 else { return nil }
        let frame = CGRect(x: origin.x, y: top - origin.y - extent.height, width: extent.width, height: extent.height)
        return coversADisplay(frame) ? nil : frame
    }

    private static func coversADisplay(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            let shared = frame.intersection(screen.frame)
            return !shared.isNull && shared.width * shared.height >= screen.frame.width * screen.frame.height * 0.9
        }
    }

    private func show() {
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let shot = shots[id] else { continue }
            let panel = OverlayWindow(screen: screen, shot: shot, overlay: self)
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        guard !panels.isEmpty else { return finish(nil) }

        // Key, so the keyboard reaches the overlay; and OCRFlow asked to come
        // in front, for the pointer to be a crosshair, which an app in the
        // background cannot set. The overlay is made the main window first,
        // since activating an app brings its main window forward — OCRFlow's
        // own, over what the user is about to capture, were it left to be.
        let front = NSWorkspace.shared.frontmostApplication
        if front != .current { previousApp = front }
        let pointer = NSEvent.mouseLocation
        let first = panels.first { NSMouseInRect(pointer, $0.frame, false) } ?? panels[0]
        first.makeKeyAndOrderFront(nil)
        first.makeMain()
        NSApp.activate()
        NSCursor.crosshair.push()
        redraw()
    }

    /// `area`: what was chosen, in screen coordinates.
    private func finish(_ choice: Choice?, area: CGRect? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        NSCursor.pop()
        if choice != nil, lingering, let area {
            // Kept until what comes next is up — or a moment, unless that
            // asks for more.
            settled = area
            selection = nil
            highlight = nil
            redraw()
            Self.lingeringOverlay = self
            Task {
                try? await Task.sleep(for: .seconds(2))
                if Self.lingeringOverlay === self, !kept { await Self.closeLingering() }
            }
        } else {
            if let previousApp { Activation.handOver(to: previousApp) }
            for panel in panels { panel.orderOut(nil) }
            panels.removeAll()
        }
        Self.current = nil
        continuation.resume(returning: choice)
    }

    /// Choosing is over; the held screen may still be up.
    fileprivate var isChoosing: Bool { continuation != nil }

    private func redraw() {
        for panel in panels { panel.marks.needsDisplay = true }
    }

    // MARK: - Events

    /// Nothing is picked out before the pointer first moves: the whole
    /// screen is dimmed, as on being asked to choose.
    fileprivate func pointerMoved(to pointer: NSPoint) {
        guard isChoosing, dragStart == nil else { return }
        highlight = spot(at: pointer)?.frame
            ?? NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }?.frame
        redraw()
    }

    fileprivate func pressed(at pointer: NSPoint) {
        guard isChoosing, let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) else { return }
        dragStart = (pointer, screen)
    }

    fileprivate func dragged(to pointer: NSPoint) {
        guard isChoosing, let dragStart else { return }
        let frame = dragStart.screen.frame
        var pointer = pointer
        // Kept to the screen the drag started on.
        pointer.x = min(max(pointer.x, frame.minX), frame.maxX)
        pointer.y = min(max(pointer.y, frame.minY), frame.maxY)
        let rect = CGRect(x: min(pointer.x, dragStart.point.x), y: min(pointer.y, dragStart.point.y),
                          width: abs(pointer.x - dragStart.point.x), height: abs(pointer.y - dragStart.point.y))
        // A hand that wobbles during a click is not a drag.
        guard selection != nil || hypot(rect.width, rect.height) > 3 else { return }
        selection = rect
        highlight = nil
        redraw()
    }

    fileprivate func released() {
        guard let start = dragStart else { return }
        dragStart = nil
        let dragged = selection
        selection = nil
        // Big enough to hold any text; anything smaller was meant as a click.
        if let dragged, dragged.width >= 4, dragged.height >= 4 {
            finish(region(dragged.integral, on: start.screen), area: dragged.integral)
        } else if let spot = spot(at: start.point) {
            // A window by itself; the menu bar, the Dock and the like as
            // they were on the held screen.
            if spot.ordinary, let id = spot.id {
                finish(.window(id), area: spot.frame)
            } else {
                let area = spot.frame.intersection(start.screen.frame).integral
                finish(region(area, on: start.screen), area: area)
            }
        } else {
            finish(region(start.screen.frame, on: start.screen), area: start.screen.frame)
        }
    }

    fileprivate func cancel() {
        finish(nil)
    }

    /// Cut out of the held picture of that screen.
    private func region(_ rect: CGRect, on screen: NSScreen) -> Choice? {
        guard let display = screen.displayID, let shot = shots[display] else { return nil }
        let (local, pixels) = Self.place(rect, on: screen.frame, pixelWidth: shot.width)
        guard let image = shot.cropping(to: pixels) else { return nil }
        return .region(.region(display: display, rect: local), image)
    }

    /// A rectangle in screen coordinates, measured instead from the top-left
    /// of the display it is on — in points, and in the pixels of a picture
    /// of that display `pixelWidth` wide.
    nonisolated static func place(_ rect: CGRect, on screenFrame: CGRect, pixelWidth: Int) -> (points: CGRect, pixels: CGRect) {
        let points = CGRect(x: rect.minX - screenFrame.minX, y: screenFrame.maxY - rect.maxY,
                            width: rect.width, height: rect.height)
        let scale = CGFloat(pixelWidth) / screenFrame.width
        let pixels = CGRect(x: points.minX * scale, y: points.minY * scale,
                            width: points.width * scale, height: points.height * scale).integral
        return (points, pixels)
    }
}

// MARK: - One screen

/// A panel that takes the keyboard without needing OCRFlow to be the active
/// app: activation is only asked for, and may be refused — Escape and the
/// rest must reach the overlay either way.
private final class OverlayWindow: NSPanel {
    let marks: OverlayMarks

    init(screen: NSScreen, shot: CGImage, overlay: CaptureOverlay) {
        marks = OverlayMarks(overlay: overlay)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        hidesOnDeactivate = false
        // Above the menu bar, the Dock and menus.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        animationBehavior = .none
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true

        let held = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        held.wantsLayer = true
        held.layer?.contents = shot
        held.layer?.contentsGravity = .resize
        marks.frame = held.bounds
        marks.autoresizingMask = [.width, .height]
        held.addSubview(marks)
        contentView = held
        initialFirstResponder = marks
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Draws the highlight or the selection over the held picture, and takes the
/// mouse and keyboard.
private final class OverlayMarks: NSView {
    private weak var overlay: CaptureOverlay?

    init(overlay: CaptureOverlay) {
        self.overlay = overlay
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        (overlay?.isChoosing ?? false ? NSCursor.crosshair : NSCursor.arrow).set()
    }
    override func mouseMoved(with event: NSEvent) { overlay?.pointerMoved(to: pointer(of: event)) }
    override func mouseDown(with event: NSEvent) { overlay?.pressed(at: pointer(of: event)) }
    override func mouseDragged(with event: NSEvent) { overlay?.dragged(to: pointer(of: event)) }
    override func mouseUp(with event: NSEvent) { overlay?.released() }
    override func rightMouseDown(with event: NSEvent) { overlay?.cancel() }
    override func cancelOperation(_ sender: Any?) { overlay?.cancel() }

    /// In screen coordinates.
    private func pointer(of event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { overlay?.cancel() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let window, let overlay else { return }
        let origin = window.frame.origin
        func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -origin.x, dy: -origin.y) }

        // What a release would take — the area dragged out, or the window
        // under the pointer — stands out bright; everything else, on every
        // screen, is dimmed. Before the pointer has moved, all of it is.
        // Once chosen, it stays so while the bar of buttons is up.
        guard let chosen = overlay.settled ?? overlay.selection ?? overlay.highlight else {
            CaptureShade.draw(in: bounds, around: .null)
            return
        }
        let cut = local(chosen)
        CaptureShade.draw(in: bounds, around: cut)
        guard cut.intersects(bounds) else { return }
        // The size, where it stays once the bar shows.
        let text = CaptureMarks.sizeText(for: chosen) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CaptureMarks.sizeFont,
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let box = CGSize(width: ceil(size.width) + 2 * CaptureMarks.sizePadding.width,
                         height: ceil(size.height) + 2 * CaptureMarks.sizePadding.height)
        let pill = local(CaptureMarks.sizeLabelFrame(size: box, for: chosen))
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text.draw(at: CGPoint(x: pill.minX + CaptureMarks.sizePadding.width, y: pill.minY + CaptureMarks.sizePadding.height),
                  withAttributes: attributes)
    }
}
