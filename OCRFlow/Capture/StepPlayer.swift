import AppKit

/// One event to send — a click, a key, a scroll, the pointer moving — with
/// the pause before it, ready to be sent again and again.
struct RecordedStep {
    let event: CGEvent
    /// Since the step before.
    let delay: TimeInterval
    /// The app in front when it happened, which a key press goes to.
    let app: pid_t?
}

/// Does recorded steps again.
@MainActor
enum StepPlayer {
    /// Marks the events posted here, so they can be told apart from the
    /// user's own.
    nonisolated static let marker: Int64 = 0x4F43_5246   // 'OCRF'

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
            post(event)
        }
    }

    /// Sends an event as if the user had done it, marked as OCRFlow's own.
    static func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        // Now, in the units the system uses: a fresh event carries it.
        if let now = CGEvent(source: nil)?.timestamp { event.timestamp = now }
        event.post(tap: .cghidEventTap)
    }

    /// Keys go to the app in front. If another app has come forward since,
    /// the one that had the keys gets them back first.
    static func bringForward(_ pid: pid_t?) async {
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
            // The key spelled out: `kAXTrustedCheckOptionPrompt` is imported as a
            // mutable global, which strict concurrency does not allow reading.
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
           let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return false
    }
}
