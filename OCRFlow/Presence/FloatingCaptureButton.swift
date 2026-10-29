import AppKit
import Combine
import SwiftUI

/// A small round button that stays above every other window, on every Space
/// and over full-screen apps. A click captures, a drag moves it, and it
/// settles against the nearer side of the screen when let go.
///
/// It never takes focus: clicking it leaves the app in front where it was, so
/// what is about to be captured is not disturbed.
@MainActor
final class FloatingCaptureButton {
    static let diameter: CGFloat = 32
    /// Room around the circle for its shadow and for growing under the pointer.
    static let padding: CGFloat = 8
    static var side: CGFloat { diameter + padding * 2 }
    /// Between the circle and the edge of the screen it rests against.
    static let edgeGap: CGFloat = 6

    private let panel: NSPanel
    private let state = FloatingButtonState()
    private var subscriptions: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?

    init(model: OCRViewModel) {
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
        panel.animationBehavior = .utilityWindow

        let view = FloatingButtonView(state: state)
        view.onClick = { [weak model] in model?.captureScreenshot() }
        view.onDrop = { [weak self] in self?.settle() }
        view.makeMenu = { [weak model] in model.map(Self.menu(model:)) }
        panel.contentView = view

        panel.setFrame(frame(for: Parking.saved), display: false)

        model.$isProcessing.combineLatest(model.$totalProgress)
            .sink { [state] processing, progress in state.progress = processing ? progress : nil }
            .store(in: &subscriptions)
        panel.orderFrontRegardless()

        // A display unplugged or rearranged: back to the same place on
        // whatever screens are left.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.panel.setFrame(self.frame(for: Parking.saved), display: true)
            }
        }
    }

    func close() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        subscriptions.removeAll()
        panel.orderOut(nil)
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
        let travel = area.height - Self.diameter - Self.edgeGap * 2
        let bottom = panel.frame.minY + Self.padding - area.minY - Self.edgeGap
        let parking = Parking(trailing: panel.frame.midX > area.midX,
                              height: travel > 0 ? min(max(bottom / travel, 0), 1) : 0.5,
                              display: screen.displayID)
        parking.save()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame(for: parking), display: true)
        }
    }

    // MARK: - Menu

    private static func menu(model: OCRViewModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuAction.item(String(localized: "Capture Screenshot")) { [weak model] in
            model?.captureScreenshot()
        })
        let again = MenuAction.item(String(localized: "Capture Same Area Again")) { [weak model] in
            model?.captureSameAreaAgain()
        }
        again.isEnabled = model.lastCaptureTarget != nil
        menu.addItem(again)
        menu.addItem(MenuAction.item(String(localized: "Capture Page by Page…")) { [weak model] in
            model?.capturePageByPage()
        })
        menu.addItem(MenuAction.item(String(localized: "Open OCRFlow")) { [weak model] in
            model?.showMainWindow?()
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item(String(localized: "Hide Floating Button")) { [weak model] in
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
private final class FloatingButtonState: ObservableObject {
    @Published var hovered = false
    @Published var pressed = false
    @Published var dragging = false
    /// Faded back after the pointer has been away a while.
    @Published var resting = false
    /// Recognition progress, while a run is going.
    @Published var progress: Double?
}

/// Takes the mouse, and tells a click from a drag. The look is SwiftUI's.
private final class FloatingButtonView: NSView {
    var onClick: () -> Void = {}
    var onDrop: () -> Void = {}
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
            dragging = true
            state.pressed = false
            state.dragging = true
        }
        window.setFrameOrigin(NSPoint(x: dragStart.origin.x + dx, y: dragStart.origin.y + dy))
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
    @ObservedObject var state: FloatingButtonState

    var body: some View {
        let lifted = state.hovered || state.dragging
        ZStack {
            Circle()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(state.dragging ? 0.32 : 0.22),
                        radius: state.dragging ? 5 : 2.5, y: state.dragging ? 2.5 : 1)
            Circle()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            Image(systemName: "text.viewfinder")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            if let progress = state.progress {
                Circle()
                    .inset(by: 1.25)
                    .trim(from: 0, to: max(progress, 0.03))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)
            }
        }
        .frame(width: FloatingCaptureButton.diameter, height: FloatingCaptureButton.diameter)
        .scaleEffect(state.pressed ? 0.9 : lifted ? 1.1 : 1)
        // Faded while it waits, but never while it is showing progress.
        .opacity(state.resting && state.progress == nil ? 0.5 : 1)
        .animation(.snappy(duration: 0.18), value: state.pressed)
        .animation(.snappy(duration: 0.18), value: lifted)
        .animation(.easeInOut(duration: 0.4), value: state.resting)
        .frame(width: FloatingCaptureButton.side, height: FloatingCaptureButton.side)
        .accessibilityHidden(true)
    }
}
