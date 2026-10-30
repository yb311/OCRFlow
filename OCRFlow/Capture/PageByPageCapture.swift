import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Takes a document shown on screen page after page: a slide deck in a
/// browser, a PDF in a web viewer, an e-book.
///
/// The user chooses what to capture, then turns to the next page once the
/// way they normally would — a click on a button, an arrow key, a scroll —
/// while it is recorded. That is repeated, capturing each page once it has
/// finished drawing, until the page stops changing: the last page.
///
/// Nothing about any app or site is known. It works from what the user did
/// and what the screen shows.
@MainActor
final class PageByPageCapture {
    /// However long the document, a run ends here.
    static let pageLimit = 300

    private let state = PageRunState()
    private var panel: NSPanel?
    private var stopRequested = false
    private var escapeMonitor: Any?
    /// Whether the pages were turned by scrolling, which makes them one long
    /// picture rather than pages.
    private(set) var turnedByScrolling = false

    /// The pages, as files in a folder of their own, in order. Empty when
    /// cancelled.
    func run() async -> [URL] {
        guard InputControl.isAllowed() else { return [] }
        guard let first = await ScreenCapture.choose(returnFocus: true),
              let firstPrint = await Self.look(at: first.target) else { return [] }
        let target = first.target
        let folder = URL.temporaryDirectory
            .appending(path: "OCRFlow Pages \(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var pages: [URL] = []
        func keep(_ image: CGImage) {
            let url = folder.appending(path: String(format: "%04d.png", pages.count + 1))
            if Self.write(image, to: url) { pages.append(url) }
        }
        keep(first.image)

        // The user shows how to turn the page.
        let recordedFrame = ScreenCapture.frame(of: target)
        showPanel(avoiding: recordedFrame)
        let recorder = StepRecorder()
        recorder.onChange = { [state, recorder] in state.actions = recorder.actions }
        recorder.start()
        let proceed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // A second click before the panel changes must not answer twice.
            var answered = false
            func answer(_ proceed: Bool) {
                guard !answered else { return }
                answered = true
                continuation.resume(returning: proceed)
            }
            state.onDone = { answer(true) }
            state.onCancel = { answer(false) }
        }
        state.onDone = {}
        state.onCancel = {}
        let steps = recorder.stop()
        guard proceed, !steps.isEmpty else {
            closePanel()
            try? FileManager.default.removeItem(at: folder)
            return []
        }

        turnedByScrolling = steps.allSatisfy { $0.event.type == .scrollWheel || $0.event.type == .mouseMoved }

        // Then it is done again and again.
        state.phase = .running
        state.onStop = { [weak self] in self?.stopRequested = true }
        watchForEscape()
        await turnPages(with: steps, of: target, recordedFrame: recordedFrame, first: firstPrint) { image in
            keep(image)
            state.pages = pages.count
            return pages.count
        }
        stopWatchingForEscape()
        closePanel()
        return pages
    }

    /// Scrolls what the user chooses from top to bottom, a screenful at a
    /// time, capturing each. The pictures, in order, to be joined into one
    /// long one; empty when cancelled.
    func runScrolling() async -> [URL] {
        guard InputControl.isAllowed() else { return [] }
        guard let first = await ScreenCapture.choose(returnFocus: true),
              let firstPrint = await Self.look(at: first.target),
              let frame = ScreenCapture.frame(of: first.target) else { return [] }
        let target = first.target
        let folder = URL.temporaryDirectory
            .appending(path: "OCRFlow Pages \(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var pages: [URL] = []
        func keep(_ image: CGImage) {
            let url = folder.appending(path: String(format: "%04d.png", pages.count + 1))
            if Self.write(image, to: url) { pages.append(url) }
        }
        keep(first.image)
        turnedByScrolling = true

        // Most of a screenful down, from the middle of it, so each picture
        // shares a band with the one before to be joined along.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: frame.midX, y: top - frame.midY)
        let steps = Self.scrollSteps(by: -(frame.height * 0.7).rounded(), at: point)

        state.phase = .running
        state.onStop = { [weak self] in self?.stopRequested = true }
        showPanel(avoiding: frame)
        watchForEscape()
        await turnPages(with: steps, of: target, recordedFrame: frame, first: firstPrint, alreadyTurned: false) { image in
            keep(image)
            state.pages = pages.count
            return pages.count
        }
        stopWatchingForEscape()
        closePanel()
        return pages
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

    /// Turns page after page with the recorded steps, handing each new page to
    /// `keep`, which says how many there are now. Ends at the last page, at
    /// the limit, or when stopped. Unless `alreadyTurned` is false, the first
    /// turn has been made already, by the user. `first` is a look at the
    /// first page, taken with `look(at:)`.
    func turnPages(with steps: [RecordedStep], of target: CaptureTarget, recordedFrame: CGRect?,
                   first: PageFingerprint, alreadyTurned: Bool = true, keep: (CGImage) -> Int) async {
        var last = first
        var count = 1
        var turned = alreadyTurned
        while !stopRequested, count < Self.pageLimit {
            if !turned {
                await StepPlayer.play(steps, offset: offset(of: target, from: recordedFrame)) { [weak self] in
                    self?.stopRequested ?? true
                }
            }
            turned = false
            guard let page = await nextPage(of: target, after: last),
                  // Back at the start: a deck that goes round.
                  count < 2 || !page.print.isSamePage(as: first) else { return }
            count = keep(page.image)
            last = page.print
        }
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

    /// Waits for the target to show something new, then for it to finish
    /// drawing, and takes it, with the look it settled on. Nil when nothing
    /// changes — the last page — or the run was stopped.
    private func nextPage(of target: CaptureTarget,
                          after last: PageFingerprint) async -> (image: CGImage, print: PageFingerprint)? {
        func look() async -> PageFingerprint? { await Self.look(at: target) }

        // A page that loads takes a moment to start changing.
        var current: PageFingerprint?
        let changeBy = Date().addingTimeInterval(6)
        while !stopRequested, Date() < changeBy {
            guard let print = await look() else { return nil }
            if !print.isSamePage(as: last) {
                current = print
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard var current else { return nil }

        // Settled once two looks in a row agree: slides fade in, pages load
        // their pictures, scrolling glides to a stop.
        let settleBy = Date().addingTimeInterval(8)
        while !stopRequested, Date() < settleBy {
            try? await Task.sleep(for: .milliseconds(250))
            guard let print = await look() else { return nil }
            if print.isSamePage(as: current) { break }
            current = print
        }
        guard !stopRequested, let image = try? await ScreenCapture.grab(target) else { return nil }
        return (image, current)
    }

    /// How far a captured window has moved since the steps were recorded,
    /// in the coordinates events use, whose y runs downward.
    private func offset(of target: CaptureTarget, from recorded: CGRect?) -> CGVector {
        guard case .window = target, let recorded, let now = ScreenCapture.frame(of: target) else { return .zero }
        return CGVector(dx: now.minX - recorded.minX, dy: recorded.maxY - now.maxY)
    }

    /// Escape stops the run from any app. Only the user's own: the steps
    /// being repeated may well press it themselves.
    private func watchForEscape() {
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard event.keyCode == 53,
                      event.cgEvent?.getIntegerValueField(.eventSourceUserData) != StepPlayer.marker else { return }
                self?.stopRequested = true
            }
        }
    }

    private func stopWatchingForEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
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

    // MARK: - Panel

    private func showPanel(avoiding target: CGRect?) {
        panel = HUDPanel.show(PageRunView(state: state), avoiding: target)
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - What the panel shows

@MainActor
@Observable
private final class PageRunState {
    enum Phase { case recording, running }

    var phase = Phase.recording
    /// Clicks, keys and scrolls recorded so far.
    var actions = 0
    /// Captured so far.
    var pages = 1

    @ObservationIgnored var onDone: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}
    @ObservationIgnored var onStop: () -> Void = {}
}

private struct PageRunView: View {
    let state: PageRunState

    var body: some View {
        Group {
            switch state.phase {
            case .recording: recording
            case .running: running
            }
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Show OCRFlow how to turn the page")
            } icon: {
                Image(systemName: "record.circle").foregroundStyle(.red)
            }
            .font(.headline)
            Text("Page 1 is captured. Now go to the next page the way you normally would — click, press a key or scroll — then click Done.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(state.actions == 0 ? "Waiting for you…" : "Recorded: \(state.actions)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel") { state.onCancel() }
                Button("Done") { state.onDone() }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.actions == 0)
            }
        }
    }

    private var running: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Capturing page \(state.pages + 1)…")
                    .font(.headline)
                    .monospacedDigit()
                Text("Stops by itself at the last page. Press Esc to stop now; leave the mouse and keyboard alone meanwhile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Stop") { state.onStop() }
        }
    }
}
