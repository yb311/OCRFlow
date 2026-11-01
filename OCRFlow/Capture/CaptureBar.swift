import AppKit
import SwiftUI

/// What to do with what was captured, chosen there and then.
enum CaptureFinish: Sendable {
    case recognize
    /// Scroll on from here, into one long picture.
    case longCapture
    case save
    case copy
    /// Keep it as it is: a long screenshot that is a step of a recording.
    case done
    case cancel
}

/// Shown once a screenshot is taken: its size above what was chosen, and
/// under it a row of buttons — recognize the text, scroll on for a long
/// screenshot, cancel, save, copy. Recognizing is one choice among others; a
/// screenshot is often wanted as a picture.
///
/// Over the held screen, when the choice left it up: the screen stays as it
/// was while choosing, and nothing beneath answers until the bar is done
/// with. The caller takes the held screen away afterwards.
///
/// Return copies, Space saves, Escape or a right-click lets it go, and a
/// double-click on what was chosen copies it.
@MainActor
final class CaptureBar {
    /// `area` is what was chosen, in screen coordinates.
    static func choose(around area: CGRect) async -> CaptureFinish {
        let bar = CaptureBar()
        current = bar
        defer { current = nil }
        return await withCheckedContinuation { continuation in
            bar.continuation = continuation
            bar.show(around: area)
        }
    }

    /// Kept alive while it waits.
    private static var current: CaptureBar?

    private var continuation: CheckedContinuation<CaptureFinish, Never>?
    private var panels: [NSPanel] = []
    private var monitors: [Any] = []

    private func show(around area: CGRect) {
        // As it looked while being chosen: the held screen, dimmed around
        // it and with its size, or the same drawn over the live one.
        let held = CaptureOverlay.keepLingering()
        let shades = held ? [] : CaptureMarks.shades(around: area) + [CaptureMarks.sizeLabel(for: area)]
        let catcher = CaptureMarks.outline(area, catchesClicks: true)
        (catcher.contentView as? OutlineView)?.onDoubleClick = { [weak self] in self?.finish(.copy) }
        let bar = CaptureMarks.bar(CaptureActionsBar(items: [.recognize, .longCapture, .cancel, .save, .copy]) {
            [weak self] in self?.finish($0)
        }, beside: area)
        panels = shades + [catcher, bar]
        panels.forEach { $0.orderFrontRegardless() }

        // The keys come here without OCRFlow coming forward: the bar is a
        // panel that takes the keyboard while another app stays active, as
        // Spotlight does.
        bar.makeKey()
        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .rightMouseDown {
                self.finish(.cancel)
                return nil
            }
            let command = event.modifierFlags.contains(.command)
            switch (event.keyCode, command) {
            case (36, false), (76, false), (8, true): self.finish(.copy)    // Return, Enter, ⌘C
            case (49, false), (1, true): self.finish(.save)                 // Space, ⌘S
            case (53, false): self.finish(.cancel)                          // Escape
            default: return event
            }
            return nil
        }
        if let local { monitors.append(local) }
        // A right-click anywhere else lets it go too.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.cancel) }
        }) { monitors.append(monitor) }
    }

    private func finish(_ action: CaptureFinish) {
        guard let continuation else { return }
        self.continuation = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panels.forEach { $0.orderOut(nil) }
        panels = []
        continuation.resume(returning: action)
    }
}

/// The marks shown around something captured: an outline, its size, a bar
/// of buttons. Each its own panel, over everything.
@MainActor
enum CaptureMarks {
    static func panel(_ frame: CGRect, key: Bool = false, passesWheel: Bool = false) -> NSPanel {
        let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        let panel = key ? KeyPanel(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
            : passesWheel ? WheelThroughPanel(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
            : NSPanel(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Shown while another app is in front: during a long screenshot the
        // keys and the wheel belong to the app being scrolled.
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        return panel
    }

    /// The rest of every screen dimmed around `area`, which stays bright,
    /// with a line round it — as the screen looks while it is chosen. Clicks
    /// and the wheel go through to what is beneath.
    static func shades(around area: CGRect) -> [NSPanel] {
        NSScreen.screens.map { screen in
            let shade = panel(screen.frame)
            shade.ignoresMouseEvents = true
            let view = ShadeView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.cut = area.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            shade.contentView = view
            return shade
        }
    }

    /// `catchesClicks` false lets everything inside reach the app beneath:
    /// to scroll it, say.
    static func outline(_ area: CGRect, catchesClicks: Bool) -> NSPanel {
        let outline = panel(area)
        outline.ignoresMouseEvents = !catchesClicks
        outline.contentView = OutlineView(frame: NSRect(origin: .zero, size: outline.frame.size), catchesClicks: catchesClicks)
        return outline
    }

    // MARK: Size and bar, placed alike everywhere

    static let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    static let sizePadding = CGSize(width: 6, height: 3)

    static func sizeText(for area: CGRect) -> String {
        "\(Int(area.width.rounded())) × \(Int(area.height.rounded()))"
    }

    /// Above the top-left corner, its left edge on the area's — or just
    /// inside the corner, at the top of the screen.
    static func sizeLabelFrame(size: CGSize, for area: CGRect) -> CGRect {
        let gap: CGFloat = 4
        let screen = wholeScreen(for: area)
        let y = area.maxY + gap + size.height <= screen.maxY ? area.maxY + gap : area.maxY - size.height - gap
        let x = min(max(area.minX, screen.minX + gap), screen.maxX - size.width - gap)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The size of the area, as the held screen shows it while choosing.
    static func sizeLabel(for area: CGRect) -> NSPanel {
        let host = NSHostingView(rootView: Text(verbatim: sizeText(for: area))
            .font(Font(sizeFont))
            .foregroundStyle(.white)
            .padding(.horizontal, sizePadding.width)
            .padding(.vertical, sizePadding.height)
            .background(.black.opacity(0.7), in: Capsule()))
        let label = panel(sizeLabelFrame(size: host.fittingSize, for: area))
        label.ignoresMouseEvents = true
        label.contentView = host
        return label
    }

    /// Under the area, its right edge on the area's. Without room below,
    /// above it — over the size, when the two would meet; without room
    /// there either, inside it at the bottom.
    static func barFrame(size: CGSize, for area: CGRect, labelSize: CGSize = CGSize(width: 80, height: 20)) -> CGRect {
        let gap: CGFloat = 8
        let screen = wholeScreen(for: area)
        let x = min(max(area.maxX - size.width, screen.minX + gap), screen.maxX - size.width - gap)
        var frame = CGRect(x: x, y: area.minY - gap - size.height, width: size.width, height: size.height)
        if frame.minY >= screen.minY + gap { return frame }
        frame.origin.y = area.maxY + gap
        let label = sizeLabelFrame(size: labelSize, for: area)
        if frame.intersects(label.insetBy(dx: -4, dy: -4)) { frame.origin.y = max(frame.minY, label.maxY + 4) }
        if frame.maxY <= screen.maxY - gap { return frame }
        frame.origin.y = max(area.minY, screen.minY) + gap
        return frame
    }

    /// A long screenshot's own controls: the button that scrolls for the
    /// user in the middle of the area, where the eye already is; what has
    /// been joined beside it, on whichever side has more room, its top level
    /// with the area's. The button lets the wheel through to what is under it.
    ///
    /// `screen` is the visible part of the screen the area is on.
    static func scrollFrames(for area: CGRect, on screen: CGRect,
                             buttonSize: CGSize) -> (button: CGRect, preview: CGRect) {
        let gap: CGFloat = 8
        let button = CGRect(x: (area.midX - buttonSize.width / 2).rounded(), y: (area.midY - buttonSize.height / 2).rounded(),
                            width: buttonSize.width, height: buttonSize.height)
        let room = (left: area.minX - screen.minX - 2 * gap, right: screen.maxX - area.maxX - 2 * gap)
        let right = room.right >= room.left
        // As wide as the preview needs to be read; narrower only for want of
        // room, never so narrow it can no longer be.
        let width = min(columnWidth, max(minimumColumnWidth, right ? room.right : room.left))
        let x = right ? min(area.maxX + gap, screen.maxX - gap - width) : max(area.minX - gap - width, screen.minX + gap)
        let top = min(area.maxY, screen.maxY - gap)
        let bottom = max(area.minY, screen.minY + gap)
        let height = max(top - bottom, minimumPreviewHeight)
        return (button, CGRect(x: x, y: top - height, width: width, height: height))
    }

    static let columnWidth: CGFloat = 240
    static let minimumColumnWidth: CGFloat = 140
    static let minimumPreviewHeight: CGFloat = 80

    static func bar(_ content: some View, beside area: CGRect) -> NSPanel {
        let host = FirstMouseHostingView(rootView: content)
        let text = sizeText(for: area).size(withAttributes: [.font: sizeFont])
        let labelSize = CGSize(width: ceil(text.width) + 2 * sizePadding.width, height: ceil(text.height) + 2 * sizePadding.height)
        let bar = panel(barFrame(size: host.fittingSize, for: area, labelSize: labelSize), key: true)
        bar.hasShadow = true
        bar.contentView = host
        return bar
    }

    /// The whole of the screen the area is on, menu bar and Dock included:
    /// over the held screen they are only a picture.
    static func wholeScreen(for area: CGRect) -> CGRect {
        let center = CGPoint(x: area.midX, y: area.midY)
        return (NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
            ?? NSScreen.screens.first { $0.frame.intersects(area) } ?? NSScreen.main ?? NSScreen.screens[0]).frame
    }

    /// Pixels a point, on the screen the area is on.
    static func backingScale(for area: CGRect) -> CGFloat {
        (NSScreen.screens.first { $0.frame.intersects(area) } ?? NSScreen.main)?.backingScaleFactor ?? 2
    }

    static func screenFrame(for area: CGRect) -> CGRect {
        (NSScreen.screens.first { $0.frame.intersects(area) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    }
}

/// A panel that can take the keyboard without making OCRFlow the active app.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A panel over something being scrolled: the wheel turned over it goes
/// through to what is beneath. The first turn makes it see-through, and it
/// takes clicks again once the wheel has been still a moment.
final class WheelThroughPanel: NSPanel {
    private var wheelMonitor: Any?
    private var still: Timer?

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .scrollWheel else { return super.sendEvent(event) }
        ignoresMouseEvents = true
        // See-through, its turns go to other apps: seen from there.
        wheelMonitor = wheelMonitor ?? NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            MainActor.assumeIsolated { self?.turning() }
        }
        turning()
    }

    override func orderOut(_ sender: Any?) {
        stopWatching()
        super.orderOut(sender)
    }

    private func turning() {
        still?.invalidate()
        still = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ignoresMouseEvents = false
                self?.stopWatching()
            }
        }
    }

    private func stopWatching() {
        still?.invalidate()
        still = nil
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
    }
}

/// The outline around what was chosen.
final class OutlineView: NSView {
    var onDoubleClick: () -> Void = {}
    private let catchesClicks: Bool

    init(frame: NSRect, catchesClicks: Bool) {
        self.catchesClicks = catchesClicks
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // All but invisible, so the clicks land here; the line round it is
        // the shade's.
        if catchesClicks {
            NSColor.black.withAlphaComponent(0.01).setFill()
            bounds.fill()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick() }
    }
}

/// The row of buttons, each an icon that says what it does on hover.
struct CaptureActionsBar: View {
    let items: [CaptureFinish]
    let act: (CaptureFinish) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                // Cancel, save and copy are set apart from the rest.
                if item == .cancel, index > 0 {
                    Divider().frame(height: 22).padding(.horizontal, 4)
                }
                button(item)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
    }

    private func button(_ item: CaptureFinish) -> some View {
        Button { act(item) } label: {
            Group {
                if item == .recognize {
                    Text(verbatim: "OCR")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.primary, in: RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: symbol(item)).font(.system(size: 16, weight: .regular))
                }
            }
            .frame(width: 34, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(item == .copy || item == .done ? Color.accentColor : .primary)
        .help(help(item))
    }

    private func symbol(_ item: CaptureFinish) -> String {
        switch item {
        case .recognize: "text.viewfinder"
        case .longCapture: "arrow.up.and.down.square"
        case .save: "square.and.arrow.down"
        case .copy, .done: "checkmark"
        case .cancel: "xmark"
        }
    }

    private func help(_ item: CaptureFinish) -> LocalizedStringKey {
        switch item {
        case .recognize: "Recognize the text"
        case .longCapture: "Long screenshot: scroll on from here"
        case .save: "Save (Space)"
        case .copy: "Copy to the clipboard (Return)"
        case .done: "Done"
        case .cancel: "Cancel (Esc or right-click)"
        }
    }
}

/// Dims all but the area, and draws a line round it.
private final class ShadeView: NSView {
    var cut: CGRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        CaptureShade.draw(in: bounds, around: cut)
    }
}

/// The look of what is chosen, the same while choosing and after: the rest
/// dimmed, a light line with a dark one outside it, visible on any
/// background.
enum CaptureShade {
    static func draw(in bounds: CGRect, around cut: CGRect) {
        let shade = NSBezierPath(rect: bounds)
        if cut.intersects(bounds) { shade.append(NSBezierPath(rect: cut)) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.4).setFill()
        shade.fill()
        guard cut.intersects(bounds) else { return }
        NSColor.black.withAlphaComponent(0.35).setStroke()
        NSBezierPath(rect: cut.insetBy(dx: -0.5, dy: -0.5)).stroke()
        let inner = NSBezierPath(rect: cut.insetBy(dx: 0.5, dy: 0.5))
        inner.lineWidth = 1
        NSColor.white.setStroke()
        inner.stroke()
    }
}
