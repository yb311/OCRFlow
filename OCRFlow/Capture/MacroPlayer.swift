import AppKit
import SwiftUI

/// Does a recorded macro again: for each address, if it has any, the steps
/// over and over as it says, keeping what each capture step takes.
///
/// Waits for the screen to settle after each step rather than for set
/// times, so a slow page does not throw it. Stops by itself when a round
/// leaves the screen as it found it, pauses when the user takes the mouse or
/// keyboard, and stops on Escape.
@MainActor
final class MacroPlayer {
    /// However long a run, it ends after this many rounds.
    static let roundLimit = 300

    private let state = MacroRunState()
    private var panel: NSPanel?
    private var stopRequested = false
    private var pauseRequested: String?
    private var userMonitor: Any?
    /// Windows already put back where they were recorded, this run.
    private var restored: Set<CGWindowID> = []
    /// An app a step happened in that has no window open now.
    private(set) var missingApp: String?
    /// Stopped by the user, rather than come to its end.
    var wasStopped: Bool { stopRequested }

    /// Where what the capture steps take is written, as it is taken: a long
    /// run's screenfuls do not fit in memory. The caller removes it.
    let folder = URL.temporaryDirectory.appending(path: "OCRFlow Run \(UUID().uuidString)", directoryHint: .isDirectory)
    private var written = 0
    /// Where the last capture step took its picture.
    private var pixelsPerPoint: CGFloat = 1

    /// What the capture steps took, as files in `folder`: one list for each
    /// address, or one in all.
    func run(_ macro: Macro) async -> [[URL]] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard InputControl.isAllowed(), ScreenCapture.checkAllowed() else { return [] }
        state.name = macro.name
        let urls: [URL?] = macro.openableURLs.isEmpty ? [nil] : macro.openableURLs
        state.addresses = urls.count
        let firstWindow = macro.steps.lazy.compactMap(\.window).first
        panel = HUDPanel.show(MacroRunView(state: state), avoiding: firstWindow.flatMap { ScreenWindows.find($0) }
            .map { cocoaFrame(of: $0.frame) })
        state.onStop = { [weak self] in self?.stopRequested = true }
        state.onContinue = { [weak self] in self?.state.pausedBecause = nil }
        watchTheUser()
        defer {
            stopWatchingTheUser()
            panel?.orderOut(nil)
            panel = nil
        }

        var results: [[URL]] = []
        for (index, url) in urls.enumerated() {
            guard !stopRequested else { break }
            state.address = index + 1
            if let url {
                await open(url, in: firstWindow?.bundleID)
            }
            results.append(await rounds(of: macro))
        }
        return results
    }

    /// The steps, again and again as the macro says, with what they took.
    private func rounds(of macro: Macro) async -> [URL] {
        let limit: Int
        switch macro.repetition {
        case .once: limit = 1
        case let .times(count): limit = max(1, min(count, Self.roundLimit))
        case .untilUnchanged: limit = Self.roundLimit
        }
        var taken: [URL] = []
        var firstLook: PageFingerprint?
        var lastLook: PageFingerprint?
        var round = 0
        while round < limit, !stopRequested {
            round += 1
            state.round = round
            var took: [CGImage] = []
            for step in macro.steps {
                await waitWhilePaused()
                guard !stopRequested else { break }
                if let image = await perform(step) { took.append(image) }
            }
            guard !stopRequested else {
                taken += keep(took)
                break
            }

            // Whether the round changed anything, judged by the first thing
            // it took, or else by the screen.
            let look: PageFingerprint?
            if let first = took.first { look = PageFingerprint(first) } else { look = await lookAtScreen(for: macro) }
            if let look, let lastLook, look.isSamePage(as: lastLook) {
                if case .untilUnchanged = macro.repetition { break }
                // Asked for more rounds, and nothing happens: a dialog in the
                // way, or a click that missed.
                pause(String(localized: "Nothing changed on screen in the last round. A dialog may be in the way, or a click may have missed."))
                await waitWhilePaused()
                continue
            }
            // Back at the start: something that goes round.
            if case .untilUnchanged = macro.repetition, round > 2, let look, let firstLook, look.isSamePage(as: firstLook) { break }
            if firstLook == nil { firstLook = look }
            lastLook = look
            taken += keep(took)
            state.captured += took.count
        }
        return taken
    }

    /// Writes pictures to `folder`, numbered in the order taken.
    private func keep(_ images: [CGImage]) -> [URL] {
        images.compactMap { image in
            written += 1
            let url = folder.appending(path: String(format: "%04d.png", written))
            return ScreenshotFormat.png.write(image, to: url, pixelsPerPoint: pixelsPerPoint) ? url : nil
        }
    }

    // MARK: - Steps

    /// Does one step and waits for the screen to settle. A capture step
    /// returns what it took.
    private func perform(_ step: MacroStep) async -> CGImage? {
        let window = await place(step.window)
        let origin = window?.frame.origin ?? .zero
        func onScreen(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + origin.x, y: point.y + origin.y) }
        let watched = window.map { CaptureTarget.window($0.id) }

        switch step.action {
        case let .click(click):
            // Not for a menu: it is open in the app in front already.
            if let window { await StepPlayer.bringForward(window.pid) }
            var point = onScreen(click.point)
            if click.findsElement, let element = click.element, let pid = window?.pid ?? app(of: step.window) {
                let frame = window?.frame
                let found = await Task.detached(operation: { ElementLocator.find(element, pid: pid, window: frame) }).value
                switch found {
                case let .point(found)?: point = found
                case .pressed?:
                    await settle(watched ?? ScreenWindows.display(at: point))
                    return nil
                case nil: break
                }
            }
            await self.click(click, at: point)
            await settle(watched ?? ScreenWindows.display(at: point))

        case let .drag(drag):
            if let window { await StepPlayer.bringForward(window.pid) }
            await self.drag(drag.path.map(onScreen), button: drag.button, modifiers: drag.modifiers)
            await settle(watched ?? ScreenWindows.display(at: onScreen(drag.path.first ?? .zero)))

        case let .key(key):
            await StepPlayer.bringForward(window?.pid ?? app(of: step.window))
            press(key.keyCode, modifiers: key.modifiers)
            await settle(watched ?? ScreenWindows.display(at: NSEvent.mouseLocationInEventCoordinates))

        case let .type(text):
            await StepPlayer.bringForward(window?.pid ?? app(of: step.window))
            await type(text)
            await settle(watched ?? ScreenWindows.display(at: NSEvent.mouseLocationInEventCoordinates))

        case let .scroll(scroll):
            let point = onScreen(scroll.point)
            await self.scroll(by: CGVector(dx: scroll.dx, dy: scroll.dy), at: point)
            await settle(watched ?? ScreenWindows.display(at: point))

        case let .capture(area):
            let target: CaptureTarget?
            switch (window, area.rect) {
            case let (window?, nil): target = .window(window.id)
            case let (window?, rect?): target = ScreenWindows.target(for: rect.offsetBy(dx: window.frame.minX, dy: window.frame.minY))
            case let (nil, rect?): target = ScreenWindows.target(for: rect)
            case (nil, nil): target = nil
            }
            guard let target else { return nil }
            pixelsPerPoint = ScreenCapture.pixelsPerPoint(of: target)
            await settle(target, waitForChange: false)
            if let distance = area.scrollDistance {
                // Scrolled on as far as when recorded, and joined.
                guard let first = try? await ScreenCapture.grab(target) else { return nil }
                let parts = await ScrollingCapture().runAutomatically(target, size: CGSize(width: first.width, height: first.height),
                                                                      distance: distance)
                return parts.first ?? first
            }
            return try? await ScreenCapture.grab(target)

        case let .wait(seconds):
            let until = Date().addingTimeInterval(seconds)
            while Date() < until, !stopRequested { try? await Task.sleep(for: .milliseconds(100)) }
        }
        return nil
    }

    /// The window a step happened in, as it is now — put back where it was
    /// when recorded, the first time it is met in a run, so positions in it
    /// land where they did, and what is taken of it is the size it was: to
    /// be joined with what was taken while recording, a picture a point
    /// larger is another picture.
    private func place(_ place: WindowPlace?) async -> ScreenWindow? {
        guard let place, !place.isFloating else { return nil }
        if ScreenWindows.find(place) == nil, let bundleID = place.bundleID {
            // Not open: the app is started, and its window waited for.
            await launch(bundleID) { ScreenWindows.find(place) != nil }
        }
        guard var window = ScreenWindows.find(place) else {
            missingApp = place.appName
            return nil
        }
        // Its app in front first, as when it was recorded: steps land on the
        // window, captures see it. In Stage Manager a window in the strip at
        // the side is only a small picture of itself until then, and moves
        // to the middle as its app comes forward.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != window.pid,
           let app = NSRunningApplication(processIdentifier: window.pid) {
            await Activation.bringForward(app)
            window = await settled(window)
        }
        let moved = abs(window.frame.minX - place.frame.minX) + abs(window.frame.minY - place.frame.minY)
            + abs(window.frame.width - place.frame.width) + abs(window.frame.height - place.frame.height)
        guard !restored.contains(window.id), moved > 0 else { return window }
        restored.insert(window.id)
        let pid = window.pid, current = window.frame, recorded = place.frame
        let moving = await Task.detached { ElementLocator.move(windowOf: pid, at: current, to: recorded) }.value
        guard moving else { return window }
        return await arrived(window, at: recorded)
    }

    /// The window once it has stopped moving — or after a second and a
    /// half, however it is.
    private func settled(_ window: ScreenWindow) async -> ScreenWindow {
        var last = window
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(50))
            guard let now = ScreenWindows.all().first(where: { $0.id == window.id }) else { return last }
            if now.frame == last.frame { return now }
            last = now
        }
        return last
    }

    /// The window once it is at `frame` — or, should its app not let it be
    /// quite that, once it has moved and stopped; or after a second and a
    /// half, however it is.
    private func arrived(_ window: ScreenWindow, at frame: CGRect) async -> ScreenWindow {
        var last = window
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(50))
            guard let now = ScreenWindows.all().first(where: { $0.id == window.id }) else { return last }
            if now.frame == frame || (now.frame != window.frame && now.frame == last.frame) { return now }
            last = now
        }
        return last
    }

    private func app(of place: WindowPlace?) -> pid_t? {
        guard let bundleID = place?.bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }

    /// Starts the app, and waits until `ready` — its window open — or, for
    /// an app slow to start, twenty seconds.
    private func launch(_ bundleID: String, until ready: () -> Bool) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              (try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())) != nil
        else { return }
        let deadline = Date().addingTimeInterval(20)
        while !ready(), !stopRequested, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Opens a page, in the app the steps were recorded in when it can open
    /// one, and waits for it to load: for the app to come forward, then for
    /// its window to change and come to rest.
    private func open(_ url: URL, in bundleID: String?) async {
        guard let appURL = bundleID.flatMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
                ?? NSWorkspace.shared.urlForApplication(toOpen: url),
              let app = try? await NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                                           configuration: NSWorkspace.OpenConfiguration())
        else { return }
        let deadline = Date().addingTimeInterval(20)
        while !app.isActive, !stopRequested, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let window = ScreenWindows.all().first { $0.pid == app.processIdentifier && $0.layer == 0 }
        await settle(window.map { .window($0.id) } ?? ScreenWindows.display(at: NSEvent.mouseLocationInEventCoordinates),
                     changeWithin: 5, longest: 20)
    }

    // MARK: - Input

    private func click(_ click: MacroStep.Click, at point: CGPoint) async {
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = switch click.button {
        case .left: (.leftMouseDown, .leftMouseUp, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .right)
        case .other: (.otherMouseDown, .otherMouseUp, .center)
        }
        // There first, as a hand would be: some pages only show a control
        // under the pointer.
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            StepPlayer.post(move)
        }
        try? await Task.sleep(for: .milliseconds(60))
        for count in 1...max(1, click.count) {
            for type in [down, up] {
                guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                                          mouseButton: button) else { continue }
                event.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                event.flags = CGEventFlags(rawValue: click.modifiers)
                StepPlayer.post(event)
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private func drag(_ path: [CGPoint], button: MacroStep.Click.Button, modifiers: UInt64) async {
        guard let start = path.first, let end = path.last else { return }
        let (down, dragged, up, mouse): (CGEventType, CGEventType, CGEventType, CGMouseButton) = switch button {
        case .left: (.leftMouseDown, .leftMouseDragged, .leftMouseUp, .left)
        case .right: (.rightMouseDown, .rightMouseDragged, .rightMouseUp, .right)
        case .other: (.otherMouseDown, .otherMouseDragged, .otherMouseUp, .center)
        }
        func post(_ type: CGEventType, _ point: CGPoint) {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                                      mouseButton: mouse) else { return }
            event.flags = CGEventFlags(rawValue: modifiers)
            StepPlayer.post(event)
        }
        post(down, start)
        for point in path.dropFirst() {
            try? await Task.sleep(for: .milliseconds(16))
            post(dragged, point)
        }
        try? await Task.sleep(for: .milliseconds(30))
        post(up, end)
    }

    private func press(_ keyCode: UInt16, modifiers: UInt64, text: String? = nil) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = CGEventFlags(rawValue: modifiers)
            if let text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            StepPlayer.post(event)
        }
    }

    /// Character by character. While the text is as recorded, each goes on
    /// the key that typed it.
    private func type(_ typed: MacroStep.TypedText) async {
        let characters = Array(typed.text)
        let keys = typed.keyCodes.count == characters.count ? typed.keyCodes : nil
        for (index, character) in characters.enumerated() {
            guard !stopRequested else { return }
            press(keys?[index] ?? 0, modifiers: 0, text: String(character))
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    /// In steps of a few dozen points, as a wheel or trackpad sends it: a
    /// single huge step is ignored by some pages.
    private func scroll(by distance: CGVector, at point: CGPoint) async {
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            StepPlayer.post(move)
        }
        try? await Task.sleep(for: .milliseconds(40))
        let parts = max(1, Int((max(abs(distance.dx), abs(distance.dy)) / 40).rounded(.up)))
        for _ in 0..<parts {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: Int32((distance.dy / Double(parts)).rounded()),
                                      wheel2: Int32((distance.dx / Double(parts)).rounded()), wheel3: 0) else { continue }
            event.location = point
            StepPlayer.post(event)
            try? await Task.sleep(for: .milliseconds(12))
        }
    }

    // MARK: - Watching the screen

    /// Gives the screen a moment to start changing — `changeWithin` seconds
    /// at most — then waits for it to stop: a page loading, a slide fading
    /// in, a scroll gliding to a halt.
    private func settle(_ target: CaptureTarget, waitForChange: Bool = true, changeWithin: Double = 1,
                        longest: Double = 10) async {
        try? await Task.sleep(for: .milliseconds(150))
        guard var last = await ScrollingCapture.look(at: target) else { return }
        let deadline = Date().addingTimeInterval(longest)
        if waitForChange {
            // Most steps change something within a second. One that does not
            // may change nothing at all: it is not waited out.
            let changeBy = Date().addingTimeInterval(changeWithin)
            var changed = false
            while !stopRequested, Date() < changeBy {
                try? await Task.sleep(for: .milliseconds(150))
                guard let look = await ScrollingCapture.look(at: target) else { return }
                if !look.isSamePage(as: last) { last = look; changed = true; break }
            }
            guard changed else { return }
        }
        while !stopRequested, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            guard let look = await ScrollingCapture.look(at: target) else { return }
            if look.isSamePage(as: last) { return }
            last = look
        }
    }

    /// The screen where the macro works: its first step's window, or the
    /// display.
    private func lookAtScreen(for macro: Macro) async -> PageFingerprint? {
        if let place = macro.steps.lazy.compactMap(\.window).first, let window = ScreenWindows.find(place) {
            return await ScrollingCapture.look(at: .window(window.id))
        }
        return await ScrollingCapture.look(at: ScreenWindows.display(at: NSEvent.mouseLocationInEventCoordinates))
    }

    // MARK: - The user

    /// Escape stops; a click, a key or a scroll of the user's own pauses —
    /// they may need the screen, and the steps would fight them for it.
    private func watchTheUser() {
        userMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) {
            [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.cgEvent?.getIntegerValueField(.eventSourceUserData) != StepPlayer.marker else { return }
                if event.type == .keyDown, event.keyCode == 53 {
                    self.stopRequested = true
                } else if self.state.pausedBecause == nil {
                    self.pause(String(localized: "Paused while you use the mouse or keyboard."))
                }
            }
        }
    }

    private func stopWatchingTheUser() {
        if let userMonitor { NSEvent.removeMonitor(userMonitor) }
        userMonitor = nil
    }

    private func pause(_ reason: String) {
        state.pausedBecause = reason
    }

    private func waitWhilePaused() async {
        while state.pausedBecause != nil, !stopRequested {
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func cocoaFrame(of rect: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension NSEvent {
    /// Where the pointer is, in event coordinates.
    @MainActor
    static var mouseLocationInEventCoordinates: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}

// MARK: - What the panel shows

@MainActor
@Observable
final class MacroRunState {
    var name = ""
    var round = 0
    var captured = 0
    var address = 1
    var addresses = 1
    /// Why the run is waiting for the user, while it is.
    var pausedBecause: String?

    @ObservationIgnored var onStop: () -> Void = {}
    @ObservationIgnored var onContinue: () -> Void = {}
}

struct MacroRunView: View {
    let state: MacroRunState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if state.pausedBecause == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "pause.circle.fill").foregroundStyle(.orange).font(.title3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.name).font(.headline).lineLimit(1)
                    Text(progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            Text(state.pausedBecause ?? String(localized: "Press Esc to stop. Clicking or typing pauses the run."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Stop") { state.onStop() }
                if state.pausedBecause != nil {
                    Button("Continue") { state.onContinue() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var progress: String {
        let round = String(localized: "Round \(state.round), \(state.captured) captured")
        guard state.addresses > 1 else { return round }
        return String(localized: "Page \(state.address) of \(state.addresses) · \(round)")
    }
}
