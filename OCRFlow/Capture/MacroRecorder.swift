import AppKit

/// One thing the user did while being recorded, as it arrived, before it is
/// made into steps.
struct RecordedInput: Sendable {
    enum Kind: Sendable {
        case mouseDown(MacroStep.Click.Button, clickCount: Int)
        case mouseDragged
        case mouseUp
        /// `continues` when it is part of the same gesture as the scroll
        /// before it: the fingers still down, or the page still gliding.
        case scroll(dx: Double, dy: Double, continues: Bool)
        case key(code: UInt16, characters: String)
        case capture(CaptureArea)
    }

    var kind: Kind
    /// In event coordinates.
    var location: CGPoint = .zero
    var modifiers: UInt64 = 0
    var window: WindowPlace?
    /// The control under a mouse press, filled in once Accessibility answers.
    var element: ElementDescription?
}

/// Makes what the user did into steps someone would recognise: a press and
/// release in place is a click, a second one there makes it a double click,
/// keys typed one after another are text, one swipe is one scroll.
enum MacroStepBuilder {
    /// Further than this, a press and release is a drag.
    static let dragDistance: CGFloat = 4

    static func steps(from inputs: [RecordedInput]) -> [MacroStep] {
        var steps: [MacroStep] = []
        var press: (input: RecordedInput, button: MacroStep.Click.Button, count: Int, path: [CGPoint])?

        for input in inputs {
            switch input.kind {
            case let .mouseDown(button, clickCount):
                press = (input, button, clickCount, [input.location])
            case .mouseDragged:
                press?.path.append(input.location)
            case .mouseUp:
                guard let done = press else { continue }
                press = nil
                var path = done.path
                path.append(input.location)
                let start = path[0]
                let far = path.contains { hypot($0.x - start.x, $0.y - start.y) > dragDistance }
                let origin = done.input.window?.frame.origin ?? .zero
                func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - origin.x, y: point.y - origin.y) }
                if far {
                    let drag = MacroStep.Drag(path: thinned(path).map(local), button: done.button,
                                              modifiers: done.input.modifiers)
                    steps.append(MacroStep(action: .drag(drag), window: done.input.window))
                    continue
                }
                // The second click of a double click, on the first.
                if done.count > 1, let last = steps.last, case var .click(click) = last.action,
                   click.button == done.button,
                   hypot(click.point.x - local(start).x, click.point.y - local(start).y) <= dragDistance {
                    click.count = done.count
                    steps[steps.count - 1].action = .click(click)
                    continue
                }
                var click = MacroStep.Click(point: local(start), button: done.button, count: 1,
                                            modifiers: done.input.modifiers, element: done.input.element)
                if let element = done.input.element { click.findsElement = ElementLocator.prefersElement(element) }
                steps.append(MacroStep(action: .click(click), window: done.input.window))

            case let .scroll(dx, dy, continues):
                if continues, let last = steps.last, case var .scroll(scroll) = last.action {
                    scroll.dx += dx
                    scroll.dy += dy
                    steps[steps.count - 1].action = .scroll(scroll)
                    continue
                }
                let origin = input.window?.frame.origin ?? .zero
                let scroll = MacroStep.Scroll(point: CGPoint(x: input.location.x - origin.x, y: input.location.y - origin.y),
                                              dx: dx, dy: dy)
                steps.append(MacroStep(action: .scroll(scroll), window: input.window))

            case let .key(code, characters):
                steps.append(MacroStep(action: .key(MacroStep.Key(keyCode: code, modifiers: input.modifiers,
                                                                  characters: characters)),
                                       window: input.window))

            case let .capture(area):
                steps.append(MacroStep(action: .capture(area), window: input.window))
            }
        }
        return joiningTypedKeys(steps.filter(\.isWorthKeeping))
    }

    /// A row of plain keys, two or more, with a letter among them, is typing.
    /// A space or a letter on its own stays a key: in a viewer, a page turn.
    private static func joiningTypedKeys(_ steps: [MacroStep]) -> [MacroStep] {
        var result: [MacroStep] = []
        var run: [MacroStep] = []
        func flush() {
            let keys = run.compactMap { step -> MacroStep.Key? in
                if case let .key(key) = step.action { return key }
                return nil
            }
            if keys.count >= 2, keys.contains(where: { $0.characters != " " }) {
                let text = MacroStep.TypedText(text: keys.map(\.characters).joined(), keyCodes: keys.map(\.keyCode))
                result.append(MacroStep(action: .type(text), window: run[0].window))
            } else {
                result += run
            }
            run = []
        }
        for step in steps {
            if case let .key(key) = step.action, isTyping(key),
               run.isEmpty || run[0].window?.bundleID == step.window?.bundleID {
                run.append(step)
            } else {
                flush()
                if case let .key(key) = step.action, isTyping(key) { run.append(step) } else { result.append(step) }
            }
        }
        flush()
        return result
    }

    /// A key that puts a character in text, as opposed to a shortcut, an
    /// arrow, Return or the like.
    static func isTyping(_ key: MacroStep.Key) -> Bool {
        let flags = CGEventFlags(rawValue: key.modifiers)
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl),
              key.characters.count == 1 else { return false }
        return key.characters.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    /// Fewer points along a drag: one every few points is plenty to repeat it.
    private static func thinned(_ path: [CGPoint]) -> [CGPoint] {
        guard var last = path.first else { return path }
        var kept = [last]
        for point in path.dropFirst().dropLast() where hypot(point.x - last.x, point.y - last.y) >= 6 {
            kept.append(point)
            last = point
        }
        if let end = path.last, path.count > 1 { kept.append(end) }
        return kept
    }
}

private extension MacroStep {
    /// A scroll that went nowhere is no step.
    var isWorthKeeping: Bool {
        if case let .scroll(scroll) = action { return abs(scroll.dx) + abs(scroll.dy) >= 1 }
        return true
    }
}

/// Watches what the user does in other apps until told to stop, and makes it
/// into steps.
///
/// Needs Accessibility permission; see `InputControl`. What the user does in
/// OCRFlow itself — the recording panel — is never seen.
@MainActor
final class MacroRecorder {
    private(set) var inputs: [RecordedInput] = []
    /// Clicks, key presses, scrolls and captures so far — what the user would
    /// count.
    private(set) var actions = 0
    var onChange: () -> Void = {}

    private var monitor: Any?
    private var lastScroll: TimeInterval = 0
    /// The press being left out, until its release.
    private var skippingPress = false
    /// The app in front when recording started. Read then, not at the
    /// click: by the time a click is seen, its app has come forward.
    private var frontAtStart: pid_t?
    private var lookups: [Task<Void, Never>] = []

    func start() {
        frontAtStart = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let types: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                                            .scrollWheel, .keyDown]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: types) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
        }
    }

    /// The steps, once every control under a click has been looked up.
    func stop() async -> [MacroStep] {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for lookup in lookups { await lookup.value }
        lookups = []
        return MacroStepBuilder.steps(from: inputs)
    }

    /// A capture, here, of what the user chose.
    func addCapture(_ area: CaptureArea, in window: WindowPlace?) {
        inputs.append(RecordedInput(kind: .capture(area), window: window))
        actions += 1
        onChange()
    }

    private func record(_ event: NSEvent) {
        guard let cgEvent = event.cgEvent,
              cgEvent.getIntegerValueField(.eventSourceUserData) != StepPlayer.marker else { return }
        let location = cgEvent.location
        let modifiers = cgEvent.flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).rawValue
        var input = RecordedInput(kind: .mouseUp, location: location, modifiers: modifiers)

        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button: MacroStep.Click.Button = event.type == .leftMouseDown ? .left
                : event.type == .rightMouseDown ? .right : .other
            input.kind = .mouseDown(button, clickCount: max(1, event.clickCount))
            let window = ScreenWindows.at(location)
            // The first click into another app, before anything but
            // captures, only brings it forward: OCRFlow was in front,
            // recording having been started there. Repeating it would click
            // the page each round, which many viewers take as a page turn;
            // the app is brought forward anyway when the steps are done
            // again.
            let nothingDoneYet = inputs.allSatisfy { if case .capture = $0.kind { true } else { false } }
            if nothingDoneYet, let window, window.pid != frontAtStart {
                skippingPress = true
                return
            }
            skippingPress = false
            input.window = window.map { $0.layer == 0 ? $0.place : WindowPlace.floating(of: $0) }
            actions += 1
            let index = inputs.count
            let origin = input.window?.frame.origin ?? .zero
            lookups.append(Task { [weak self] in
                let element = await Task.detached { ElementLocator.describe(at: location, windowOrigin: origin) }.value
                guard let self, self.inputs.indices.contains(index) else { return }
                self.inputs[index].element = element
            })
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard !skippingPress else { return }
            input.kind = .mouseDragged
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard !skippingPress else { skippingPress = false; return }
            input.kind = .mouseUp
        case .scrollWheel:
            let dy = cgEvent.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let dx = cgEvent.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            let gesture = event.phase != [] || event.momentumPhase != []
            let continues = event.phase != .began
                && (gesture || event.timestamp - lastScroll < 0.35)
            if !continues { actions += 1 }
            lastScroll = event.timestamp
            input.kind = .scroll(dx: dx, dy: dy, continues: continues)
            // Where a swipe starts is where it is done again; the rest of it
            // only adds to the distance.
            if !continues { input.window = ScreenWindows.ordinary(at: location)?.place }
        case .keyDown:
            // The screenshot shortcut, pressed to capture here, is no step.
            guard !GlobalHotKey.isOwn(keyCode: event.keyCode, flags: cgEvent.flags) else { return }
            // A shortcut by the key it is on, text by what it typed.
            let shortcut = cgEvent.flags.contains(.maskCommand) || cgEvent.flags.contains(.maskControl)
            input.kind = .key(code: event.keyCode,
                              characters: (shortcut ? event.charactersIgnoringModifiers : event.characters) ?? "")
            input.window = ScreenWindows.frontPlace()
            actions += 1
        default:
            return
        }
        inputs.append(input)
        onChange()
    }
}
