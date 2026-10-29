import AppKit

/// One thing the user did — a click, a key, a scroll, the pointer moving —
/// kept as the system delivered it, so it can be done again exactly.
///
/// Nothing is known about what was clicked or why: the same recording works
/// for any app and any page.
struct RecordedStep {
    let event: CGEvent
    /// Since the step before.
    let delay: TimeInterval
    /// The app in front when it happened, which a key press goes to.
    let app: pid_t?
}

/// Watches what the user does in other apps until told to stop.
///
/// Needs Accessibility permission to see key presses; see `InputControl`.
@MainActor
final class StepRecorder {
    private(set) var steps: [RecordedStep] = []
    /// Clicks, key presses and scrolls so far — what the user would count.
    private(set) var actions = 0
    var onChange: () -> Void = {}

    private var monitor: Any?
    private var lastTime: TimeInterval?

    func start() {
        let types: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                                            .mouseMoved, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: types) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
        }
    }

    /// The steps, without the pointer's way to the Done button at the end.
    func stop() -> [RecordedStep] {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        while let last = steps.last, last.event.type == .mouseMoved { steps.removeLast() }
        return steps
    }

    private func record(_ event: NSEvent) {
        guard let cgEvent = event.cgEvent else { return }
        let delay = lastTime.map { event.timestamp - $0 } ?? 0
        lastTime = event.timestamp
        steps.append(RecordedStep(event: cgEvent, delay: delay,
                                  app: NSWorkspace.shared.frontmostApplication?.processIdentifier))
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown:
            actions += 1
        case .scrollWheel where event.phase == .began || (event.phase == [] && event.momentumPhase == []):
            actions += 1
        default:
            return
        }
        onChange()
    }
}

/// Does recorded steps again.
@MainActor
enum StepPlayer {
    /// Marks the events posted here, so they can be told apart from the
    /// user's own.
    static let marker: Int64 = 0x4F43_5246   // 'OCRF'

    /// `offset` moves every pointer position, for a window that has moved
    /// since it was recorded. Stops between steps once `shouldStop` says so.
    static func play(_ steps: [RecordedStep], offset: CGVector, shouldStop: () -> Bool) async {
        for step in steps {
            if shouldStop() { return }
            // Pauses are kept, so double clicks stay double clicks and pages
            // have time to react, but none is waited out in full.
            let pause = min(step.delay, 1)
            if pause > 0.005 { try? await Task.sleep(for: .seconds(pause)) }
            guard let event = step.event.copy() else { continue }

            if event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged {
                await bringForward(step.app)
            } else {
                event.location = CGPoint(x: event.location.x + offset.dx, y: event.location.y + offset.dy)
            }
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Keys go to the app in front. If another app has come forward since,
    /// the one that had the keys gets them back first.
    private static func bringForward(_ pid: pid_t?) async {
        guard let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
        try? await Task.sleep(for: .milliseconds(250))
    }
}

/// Permission to watch and repeat key presses and clicks in other apps —
/// macOS's Accessibility setting.
@MainActor
enum InputControl {
    private static let requestedKey = "inputControl.requested"

    static func isAllowed() -> Bool {
        if AXIsProcessTrusted() { return true }
        // The first time, the system asks. After that it no longer does, so
        // the app explains.
        if !UserDefaults.standard.bool(forKey: requestedKey) {
            UserDefaults.standard.set(true, forKey: requestedKey)
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return false
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "OCRFlow needs Accessibility permission to turn pages")
        alert.informativeText = String(localized: "To repeat your clicks and key presses, turn on OCRFlow in Privacy & Security → Accessibility. What you do is only watched while you show it how to turn a page, and is never stored.")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return false
    }
}
