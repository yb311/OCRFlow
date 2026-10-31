import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Takes something too long for the screen — a web page, a document, a
/// chat — scrolled through, into one long picture.
///
/// It is joined while it scrolls, from the frames of the screen as they
/// change, the way a recording sees them: the user scrolls by hand at their
/// own pace, or Auto Scroll scrolls for them, smoothly, as a trackpad would.
/// The two are one: Auto Scroll only does the scrolling. What has been
/// joined is shown beside it as it grows. Nothing about any app or site is
/// known; it works from what the screen shows.
@MainActor
final class ScrollingCapture {
    /// However long the page, a run ends here, in pixels.
    static let heightLimit = 120_000
    /// Auto Scroll's pace, in points a second.
    static let autoSpeed: CGFloat = 700
    /// No new rows for this long while a macro scrolls: the end.
    static let endAfter: Duration = .milliseconds(1200)

    private let state = ScrollRunState()
    private var panels: [NSPanel] = []
    private var escapeMonitor: Any?
    private var finish: CaptureFinish?
    private let stitcher = LiveStitcher()
    private var stream: FrameStream?
    private var scroller: SmoothScroller?
    private var lastGrowth = ContinuousClock.now
    private var lostFrames = 0
    /// How far it has been scrolled, in pixels of the picture.
    private(set) var grown = 0

    /// Takes `target` scrolled through — `first` is a picture of it as it is
    /// now — until the user picks one of `finishes` from the bar. The long
    /// picture, in parts when very long, and what was picked; nothing when
    /// cancelled.
    func run(_ target: CaptureTarget, first: CGImage,
             finishes: [CaptureFinish] = [.cancel, .recognize, .save, .copy]) async -> (parts: [CGImage], finish: CaptureFinish) {
        guard InputControl.isAllowed(), let frame = ScreenCapture.frame(of: target) else { return ([], .cancel) }
        state.head = LiveStitcher.scaled(first, toWidth: LiveStitcher.previewWidth)
        state.onAutomatic = { [weak self] in self?.toggleAutomatic(target, in: frame) }
        showPanels(around: frame, finishes: finishes)
        watchForEscape()
        defer {
            stopWatchingForEscape()
            panels.forEach { $0.orderOut(nil) }
            panels = []
        }
        guard await startStream(target, size: CGSize(width: first.width, height: first.height),
                                excluding: panels.map { CGWindowID($0.windowNumber) }) else { return ([], .cancel) }

        // Scrolling, by hand or automatically, until the user says it is
        // done: at the end of the page nothing more comes in, and it waits.
        while finish == nil {
            try? await Task.sleep(for: .milliseconds(100))
            if grown > Self.heightLimit { finish = .copy }
        }
        stopAutomatic()
        let parts = await finishStream()
        guard let finish, finish != .cancel else { return ([], .cancel) }
        return (parts, finish)
    }

    /// Scrolls `target` on by `distance` points — to the end, without one —
    /// smoothly, with nothing on screen: for a macro being run. The long
    /// picture, in parts when very long.
    func runAutomatically(_ target: CaptureTarget, size: CGSize, distance: CGFloat?) async -> [CGImage] {
        guard let frame = ScreenCapture.frame(of: target),
              await startStream(target, size: size, excluding: []) else { return [] }
        watchForEscape()
        defer { stopWatchingForEscape() }
        // A moment for the first frame.
        try? await Task.sleep(for: .milliseconds(300))
        let scroller = SmoothScroller(at: Self.scrollPoint(in: frame), speed: Self.autoSpeed, distance: distance,
                                      shouldWait: { [stream] in stream?.isBehind ?? false })
        self.scroller = scroller
        lastGrowth = .now
        scroller.start()
        while finish == nil, !scroller.isDone, ContinuousClock.now - lastGrowth < Self.endAfter {
            try? await Task.sleep(for: .milliseconds(100))
        }
        stopAutomatic()
        // The last frames, as the view comes to rest.
        try? await Task.sleep(for: .milliseconds(400))
        return await finishStream()
    }

    // MARK: - Frames

    private func startStream(_ target: CaptureTarget, size: CGSize, excluding: [CGWindowID]) async -> Bool {
        let stitcher = self.stitcher
        let stream = FrameStream { [weak self] image in
            let outcome = stitcher.add(image)
            let taken = stitcher.taken
            // What came into view, small, for the preview to grow by; and,
            // the first time, the head it grows under, now that the bar at
            // the bottom that stays put is known.
            var slice: CGImage?, head: CGImage?
            if case .grew(let rows) = outcome, rows > 0 {
                slice = stitcher.previewSlices.last
                if stitcher.previewSlices.count == 1 { head = stitcher.previewHead() }
            }
            Task { @MainActor in self?.took(outcome, taken: taken, slice: slice, head: head) }
        }
        do {
            try await stream.start(target, size: size, excluding: excluding)
        } catch {
            return false
        }
        self.stream = stream
        lastGrowth = .now
        return true
    }

    private func took(_ outcome: LiveStitcher.Outcome, taken: Int, slice: CGImage?, head: CGImage?) {
        state.pages = taken
        if let head { state.head = head }
        if let slice { state.grow(by: slice) }
        switch outcome {
        case .grew(let rows):
            grown += rows
            if rows > 0 { lastGrowth = .now }
            lostFrames = 0
            state.lost = false
        case .unchanged:
            break
        case .lost:
            // A frame or two now and then is nothing; a run of them is the
            // view gone ahead of the join.
            lostFrames += 1
            if lostFrames >= 3 { state.lost = true }
        }
    }

    private func finishStream() async -> [CGImage] {
        guard let stream else { return [] }
        await stream.stop()
        self.stream = nil
        let stitcher = self.stitcher
        return await Task.detached { stitcher.finish() }.value
    }

    // MARK: - Scrolling for the user

    private func toggleAutomatic(_ target: CaptureTarget, in frame: CGRect) {
        if state.automatic { return stopAutomatic() }
        let scroller = SmoothScroller(at: Self.scrollPoint(in: frame), speed: Self.autoSpeed, distance: nil,
                                      shouldWait: { [stream] in stream?.isBehind ?? false })
        self.scroller = scroller
        lastGrowth = .now
        state.automatic = true
        scroller.start()
    }

    private func stopAutomatic() {
        scroller?.stop()
        scroller = nil
        state.automatic = false
    }

    /// Where to scroll: a quarter of the way down, clear of the Auto Scroll
    /// button in the middle, which would otherwise take the wheel.
    private static func scrollPoint(in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY + frame.height / 4)
    }

    /// The pointer moved to `point`, then a scroll of `distance` points
    /// there, in wheel-sized steps.
    static func scrollSteps(by distance: CGFloat, at point: CGPoint) -> [RecordedStep] {
        var steps: [RecordedStep] = []
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            steps.append(RecordedStep(event: move, delay: 0, app: nil))
        }
        let parts = max(1, Int((abs(distance) / 40).rounded(.up)))
        for _ in 0..<parts {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: Int32((distance / CGFloat(parts)).rounded()), wheel2: 0, wheel3: 0)
            else { continue }
            event.location = point
            steps.append(RecordedStep(event: event, delay: 0.012, app: nil))
        }
        return steps
    }

    // MARK: - Watching the screen

    /// A small look at the target, to compare with other looks.
    ///
    /// Only looks are compared with looks: a full capture made small draws
    /// fine print differently from one taken small, enough to count as
    /// another page.
    static func look(at target: CaptureTarget) async -> PageFingerprint? {
        guard let image = try? await ScreenCapture.grab(target, maxWidth: 640) else { return nil }
        return PageFingerprint(image)
    }

    // MARK: - Files

    static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// One multi-page TIFF, which is read as one document: one result, one
    /// export, one searchable PDF. Each page keeps its full resolution.
    nonisolated static func assemble(_ images: [CGImage], into url: URL) -> Bool {
        guard !images.isEmpty,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString,
                                                                images.count, nil) else { return false }
        let properties = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary
        for image in images { CGImageDestinationAddImage(destination, image, properties) }
        return CGImageDestinationFinalize(destination)
    }

    /// The same, from files of one page each.
    nonisolated static func assemble(_ pages: [URL], into url: URL) -> Bool {
        guard !pages.isEmpty,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString,
                                                                pages.count, nil) else { return false }
        // LZW: lossless, and screens of text shrink a lot.
        let properties = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary
        for page in pages {
            guard let source = CGImageSourceCreateWithURL(page as CFURL, nil) else { return false }
            CGImageDestinationAddImageFromSource(destination, source, 0, properties)
        }
        return CGImageDestinationFinalize(destination)
    }

    // MARK: - On screen

    private func showPanels(around area: CGRect, finishes: [CaptureFinish]) {
        // As while choosing: the rest dimmed. The wheel goes through.
        let shades = CaptureMarks.shades(around: area)
        let size = CaptureMarks.sizeLabel(for: area)
        let bar = CaptureMarks.bar(CaptureActionsBar(items: finishes) { [weak self] picked in
            self?.finish = picked
        }, beside: area)

        // In the middle of the area, the button that scrolls for the user.
        let buttonHost = FirstMouseHostingView(rootView: AutoScrollButton(state: state))
        let buttonSize = buttonHost.fittingSize
        let button = CaptureMarks.panel(CGRect(x: area.midX - buttonSize.width / 2, y: area.midY - buttonSize.height / 2,
                                               width: buttonSize.width, height: buttonSize.height))
        button.contentView = buttonHost

        // Beside it, on whichever side has more room, what has been joined.
        let screen = CaptureMarks.screenFrame(for: area)
        let width = min(max(area.width * 0.6, 160), 320)
        let right = screen.maxX - area.maxX >= area.minX - screen.minX
        let x = right ? min(area.maxX + 12, screen.maxX - width) : max(area.minX - 12 - width, screen.minX)
        let preview = CaptureMarks.panel(CGRect(x: x, y: area.minY, width: width, height: area.height))
        preview.ignoresMouseEvents = true
        preview.contentView = NSHostingView(rootView: JoinedPreview(state: state))

        panels = shades + [size, preview, button, bar]
        panels.forEach { $0.orderFrontRegardless() }
    }

    /// Escape lets it go, from any app. Only the user's own: OCRFlow's
    /// scrolling sends no keys, but a macro's steps may.
    private func watchForEscape() {
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard event.keyCode == 53,
                      event.cgEvent?.getIntegerValueField(.eventSourceUserData) != StepPlayer.marker else { return }
                if self?.finish == nil { self?.finish = .cancel }
            }
        }
    }

    private func stopWatchingForEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}

/// Scrolls smoothly: small steps sixty times a second, so the view glides
/// rather than jumps. Sent from a timer of its own, so its pace does not
/// depend on how busy the app is.
///
/// The window server sends the wheel to whatever is under the pointer, so
/// each step takes the pointer to what is scrolled and straight back to
/// where the user has it — without the pause in the user's own mouse
/// movements that follows an event sent this way by default. The pointer
/// stays the user's, to use meanwhile. (Sent to the app directly, or marked
/// as a trackpad gesture, the steps are ignored.)
final class SmoothScroller: @unchecked Sendable {
    private let point: CGPoint
    /// Points a second.
    private let speed: CGFloat
    private let distance: CGFloat?
    private let shouldWait: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "OCRFlow.scroll", qos: .userInteractive)
    private let source: CGEventSource?
    private var timer: DispatchSourceTimer?
    private var travelled: CGFloat = 0
    private let lock = NSLock()
    private var done = false

    /// Done once `distance` points have been scrolled, when given.
    var isDone: Bool { lock.withLock { done } }

    /// `shouldWait`: whether what follows the scrolling has fallen behind,
    /// and the next step had better wait for it.
    init(at point: CGPoint, speed: CGFloat, distance: CGFloat?, shouldWait: @escaping @Sendable () -> Bool) {
        self.point = point
        self.speed = speed
        self.distance = distance
        self.shouldWait = shouldWait
        source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / 60
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick(interval) }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func tick(_ interval: Double) {
        guard !shouldWait() else { return }
        // Whole points: what is sent is what is counted.
        var step = (speed * CGFloat(interval)).rounded()
        if let distance {
            step = min(step, (distance - travelled).rounded())
            if step < 0.5 {
                lock.withLock { done = true }
                timer?.cancel()
                timer = nil
                return
            }
        }
        send(step)
        travelled += step
    }

    private func send(_ step: CGFloat) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                  wheel1: Int32(-step), wheel2: 0, wheel3: 0) else { return }
        let user = CGEvent(source: nil)?.location
        event.location = point
        event.setIntegerValueField(.eventSourceUserData, value: StepPlayer.marker)
        if let now = CGEvent(source: nil)?.timestamp { event.timestamp = now }
        event.post(tap: .cghidEventTap)
        if let user {
            CGWarpMouseCursorPosition(user)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }
}

// MARK: - What is shown

@MainActor
@Observable
private final class ScrollRunState {
    /// Captured so far.
    var pages = 1
    /// OCRFlow scrolling, rather than the user.
    var automatic = false
    /// What has been joined so far, small: the first frame, then each strip
    /// that came into view, in order.
    var head: CGImage?
    var strips: [CGImage] = []

    /// A strip more. Many small ones become one now and then, so there are
    /// never many to lay out.
    func grow(by strip: CGImage) {
        strips.append(strip)
        if strips.count > 48, let joined = LiveStitcher.stack(Array(strips.prefix(40))) {
            strips = [joined] + strips.dropFirst(40)
        }
    }
    /// The last screenful would not join to the one before.
    var lost = false

    @ObservationIgnored var onAutomatic: () -> Void = {}
}

private struct AutoScrollButton: View {
    let state: ScrollRunState

    var body: some View {
        Button { state.onAutomatic() } label: {
            Label(state.automatic ? "Stop Scrolling" : "Auto Scroll",
                  systemImage: state.automatic ? "pause.fill" : "arrow.down")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.78), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Scroll by hand at your own pace, or let OCRFlow scroll. Stop wherever you want the picture to end.")
    }
}

private struct JoinedPreview: View {
    let state: ScrollRunState

    /// The newest part, at the bottom, as the page grows a strip at a time:
    /// what was just scrolled to is what the user wants to see joined.
    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { space in
                VStack(spacing: 0) {
                    ForEach(Array(([state.head].compactMap { $0 } + state.strips).enumerated()), id: \.offset) { _, strip in
                        Image(decorative: strip, scale: 1)
                            .resizable()
                            .frame(width: space.size.width,
                                   height: space.size.width * CGFloat(strip.height) / CGFloat(max(strip.width, 1)))
                    }
                }
                .frame(width: space.size.width, height: space.size.height, alignment: .bottom)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
            }
            Text(state.lost ? "Too fast: scroll back a little, then on more slowly"
                            : "\(state.pages) captured")
                .font(.caption)
                .foregroundStyle(state.lost ? Color.orange : Color.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6), in: Capsule())
        }
    }
}
