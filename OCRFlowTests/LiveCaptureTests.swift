import XCTest
import Vision
@testable import OCRFlow

/// Capture, recording and repeating on the real screen, against a small
/// five-page "document" app — or, for scrolling, one long page. They take over the mouse and keyboard for a
/// few seconds, and need Screen Recording and Accessibility permission for
/// the test host, so they only run when asked for:
///
///     TEST_RUNNER_OCRFLOW_LIVE_SLIDES=<path to the built slides helper> xcodebuild test \
///         -only-testing:OCRFlowTests/LiveCaptureTests …
///
/// Run them on their own: the other tests run in parallel, and their work on
/// the main thread holds up the events and captures these wait for.
///
/// The helper is `Scripts/slides.swift`, built with `swiftc -O`. Sign the
/// test host with a real identity (`CODE_SIGN_IDENTITY="Developer ID
/// Application"`): an ad-hoc signature changes with every build, and the
/// permissions with it.
@MainActor
final class LiveCaptureTests: XCTestCase {
    private struct Slides {
        let process: Process
        let window: CGWindowID
        /// In event coordinates: from the main display's top-left, y down.
        let frame: CGRect
        let button: CGPoint
    }

    private var slides: Slides?
    private var helper = ""

    override func setUp() async throws {
        guard let helper = ProcessInfo.processInfo.environment["OCRFLOW_LIVE_SLIDES"] else {
            throw XCTSkip("Set OCRFLOW_LIVE_SLIDES to run the live capture tests")
        }
        // Asking puts the test host in System Settings' lists, ready to be
        // turned on.
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !AXIsProcessTrusted() { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
        try XCTSkipUnless(CGPreflightScreenCaptureAccess() && AXIsProcessTrusted(),
                          "Turn on Screen Recording (\(CGPreflightScreenCaptureAccess())) and Accessibility "
                          + "(\(AXIsProcessTrusted())) for \(Bundle.main.bundlePath), then run again")
        self.helper = helper
        slides = try await launch(helper)
    }

    override func tearDown() async throws {
        slides?.process.terminate()
        slides = nil
    }

    private func launch(_ helper: String, scrolling: Bool = false) async throws -> Slides {
        let info = URL.temporaryDirectory.appending(path: "slides-\(UUID().uuidString).json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = [info.path] + (scrolling ? ["scroll"] : [])
        try process.run()
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: info.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(500))
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: info)) as? [String: Double])
        return Slides(process: process, window: CGWindowID(values["id"]!),
                      frame: CGRect(x: values["x"]!, y: values["y"]!, width: values["w"]!, height: values["h"]!),
                      button: CGPoint(x: values["bx"]!, y: values["by"]!))
    }

    /// What the user would do, posted as if they did it.
    private func press(_ key: CGKeyCode) {
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    private func click(_ point: CGPoint) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    private func text(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Records what `turn` does to turn from page 1 to page 2, as the user
    /// would show it, then turns the rest of the slides with it.
    private func capturePages(turn: () async throws -> Void,
                              afterRecording: () async throws -> Void = {}) async throws -> [CGImage] {
        let slides = try XCTUnwrap(slides)
        let target = CaptureTarget.window(slides.window)
        let first = try await ScreenCapture.grab(target)
        let look = await PageByPageCapture.look(at: target)
        let firstLook = try XCTUnwrap(look)
        let frame = ScreenCapture.frame(of: target)

        let recorder = StepRecorder()
        recorder.start()
        try await turn()
        try await Task.sleep(for: .milliseconds(400))
        let steps = recorder.stop()
        XCTAssertEqual(recorder.actions, 1)
        try await afterRecording()

        var pages = [first]
        await PageByPageCapture().turnPages(with: steps, of: target, recordedFrame: frame, first: firstLook) { image in
            pages.append(image)
            return pages.count
        }
        return pages
    }

    private func assertSlides(_ pages: [CGImage], file: StaticString = #filePath, line: UInt = #line) throws {
        let texts = try pages.map { try text(in: $0) }
        XCTAssertEqual(pages.count, 5, "\(texts)", file: file, line: line)
        for (index, text) in texts.enumerated() {
            XCTAssertTrue(text.contains("Page \(index + 1)"), "page \(index + 1) read \(text)", file: file, line: line)
        }
    }

    // MARK: -

    func testCapturesTheScreenAndOneWindow() async throws {
        let slides = try XCTUnwrap(slides)
        let shots = try await ScreenGrabber.displays(excluding: [])
        XCTAssertEqual(shots.count, NSScreen.screens.count)
        for screen in NSScreen.screens {
            let shot = try XCTUnwrap(shots[try XCTUnwrap(screen.displayID)])
            XCTAssertEqual(shot.width, Int(screen.frame.width * screen.backingScaleFactor))
        }

        let window = try await ScreenCapture.grab(.window(slides.window))
        let scale = NSScreen.screens.first { $0.frame.contains(CGPoint(x: slides.frame.midX, y: 10)) }?.backingScaleFactor
            ?? NSScreen.screens[0].backingScaleFactor
        XCTAssertEqual(Double(window.width), slides.frame.width * scale, accuracy: 2)
        XCTAssertTrue(try text(in: window).contains("Page 1"))

        // Part of the main display: the slide's title, wherever the window is.
        let main = try XCTUnwrap(NSScreen.screens[0].displayID)
        let title = CGRect(x: slides.frame.minX, y: slides.frame.minY + 28, width: 400, height: 120)
        let region = try await ScreenCapture.grab(.region(display: main, rect: title))
        XCTAssertEqual(region.width, Int(400 * NSScreen.screens[0].backingScaleFactor))
        XCTAssertTrue(try text(in: region).contains("Page 1"))
    }

    func testRepeatsAnArrowKeyToTheLastPage() async throws {
        let pages = try await capturePages(turn: {
            press(124)   // →
        })
        try assertSlides(pages)
    }

    /// A click on the page's Next button, repeated after the window has been
    /// moved: the clicks follow it.
    func testRepeatsAClickOnAWindowThatMoved() async throws {
        let slides = try XCTUnwrap(slides)
        // Where the window server put the window, which may not be where
        // the helper asked for it.
        let frame = try XCTUnwrap(ScreenCapture.frame(of: .window(slides.window)))
        let top = NSScreen.screens[0].frame.maxY
        // The button sits 20 points up from the bottom and 30 in from the
        // right edge, 90 by 32.
        let button = CGPoint(x: frame.maxX - 30 - 45, y: top - (frame.minY + 20 + 16))
        let pages = try await capturePages(turn: {
            click(button)
        }, afterRecording: {
            // Moved after the click is recorded, before it is repeated.
            kill(slides.process.processIdentifier, SIGUSR1)
            try await Task.sleep(for: .milliseconds(300))
        })
        XCTAssertNotEqual(ScreenCapture.frame(of: .window(slides.window))?.origin.x, frame.minX)
        try assertSlides(pages)
    }

    // MARK: - Choosing

    private func drag(from start: CGPoint, to end: CGPoint) async throws {
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        for step in 1...10 {
            try await Task.sleep(for: .milliseconds(20))
            let t = CGFloat(step) / 10
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// The held screen, with the real pointer and keyboard: a drag takes an
    /// area, Escape cancels, a click takes the window under it by itself.
    func testChoosesWithThePointerAndKeyboard() async throws {
        let slides = try XCTUnwrap(slides)
        let frame = try XCTUnwrap(ScreenCapture.frame(of: .window(slides.window)))
        let top = NSScreen.screens[0].frame.maxY
        // The slide's title, from just inside the window's top-left.
        let start = CGPoint(x: frame.minX + 20, y: top - frame.maxY + 40)
        let end = CGPoint(x: start.x + 400, y: start.y + 120)

        let dragged = Task { await ScreenCapture.choose() }
        try await Task.sleep(for: .milliseconds(1200))
        try await drag(from: start, to: end)
        let area = await dragged.value
        guard case let .region(_, rect)? = area?.target else { return XCTFail("no area: \(String(describing: area?.target))") }
        XCTAssertEqual(rect.width, 400, accuracy: 1)
        XCTAssertEqual(rect.height, 120, accuracy: 1)
        XCTAssertTrue(try text(in: try XCTUnwrap(area?.image)).contains("Page 1"))

        let escaped = Task { await ScreenCapture.choose() }
        try await Task.sleep(for: .milliseconds(1200))
        press(53)   // Escape
        let none = await escaped.value
        XCTAssertNil(none?.target)

        let clicked = Task { await ScreenCapture.choose() }
        try await Task.sleep(for: .milliseconds(1200))
        click(CGPoint(x: frame.midX, y: top - frame.midY))
        let window = await clicked.value
        XCTAssertEqual(window?.target, .window(slides.window))
        XCTAssertTrue(try text(in: try XCTUnwrap(window?.image)).contains("Page 1"))
    }

    /// The whole of Capture Page by Page, as the user goes through it: click
    /// the window, turn the page once, click Done on the panel.
    func testCapturesPageByPageFromStartToFinish() async throws {
        let slides = try XCTUnwrap(slides)
        let frame = try XCTUnwrap(ScreenCapture.frame(of: .window(slides.window)))
        let top = NSScreen.screens[0].frame.maxY

        let run = Task { await PageByPageCapture().run() }
        try await Task.sleep(for: .milliseconds(1200))
        click(CGPoint(x: frame.midX, y: top - frame.midY))
        try await Task.sleep(for: .milliseconds(800))
        press(124)   // →
        try await Task.sleep(for: .milliseconds(600))

        // Done sits in the panel's bottom-right corner.
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is NSPanel && $0.isVisible && $0.frame.width > 300 })
        click(CGPoint(x: panel.frame.maxX - 14 - 25, y: top - (panel.frame.minY + 14 + 10)))

        let pages = await run.value
        defer { try? FileManager.default.removeItem(at: pages.first?.deletingLastPathComponent() ?? URL.temporaryDirectory.appending(path: "none")) }
        XCTAssertFalse(panel.isVisible)
        let document = URL.temporaryDirectory.appending(path: "Pages \(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: document) }
        XCTAssertTrue(PageByPageCapture.assemble(pages, into: document))
        XCTAssertEqual(PageImages.frameCount(of: document), 5)
        try assertSlides((0..<5).compactMap { PageImages.image(at: document, frame: $0) })
    }

    // MARK: - Macros

    /// The slides window as a recorded step would remember it.
    private func place() throws -> WindowPlace {
        let slides = try XCTUnwrap(slides)
        return try XCTUnwrap(ScreenWindows.all().first { $0.id == slides.window }).place
    }

    /// Records a capture of the window and then `turn`, as the user would
    /// show it, and runs it until the last page.
    private func recordAndRun(turn: () async throws -> Void,
                              beforeRunning: () async throws -> Void = {}) async throws -> (steps: [MacroStep], pages: [CGImage]) {
        let recorder = MacroRecorder()
        recorder.start()
        recorder.addCapture(CaptureArea(rect: nil), in: try place())
        try await turn()
        try await Task.sleep(for: .milliseconds(600))
        let steps = await recorder.stop()
        try await beforeRunning()
        let player = MacroPlayer()
        let runs = await player.run(Macro(name: "Slides", steps: steps))
        defer { try? FileManager.default.removeItem(at: player.folder) }
        return (steps, (runs.first ?? []).compactMap { PageImages.wholeImage(at: $0) })
    }

    private func assertSlides(_ pages: [CGImage], from first: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let texts = try pages.map { try text(in: $0) }
        XCTAssertEqual(pages.count, 5 - first + 1, "\(texts)", file: file, line: line)
        for (index, text) in texts.enumerated() {
            XCTAssertTrue(text.contains("Page \(first + index)"), "page \(first + index) read \(text)", file: file, line: line)
        }
    }

    /// A click on Next, recorded, then done again after the window has been
    /// moved and the button has gone to the window's other side: the window
    /// is put back where it was, and the button found by its name.
    func testRunsAMacroThatFindsTheButtonByName() async throws {
        let slides = try XCTUnwrap(slides)
        let recorded = try XCTUnwrap(ScreenCapture.frame(of: .window(slides.window)))
        let top = NSScreen.screens[0].frame.maxY
        let button = CGPoint(x: recorded.maxX - 30 - 45, y: top - (recorded.minY + 20 + 16))
        let (steps, pages) = try await recordAndRun(turn: {
            click(button)
        }, beforeRunning: {
            kill(slides.process.processIdentifier, SIGUSR1)
            kill(slides.process.processIdentifier, SIGUSR2)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertNotEqual(ScreenCapture.frame(of: .window(slides.window)), recorded)
        })
        XCTAssertEqual(steps.count, 2, "\(steps)")
        guard case let .click(click)? = steps.last?.action else { return XCTFail("no click: \(steps)") }
        XCTAssertEqual(click.element?.title, "Next")
        XCTAssertTrue(click.findsElement)
        let now = try XCTUnwrap(ScreenCapture.frame(of: .window(slides.window)))
        XCTAssertEqual(now.minX, recorded.minX, accuracy: 2)
        XCTAssertEqual(now.minY, recorded.minY, accuracy: 2)
        // The recorded click turned to page 2 already.
        try assertSlides(pages, from: 2)
    }

    func testRunsAMacroThatPressesAKey() async throws {
        let (steps, pages) = try await recordAndRun(turn: {
            press(124)   // →
        })
        guard case let .key(key)? = steps.last?.action else { return XCTFail("no key: \(steps)") }
        XCTAssertEqual(key.keyCode, 124)
        try assertSlides(pages, from: 2)
    }

    /// Scrolled from top to bottom a screenful at a time, and joined: every
    /// line once, none missing.
    func testScrollsALongPageAndJoinsItIntoOnePicture() async throws {
        slides?.process.terminate()
        let slides = try await launch(helper, scrolling: true)
        self.slides = slides
        let target = CaptureTarget.window(slides.window)
        let first = try await ScreenCapture.grab(target)
        let look = await PageByPageCapture.look(at: target)
        let firstLook = try XCTUnwrap(look)
        let frame = try XCTUnwrap(ScreenCapture.frame(of: target))
        let top = NSScreen.screens[0].frame.maxY
        let steps = PageByPageCapture.scrollSteps(by: -(frame.height * 0.7).rounded(),
                                                  at: CGPoint(x: frame.midX, y: top - frame.midY))
        var pages = [first]
        await PageByPageCapture().turnPages(with: steps, of: target, recordedFrame: frame, first: firstLook,
                                            alreadyTurned: false) { image in
            pages.append(image)
            return pages.count
        }
        XCTAssertGreaterThan(pages.count, 4)
        if ScrollStitcher.stitch(pages) == nil, let dump = ProcessInfo.processInfo.environment["OCRFLOW_LIVE_DUMP"] {
            for (index, page) in pages.enumerated() {
                _ = PageByPageCapture.write(page, to: URL(fileURLWithPath: dump).appending(path: "scroll-\(index).png"))
            }
        }
        let joined = try XCTUnwrap(ScrollStitcher.stitch(pages))
        XCTAssertEqual(joined.count, 1)

        // Read as a long screenshot is: in pages.
        let url = URL.temporaryDirectory.appending(path: "long-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(PageByPageCapture.write(joined[0], to: url))
        let count = PageImages.frameCount(of: url)
        XCTAssertGreaterThan(count, 1)
        let text = try (0..<count).compactMap { PageImages.image(at: url, frame: $0) }.map { try self.text(in: $0) }
            .joined(separator: "\n")
        let numbers = text.matches(of: /Line (\d+):/).compactMap { Int($0.1) }
        XCTAssertEqual(Set(numbers).count, numbers.count, "a line twice: \(numbers)")
        XCTAssertTrue(numbers.contains(1) && numbers.contains(LongPageLines.count), "\(numbers)")
        XCTAssertGreaterThanOrEqual(Set(numbers).count, LongPageLines.count - 3, "\(numbers)")
    }
}

extension LiveCaptureTests {
    /// A scroll, recorded as the user would make it — a wheel turned a few
    /// times — and done again until the page ends: one long picture.
    func testRunsARecordedScrollIntoOneLongPicture() async throws {
        slides?.process.terminate()
        let slides = try await launch(helper, scrolling: true)
        self.slides = slides
        let frame = try XCTUnwrap(ScreenCapture.frame(of: .window(slides.window)))
        let top = NSScreen.screens[0].frame.maxY
        let point = CGPoint(x: frame.midX, y: top - frame.midY)
        let (steps, pages) = try await recordAndRun(turn: {
            for _ in 0..<10 {
                let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40,
                                    wheel2: 0, wheel3: 0)
                event?.location = point
                event?.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(20))
            }
        })
        guard case let .scroll(scroll)? = steps.last?.action else { return XCTFail("no scroll: \(steps)") }
        XCTAssertEqual(steps.count, 2, "\(steps)")
        XCTAssertEqual(scroll.dy, -400, accuracy: 1)
        XCTAssertGreaterThan(pages.count, 5)
        let joined = try XCTUnwrap(ScrollStitcher.stitch(pages))
        XCTAssertEqual(joined.count, 1)
        // The recorded scroll moved the page before the first capture was
        // repeated; from there, everything to the end.
        XCTAssertGreaterThan(joined[0].height, 6000)
    }
}

extension LiveCaptureTests {
    /// Recording started with another app in front — OCRFlow, when started
    /// from its window: the click that brings the slides forward only does
    /// that, and is no step. Repeated, it would click the page every round.
    func testTheClickThatOnlyBringsAWindowForwardIsNoStep() async throws {
        let slides = try XCTUnwrap(slides)
        // Another app in front: a second copy of the helper, moved aside to
        // leave a strip of the first one showing on the left.
        let other = try await launch(helper)
        defer { other.process.terminate() }
        kill(other.process.processIdentifier, SIGUSR1)
        try await Task.sleep(for: .milliseconds(600))
        try XCTSkipUnless(NSWorkspace.shared.frontmostApplication?.processIdentifier == other.process.processIdentifier,
                          "The second helper did not come to the front")
        let frame = try XCTUnwrap(ScreenCapture.frame(of: .window(slides.window)))
        let top = NSScreen.screens[0].frame.maxY
        let recorder = MacroRecorder()
        recorder.start()
        click(CGPoint(x: frame.minX + 30, y: top - frame.midY))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, slides.process.processIdentifier)
        press(124)   // →
        try await Task.sleep(for: .milliseconds(500))
        let steps = await recorder.stop()
        XCTAssertEqual(steps.count, 1, "\(steps)")
        guard case let .key(key)? = steps.first?.action else { return XCTFail("not a key: \(steps)") }
        XCTAssertEqual(key.keyCode, 124)
    }
}

extension LiveCaptureTests {
    /// Recording and running as the user does it, through the app: start
    /// recording, take a capture with the screenshot command, turn the page,
    /// click Done; then run it. What was captured while recording comes
    /// first, and the run carries on from page 2 to the end: one document of
    /// all five pages. Uses its own library folder, OCRFLOW_LIBRARY_DIR.
    func testRecordsAndRunsThroughTheApp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OCRFLOW_LIBRARY_DIR"] != nil,
                          "Set OCRFLOW_LIBRARY_DIR to a scratch folder: the app's list and macros are kept there")
        let slides = try XCTUnwrap(slides)
        let frame = try XCTUnwrap(ScreenCapture.frame(of: .window(slides.window)))
        let top = NSScreen.screens[0].frame.maxY
        let vm = OCRViewModel()
        vm.macros.macros = []

        vm.recordMacro()
        try await Task.sleep(for: .milliseconds(800))
        // Capture here, as the screenshot shortcut or the floating button
        // would: the screen holds still, and a click takes the window.
        vm.captureScreenshot()
        try await Task.sleep(for: .milliseconds(1200))
        click(CGPoint(x: frame.midX, y: top - frame.midY))
        try await Task.sleep(for: .milliseconds(1000))
        press(124)   // →
        try await Task.sleep(for: .milliseconds(800))
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is NSPanel && $0.isVisible && $0.frame.width > 300 })
        click(CGPoint(x: panel.frame.maxX - 14 - 25, y: top - (panel.frame.minY + 14 + 10)))
        for _ in 0..<50 where vm.macros.macros.isEmpty { try await Task.sleep(for: .milliseconds(100)) }

        let macro = try XCTUnwrap(vm.macros.macros.first)
        XCTAssertEqual(macro.steps.count, 2, "\(macro.steps)")
        guard case .capture? = macro.steps.first?.action, case .key? = macro.steps.last?.action else {
            return XCTFail("\(macro.steps)")
        }
        XCTAssertEqual(macro.repetition, .untilUnchanged)
        let recorded = try XCTUnwrap(vm.macros.recordedCapture(for: macro.steps[0].id))
        XCTAssertTrue(try text(in: try XCTUnwrap(PageImages.wholeImage(at: recorded))).contains("Page 1"))

        let before = Set(vm.items.map(\.id))
        vm.runMacro(id: macro.id)
        for _ in 0..<600 where vm.isCapturing || vm.items.count == before.count {
            try await Task.sleep(for: .milliseconds(100))
        }
        let added = vm.items.filter { !before.contains($0.id) }
        XCTAssertEqual(added.count, 1)
        let document = try XCTUnwrap(added.first).url
        XCTAssertEqual(document.pathExtension, "tiff")
        XCTAssertEqual(PageImages.frameCount(of: document), 5)
        try assertSlides((0..<5).compactMap { PageImages.image(at: document, frame: $0) })
        // Handed on: the next run starts afresh.
        XCTAssertNil(vm.macros.recordedCapture(for: macro.steps[0].id))
        vm.stopProcessing()

        // Its originals: a picture a page, in a folder named after it.
        let out = URL.temporaryDirectory.appending(path: "originals-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let (written, failures) = OCRViewModel.writeOriginals(of: added, into: out)
        XCTAssertEqual(failures, [])
        let folder = try XCTUnwrap(written.first)
        XCTAssertEqual(folder.lastPathComponent, document.deletingPathExtension().lastPathComponent)
        let pictures = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(pictures.count, 5)
        try assertSlides(pictures.compactMap { PageImages.wholeImage(at: $0) })
    }
}

/// How many lines the helper's long page has.
private enum LongPageLines {
    static let count = 120
}
