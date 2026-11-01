import AppKit
import SwiftUI

/// Screenshot after screenshot, with no shortcut in between: while it is on,
/// dragging anywhere takes that area. A click, a scroll, a key — everything
/// else — reaches the app under it as usual, so the user can turn to the
/// next page and drag out the next picture, and so on until Escape.
///
/// The mouse is watched through an event tap, which needs Accessibility
/// permission. A press is held back until it is clear whether it is a drag;
/// if it is not, it is sent on as the click it was.
@MainActor
final class QueueCapture {
    /// Further than this, a press is a drag.
    static let dragDistance: CGFloat = 4

    private let state = QueueState()
    private var panel: NSPanel?
    private var selectionPanel: NSPanel?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var continuation: CheckedContinuation<Void, Never>?

    /// The press being held back, as it arrived.
    private var press: CGEvent?
    private var selecting = false
    private let folder = URL.temporaryDirectory.appending(path: "OCRFlow Queue \(UUID().uuidString)", directoryHint: .isDirectory)
    private var taken: [URL] = []

    /// What was taken, as files in a folder of their own, in order. Empty
    /// when nothing was.
    func run() async -> [URL] {
        guard InputControl.isAllowed(), ScreenCapture.checkAllowed() else { return [] }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard startTap() else { return [] }
        state.onEnd = { [weak self] in self?.end() }
        panel = HUDPanel.show(QueueView(state: state), avoiding: nil)
        await withCheckedContinuation { self.continuation = $0 }
        return taken
    }

    private func end() {
        guard let continuation else { return }
        self.continuation = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        panel?.orderOut(nil)
        selectionPanel?.orderOut(nil)
        panel = nil
        selectionPanel = nil
        continuation.resume()
    }

    // MARK: - The tap

    private func startTap() -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: queueTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    /// Whether the event goes on to where it was going.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return true }
            end()
            return false
        case .leftMouseDown:
            // OCRFlow's own panel works as usual, and can be dragged aside.
            if let panel, panel.frame.contains(cocoaPoint(event.location)) { return true }
            press = event.copy()
            selecting = false
            return false
        case .leftMouseDragged:
            guard let press else { return true }
            let start = press.location, now = event.location
            if !selecting, hypot(now.x - start.x, now.y - start.y) > Self.dragDistance { selecting = true }
            if selecting { showSelection(from: start, to: now) }
            return false
        case .leftMouseUp:
            guard let held = press else { return true }
            press = nil
            if selecting {
                selecting = false
                let rect = Self.rect(from: held.location, to: event.location)
                Task { await take(rect) }
            } else {
                // Not a drag after all: the click goes where it was aimed.
                StepPlayer.post(held)
                if let up = event.copy() { StepPlayer.post(up) }
            }
            return false
        default:
            return true
        }
    }

    // MARK: - Taking

    private func take(_ rect: CGRect) async {
        selectionPanel?.orderOut(nil)
        guard rect.width >= 4, rect.height >= 4, let target = ScreenWindows.target(for: rect),
              let image = try? await ScreenCapture.grab(target) else { return }
        let url = folder.appending(path: String(format: "%04d.png", taken.count + 1))
        guard ScrollingCapture.write(image, to: url) else { return }
        taken.append(url)
        ScreenCapture.flash(target)
    }

    /// The area being dragged out, outlined, in event coordinates.
    private func showSelection(from start: CGPoint, to end: CGPoint) {
        let frame = cocoaRect(Self.rect(from: start, to: end))
        if selectionPanel == nil {
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.ignoresMouseEvents = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.contentView = SelectionView()
            selectionPanel = panel
        }
        selectionPanel?.setFrame(frame, display: true)
        selectionPanel?.orderFrontRegardless()
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func cocoaPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }

    private func cocoaRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Called on the main thread, where the tap's source runs. Events OCRFlow
/// sent itself go straight through.
private func queueTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo, event.getIntegerValueField(.eventSourceUserData) != StepPlayer.marker else {
        return Unmanaged.passUnretained(event)
    }
    let capture = Unmanaged<QueueCapture>.fromOpaque(userInfo).takeUnretainedValue()
    // On the main thread already; the event is not used past this call.
    nonisolated(unsafe) let event = event
    let passes = MainActor.assumeIsolated { capture.handle(type, event) }
    return passes ? Unmanaged.passUnretained(event) : nil
}

private final class SelectionView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        bounds.fill()
        NSColor.white.setStroke()
        let edge = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        edge.lineWidth = 2
        edge.stroke()
        NSColor.controlAccentColor.setStroke()
        let inner = NSBezierPath(rect: bounds.insetBy(dx: 2.5, dy: 2.5))
        inner.lineWidth = 1
        inner.stroke()
    }
}

// MARK: - What the panel shows

@MainActor
@Observable
private final class QueueState {
    @ObservationIgnored var onEnd: () -> Void = {}
}

private struct QueueView: View {
    let state: QueueState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.down.right").foregroundStyle(Color.accentColor)
                Text("Queue Screenshots").font(.headline)
                Spacer(minLength: 0)
            }
            Text("Drag out an area to take it. Clicks, scrolling and keys work as usual — turn the page, then drag again. Press Esc to finish.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Finish") { state.onEnd() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
