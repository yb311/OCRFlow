import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Takes something too long for the screen — a web page, a document, a
/// chat — scrolled through, capturing as it goes, to be joined into one long
/// picture.
///
/// The user scrolls it, at their own pace, to wherever they want it to end,
/// or has OCRFlow scroll it a screenful at a time. What has been joined so
/// far is shown beside it as it grows. Nothing about any app or site is
/// known: it works from what the screen shows.
@MainActor
final class ScrollingCapture {
    /// However long the page, a run ends here.
    static let pageLimit = 300

    private let state = ScrollRunState()
    private var panels: [NSPanel] = []
    private var stopRequested = false
    private var escapeMonitor: Any?
    private var finish: CaptureFinish?
    private let folder = URL.temporaryDirectory
        .appending(path: "OCRFlow Pages \(UUID().uuidString)", directoryHint: .isDirectory)
    private var pages: [URL] = []
    private var joining = false

    /// Takes `target` scrolled through, from `first` — a picture of it as it
    /// is now — until the user picks one of `finishes` from the bar. The
    /// pictures, in order, to be joined, and what was picked; nothing when
    /// cancelled.
    func run(_ target: CaptureTarget, first: CGImage,
             finishes: [CaptureFinish] = [.cancel, .recognize, .save, .copy]) async -> (pages: [URL], finish: CaptureFinish) {
        guard InputControl.isAllowed(), let firstPrint = await Self.look(at: target),
              let frame = ScreenCapture.frame(of: target) else { return ([], .cancel) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Every picture the size of the first, to be joined.
        let size = CGSize(width: first.width, height: first.height)
        // Taken again: the first was taken while choosing, its window in the
        // background, and a background window's title bar is lighter than
        // in the rest.
        keep((try? await ScreenCapture.grab(target, like: size)) ?? first)
        let steps = Self.scrollSteps(by: -(frame.height * 0.7).rounded(), at: Self.eventPoint(frame))

        state.preview = first
        state.onAutomatic = { [state] in state.automatic.toggle() }
        showPanels(around: frame, finishes: finishes)
        watchForEscape()

        var last = firstPrint
        var missed = 0
        while finish == nil, pages.count < Self.pageLimit {
            if state.automatic {
                await StepPlayer.play(steps, offset: .zero) { [weak self] in self?.finish != nil }
                guard let page = await nextPage(of: target, after: last, size: size) else {
                    // The end: the user picks what to do with it.
                    state.automatic = false
                    continue
                }
                keep(page.image)
                last = page.print
                continue
            }
            // By hand: whatever the user has scrolled to, as often as it
            // changes, so neighbours overlap however fast they go.
            try? await Task.sleep(for: .milliseconds(150))
            guard let look = await Self.look(at: target) else {
                // The window closed: nothing left to scroll.
                missed += 1
                if missed > 10 { finish = .cancel }
                continue
            }
            missed = 0
            guard !look.isSamePage(as: last), let image = try? await ScreenCapture.grab(target, like: size),
                  // A window being resized or minimized is no screenful.
                  abs(CGFloat(image.width) - size.width) <= 4, abs(CGFloat(image.height) - size.height) <= 4 else { continue }
            keep(image)
            last = look
        }
        stopWatchingForEscape()
        panels.forEach { $0.orderOut(nil) }
        panels = []
        let finish = finish ?? .copy
        guard finish != .cancel else {
            try? FileManager.default.removeItem(at: folder)
            return ([], .cancel)
        }
        return (pages, finish)
    }

    /// Scrolls `target` on from `first` by `distance` points — to the end,
    /// without one — a screenful at a time, with nothing on screen: for a
    /// macro being run. The pictures, in order, to be joined.
    func runAutomatically(_ target: CaptureTarget, first: CGImage, distance: CGFloat?) async -> [URL] {
        guard let firstPrint = await Self.look(at: target), let frame = ScreenCapture.frame(of: target) else { return [] }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        keep(first)
        let size = CGSize(width: first.width, height: first.height)
        let screenful = (frame.height * 0.7).rounded()
        var remaining = distance ?? .infinity
        var last = firstPrint
        watchForEscape()
        defer { stopWatchingForEscape() }
        while !stopRequested, remaining > 0.5, pages.count < Self.pageLimit {
            let step = min(screenful, remaining)
            remaining -= step
            await StepPlayer.play(Self.scrollSteps(by: -step, at: Self.eventPoint(frame)), offset: .zero) { [weak self] in
                self?.stopRequested ?? true
            }
            guard let page = await nextPage(of: target, after: last, size: size) else { break }
            keep(page.image)
            last = page.print
        }
        return pages
    }

    private func keep(_ image: CGImage) {
        let url = folder.appending(path: String(format: "%04d.png", pages.count + 1))
        guard Self.write(image, to: url) else { return }
        pages.append(url)
        state.pages = pages.count
        if pages.count > 1 { joinForPreview() }
    }

    /// What has been joined so far, shown as it grows — and word when the
    /// newest screenful would not join, while there is time to scroll back.
    private func joinForPreview() {
        guard !joining else { return }
        joining = true
        let pages = self.pages
        Task {
            let joined = await Task.detached {
                ScrollStitcher.join(count: pages.count) { index in
                    CGImageSourceCreateWithURL(pages[index] as CFURL, nil)
                        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                }
            }.value
            joining = false
            if let joined {
                state.preview = joined.parts.first
                // The newest left out: scrolled too far at once.
                state.lost = !joined.usesLast
            } else {
                state.lost = true
            }
            // More may have come in meanwhile.
            if self.pages.count != pages.count, finish == nil { joinForPreview() }
        }
    }

    /// Where to scroll: a quarter of the way down, clear of the Auto Scroll
    /// button in the middle, which would otherwise take the wheel.
    private static func eventPoint(_ frame: CGRect) -> CGPoint {
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

    /// Waits for the target to show something new, then for it to finish
    /// drawing, and takes it, with the look it settled on. Nil when nothing
    /// changes — the last page — or the run was stopped.
    private func nextPage(of target: CaptureTarget, after last: PageFingerprint,
                          size: CGSize?) async -> (image: CGImage, print: PageFingerprint)? {
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
        guard !stopRequested, let image = try? await ScreenCapture.grab(target, like: size) else { return nil }
        return (image, current)
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
        let outline = CaptureMarks.outline(area, catchesClicks: false)
        let size = CaptureMarks.sizeLabel(for: area)
        let bar = CaptureMarks.bar(CaptureActionsBar(items: finishes) { [weak self] picked in
            self?.finish = picked
            self?.stopRequested = true
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

        panels = [outline, size, preview, button, bar]
        panels.forEach { $0.orderFrontRegardless() }
    }

    /// Escape lets it go, from any app. Only the user's own: OCRFlow's
    /// scrolling sends no keys, but a macro's steps may.
    private func watchForEscape() {
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard event.keyCode == 53,
                      event.cgEvent?.getIntegerValueField(.eventSourceUserData) != StepPlayer.marker else { return }
                self?.stopRequested = true
                if self?.finish == nil { self?.finish = .cancel }
            }
        }
    }

    private func stopWatchingForEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
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
    /// What has been joined so far.
    var preview: CGImage?
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

    /// The newest part, at the bottom, as the page grows: what was just
    /// scrolled to is what the user wants to see joined.
    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { space in
                if let preview = state.preview {
                    let height = space.size.width * CGFloat(preview.height) / CGFloat(max(preview.width, 1))
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .frame(width: space.size.width, height: height)
                        .frame(width: space.size.width, height: space.size.height, alignment: .bottom)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                }
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
