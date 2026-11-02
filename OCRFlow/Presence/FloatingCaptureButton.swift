import AppKit
import SwiftUI

/// A small round button that stays above every other window, on every Space
/// and over full-screen apps. A click captures, a drag moves it, and it
/// settles against the nearer side of the screen when let go.
///
/// With the pointer over it, two more open out of it, below it — above it,
/// near the bottom of the screen: a queue of screenshots, and recording.
/// Each says what it is beside it while the pointer is on it.
///
/// It never takes focus: clicking it leaves the app in front where it was, so
/// what is about to be captured is not disturbed.
@MainActor
final class FloatingCaptureButton {
    /// Big enough to hit without aiming; 32 was easy to miss.
    static let diameter: CGFloat = 48
    /// Room around the circle for its shadow and for growing under the pointer.
    static let padding: CGFloat = 8
    static var side: CGFloat { diameter + padding * 2 }
    /// Between the circle and the edge of the screen it rests against.
    static let edgeGap: CGFloat = 6

    /// Those that open out are a little smaller, and clearly apart.
    static let extraDiameter: CGFloat = 42
    static let gap: CGFloat = 12
    static var extrasHeight: CGFloat { (extraDiameter + gap) * 2 }
    /// Room beside the buttons for what they are called.
    static let labelRoom: CGFloat = 132

    private let panel: NSPanel
    private let state: FloatingButtonState
    private let button: FloatingButtonView
    private let extras: FirstMouseHostingView<FloatingExtras>
    private var screenObserver: NSObjectProtocol?
    /// Closes the others, once the pointer has been away from them a moment.
    private var leaving: Task<Void, Never>?
    /// Where the main button rests, whatever the panel's size.
    private var resting: NSRect = .zero
    /// The others are out, or opening.
    private(set) var isOpen = false

    init(model: OCRViewModel) {
        state = FloatingButtonState(model: model)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Drawn by the face, so it can deepen while dragging.
        panel.hasShadow = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none

        button = FloatingButtonView(state: state)
        extras = FirstMouseHostingView(rootView: FloatingExtras(
            state: state,
            queue: { [weak model] in model?.queueScreenshots() },
            record: { [weak model] in model?.recordMacro() }))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        container.addSubview(extras)
        container.addSubview(button)
        let watch = PointerWatchView(frame: container.bounds)
        watch.autoresizingMask = [.width, .height]
        container.addSubview(watch)
        panel.contentView = container

        button.onClick = { [weak self, weak model] in
            self?.collapse()
            model?.captureScreenshot()
        }
        button.onDrop = { [weak self] in self?.settle() }
        button.onDragStart = { [weak self] in self?.collapse() }
        button.onHover = { [weak self] in self?.expand() }
        watch.moved = { [weak self] in self?.pointer(at: $0) }
        button.makeMenu = { [weak self, weak model] in
            // Closed first: the menu opens where the others would be.
            self?.collapse()
            return model.map(Self.menu(model:))
        }

        rest(at: frame(for: Parking.saved))

        panel.orderFrontRegardless()

        // A display unplugged or rearranged: back to the same place on
        // whatever screens are left.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.collapse()
                self.rest(at: self.frame(for: Parking.saved))
            }
        }
    }

    func close() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        leaving?.cancel()
        panel.orderOut(nil)
    }

    // MARK: - Opening out

    /// Only what is drawn changes: the panel stays where it is, the size it
    /// is. Grown under the pointer as it arrived, a click that came with it
    /// was taken against the panel's old place and lost.
    private func expand() {
        guard !isOpen, !state.dragging else { return }
        isOpen = true
        state.expanded = true
    }

    private func collapse() {
        leaving?.cancel()
        leaving = nil
        guard isOpen else { return }
        isOpen = false
        state.expanded = false
        state.hoveredExtra = nil
    }

    /// Which way they open: down, or up near the bottom of the screen; their
    /// names on the side away from the edge. Settled where the button comes
    /// to rest, while they are closed, so the change is never seen.
    private func orient() {
        let screen = (NSScreen.screens.first { $0.frame.intersects(resting) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let upward = resting.minY - Self.extrasHeight < screen.minY
        let trailing = resting.midX > screen.midX
        if state.upward != upward { state.upward = upward }
        if state.trailing != trailing { state.trailing = trailing }
    }

    /// Rests the main button at `frame`.
    private func rest(at frame: NSRect) {
        resting = frame
        orient()
        layOut(at: resting)
    }

    /// The main button's place in the panel, which holds the others and
    /// room for their names beside it.
    private var mainAt: NSPoint {
        NSPoint(x: state.trailing ? Self.labelRoom : 0, y: state.upward ? 0 : Self.extrasHeight)
    }

    /// The panel with the main button at `place` on screen. It is the one
    /// size, open or closed — closed, the others are not drawn and clicks
    /// go through where they would be — so opening never moves it.
    private func panelFrame(at place: NSRect) -> NSRect {
        NSRect(x: place.minX - mainAt.x, y: place.minY - mainAt.y,
               width: Self.side + Self.labelRoom, height: Self.side + Self.extrasHeight)
    }

    private func layOut(at place: NSRect) {
        let frame = panelFrame(at: place)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            panel.setFrame(frame, display: false)
            button.frame = NSRect(origin: mainAt, size: NSSize(width: Self.side, height: Self.side))
            extras.frame = NSRect(origin: .zero, size: frame.size)
        }
        panel.display()
    }

    /// The pointer at `pointer` over the panel, or off it — nil: which
    /// button it is on, for its name, and closing once it has left them all.
    /// A moment's grace, so crossing a gap, or overshooting a little, does
    /// not close them.
    private func pointer(at pointer: NSPoint?) {
        guard isOpen else { return }
        let circles = circles()
        let on = pointer.flatMap { pointer in circles.dropFirst().firstIndex { $0.insetBy(dx: -3, dy: -3).contains(pointer) } }
        if state.hoveredExtra != on.map({ $0 - 1 }) { state.hoveredExtra = on.map { $0 - 1 } }
        let near = pointer.map { pointer in circles.contains { $0.insetBy(dx: -10, dy: -10).contains(pointer) } } ?? false
        if near {
            leaving?.cancel()
            leaving = nil
        } else if leaving == nil {
            leaving = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.collapse()
            }
        }
    }

    /// The circles on screen: the main one, then the others, nearest first.
    private func circles() -> [NSRect] {
        let main = resting.insetBy(dx: Self.padding, dy: Self.padding)
        let first = (Self.diameter + Self.extraDiameter) / 2 + Self.gap
        return [main] + (0..<2).map { index in
            let distance = first + CGFloat(index) * (Self.extraDiameter + Self.gap)
            let centerY = main.midY + (state.upward ? distance : -distance)
            return NSRect(x: main.midX - Self.extraDiameter / 2, y: centerY - Self.extraDiameter / 2,
                          width: Self.extraDiameter, height: Self.extraDiameter)
        }
    }

    // MARK: - Where it rests

    /// The side of the screen it rests against, and how far up.
    private struct Parking: Codable {
        var trailing = true
        /// 0 at the bottom of the usable area, 1 at the top.
        var height = 0.5
        var display: CGDirectDisplayID?

        static let key = "floatingButton.parking"

        static var saved: Parking {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let parking = try? JSONDecoder().decode(Parking.self, from: data) else { return Parking() }
            return parking
        }

        func save() {
            UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
        }
    }

    private func frame(for parking: Parking) -> NSRect {
        let screen = NSScreen.screens.first { $0.displayID == parking.display }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let inset = Self.edgeGap - Self.padding
        let x = parking.trailing ? area.maxX - Self.side - inset : area.minX + inset
        let travel = max(0, area.height - Self.diameter - Self.edgeGap * 2)
        let y = area.minY + inset + travel * parking.height
        return NSRect(x: x, y: y, width: Self.side, height: Self.side)
    }

    /// After a drag: against the nearer side of the screen it was dropped on,
    /// at the height it was dropped at.
    private func settle() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
                ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        // Where the main button was let go.
        let dropped = button.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        let travel = area.height - Self.diameter - Self.edgeGap * 2
        let bottom = dropped.minY + Self.padding - area.minY - Self.edgeGap
        let parking = Parking(trailing: dropped.midX > area.midX,
                              height: travel > 0 ? min(max(bottom / travel, 0), 1) : 0.5,
                              display: screen.displayID)
        parking.save()
        resting = frame(for: parking)
        // Turned for the side it is going to, where it was let go, then
        // carried there.
        orient()
        layOut(at: dropped)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(panelFrame(at: resting), display: true)
        }
    }

    // MARK: - Menu

    private static func menu(model: OCRViewModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuAction.item(String(localized: "Capture Screenshot")) { [weak model] in
            model?.captureScreenshot()
        })
        menu.addItem(MenuAction.item(String(localized: "Queue Screenshots")) { [weak model] in
            model?.queueScreenshots()
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item(String(localized: "Record Actions…")) { [weak model] in
            model?.recordMacro()
        })
        if !model.macros.macros.isEmpty {
            let run = NSMenuItem(title: String(localized: "Run Recorded Actions"), action: nil, keyEquivalent: "")
            let list = NSMenu()
            list.autoenablesItems = false
            for macro in model.macros.macros {
                let item = MenuAction.item(macro.name) { [weak model] in model?.runMacro(id: macro.id) }
                item.isEnabled = !model.isCapturing && !macro.steps.isEmpty
                list.addItem(item)
            }
            run.submenu = list
            menu.addItem(run)
        }
        menu.addItem(MenuAction.item(String(localized: "Manage Recorded Actions…")) { [weak model] in
            model?.showMacros?()
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item(String(localized: "Open OCRFlow")) { [weak model] in
            model?.showMainWindow?()
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item(String(localized: "Hide Floating Capture Button")) { [weak model] in
            model?.showFloatingButton = false
        })
        return menu
    }
}

/// An `NSMenuItem` that runs a closure. The item holds on to it, since a
/// menu item's target is only a weak reference.
private final class MenuAction: NSObject {
    private let handler: @MainActor () -> Void

    private init(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @MainActor @objc private func run() { handler() }

    @MainActor
    static func item(_ title: String, handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }
}

// MARK: - The button

@MainActor
@Observable
private final class FloatingButtonState {
    /// The others open out of it.
    var expanded = false
    /// Opening out above it, near the bottom of the screen.
    var upward = false
    /// At the right edge of the screen: names show to its left.
    var trailing = true
    /// The one among the others the pointer is on: 0 queue, 1 recording.
    var hoveredExtra: Int?
    var hovered = false
    var pressed = false
    var dragging = false
    /// Faded back after the pointer has been away a while.
    var resting = false

    @ObservationIgnored private weak var model: OCRViewModel?

    init(model: OCRViewModel) {
        self.model = model
    }

    /// Recognition progress, while a run is going.
    var progress: Double? {
        guard let model, model.isProcessing else { return nil }
        return model.totalProgress
    }
}

/// Tells where the pointer is over the panel, and when it leaves — in an
/// app in the background too, which SwiftUI's own hovering is not reliably
/// told of. Clicks go through.
private final class PointerWatchView: NSView {
    /// In screen coordinates; nil when it has left.
    var moved: (NSPoint?) -> Void = { _ in }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { moved(NSEvent.mouseLocation) }
    override func mouseMoved(with event: NSEvent) { moved(NSEvent.mouseLocation) }
    override func mouseExited(with event: NSEvent) { moved(nil) }
}

/// Takes the mouse, and tells a click from a drag. The look is SwiftUI's.
private final class FloatingButtonView: NSView {
    var onClick: () -> Void = {}
    var onDrop: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onHover: () -> Void = {}
    /// Made on each right-click, so what it offers is current.
    var makeMenu: () -> NSMenu? = { nil }

    private let state: FloatingButtonState
    private var dragStart: (pointer: NSPoint, origin: NSPoint)?
    private var dragging = false
    private var restTask: Task<Void, Never>?

    init(state: FloatingButtonState) {
        self.state = state
        let side = FloatingCaptureButton.side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        let face = NSHostingView(rootView: FloatingButtonFace(state: state))
        face.frame = bounds
        face.autoresizingMask = [.width, .height]
        addSubview(face)

        toolTip = String(localized: "Capture Screenshot")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Capture Screenshot"))
        restSoon()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Only the circle is the button; the corners around it let clicks
    /// through to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let reach = FloatingCaptureButton.diameter / 2 + 2
        return hypot(local.x - bounds.midX, local.y - bounds.midY) <= reach ? self : nil
    }

    // The window is never key, so the very first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        restTask?.cancel()
        state.resting = false
        state.hovered = true
        onHover()
    }

    override func mouseExited(with event: NSEvent) {
        state.hovered = false
        restSoon()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        guard let window else { return }
        dragStart = (NSEvent.mouseLocation, window.frame.origin)
        state.pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let window else { return }
        let pointer = NSEvent.mouseLocation
        let dx = pointer.x - dragStart.pointer.x
        let dy = pointer.y - dragStart.pointer.y
        // A hand that wobbles during a click is not a drag.
        if !dragging {
            guard hypot(dx, dy) > 3 else { return }
            onDragStart()
            dragging = true
            state.pressed = false
            state.dragging = true
        }
        guard let origin = self.dragStart?.origin else { return }
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dragging = false
            state.pressed = false
            state.dragging = false
        }
        guard dragStart != nil else { return }
        if dragging {
            onDrop()
        } else if let superview, hitTest(superview.convert(event.locationInWindow, from: nil)) != nil {
            // Let go over the button, not after sliding off it.
            onClick()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    private func restSoon() {
        restTask?.cancel()
        restTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.state.resting = true
        }
    }
}

private struct FloatingButtonFace: View {
    let state: FloatingButtonState

    var body: some View {
        let lifted = state.hovered || state.dragging
        ZStack {
            Circle()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(state.dragging ? 0.32 : 0.22),
                        radius: state.dragging ? 5 : 2.5, y: state.dragging ? 2.5 : 1)
            Circle()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            Image(systemName: "viewfinder")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            if let progress = state.progress {
                Circle()
                    .inset(by: 1.5)
                    .trim(from: 0, to: max(progress, 0.03))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)
            }
        }
        .frame(width: FloatingCaptureButton.diameter, height: FloatingCaptureButton.diameter)
        .scaleEffect(state.pressed ? 0.9 : lifted ? 1.1 : 1)
        // Faded while it waits, but never while it is showing progress.
        .opacity(state.resting && state.progress == nil ? 0.7 : 1)
        .animation(.snappy(duration: 0.18), value: state.pressed)
        .animation(.snappy(duration: 0.18), value: lifted)
        .animation(.easeInOut(duration: 0.4), value: state.resting)
        .frame(width: FloatingCaptureButton.side, height: FloatingCaptureButton.side)
        .accessibilityHidden(true)
    }
}

/// What opens out of the main button: the queue, then recording — recording
/// furthest from it either way — each named beside it under the pointer.
/// The main button is drawn by its own view, over the room left for it here;
/// its name shows here too.
struct FloatingExtras: View {
    fileprivate let state: FloatingButtonState
    let queue: () -> Void
    let record: () -> Void

    var body: some View {
        VStack(spacing: FloatingCaptureButton.gap) {
            if state.upward {
                extra(1)
                extra(0)
                mainRow
            } else {
                mainRow
                extra(0)
                extra(1)
            }
        }
        .padding(.vertical, FloatingCaptureButton.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// From the middle of the main button to the middle of an extra one.
    private static func distance(_ index: Int) -> CGFloat {
        (FloatingCaptureButton.diameter + FloatingCaptureButton.extraDiameter) / 2 + FloatingCaptureButton.gap
            + CGFloat(index) * (FloatingCaptureButton.extraDiameter + FloatingCaptureButton.gap)
    }

    /// The main button's place, and its name while the pointer is on it.
    private var mainRow: some View {
        row("Capture Screenshot", named: state.expanded && state.hovered && state.hoveredExtra == nil) {
            Color.clear.frame(width: FloatingCaptureButton.diameter, height: FloatingCaptureButton.diameter)
        }
    }

    private func extra(_ index: Int) -> some View {
        let isQueue = index == 0
        let hovered = state.hoveredExtra == index
        let name: LocalizedStringKey = isQueue ? "Queue Screenshots" : "Record Actions"
        // Plain like the main button until pointed at; then the colour of
        // what it does.
        let tint: Color = isQueue ? .accentColor : .red
        return row(name, named: hovered) {
            Button(action: isQueue ? queue : record) {
                Image(systemName: isQueue ? "square.on.square.dashed" : "record.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(hovered ? Color.white : Color.primary.opacity(0.75))
                    .frame(width: FloatingCaptureButton.extraDiameter, height: FloatingCaptureButton.extraDiameter)
                    .background {
                        Circle()
                            .fill(hovered ? AnyShapeStyle(tint) : AnyShapeStyle(.regularMaterial))
                            .shadow(color: .black.opacity(0.2), radius: 2.5, y: 1)
                    }
                    .overlay(Circle().strokeBorder(Color.primary.opacity(hovered ? 0 : 0.12), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .scaleEffect(hovered ? 1.06 : 1)
            .animation(.snappy(duration: 0.15), value: hovered)
            .accessibilityLabel(Text(name))
            // Springing straight out of the main button as it opens: from
            // its middle, up or down. The circle alone grows, about its own
            // middle — the whole row, room for the name and all, would grow
            // about the row's middle and carry the circle in from the side.
            .scaleEffect(state.expanded ? 1 : 0.6)
            .offset(y: state.expanded ? 0 : (state.upward ? 1 : -1) * Self.distance(index))
            .opacity(state.expanded ? 1 : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.78).delay(Double(index) * 0.03), value: state.expanded)
        }
    }

    /// A button in the column against the screen's edge, its name on the
    /// inner side.
    private func row(_ name: LocalizedStringKey, named: Bool, @ViewBuilder circle: () -> some View) -> some View {
        HStack(spacing: 6) {
            if state.trailing {
                Spacer(minLength: 0)
                label(name, shown: named)
            }
            circle()
                .frame(width: FloatingCaptureButton.side)
            if !state.trailing {
                label(name, shown: named)
                Spacer(minLength: 0)
            }
        }
    }

    private func label(_ name: LocalizedStringKey, shown: Bool) -> some View {
        Text(name)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(shown ? 1 : 0)
            .offset(x: shown ? 0 : (state.trailing ? 6 : -6))
            .animation(.easeOut(duration: 0.12), value: shown)
    }
}
