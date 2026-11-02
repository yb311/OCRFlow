import AppKit
import Carbon.HIToolbox

/// Holds the screen still and lets the user choose what to capture: drag out
/// a part of it, or click a window. Clicking where there is no window takes
/// the whole display.
///
/// The screens are shown as they were the moment capture started, so menus,
/// tooltips and hover states are kept, and what is cut out is exactly what
/// was seen.
///
/// It is the screen of the whole capture, from choosing to the end: once
/// something is chosen it stays, dimmed around it, outlined, its size shown,
/// while the bar asks what to do with it — and while a long screenshot
/// scrolls it, the held picture gone (`goLive()`) and the marks the same
/// marks. Nothing comes and goes in between. Whoever asked closes it.
///
/// While choosing, the pointer is a crosshair of lines across the screen,
/// drawn here, the system's own hidden: the app in front keeps setting its
/// own pointer as it moves. Once chosen, whoever goes on over it may let
/// the area be adjusted (`beginAdjusting`): its edges and corners dragged,
/// itself dragged by its middle, the arrow keys moving it a point at a time,
/// its width and height typed into the size. Its pointer is drawn the same
/// way, over this screen.
///
/// OCRFlow never comes in front for it: the app the user is in stays where
/// it is, and so do OCRFlow's own windows — an app coming in front brings
/// its windows with it, with Stage Manager onto the stage.
@MainActor
final class CaptureOverlay {
    private enum Choice {
        /// Cut from the held picture, which is already the result.
        case region(CaptureTarget, CGImage)
        /// Taken by itself afterwards, without what is in front of it.
        case window(CGWindowID)
    }

    init(shots: [CGDirectDisplayID: CGImage]) {
        self.shots = shots
        windows = Self.windowsFrontToBack()
    }

    /// False when the user cancels, and then it is gone; otherwise it stays
    /// up around what was chosen, `chosen`, until `close()`.
    func choose() async throws -> Bool {
        let choice = await withCheckedContinuation { continuation in
            self.continuation = continuation
            show()
        }
        switch choice {
        case nil:
            return false
        case let .region(target, image):
            chosen = (image, target)
        case let .window(id):
            chosen = (try await ScreenGrabber.capture(.window(id)), .window(id))
        }
        return true
    }

    /// Up around `area`, in screen coordinates, as though it had just been
    /// chosen there: the last one again, say.
    func show(around area: CGRect) {
        self.area = area
        let screen = NSScreen.screens.first { $0.frame.intersects(area) }
        if let screen, case let .region(target, image)? = region(area.intersection(screen.frame), on: screen) {
            chosen = (image, target)
        }
        putUp()
        redraw()
    }

    /// What was chosen, in screen coordinates.
    private(set) var area: CGRect?
    /// What was chosen, as it is now: as it was taken, or — once adjusted —
    /// cut again from the held picture, a window then an area like any other.
    private(set) var chosen: (image: CGImage, target: CaptureTarget)?

    /// A double-click on what was chosen, once it is.
    var onDoubleClick: () -> Void = {}

    /// The held picture goes: what is beneath shows, live, and clicks and
    /// the wheel reach it — around what was chosen still dimmed, as before.
    /// Adjusting, its edges and size still take the pointer.
    func goLive() {
        isLive = true
        updateBackgroundCursor()
        for panel in panels { panel.goLive() }
    }

    func close() {
        if isChoosing { finish(nil) }
        endAdjusting()
        ticker?.stop()
        ticker = nil
        hideSystemCursor(false)
        BackgroundCursor.allow(false)
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    // MARK: - Adjusting

    /// From now until `endAdjusting()`, what was chosen can be changed —
    /// kept to the screen it is on, on whole points — and `changed` is told
    /// of each change, `area` and `chosen` already as changed.
    func beginAdjusting(_ changed: @escaping (CGRect) -> Void) {
        guard adjusting == nil, let area else { return }
        var keys: [(keyCode: Int, modifiers: Int, action: () -> Void)] = []
        for (key, dx, dy) in [(kVK_LeftArrow, -1, 0), (kVK_RightArrow, 1, 0), (kVK_DownArrow, 0, -1), (kVK_UpArrow, 0, 1)] {
            let (dx, dy) = (CGFloat(dx), CGFloat(dy))
            // A point at a time; ten with ⇧; with ⌘ the bottom-right corner,
            // the size, as the size typed in changes it.
            keys.append((key, 0, { [weak self] in self?.adjust { $0.moved(by: CGVector(dx: dx, dy: dy), within: $1) } }))
            keys.append((key, shiftKey, { [weak self] in
                self?.adjust { $0.moved(by: CGVector(dx: 10 * dx, dy: 10 * dy), within: $1) }
            }))
            keys.append((key, cmdKey, { [weak self] in
                self?.adjust { $0.adjusted(dx != 0 ? .right : .bottom, by: CGVector(dx: dx, dy: dy), within: $1) }
            }))
        }
        adjusting = Adjusting(bounds: CaptureMarks.wholeScreen(for: area), changed: changed, keys: GlobalHotKey.claim(keys))
        redraw()
    }

    /// A size being typed is taken as it is — unless not `applyingTyping`:
    /// it is too late for it to count.
    func endAdjusting(applyingTyping: Bool = true) {
        guard let adjusting else { return }
        finishTyping(applying: applyingTyping)
        GlobalHotKey.release(adjusting.keys)
        self.adjusting = nil
        areaDrag = nil
        redraw()
    }

    /// An edge, a corner or the whole being dragged.
    var isDraggingArea: Bool { areaDrag != nil }

    private struct Adjusting {
        /// The screen it is kept to.
        let bounds: CGRect
        let changed: (CGRect) -> Void
        let keys: [GlobalHotKey]
    }

    fileprivate enum SizeField { case width, height }

    /// The size, as it is being typed: `fresh` until the first key, which
    /// then replaces what was there.
    private struct Typing {
        var field: SizeField
        var text: String
        var fresh = true
    }

    private var adjusting: Adjusting?
    private var areaDrag: (grip: AreaGrip, start: NSPoint, area: CGRect)?
    private var typing: Typing?
    private var typingKeys: [GlobalHotKey] = []

    fileprivate var isAdjustable: Bool { adjusting != nil }

    private func adjust(_ change: (CGRect, CGRect) -> CGRect) {
        guard let adjusting, let area else { return }
        apply(change(area.kept(within: adjusting.bounds), adjusting.bounds))
    }

    /// The area now `new`, and the picture cut from the held one again.
    private func apply(_ new: CGRect) {
        guard let adjusting, new != area,
              let screen = NSScreen.screens.first(where: { $0.frame == adjusting.bounds }),
              case let .region(target, image)? = region(new, on: screen) else { return }
        area = new
        chosen = (image, target)
        redraw()
        adjusting.changed(new)
    }

    private func type(into field: SizeField) {
        guard area != nil, typing?.field != field else { return }
        if typing == nil {
            var keys: [(keyCode: Int, modifiers: Int, action: () -> Void)] = []
            let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                          kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            let keypad = [kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
                          kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
            for (digit, key) in Array(zip(0..., digits)) + zip(0..., keypad) {
                keys.append((key, 0, { [weak self] in self?.typed(digit) }))
            }
            keys += [
                (kVK_Delete, 0, { [weak self] in self?.typed(nil) }),
                (kVK_ForwardDelete, 0, { [weak self] in self?.typed(nil) }),
                (kVK_Tab, 0, { [weak self] in self?.type(into: self?.typing?.field == .width ? .height : .width) }),
                (kVK_Return, 0, { [weak self] in self?.finishTyping(applying: true) }),
                (kVK_ANSI_KeypadEnter, 0, { [weak self] in self?.finishTyping(applying: true) }),
                (kVK_Escape, 0, { [weak self] in self?.finishTyping(applying: false) }),
                // Nothing else of the bar's while typing.
                (kVK_Space, 0, {}),
            ]
            typingKeys = GlobalHotKey.claim(keys)
        } else {
            applyTyping()
        }
        guard let area else { return }
        let value = field == .width ? area.width : area.height
        typing = Typing(field: field, text: String(Int(value.rounded())))
        redraw()
    }

    /// A digit, or nil: the last one taken away.
    private func typed(_ digit: Int?) {
        guard var typing else { return }
        if typing.fresh { typing.text = "" }
        typing.fresh = false
        if let digit {
            if typing.text.count < 5, !(typing.text.isEmpty && digit == 0) { typing.text += String(digit) }
        } else if !typing.text.isEmpty {
            typing.text.removeLast()
        }
        self.typing = typing
        redraw()
    }

    private func applyTyping() {
        guard let typing, let value = Int(typing.text), value > 0 else { return }
        adjust { area, bounds in
            let size = typing.field == .width ? CGSize(width: CGFloat(value), height: area.height)
                                              : CGSize(width: area.width, height: CGFloat(value))
            return area.resized(to: size, within: bounds)
        }
    }

    private func finishTyping(applying: Bool) {
        guard typing != nil else { return }
        if applying { applyTyping() }
        typing = nil
        GlobalHotKey.release(typingKeys)
        typingKeys = []
        redraw()
    }

    /// The size, laid out as it is drawn: the width, " × ", the height.
    fileprivate struct SizeLabel {
        let pill: CGRect
        let parts: [(text: String, frame: CGRect)]
        /// The part being typed into, and whether nothing has been typed yet.
        let typing: (part: Int, fresh: Bool)?
    }

    fileprivate static let sizeAttributes: [NSAttributedString.Key: Any] = [
        .font: CaptureMarks.sizeFont,
        .foregroundColor: NSColor.white,
    ]

    /// In screen coordinates.
    fileprivate var sizeLabel: SizeLabel? {
        guard let chosen = area ?? selection ?? highlight else { return nil }
        let size = CaptureMarks.sizeText(for: chosen).components(separatedBy: " × ")
        var texts = [size.first ?? "", " × ", size.last ?? ""]
        if let typing { texts[typing.field == .width ? 0 : 2] = typing.text }
        let widths = texts.map { max(ceil(($0 as NSString).size(withAttributes: Self.sizeAttributes).width), 2) }
        let height = ceil(("0" as NSString).size(withAttributes: Self.sizeAttributes).height)
        let padding = CaptureMarks.sizePadding
        let box = CGSize(width: widths.reduce(0, +) + 2 * padding.width, height: height + 2 * padding.height)
        let pill = CaptureMarks.sizeLabelFrame(size: box, for: chosen)
        var x = pill.minX + padding.width
        let parts = zip(texts, widths).map { text, width in
            defer { x += width }
            return (text, CGRect(x: x, y: pill.minY + padding.height, width: width, height: height))
        }
        return SizeLabel(pill: pill, parts: parts, typing: typing.map { ($0.field == .width ? 0 : 2, $0.fresh) })
    }

    private func sizeField(at point: NSPoint) -> SizeField? {
        guard isAdjustable, let label = sizeLabel, NSMouseInRect(point, label.pill.insetBy(dx: -2, dy: -2), false)
        else { return nil }
        return point.x < label.parts[1].frame.midX ? .width : .height
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
    private let windows: [Layer]
    /// The last spot found, and where: pointing within it again finds it
    /// again without asking.
    private var lastSpot: (window: CGWindowID, spot: Spot)?
    private var panels: [OverlayWindow] = []
    private var continuation: CheckedContinuation<Choice?, Never>?
    /// Escape, while choosing.
    private var keys: [GlobalHotKey] = []

    /// Where a drag started, and the screen it is kept to.
    private var dragStart: (point: NSPoint, screen: NSScreen)?
    /// Being dragged out, in screen coordinates.
    private(set) var selection: CGRect?
    /// What a click would take.
    private(set) var highlight: CGRect?
    private var isLive = false
    /// Follows the pointer, whatever events the windows are sent.
    private var ticker: Ticker?
    private var lastPointer: NSPoint?
    private var lastLook: PointerLook?
    private var systemCursorHidden = false

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
        putUp()
        guard !panels.isEmpty else { return finish(nil) }

        // OCRFlow stays in the background, none of its windows key — see
        // `CaptureBar`. Escape is claimed meanwhile.
        keys = GlobalHotKey.claim([(kVK_Escape, 0, { [weak self] in self?.cancel() })])
        redraw()
    }

    private func putUp() {
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let shot = shots[id] else { continue }
            let panel = OverlayWindow(screen: screen, shot: shot, overlay: self)
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        updateBackgroundCursor()
        if ticker == nil, let screen = NSScreen.main ?? NSScreen.screens.first {
            ticker = Ticker(screen: screen) { [weak self] in self?.tick() }
        }
        tick()
    }

    /// `area`: what was chosen, in screen coordinates.
    private func finish(_ choice: Choice?, area: CGRect? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        GlobalHotKey.release(keys)
        keys = []
        selection = nil
        highlight = nil
        if choice != nil, let area {
            self.area = area
            redraw()
            tick()
        } else {
            close()
        }
        continuation.resume(returning: choice)
    }

    /// Choosing is over once something is chosen; the screen stays up.
    fileprivate var isChoosing: Bool { continuation != nil }

    private func redraw() {
        for panel in panels { panel.marks.needsDisplay = true }
    }

    // MARK: - The pointer

    /// What the pointer is drawn as over this screen; nil where the
    /// system's own is shown: over the bar and the other marks, where
    /// nothing here is to be done, and — live — over what is beneath.
    private func look(at pointer: NSPoint) -> PointerLook? {
        let overAMark = NSApp.windows.contains {
            $0.isVisible && $0.level >= CaptureMarks.level && NSMouseInRect(pointer, $0.frame, false)
        }
        guard !overAMark, NSScreen.screens.contains(where: { NSMouseInRect(pointer, $0.frame, false) }) else { return nil }
        if isChoosing { return .crosshair }
        guard isAdjustable, let area else { return nil }
        if let areaDrag { return areaDrag.grip.isEmpty ? .moving : .resize(areaDrag.grip) }
        if sizeField(at: pointer) != nil { return .text }
        guard let grip = AreaGrip.at(pointer, of: area) else { return isLive ? nil : .arrow }
        if grip.isEmpty { return isLive ? nil : .move }
        return .resize(grip)
    }

    /// Each time the screen is drawn, the pointer read where it is: live, it
    /// is over another app's window, which is sent its moves rather than
    /// OCRFlow, and the pointer drawn here has to follow it frame by frame
    /// either way.
    private func tick() {
        let pointer = NSEvent.mouseLocation
        let look = look(at: pointer)
        if pointer != lastPointer, isChoosing, dragStart == nil { pointerMoved(to: pointer) }
        guard pointer != lastPointer || look != lastLook else { return }
        lastPointer = pointer
        lastLook = look
        // Live, the pointer is taken only where the area is adjusted.
        if isLive {
            let takes = look != nil || areaDrag != nil
            for panel in panels where panel.ignoresMouseEvents == takes { panel.ignoresMouseEvents = !takes }
        }
        hideSystemCursor(look != nil)
        for panel in panels {
            panel.pointer.show(NSMouseInRect(pointer, panel.frame, false) ? look : nil,
                               at: CGPoint(x: pointer.x - panel.frame.minX, y: pointer.y - panel.frame.minY))
        }
    }

    /// Hidden from the background too, once allowed — see `BackgroundCursor`.
    /// Balanced: shown again on every way out, by `close()`.
    private func hideSystemCursor(_ hidden: Bool) {
        guard hidden != systemCursorHidden else { return }
        systemCursorHidden = hidden
        if hidden {
            updateBackgroundCursor()
            CGDisplayHideCursor(CGMainDisplayID())
        } else {
            CGDisplayShowCursor(CGMainDisplayID())
            updateBackgroundCursor()
        }
    }

    /// Live, the app beneath sets the pointer — but while it is hidden here.
    private func updateBackgroundCursor() {
        BackgroundCursor.allow(!isLive || systemCursorHidden)
    }

    // MARK: - Events

    /// Nothing is picked out before the pointer first moves: the whole
    /// screen is dimmed, as on being asked to choose.
    private func pointerMoved(to pointer: NSPoint) {
        guard isChoosing, dragStart == nil, lastPointer != nil else { return }
        highlight = spot(at: pointer)?.frame
            ?? NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }?.frame
        redraw()
    }

    fileprivate func pressed(at pointer: NSPoint, clickCount: Int) {
        guard !isChoosing else {
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) else { return }
            dragStart = (pointer, screen)
            return
        }
        guard let area else { return }
        if let field = sizeField(at: pointer) { return type(into: field) }
        finishTyping(applying: true)
        if clickCount == 2, NSMouseInRect(pointer, area, false) { return onDoubleClick() }
        guard let adjusting, let grip = AreaGrip.at(pointer, of: area), !(isLive && grip.isEmpty) else { return }
        areaDrag = (grip, pointer, area.kept(within: adjusting.bounds))
        tick()
    }

    fileprivate func dragged(to pointer: NSPoint) {
        if let areaDrag, let adjusting {
            let offset = CGVector(dx: pointer.x - areaDrag.start.x, dy: pointer.y - areaDrag.start.y)
            apply(areaDrag.area.adjusted(areaDrag.grip, by: offset, within: adjusting.bounds))
            return
        }
        guard isChoosing, let dragStart else { return }
        let frame = dragStart.screen.frame
        var pointer = pointer
        // Kept to the screen the drag started on.
        pointer.x = min(max(pointer.x, frame.minX), frame.maxX)
        pointer.y = min(max(pointer.y, frame.minY), frame.maxY)
        let rect = CGRect(draggedFrom: dragStart.point, to: pointer)
        // A hand that wobbles during a click is not a drag.
        guard selection != nil || hypot(rect.width, rect.height) > 3 else { return }
        selection = rect
        highlight = nil
        redraw()
    }

    fileprivate func released() {
        if areaDrag != nil {
            areaDrag = nil
            tick()
            return
        }
        guard let start = dragStart else { return }
        dragStart = nil
        let dragged = selection
        selection = nil
        // Big enough to hold any text; anything smaller was meant as a click.
        if let dragged, dragged.width >= 4, dragged.height >= 4 {
            finish(region(dragged, on: start.screen), area: dragged)
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

extension CGRect {
    /// Dragged out from `a` to `b`, its edges on whole points: what is shown
    /// while dragging is exactly what is taken, its size the one shown.
    init(draggedFrom a: CGPoint, to b: CGPoint) {
        let (a, b) = (CGPoint(x: a.x.rounded(), y: a.y.rounded()), CGPoint(x: b.x.rounded(), y: b.y.rounded()))
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The part of it within `bounds`, its edges on whole points — a window
    /// partly off the screen, say, about to be adjusted. At least a point
    /// each way.
    func kept(within bounds: CGRect) -> CGRect {
        let shared = intersection(bounds)
        guard !shared.isNull else { return CGRect(x: bounds.minX, y: bounds.minY, width: 1, height: 1) }
        return Self.spanning(x: (shared.minX.rounded(), shared.maxX.rounded()), y: (shared.minY.rounded(), shared.maxY.rounded()),
                             within: bounds)
    }

    /// The edges `grip` names moved by `offset` — all of it, when it names
    /// none — on whole points and within `bounds`. An edge dragged past the
    /// one across from it turns it inside out, as dragging it out did.
    func adjusted(_ grip: AreaGrip, by offset: CGVector, within bounds: CGRect) -> CGRect {
        guard !grip.isEmpty else { return moved(by: offset, within: bounds) }
        func clamped(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(value.rounded(), low), high) }
        var x = (minX, maxX), y = (minY, maxY)
        if grip.contains(.left) { x.0 = clamped(minX + offset.dx, bounds.minX, bounds.maxX) }
        if grip.contains(.right) { x.1 = clamped(maxX + offset.dx, bounds.minX, bounds.maxX) }
        if grip.contains(.bottom) { y.0 = clamped(minY + offset.dy, bounds.minY, bounds.maxY) }
        if grip.contains(.top) { y.1 = clamped(maxY + offset.dy, bounds.minY, bounds.maxY) }
        return Self.spanning(x: x, y: y, within: bounds)
    }

    /// Moved by `offset`, as large as it is, on whole points and kept
    /// within `bounds`: pushed against an edge, it stops there.
    func moved(by offset: CGVector, within bounds: CGRect) -> CGRect {
        let width = min(width, bounds.width), height = min(height, bounds.height)
        let x = min(max((minX + offset.dx).rounded(), bounds.minX), bounds.maxX - width)
        let y = min(max((minY + offset.dy).rounded(), bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// As large as `size`, in whole points, its top-left corner where it
    /// is — or moved up and left as far as it must be to stay in `bounds`,
    /// and no larger than they are.
    func resized(to size: CGSize, within bounds: CGRect) -> CGRect {
        let width = min(max(size.width.rounded(), 1), bounds.width)
        let height = min(max(size.height.rounded(), 1), bounds.height)
        let x = min(max(minX, bounds.minX), bounds.maxX - width)
        let top = max(min(maxY, bounds.maxY), bounds.minY + height)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// Between the two edges each way, whichever is first; a point wide at
    /// least, more of `bounds` taken for it where there is no room.
    private static func spanning(x: (CGFloat, CGFloat), y: (CGFloat, CGFloat), within bounds: CGRect) -> CGRect {
        func span(_ a: CGFloat, _ b: CGFloat, _ low: CGFloat, _ high: CGFloat) -> (CGFloat, CGFloat) {
            let (start, end) = (min(a, b), max(a, b))
            guard end - start < 1 else { return (start, end) }
            return start + 1 <= high ? (start, start + 1) : (high - 1, high)
        }
        let (x0, x1) = span(x.0, x.1, bounds.minX, bounds.maxX)
        let (y0, y1) = span(y.0, y.1, bounds.minY, bounds.maxY)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// The edges of a chosen area a drag takes hold of: one, or two at a
/// corner; none, in the middle, and the whole of it moves.
struct AreaGrip: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let left = AreaGrip(rawValue: 1)
    static let right = AreaGrip(rawValue: 2)
    static let bottom = AreaGrip(rawValue: 4)
    static let top = AreaGrip(rawValue: 8)

    /// How near an edge, in points, inside or out, takes hold of it.
    static let reach: CGFloat = 6

    /// What a drag from `point` takes hold of; nil, away from the area. An
    /// area too small to have a middle has only edges, the nearest taken.
    static func at(_ point: CGPoint, of area: CGRect) -> AreaGrip? {
        guard area.insetBy(dx: -reach, dy: -reach).contains(point) else { return nil }
        var grip: AreaGrip = []
        let (left, right) = (abs(point.x - area.minX), abs(point.x - area.maxX))
        if min(left, right) <= reach { grip.insert(left <= right ? .left : .right) }
        let (bottom, top) = (abs(point.y - area.minY), abs(point.y - area.maxY))
        if min(bottom, top) <= reach { grip.insert(bottom <= top ? .bottom : .top) }
        return grip
    }
}

/// The pointer set — or hidden — by OCRFlow while another app is in front.
/// The window server takes cursor changes only from the active app, unless a
/// connection property it has long had, `SetsCursorInBackground`, says
/// otherwise — what screenshot tools rely on. Not public: looked up at run
/// time, and without it the system's pointer shows over the one drawn.
@MainActor
private enum BackgroundCursor {
    private typealias Connection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private static let functions: (Connection, SetProperty)? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let connection = dlsym(handle, "CGSMainConnectionID"),
              let setProperty = dlsym(handle, "CGSSetConnectionProperty") else { return nil }
        return (unsafeBitCast(connection, to: Connection.self), unsafeBitCast(setProperty, to: SetProperty.self))
    }()

    static func allow(_ allowed: Bool) {
        guard let (connection, setProperty) = functions else { return }
        let id = connection()
        _ = setProperty(id, id, "SetsCursorInBackground" as CFString, allowed ? kCFBooleanTrue : kCFBooleanFalse)
    }
}

// MARK: - One screen

private final class OverlayWindow: NSPanel {
    let marks: OverlayMarks
    let pointer: PointerMarks
    private let held: NSView

    init(screen: NSScreen, shot: CGImage, overlay: CaptureOverlay) {
        marks = OverlayMarks(overlay: overlay)
        held = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        pointer = PointerMarks(frame: held.bounds)
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

        held.wantsLayer = true
        held.layer?.contents = shot
        held.layer?.contentsGravity = .resize
        for view in [marks, pointer] as [NSView] {
            view.frame = held.bounds
            view.autoresizingMask = [.width, .height]
            held.addSubview(view)
        }
        contentView = held
    }

    /// What is beneath shows through and takes the mouse; the marks stay.
    func goLive() {
        held.layer?.contents = nil
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = true
    }
}

/// The app's own green, as its controls show it.
@MainActor
private let themeColor = NSColor(named: "AccentColor") ?? .systemGreen

/// Draws the highlight or the selection over the held picture, and takes the
/// mouse.
private final class OverlayMarks: NSView {
    private weak var overlay: CaptureOverlay?

    init(overlay: CaptureOverlay) {
        self.overlay = overlay
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { overlay?.pressed(at: pointer(of: event), clickCount: event.clickCount) }
    override func mouseDragged(with event: NSEvent) { overlay?.dragged(to: pointer(of: event)) }
    override func mouseUp(with event: NSEvent) { overlay?.released() }
    override func rightMouseDown(with event: NSEvent) { overlay?.cancel() }

    /// In screen coordinates.
    private func pointer(of event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let window, let overlay else { return }
        let origin = window.frame.origin
        func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -origin.x, dy: -origin.y) }

        // What a release would take — the area dragged out, or the window
        // under the pointer — stands out bright; everything else, on every
        // screen, is dimmed. Before the pointer has moved, all of it is.
        // Once chosen, it stays so for as long as the capture goes on.
        guard let chosen = overlay.area ?? overlay.selection ?? overlay.highlight else {
            CaptureShade.draw(in: bounds, around: .null)
            return
        }
        let cut = local(chosen)
        CaptureShade.draw(in: bounds, around: cut, grips: overlay.isAdjustable)
        guard cut.intersects(bounds), let label = overlay.sizeLabel else { return }
        // The size, where it stays once the bar shows; its numbers typed
        // into, adjusting.
        let pill = local(label.pill)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        for (index, part) in label.parts.enumerated() {
            let frame = local(part.frame)
            if let typing = label.typing, typing.part == index {
                if typing.fresh {
                    themeColor.setFill()
                    NSBezierPath(roundedRect: frame.insetBy(dx: -2, dy: -1), xRadius: 2, yRadius: 2).fill()
                } else {
                    NSColor.white.setFill()
                    CGRect(x: frame.maxX + 0.5, y: frame.minY, width: 1, height: frame.height).fill()
                }
            }
            (part.text as NSString).draw(at: frame.origin, withAttributes: CaptureOverlay.sizeAttributes)
        }
    }
}

/// All but what is chosen dimmed, with a thin line of the app's green round
/// it — and, while it can be adjusted, a dot at each corner and edge.
private enum CaptureShade {
    @MainActor static func draw(in bounds: CGRect, around cut: CGRect, grips: Bool = false) {
        let shade = NSBezierPath(rect: bounds)
        if cut.intersects(bounds) { shade.append(NSBezierPath(rect: cut)) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.4).setFill()
        shade.fill()
        guard cut.intersects(bounds) else { return }
        // Just outside: what is taken shows whole.
        let line = NSBezierPath(rect: cut.insetBy(dx: -0.5, dy: -0.5))
        line.lineWidth = 1
        themeColor.setStroke()
        line.stroke()
        guard grips else { return }
        var dots = [CGPoint(x: cut.minX, y: cut.minY), CGPoint(x: cut.maxX, y: cut.minY),
                    CGPoint(x: cut.minX, y: cut.maxY), CGPoint(x: cut.maxX, y: cut.maxY)]
        if cut.width >= 40 { dots += [CGPoint(x: cut.midX, y: cut.minY), CGPoint(x: cut.midX, y: cut.maxY)] }
        if cut.height >= 40 { dots += [CGPoint(x: cut.minX, y: cut.midY), CGPoint(x: cut.maxX, y: cut.midY)] }
        for dot in dots {
            let circle = NSBezierPath(ovalIn: CGRect(x: dot.x - 3.5, y: dot.y - 3.5, width: 7, height: 7))
            themeColor.setFill()
            circle.fill()
            circle.lineWidth = 1
            NSColor.white.setStroke()
            circle.stroke()
        }
    }
}

/// What the pointer is drawn as over the capture screen.
private enum PointerLook: Equatable {
    /// Lines across the screen through it, while choosing.
    case crosshair
    case arrow
    /// The size, to type into.
    case text
    /// The middle of the area, to move it by; and moving it.
    case move, moving
    case resize(AreaGrip)

    @MainActor var cursor: NSCursor {
        switch self {
        case .crosshair, .arrow: .arrow
        case .text: .iBeam
        case .move: .openHand
        case .moving: .closedHand
        case let .resize(grip):
            .frameResize(position: Self.position(of: grip), directions: .all)
        }
    }

    private static func position(of grip: AreaGrip) -> NSCursor.FrameResizePosition {
        switch (grip.contains(.left), grip.contains(.right), grip.contains(.top), grip.contains(.bottom)) {
        case (true, _, true, _): .topLeft
        case (true, _, _, true): .bottomLeft
        case (_, true, true, _): .topRight
        case (_, true, _, true): .bottomRight
        case (true, _, _, _): .left
        case (_, true, _, _): .right
        case (_, _, true, _): .top
        default: .bottom
        }
    }
}

/// The pointer, drawn: the crosshair's lines, or the system's own pointer
/// for what is under it, its hot spot on the pointer.
private final class PointerMarks: NSView {
    private let across = CALayer(), down = CALayer(), cursor = CALayer()
    private var shown: PointerLook?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for line in [across, down] {
            line.backgroundColor = themeColor.cgColor
            line.isHidden = true
            layer?.addSublayer(line)
        }
        cursor.isHidden = true
        layer?.addSublayer(cursor)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Nil hides it. `point` is in the window's coordinates.
    func show(_ look: PointerLook?, at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // On whole points, where the edge of an area dragged out from here
        // would be.
        let x = point.x.rounded(), y = point.y.rounded()
        across.isHidden = look != .crosshair
        down.isHidden = look != .crosshair
        across.frame = CGRect(x: 0, y: y - 0.5, width: bounds.width, height: 1)
        down.frame = CGRect(x: x - 0.5, y: 0, width: 1, height: bounds.height)
        guard let look, look != .crosshair else {
            cursor.isHidden = true
            return
        }
        let shape = look.cursor
        let image = shape.image
        if look != shown {
            let scale = window?.backingScaleFactor ?? 2
            cursor.contents = image.layerContents(forContentsScale: scale)
            cursor.contentsScale = image.recommendedLayerContentsScale(scale)
            shown = look
        }
        cursor.frame = CGRect(x: point.x - shape.hotSpot.x, y: point.y - (image.size.height - shape.hotSpot.y),
                              width: image.size.width, height: image.size.height)
        cursor.isHidden = false
    }
}

/// Calls `tick` each time the screen is drawn, on the main thread.
@MainActor
private final class Ticker: NSObject {
    private let tick: () -> Void
    private var link: CADisplayLink?

    init(screen: NSScreen, tick: @escaping () -> Void) {
        self.tick = tick
        super.init()
        link = screen.displayLink(target: self, selector: #selector(step(_:)))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func step(_ link: CADisplayLink) { tick() }

    func stop() {
        link?.invalidate()
        link = nil
    }
}
