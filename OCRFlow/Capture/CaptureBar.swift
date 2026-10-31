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
        let outline = CaptureMarks.outline(area, catchesClicks: true)
        (outline.contentView as? OutlineView)?.onDoubleClick = { [weak self] in self?.finish(.copy) }
        let size = CaptureMarks.sizeLabel(for: area)
        let bar = CaptureMarks.bar(CaptureActionsBar(items: [.recognize, .longCapture, .cancel, .save, .copy]) {
            [weak self] in self?.finish($0)
        }, beside: area)
        panels = [outline, size, bar]
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
    static func panel(_ frame: CGRect, key: Bool = false) -> NSPanel {
        let panel = key ? KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            : NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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

    /// `catchesClicks` false lets everything inside reach the app beneath:
    /// to scroll it, say.
    static func outline(_ area: CGRect, catchesClicks: Bool) -> NSPanel {
        let outline = panel(area.insetBy(dx: -2, dy: -2))
        outline.ignoresMouseEvents = !catchesClicks
        outline.contentView = OutlineView(frame: NSRect(origin: .zero, size: outline.frame.size), catchesClicks: catchesClicks)
        return outline
    }

    /// Above the top-left corner — or inside it, at the top of the screen.
    static func sizeLabel(for area: CGRect) -> NSPanel {
        let host = NSHostingView(rootView: Text(verbatim: "\(Int(area.width.rounded())) × \(Int(area.height.rounded()))")
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5)))
        let size = host.fittingSize
        let screen = screenFrame(for: area)
        let y = area.maxY + 4 + size.height <= screen.maxY ? area.maxY + 4 : area.maxY - size.height - 4
        let label = panel(CGRect(x: area.minX, y: y, width: size.width, height: size.height))
        label.ignoresMouseEvents = true
        label.contentView = host
        return label
    }

    /// Under the area at its right edge; above it when there is no room
    /// below; inside it, at the bottom, when it fills the screen.
    static func bar(_ content: some View, beside area: CGRect) -> NSPanel {
        let host = FirstMouseHostingView(rootView: content)
        let size = host.fittingSize
        let gap: CGFloat = 8
        let screen = screenFrame(for: area)
        let x = min(max(area.maxX - size.width, screen.minX + gap), screen.maxX - size.width - gap)
        let y: CGFloat
        if area.minY - gap - size.height >= screen.minY { y = area.minY - gap - size.height }
        else if area.maxY + gap + size.height <= screen.maxY - 24 { y = area.maxY + gap + 24 }
        else { y = max(area.minY, screen.minY) + gap }
        let bar = panel(CGRect(x: x, y: y, width: size.width, height: size.height), key: true)
        bar.hasShadow = true
        bar.contentView = host
        return bar
    }

    static func screenFrame(for area: CGRect) -> CGRect {
        (NSScreen.screens.first { $0.frame.intersects(area) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    }
}

/// A panel that can take the keyboard without making OCRFlow the active app.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
        if catchesClicks {
            // All but invisible inside, so the clicks land here.
            NSColor.black.withAlphaComponent(0.01).setFill()
            bounds.fill()
        }
        NSColor.controlAccentColor.setStroke()
        let edge = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        edge.lineWidth = 2
        edge.stroke()
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
        case .save: "Save… (Space)"
        case .copy: "Copy to the clipboard (Return)"
        case .done: "Done"
        case .cancel: "Cancel (Esc or right-click)"
        }
    }
}
