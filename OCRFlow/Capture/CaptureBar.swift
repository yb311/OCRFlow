import AppKit
import Carbon.HIToolbox
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

/// Shown once a screenshot is taken: under what was chosen, a row of
/// buttons — recognize the text, scroll on for a long screenshot, cancel,
/// save, copy. Recognizing is one choice among others; a screenshot is often
/// wanted as a picture.
///
/// Over the screen it was chosen on, still held, dimmed around it and its
/// size shown: nothing beneath answers until the bar is done with.
///
/// Return copies — or, with Done there instead, is Done — Space saves,
/// Escape or a right-click lets it go, and a double-click on what was chosen
/// is the same as Return.
///
/// Meanwhile what was chosen can still be adjusted, and the bar keeps
/// beside it: what is taken is the screen's `chosen` once it is done.
@MainActor
final class CaptureBar {
    /// `finishes`: the buttons, in order.
    static func choose(on screen: CaptureOverlay,
                       finishes: [CaptureFinish] = [.recognize, .longCapture, .cancel, .save, .copy]) async -> CaptureFinish {
        guard let area = screen.area else { return .cancel }
        let bar = CaptureBar()
        current = bar
        defer {
            current = nil
            screen.onDoubleClick = {}
        }
        return await withCheckedContinuation { continuation in
            bar.continuation = continuation
            bar.show(around: area, on: screen, finishes: finishes)
        }
    }

    /// Kept alive while it waits.
    private static var current: CaptureBar?

    private var continuation: CheckedContinuation<CaptureFinish, Never>?
    private weak var screen: CaptureOverlay?
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var keys: [GlobalHotKey] = []
    private var switching: NSObjectProtocol?

    private func show(around area: CGRect, on screen: CaptureOverlay, finishes: [CaptureFinish]) {
        // Taken as it is: copied, or Done.
        let keep: CaptureFinish = finishes.contains(.done) ? .done : .copy
        screen.onDoubleClick = { [weak self] in self?.finish(keep) }
        let bar = CaptureMarks.bar(finishes, beside: area) {
            [weak self] in self?.finish($0)
        }
        bar.orderFrontRegardless()
        panel = bar
        self.screen = screen
        screen.beginAdjusting { CaptureMarks.move(bar, beside: $0) }

        // The keys come here with OCRFlow still in the background: none of
        // its windows takes the keyboard, which would hand it on to OCRFlow's
        // own window when they go — and bring OCRFlow forward with it.
        let finish: (CaptureFinish) -> () -> Void = { action in { [weak self] in self?.finish(action) } }
        let saves = finishes.contains(.save) ? [(kVK_Space, 0, finish(.save)), (kVK_ANSI_S, cmdKey, finish(.save))] : []
        keys = GlobalHotKey.claim([
            (kVK_Return, 0, finish(keep)), (kVK_ANSI_KeypadEnter, 0, finish(keep)), (kVK_ANSI_C, cmdKey, finish(keep)),
            (kVK_Escape, 0, finish(.cancel)),
        ] + saves)
        // A right-click on the bar or what was chosen lets it go.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] _ in
            self?.finish(.cancel)
            return nil
        }) { monitors.append(local) }
        // A right-click anywhere else lets it go too.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.cancel) }
        }) { monitors.append(monitor) }
        // Going to another app lets it go: its keys are its own again.
        switching = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.cancel) }
        }
    }

    private func finish(_ action: CaptureFinish) {
        guard let continuation else { return }
        self.continuation = nil
        // A size being typed counts.
        screen?.endAdjusting()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        switching.map(NSWorkspace.shared.notificationCenter.removeObserver)
        switching = nil
        GlobalHotKey.release(keys)
        keys = []
        panel?.orderOut(nil)
        panel = nil
        continuation.resume(returning: action)
    }
}

/// What is shown with something captured, over the screen it was chosen
/// on: a bar of buttons, a long screenshot's controls. Each its own panel,
/// over everything; where the size goes, which the screen draws, is given
/// here too, so the bar keeps clear of it.
@MainActor
enum CaptureMarks {
    /// Never key: OCRFlow would come forward when it went — see `CaptureBar`.
    static func panel(_ frame: CGRect) -> NSPanel {
        set(up: NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false))
    }

    /// Above the screen they are shown over, which a click on it would
    /// otherwise bring in front of them.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    private static func set<Panel: NSPanel>(up panel: Panel) -> Panel {
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Shown while another app is in front: during a long screenshot the
        // keys and the wheel belong to the app being scrolled.
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        return panel
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
    /// with the area's. The button never takes the mouse: the wheel and
    /// clicks over it reach what is under it, and a click on it is seen
    /// before they do — see `ScrollingCapture`.
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

    /// The bar's, to tell it from the other marks.
    static let barIdentifier = NSUserInterfaceItemIdentifier("captureBar")

    static func bar(_ items: [CaptureFinish], beside area: CGRect, act: @escaping (CaptureFinish) -> Void) -> NSPanel {
        let names = ButtonNames(area: area)
        let host = FirstMouseHostingView(rootView: CaptureActionsBar(items: items, act: act) { names.show($0, at: $1) })
        let bar = BarPanel(contentRect: barFrame(size: host.fittingSize, for: area, labelSize: labelSize(for: area)),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        _ = set(up: bar)
        bar.identifier = barIdentifier
        bar.hasShadow = true
        bar.contentView = host
        bar.names = names
        names.bar = bar
        return bar
    }

    /// The bar beside the area as it is now, adjusted.
    static func move(_ bar: NSPanel, beside area: CGRect) {
        (bar as? BarPanel)?.names?.area = area
        bar.setFrame(barFrame(size: bar.frame.size, for: area, labelSize: labelSize(for: area)), display: true)
    }

    private static func labelSize(for area: CGRect) -> CGSize {
        let text = sizeText(for: area).size(withAttributes: [.font: sizeFont])
        return CGSize(width: ceil(text.width) + 2 * sizePadding.width, height: ceil(text.height) + 2 * sizePadding.height)
    }

    private final class BarPanel: NSPanel {
        var names: ButtonNames?
    }

    /// Beside the bar, on the side away from the area; the other side, at
    /// the edge of the screen. Centred on the button, kept on screen.
    static func nameFrame(size: CGSize, for button: CGRect, bar: CGRect, area: CGRect) -> CGRect {
        let gap: CGFloat = 6
        let screen = wholeScreen(for: area)
        let below = bar.minY - gap - size.height, above = bar.maxY + gap
        let under = bar.midY < area.midY
        var y = under ? below : above
        if y < screen.minY + gap || y + size.height > screen.maxY - gap { y = under ? above : below }
        let x = min(max(button.midX - size.width / 2, screen.minX + gap), screen.maxX - size.width - gap)
        return CGRect(x: x.rounded(), y: y, width: size.width, height: size.height)
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

/// A button's name beside the bar while the pointer is on it. The system's
/// tooltips show only for the app in front, and OCRFlow stays behind while
/// capturing. A window of the bar's, so it goes when the bar does.
@MainActor
private final class ButtonNames {
    weak var bar: NSPanel?
    var area: CGRect
    private var panel: NSPanel?

    init(area: CGRect) {
        self.area = area
    }

    /// Nil: the pointer has left the buttons.
    func show(_ name: String?, at button: CGRect) {
        guard let bar, let name else {
            panel?.orderOut(nil)
            return
        }
        let host = NSHostingView(rootView: Text(verbatim: name)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6, style: .continuous)))
        let panel = self.panel ?? CaptureMarks.panel(.zero)
        self.panel = panel
        panel.ignoresMouseEvents = true
        panel.contentView = host
        panel.setFrame(CaptureMarks.nameFrame(size: host.fittingSize, for: button, bar: bar.frame, area: area), display: true)
        // Taken off the bar when it was last hidden.
        if panel.parent == nil { bar.addChildWindow(panel, ordered: .above) }
        panel.orderFrontRegardless()
    }
}

/// Tells of the pointer coming onto the view and leaving it, in an app in
/// the background too, which SwiftUI's own hovering is not reliably told of.
/// Clicks go through.
private struct PointerWatch: NSViewRepresentable {
    /// Whether the pointer is on it, and where the view is on screen.
    let changed: (Bool, CGRect) -> Void

    func makeNSView(context: Context) -> WatchView { WatchView() }

    func updateNSView(_ view: WatchView, context: Context) {
        view.changed = changed
    }

    final class WatchView: NSView {
        var changed: (Bool, CGRect) -> Void = { _, _ in }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { report(true) }
        override func mouseExited(with event: NSEvent) { report(false) }

        private func report(_ inside: Bool) {
            guard let window else { return }
            changed(inside, window.convertToScreen(convert(bounds, to: nil)))
        }
    }
}

/// The row of buttons, each an icon that says what it does on hover.
struct CaptureActionsBar: View {
    let items: [CaptureFinish]
    let act: (CaptureFinish) -> Void
    /// The name of the button the pointer is on, and where that is on
    /// screen; nil once it has left.
    var pointing: (String?, CGRect) -> Void = { _, _ in }

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
        .background(PointerWatch { inside, frame in pointing(inside ? name(item) : nil, frame) })
        .accessibilityLabel(Text(name(item)))
    }

    private func symbol(_ item: CaptureFinish) -> String {
        switch item {
        case .recognize: "text.viewfinder"
        case .longCapture: "arrow.up.and.down.square"
        case .save: "arrow.down.to.line"
        case .copy, .done: "checkmark"
        case .cancel: "xmark"
        }
    }

    private func name(_ item: CaptureFinish) -> String {
        switch item {
        case .recognize: String(localized: "Recognize the text")
        case .longCapture: String(localized: "Long screenshot: scroll on from here")
        case .save: String(localized: "Save (Space)")
        case .copy: String(localized: "Copy to the clipboard (Return)")
        case .done: String(localized: "Done (Return)")
        case .cancel: String(localized: "Cancel (Esc or right-click)")
        }
    }
}
