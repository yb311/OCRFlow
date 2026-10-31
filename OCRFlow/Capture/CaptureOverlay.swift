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

    /// Nil when the user cancels.
    static func choose(from shots: [CGDirectDisplayID: CGImage]) async -> Choice? {
        let overlay = CaptureOverlay(shots: shots)
        current = overlay
        return await withCheckedContinuation { continuation in
            overlay.continuation = continuation
            overlay.show()
        }
    }

    /// Kept alive while it waits.
    private static var current: CaptureOverlay?

    private struct Spot {
        let id: CGWindowID
        /// In screen coordinates, as `NSScreen.frame` uses.
        let frame: CGRect
    }

    private let shots: [CGDirectDisplayID: CGImage]
    /// Front to back, as they were when the screen was held.
    private let windows: [Spot]
    private var panels: [OverlayWindow] = []
    private var continuation: CheckedContinuation<Choice?, Never>?
    /// Given back its place once the choice is made: what comes next — the
    /// bar of buttons, a long screenshot, a recording — happens there.
    private var previousApp: NSRunningApplication?

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

    private static func windowsFrontToBack() -> [Spot] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        // Window bounds are measured down from the top of the main display.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            // Layer 0 is ordinary app windows: not the menu bar, the Dock or
            // the desktop.
            guard info[kCGWindowLayer as String] as? Int == 0,
                  info[kCGWindowOwnerPID as String] as? pid_t != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 40, rect.height >= 40 else { return nil }
            return Spot(id: id, frame: CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height))
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
        pointerMoved(to: pointer)
    }

    private func finish(_ choice: Choice?) {
        guard let continuation else { return }
        self.continuation = nil
        NSCursor.pop()
        previousApp?.activate()
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        Self.current = nil
        continuation.resume(returning: choice)
    }

    private func redraw() {
        for panel in panels { panel.marks.needsDisplay = true }
    }

    // MARK: - Events

    fileprivate func pointerMoved(to pointer: NSPoint) {
        guard dragStart == nil else { return }
        highlight = windows.first { NSMouseInRect(pointer, $0.frame, false) }?.frame
            ?? NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }?.frame
        redraw()
    }

    fileprivate func pressed(at pointer: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) else { return }
        dragStart = (pointer, screen)
    }

    fileprivate func dragged(to pointer: NSPoint) {
        guard let dragStart else { return }
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
            finish(region(dragged.integral, on: start.screen))
        } else if let window = windows.first(where: { NSMouseInRect(start.point, $0.frame, false) }) {
            finish(.window(window.id))
        } else {
            finish(region(start.screen.frame, on: start.screen))
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

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
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

        if let selection = overlay.selection {
            let cut = local(selection)
            // Everything outside the selection is dimmed, on every screen.
            let shade = NSBezierPath(rect: bounds)
            if cut.intersects(bounds) { shade.append(NSBezierPath(rect: cut)) }
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.4).setFill()
            shade.fill()
            guard cut.intersects(bounds) else { return }
            outline(cut, color: .white)
            label(for: selection, below: cut)
        } else if let highlight = overlay.highlight {
            let rect = local(highlight)
            guard rect.intersects(bounds) else { return }
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            rect.fill()
            outline(rect, color: .controlAccentColor)
        }
    }

    /// A light line with a dark one outside it, visible on any background.
    private func outline(_ rect: CGRect, color: NSColor) {
        let inner = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        inner.lineWidth = 1
        NSColor.black.withAlphaComponent(0.35).setStroke()
        NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5)).stroke()
        color.setStroke()
        inner.stroke()
    }

    /// The size, under the selection's bottom-right corner — or inside it
    /// when that would go off the screen.
    private func label(for selection: CGRect, below rect: CGRect) {
        let text = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let box = CGSize(width: size.width + 12, height: size.height + 6)
        var origin = CGPoint(x: rect.maxX - box.width, y: rect.minY - box.height - 6)
        if origin.y < bounds.minY + 4 { origin.y = rect.minY + 6 }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - box.width - 4)
        let pill = CGRect(origin: origin, size: box)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 3), withAttributes: attributes)
    }
}
