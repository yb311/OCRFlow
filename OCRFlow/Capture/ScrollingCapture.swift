import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Takes something too long for the screen — a web page, a document, a
/// chat — scrolled through, into one long picture.
///
/// It is joined while it scrolls, from the frames of the screen as they
/// change, the way a recording sees them: the user scrolls by hand at their
/// own pace, or Auto Scroll scrolls for them, smoothly, as a trackpad would.
/// The two are one: Auto Scroll only does the scrolling, and the moment the
/// user moves the pointer or scrolls, it stops and they go on by hand. What
/// has been joined is shown beside it as it grows, gliding up. Nothing about
/// any app or site is known; it works from what the screen shows.
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
    private var takeoverMonitor: Any?
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
        guard await startStream(target, size: CGSize(width: first.width, height: first.height))
        else { return ([], .cancel) }

        // Scrolling, by hand or automatically, until the user says it is
        // done: at the end of the page nothing more comes in, and it waits.
        while finish == nil {
            try? await Task.sleep(for: .milliseconds(50))
            // The user took the pointer back.
            if scroller?.isDone == true { stopAutomatic() }
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
              await startStream(target, size: size) else { return [] }
        watchForEscape()
        defer { stopWatchingForEscape() }
        // A moment for the first frame.
        try? await Task.sleep(for: .milliseconds(300))
        let scroller = SmoothScroller(at: Self.scrollPoint(in: frame), speed: Self.autoSpeed, distance: distance,
                                      yields: false, isBehind: { [stream] in stream?.isBehind ?? false })
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

    private func startStream(_ target: CaptureTarget, size: CGSize) async -> Bool {
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
            try await stream.start(target, size: size)
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

    /// The pointer goes onto the area, where the wheel is sent, and stays
    /// there while it scrolls. Moved, or a scroll of the user's own, and it
    /// stops: the pointer and the scrolling are theirs again.
    private func toggleAutomatic(_ target: CaptureTarget, in frame: CGRect) {
        if state.automatic { return stopAutomatic() }
        let scroller = SmoothScroller(at: Self.scrollPoint(in: frame), speed: Self.autoSpeed, distance: nil,
                                      yields: true, isBehind: { [stream] in stream?.isBehind ?? false })
        self.scroller = scroller
        lastGrowth = .now
        state.automatic = true
        scroller.start()
        takeoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            MainActor.assumeIsolated {
                // Not its own steps, nor a swipe of the user's from before
                // still coasting.
                guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != StepPlayer.marker,
                      event.momentumPhase.isEmpty else { return }
                self?.stopAutomatic()
            }
        }
    }

    private func stopAutomatic() {
        scroller?.stop()
        scroller = nil
        state.automatic = false
        if let takeoverMonitor { NSEvent.removeMonitor(takeoverMonitor) }
        takeoverMonitor = nil
    }

    /// Where to scroll: the middle.
    private static func scrollPoint(in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.midY)
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

        // Beside it, on whichever side has more room, the button that
        // scrolls for the user and under it what has been joined. Nothing is
        // over the area: there the pointer and the wheel are the user's.
        let screen = CaptureMarks.screenFrame(for: area)
        let width = min(max(area.width * 0.6, 160), 320)
        let right = screen.maxX - area.maxX >= area.minX - screen.minX
        let x = right ? min(area.maxX + 12, screen.maxX - width) : max(area.minX - 12 - width, screen.minX)
        let buttonHost = FirstMouseHostingView(rootView: AutoScrollButton(state: state))
        let buttonHeight = buttonHost.fittingSize.height
        // As wide as the column, so the longer "Stop Scrolling" fits too.
        let button = CaptureMarks.panel(CGRect(x: x, y: area.maxY - buttonHeight, width: width, height: buttonHeight))
        button.contentView = buttonHost
        let previewHeight = max(area.height - buttonHeight - 8, 80)
        let preview = CaptureMarks.panel(CGRect(x: x, y: area.maxY - buttonHeight - 8 - previewHeight,
                                                width: width, height: previewHeight))
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

/// Scrolls smoothly, the way a trackpad does: a step each time the screen
/// is drawn, as far as the time since the last asks, easing in at the start
/// — so the view glides rather than jumps. Sent from a thread of its own,
/// so its pace does not depend on how busy the app is.
///
/// The window server sends the wheel to whatever is under the pointer, so
/// the pointer is put on what is scrolled when it starts, once, and left
/// there — as scrolling capture tools do. (Sent to the app directly, or
/// marked as a trackpad gesture, the steps are ignored; and a step sent
/// somewhere else takes the pointer there with it.) `yields`: for the user,
/// who may take over at any moment — the pointer moved, it stops, and the
/// pointer is theirs. Otherwise, for a macro, the pointer is kept there
/// until it is done, then put back where it was.
final class SmoothScroller: NSObject, @unchecked Sendable {
    private let point: CGPoint
    /// Points a second.
    private let speed: CGFloat
    private let distance: CGFloat?
    private let yields: Bool
    private let isBehind: @Sendable () -> Bool
    private let source: CGEventSource?
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    /// Of `speed`, now.
    private var pace: CGFloat = 0
    /// How far it has scrolled, exactly, and in the whole points sent.
    private var travelled: CGFloat = 0
    private var sent: CGFloat = 0
    private var pointer: CGPoint?
    private let lock = NSLock()
    private var stopping = false
    private var done = false

    /// Stopped: at the end of `distance`, when given; told to; or for the user.
    var isDone: Bool { lock.withLock { done } }

    /// `point` is in event coordinates. `isBehind`: whether what follows the
    /// scrolling has fallen behind, and it had better go slower for a while.
    init(at point: CGPoint, speed: CGFloat, distance: CGFloat?, yields: Bool,
         isBehind: @escaping @Sendable () -> Bool) {
        self.point = point
        self.speed = speed
        self.distance = distance
        self.yields = yields
        self.isBehind = isBehind
        source = CGEventSource(stateID: .combinedSessionState)
        // The user's own mouse is not held up after the pointer is moved.
        source?.localEventsSuppressionInterval = 0
    }

    @MainActor func start() {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: point.x, y: top - point.y)) } ?? NSScreen.main
        guard let link = screen?.displayLink(target: self, selector: #selector(step(_:))) else {
            return lock.withLock { done = true }
        }
        pointer = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        self.link = link
        nonisolated(unsafe) let unsent = link
        let thread = Thread {
            unsent.add(to: .current, forMode: .default)
            CFRunLoopRun()
        }
        thread.name = "OCRFlow.scroll"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops before the next step.
    func stop() {
        lock.withLock { stopping = true }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard !lock.withLock({ stopping }) else { return halt() }
        let now = link.targetTimestamp
        defer { last = now }
        guard let last else { return }
        if yields, let at = CGEvent(source: nil)?.location, hypot(at.x - point.x, at.y - point.y) > 3 {
            return halt()
        }
        let interval = CGFloat(min(now - last, 0.05))
        // Easing in, as a finger does; and easing off while the joining
        // catches up, rather than stopping short.
        pace += ((isBehind() ? 0.4 : 1) - pace) * min(1, interval / 0.2)
        travelled += speed * pace * interval
        if let distance { travelled = min(travelled, distance) }
        // Whole points: what is sent is what is counted.
        let whole = travelled.rounded(.down) - sent
        if whole >= 1 {
            send(whole)
            sent += whole
        }
        if let distance, sent >= distance.rounded(.down) { halt() }
    }

    /// On the scrolling thread.
    private func halt() {
        link?.invalidate()
        link = nil
        if !yields, let pointer {
            CGWarpMouseCursorPosition(pointer)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        lock.withLock { done = true }
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    private func send(_ step: CGFloat) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                  wheel1: Int32(-step), wheel2: 0, wheel3: 0) else { return }
        event.location = point
        event.setIntegerValueField(.eventSourceUserData, value: StepPlayer.marker)
        if let now = CGEvent(source: nil)?.timestamp { event.timestamp = now }
        event.post(tap: .cghidEventTap)
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
    /// What has been joined, small: the first frame, then each strip that
    /// came into view, in order — less what has gone far above what the
    /// preview shows.
    var head: CGImage?
    private(set) var strips: [Strip] = []
    /// Rows the strips have added, in all: how far the preview has moved.
    private(set) var grown = 0
    @ObservationIgnored private var count = 0
    /// Strips at the end not yet made one.
    @ObservationIgnored private var loose = 0

    struct Strip: Identifiable {
        let id: Int
        let image: CGImage
    }

    /// Rows, at the preview's width, more than any preview shows.
    private static let kept = 4000

    /// A strip more. Many small ones become one now and then, so there are
    /// never many to lay out, and those far above the preview go.
    func grow(by strip: CGImage) {
        add(strip)
        grown += strip.height
        loose += 1
        if loose >= 24, let joined = LiveStitcher.stack(strips.suffix(loose).map(\.image)) {
            strips.removeLast(loose)
            add(joined)
            loose = 0
        }
        var rows = 0
        var first = strips.count
        while first > 0, rows < Self.kept {
            first -= 1
            rows += strips[first].image.height
        }
        if first > 0 {
            strips.removeFirst(first)
            head = nil
        }
    }

    private func add(_ image: CGImage) {
        strips.append(Strip(id: count, image: image))
        count += 1
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
    /// what was just scrolled to is what the user wants to see joined. It
    /// glides up as it grows, as the page itself moves, rather than jumping
    /// a strip at a time.
    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { space in
                let width = space.size.width
                let grown = CGFloat(state.grown) * width / CGFloat(LiveStitcher.previewWidth)
                VStack(spacing: 0) {
                    if let head = state.head { picture(head, width: width) }
                    ForEach(state.strips) { picture($0.image, width: width) }
                }
                .animation(.smooth(duration: 0.3)) { $0.modifier(Glide(shown: grown, target: grown)) }
                .frame(width: width, height: space.size.height, alignment: .bottom)
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

    private func picture(_ image: CGImage, width: CGFloat) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: width, height: width * CGFloat(image.height) / CGFloat(max(image.width, 1)))
    }
}

/// Held back by however far it has yet to go: as `shown` is animated on to
/// `target`, what was just added slides up into view.
private struct Glide: ViewModifier, Animatable {
    var shown: CGFloat
    let target: CGFloat

    nonisolated var animatableData: CGFloat {
        get { shown }
        set { shown = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(y: target - shown)
    }
}
