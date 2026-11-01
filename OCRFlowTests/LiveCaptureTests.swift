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
        let shots = try await ScreenGrabber.displays(keeping: [])
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

    /// Nothing of OCRFlow's that floats over the screen is in a screenshot —
    /// not in the held screen the user chooses from, nor in an area taken
    /// again, for the queue or a macro — even shown just before it is taken;
    /// OCRFlow's ordinary windows are.
    func testOCRFlowsPanelsAreNeverInAScreenshot() async throws {
        let slides = try XCTUnwrap(slides)
        let screen = NSScreen.screens[0]
        let main = try XCTUnwrap(screen.displayID)
        let top = screen.frame.maxY
        // The slide's title, in event coordinates.
        let title = CGRect(x: slides.frame.minX, y: slides.frame.minY + 28, width: 400, height: 120)
        NSRunningApplication(processIdentifier: slides.process.processIdentifier)?.activate()
        try await Task.sleep(for: .milliseconds(600))
        let clean = try await ScreenCapture.grab(.region(display: main, rect: title))
        XCTAssertTrue(try text(in: clean).contains("Page 1"))

        // The screen dimmed around somewhere else, as around an area being
        // taken, shown in the same turn as the picture is taken: then
        // ScreenCaptureKit does not yet list it as on screen.
        var shown: [NSPanel] = []
        defer { shown.forEach { $0.orderOut(nil) } }
        func dim() {
            let elsewhere = CGRect(x: title.maxX + 40, y: top - title.maxY, width: 40, height: 40)
            let shades = CaptureMarks.shades(around: elsewhere)
            shades.forEach { $0.orderFrontRegardless() }
            shown += shades
        }
        dim()
        let again = try await ScreenCapture.grab(.region(display: main, rect: title))
        dim()
        let shots = try await ScreenCapture.screens()
        let scale = screen.backingScaleFactor
        let held = try XCTUnwrap(shots[main]?.cropping(to: CGRect(x: title.minX * scale, y: title.minY * scale,
                                                                  width: title.width * scale, height: title.height * scale)))
        if let dump = ProcessInfo.processInfo.environment["OCRFLOW_LIVE_DUMP"].map({ URL(fileURLWithPath: $0) }) {
            for (name, picture) in [("clean", clean), ("again", again), ("held", held)] {
                _ = ScreenshotFormat.png.write(picture, to: dump.appending(path: "\(name).png"), pixelsPerPoint: 2)
            }
        }
        XCTAssertLessThan(try brightness(of: clean) - brightness(of: again), 0.02, "taken again, dimmed")
        XCTAssertLessThan(try brightness(of: clean) - brightness(of: held), 0.02, "held, dimmed")

        // A window of OCRFlow's own, in front (with Stage Manager, in place
        // of the slides).
        let place = title.offsetBy(dx: 0, dy: 200)
        let own = NSWindow(contentRect: CGRect(x: place.minX, y: top - place.maxY, width: place.width, height: place.height),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        own.isReleasedWhenClosed = false
        own.backgroundColor = .white
        let label = NSTextField(labelWithString: "Kept 42")
        label.font = .systemFont(ofSize: 48)
        label.textColor = .black
        label.frame = CGRect(x: 20, y: 30, width: 360, height: 60)
        own.contentView?.addSubview(label)
        own.orderFrontRegardless()
        defer { own.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(600))
        let kept = try await ScreenCapture.grab(.region(display: main, rect: place))
        let keptText = try text(in: kept)
        XCTAssertTrue(keptText.contains("Kept 42"), "OCRFlow's window: \(keptText)")
    }

    /// From 0, black, to 1, white: the mean of a small grey copy.
    private func brightness(of image: CGImage) throws -> Double {
        let (width, height) = (64, 24)
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count * 255)
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
        // The slides in front, as the user would have them.
        NSRunningApplication(processIdentifier: try XCTUnwrap(slides).process.processIdentifier)?.activate()
        try await Task.sleep(for: .milliseconds(400))
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

    /// Auto Scroll from top to bottom, joined as it goes: every line once,
    /// none missing.
    func testScrollsALongPageAndJoinsItIntoOnePicture() async throws {
        slides?.process.terminate()
        let slides = try await launch(helper, scrolling: true)
        self.slides = slides
        let target = CaptureTarget.window(slides.window)
        let first = try await ScreenCapture.grab(target)
        let joined = await ScrollingCapture().runAutomatically(target, size: CGSize(width: first.width, height: first.height),
                                                               distance: nil)
        XCTAssertEqual(joined.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(joined.first).height, first.height * 5)

        // Read as a long screenshot is: in pages.
        let url = URL.temporaryDirectory.appending(path: "long-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ScreenshotFormat.png.write(joined[0], to: url, pixelsPerPoint: 2))
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
        for _ in 0..<600 where vm.isCapturing { try await Task.sleep(for: .milliseconds(100)) }
        // Asked what becomes of them: recognized, the first choice.
        try await Task.sleep(for: .milliseconds(500))
        let choice = try XCTUnwrap(NSApp.windows.first { $0 is NSPanel && $0.isVisible && $0.frame.width > 300 })
        click(CGPoint(x: choice.frame.midX, y: top - (choice.frame.maxY - 14 - 22 - 10 - 11)))
        for _ in 0..<100 where vm.items.count == before.count { try await Task.sleep(for: .milliseconds(100)) }
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

extension LiveCaptureTests {
    /// The bar of buttons on screen.
    private func bar() throws -> NSPanel {
        try XCTUnwrap(NSApp.windows.first { $0 is KeyPanel && $0.isVisible } as? NSPanel)
    }

    /// A button of the bar, by how far its centre is from the bar's right
    /// edge: copy 25, save 61, cancel 97; past the divider, long screenshot
    /// 144.
    private func clickBar(_ fromRight: CGFloat) throws {
        let bar = try bar()
        let top = NSScreen.screens[0].frame.maxY
        click(CGPoint(x: bar.frame.maxX - fromRight, y: top - bar.frame.midY))
    }

    /// Auto Scroll, beside the area, over what has been joined.
    private func clickAutoScroll() throws {
        let button = try XCTUnwrap(NSApp.windows.first {
            $0.isVisible && ($0.contentView.map { String(describing: type(of: $0)) } ?? "").contains("AutoScrollButton")
        })
        let top = NSScreen.screens[0].frame.maxY
        click(CGPoint(x: button.frame.midX, y: top - button.frame.midY))
    }

    /// A screenshot is no longer read straight away: the bar asks, and copy
    /// puts it on the clipboard as it was.
    func testTheBarCopiesAScreenshot() async throws {
        let slides = try XCTUnwrap(slides)
        let frame = try XCTUnwrap(ScreenCapture.frame(of: .window(slides.window)))
        let top = NSScreen.screens[0].frame.maxY
        NSPasteboard.general.clearContents()
        let vm = try model()
        vm.captureScreenshot()
        try await Task.sleep(for: .milliseconds(1200))
        click(CGPoint(x: frame.midX, y: top - frame.midY))
        try await Task.sleep(for: .milliseconds(1000))
        try clickBar(25)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(vm.isCapturing)
        let data = try XCTUnwrap(NSPasteboard.general.data(forType: .png))
        let image = try XCTUnwrap(NSBitmapImageRep(data: data)?.cgImage)
        XCTAssertTrue(try text(in: image).contains("Page 1"))
        XCTAssertTrue(vm.items.isEmpty, "not read unless asked")
    }

    /// Taking a screenshot over another app leaves OCRFlow's own windows
    /// where they were — behind it — and that app in front.
    ///
    /// It cannot catch everything: activation is cooperative, and the system
    /// may refuse a test host the activation the app gets from a shortcut,
    /// which is what brought the main window forward.
    func testAScreenshotLeavesOCRFlowsWindowsBehind() async throws {
        let slides = try XCTUnwrap(slides)
        let frame = try XCTUnwrap(ScreenCapture.frame(of: .window(slides.window)))
        let top = NSScreen.screens[0].frame.maxY
        // OCRFlow's main window, under the slides.
        let own = NSWindow(contentRect: frame.insetBy(dx: 60, dy: 60), styleMask: [.titled], backing: .buffered, defer: false)
        own.isReleasedWhenClosed = false
        // Main, as the real one is: activating an app brings its main window
        // forward.
        own.makeKeyAndOrderFront(nil)
        own.makeMain()
        defer { own.orderOut(nil) }
        NSRunningApplication(processIdentifier: slides.process.processIdentifier)?.activate()
        try await Task.sleep(for: .milliseconds(600))
        func ownIsBehind() -> Bool {
            let order = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { $0[kCGWindowNumber as String] as? Int }
            guard let mine = order.firstIndex(of: own.windowNumber),
                  let theirs = order.firstIndex(of: Int(slides.window)) else { return false }
            return mine > theirs
        }
        XCTAssertTrue(ownIsBehind(), "set up wrong")

        let vm = try model()
        vm.captureScreenshot()
        try await Task.sleep(for: .milliseconds(1200))
        click(CGPoint(x: frame.minX + 30, y: top - frame.maxY + 60))   // the slides, clear of OCRFlow's window
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertTrue(ownIsBehind(), "came forward with the bar")
        try clickBar(25)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(ownIsBehind(), "came forward after copying")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, slides.process.processIdentifier)
    }

    /// Long screenshot from the bar: Auto Scroll to the end, then copy.
    func testTheBarTakesALongScreenshot() async throws {
        slides?.process.terminate()
        let slides = try await launch(helper, scrolling: true)
        self.slides = slides
        let frame = try XCTUnwrap(ScreenCapture.frame(of: .window(slides.window)))
        let top = NSScreen.screens[0].frame.maxY
        NSPasteboard.general.clearContents()
        let vm = try model()
        vm.captureScreenshot()
        try await Task.sleep(for: .milliseconds(1200))
        click(CGPoint(x: frame.midX, y: top - frame.midY))
        try await Task.sleep(for: .milliseconds(1000))
        try clickBar(144)
        try await Task.sleep(for: .milliseconds(1500))
        try clickAutoScroll()
        for _ in 0..<60 { try await Task.sleep(for: .milliseconds(500)) }
        try clickBar(25)
        // Joining takes a while in a debug build.
        for _ in 0..<240 where vm.isCapturing { try await Task.sleep(for: .milliseconds(250)) }
        let data = try XCTUnwrap(NSPasteboard.general.data(forType: .png))
        let image = try XCTUnwrap(NSBitmapImageRep(data: data)?.cgImage)
        XCTAssertGreaterThan(image.height, 6000)
    }

    /// Drag to take; a click goes through and turns the page; Escape ends.
    func testQueueTakesWhatIsDraggedOutAndLetsClicksThrough() async throws {
        let slides = try XCTUnwrap(slides)
        let frame = try XCTUnwrap(ScreenCapture.frame(of: .window(slides.window)))
        let top = NSScreen.screens[0].frame.maxY
        let title = CGPoint(x: frame.minX + 30, y: top - frame.maxY + 40)
        let button = CGPoint(x: frame.maxX - 30 - 45, y: top - (frame.minY + 20 + 16))
        let queue = QueueCapture()
        let run = Task { await queue.run() }
        try await Task.sleep(for: .milliseconds(800))
        for _ in 0..<3 {
            try await drag(from: title, to: CGPoint(x: title.x + 400, y: title.y + 120))
            try await Task.sleep(for: .milliseconds(600))
            click(button)
            try await Task.sleep(for: .milliseconds(900))
        }
        press(53)   // Escape
        let pages = await run.value
        defer { pages.first.map { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
        XCTAssertEqual(pages.count, 3)
        for (index, page) in pages.enumerated() {
            let image = try XCTUnwrap(PageImages.wholeImage(at: page))
            XCTAssertTrue(try text(in: image).contains("Page \(index + 1)"), "\(index)")
        }
    }

    /// Long Screenshot Here while recording, scrolled 1500 points by hand;
    /// run on a fresh window, it scrolls as far again, no further.
    func testRecordsALongScreenshotAndScrollsAsFarAgain() async throws {
        slides?.process.terminate()
        var slides = try await launch(helper, scrolling: true)
        self.slides = slides
        var frame = try XCTUnwrap(ScreenCapture.frame(of: .window(slides.window)))
        let top = NSScreen.screens[0].frame.maxY
        let vm = try model()
        vm.macros.macros = []

        vm.recordMacro()
        try await Task.sleep(for: .milliseconds(800))
        let recording = try XCTUnwrap(vm.activeRecording)
        let long = Task { await recording.captureHere(scrolling: true) }
        try await Task.sleep(for: .milliseconds(1200))
        click(CGPoint(x: frame.midX, y: top - frame.midY))
        try await Task.sleep(for: .milliseconds(1500))
        // The slides in front, so the wheel reaches them, as it would the
        // user's.
        NSRunningApplication(processIdentifier: slides.process.processIdentifier)?.activate()
        try await Task.sleep(for: .milliseconds(400))
        // By hand, clear of the Auto Scroll button.
        let wheel = CGPoint(x: frame.midX, y: top - frame.maxY + frame.height / 4)
        for _ in 0..<30 {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -50, wheel2: 0, wheel3: 0)
            event?.location = wheel
            event?.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(60))
        }
        try await Task.sleep(for: .milliseconds(1500))
        try clickBar(25)   // ✓
        await long.value
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is NSPanel && !($0 is KeyPanel) && $0.isVisible && $0.frame.width > 300 })
        click(CGPoint(x: panel.frame.maxX - 14 - 25, y: top - (panel.frame.minY + 14 + 10)))   // Done
        for _ in 0..<50 where vm.macros.macros.isEmpty { try await Task.sleep(for: .milliseconds(100)) }

        let macro = try XCTUnwrap(vm.macros.macros.first)
        XCTAssertEqual(macro.steps.count, 1, "the scrolling is the step's, not steps of its own: \(macro.steps)")
        guard case let .capture(area)? = macro.steps.first?.action else { return XCTFail("\(macro.steps)") }
        let distance = try XCTUnwrap(area.scrollDistance)
        XCTAssertEqual(distance, 1500, accuracy: 60)

        // A fresh window, at the top again.
        slides.process.terminate()
        slides = try await launch(helper, scrolling: true)
        self.slides = slides
        frame = try XCTUnwrap(ScreenCapture.frame(of: .window(slides.window)))
        vm.macros.macros[0].repetition = .once
        vm.macros.macros[0].output = .images
        let before = Set(vm.items.map(\.id))
        vm.runMacro(id: macro.id)
        for _ in 0..<600 where vm.isCapturing { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(500))
        let choice = try XCTUnwrap(NSApp.windows.first { $0 is NSPanel && $0.isVisible && $0.frame.width > 300 })
        click(CGPoint(x: choice.frame.midX, y: top - (choice.frame.maxY - 14 - 22 - 10 - 11)))
        for _ in 0..<100 where vm.items.count == before.count { try await Task.sleep(for: .milliseconds(100)) }
        let added = vm.items.filter { !before.contains($0.id) }
        // The recorded picture and the run's are the same: one is kept.
        XCTAssertEqual(added.count, 1, "\(added.compactMap { PageImages.wholeImage(at: $0.url) }.map { "\($0.width)×\($0.height)" })")
        if let dump = ProcessInfo.processInfo.environment["OCRFLOW_LIVE_DUMP"] {
            for (index, item) in added.enumerated() {
                try? FileManager.default.copyItem(at: item.url, to: URL(fileURLWithPath: dump).appending(path: "added-\(index).png"))
            }
        }
        let image = try XCTUnwrap(PageImages.wholeImage(at: try XCTUnwrap(added.first).url))
        let pixelsPerPoint = CGFloat(image.width) / frame.width
        XCTAssertEqual(CGFloat(image.height), (frame.height + 1500) * pixelsPerPoint, accuracy: 80 * pixelsPerPoint)
        vm.stopProcessing()
    }

    /// Scrolled by hand, in quick turns of the wheel, it still joins.
    func testJoinsWhatIsScrolledByHand() async throws {
        slides?.process.terminate()
        let slides = try await launch(helper, scrolling: true)
        self.slides = slides
        let target = CaptureTarget.window(slides.window)
        let frame = try XCTUnwrap(ScreenCapture.frame(of: target))
        let top = NSScreen.screens[0].frame.maxY
        let first = try await ScreenCapture.grab(target)
        let session = Task { await ScrollingCapture().run(target, first: first) }
        try await Task.sleep(for: .milliseconds(1000))
        NSRunningApplication(processIdentifier: slides.process.processIdentifier)?.activate()
        try await Task.sleep(for: .milliseconds(400))
        let wheel = CGPoint(x: frame.midX, y: top - frame.maxY + frame.height / 4)
        for _ in 0..<30 {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -50, wheel2: 0, wheel3: 0)
            event?.location = wheel
            event?.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(60))
        }
        try await Task.sleep(for: .milliseconds(1500))
        try clickBar(25)   // ✓
        let (parts, finish) = await session.value
        XCTAssertEqual(finish, .copy)
        let long = try XCTUnwrap(parts.first)
        let pixelsPerPoint = CGFloat(first.width) / frame.width
        XCTAssertEqual(CGFloat(long.height), (frame.height + 1500) * pixelsPerPoint, accuracy: 80 * pixelsPerPoint)
    }

    /// Auto Scroll over an area rather than a window. Nothing of OCRFlow's
    /// is in the picture, even a window of its own over the area; the steps
    /// come evenly, with the screen, and the preview grows with nearly every
    /// frame; and once the user moves the pointer it stops and leaves the
    /// pointer where they put it.
    func testAutoScrollsAnAreaAndGivesThePointerBack() async throws {
        slides?.process.terminate()
        let slides = try await launch(helper, scrolling: true)
        self.slides = slides
        let frame = try XCTUnwrap(ScreenCapture.frame(of: .window(slides.window)))
        let top = NSScreen.screens[0].frame.maxY
        // The page, below the window's title bar, in event coordinates.
        let area = CGRect(x: frame.minX + 10, y: top - frame.maxY + 60, width: frame.width - 40, height: frame.height - 80)
        let target = try XCTUnwrap(ScreenWindows.target(for: area), "\(frame) → \(area)")
        NSRunningApplication(processIdentifier: slides.process.processIdentifier)?.activate()
        try await Task.sleep(for: .milliseconds(400))
        let first = try await ScreenCapture.grab(target)
        // One of OCRFlow's own, over the area: as the Auto Scroll button once was.
        let block = NSPanel(contentRect: CGRect(x: area.midX - 100, y: top - area.midY - 150, width: 200, height: 60),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        block.level = .screenSaver
        block.backgroundColor = .black
        block.ignoresMouseEvents = true
        block.orderFrontRegardless()
        defer { block.orderOut(nil) }
        let capture = ScrollingCapture()
        let session = Task { await capture.run(target, first: first) }
        try await Task.sleep(for: .milliseconds(1000))

        final class Steps: @unchecked Sendable { var times: [TimeInterval] = [] }
        let steps = Steps()
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == StepPlayer.marker {
                steps.times.append(event.timestamp)
            }
        }
        defer { monitor.map(NSEvent.removeMonitor) }
        try clickAutoScroll()
        try await Task.sleep(for: .milliseconds(1000))
        // Past easing in.
        steps.times.removeAll()
        // How often the preview grows.
        var updates = 0, last = capture.grown
        let sampling = ContinuousClock.now
        while ContinuousClock.now - sampling < .seconds(2) {
            try await Task.sleep(for: .milliseconds(4))
            if capture.grown != last { updates += 1; last = capture.grown }
        }
        let parked = try XCTUnwrap(CGEvent(source: nil)?.location)
        XCTAssertEqual(parked.x, area.midX, accuracy: 2)
        XCTAssertEqual(parked.y, area.midY, accuracy: 2)
        XCTAssertGreaterThan(capture.grown, 1000)

        // The user moves the pointer: it stops, and the pointer is theirs.
        let away = CGPoint(x: area.midX + 80, y: area.midY + 50)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: away, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(700))
        let stopped = capture.grown
        let sent = steps.times.count
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(steps.times.count, sent, "still scrolling")
        XCTAssertEqual(capture.grown, stopped)
        let now = try XCTUnwrap(CGEvent(source: nil)?.location)
        XCTAssertEqual(now.x, away.x, accuracy: 1)
        XCTAssertEqual(now.y, away.y, accuracy: 1)

        let intervals = zip(steps.times.dropFirst(), steps.times).map { ($0 - $1) * 1000 }.sorted()
        let refresh = NSScreen.screens.first { $0.frame.contains(CGPoint(x: area.midX, y: top - area.midY)) }?
            .maximumFramesPerSecond ?? 60
        print("LIVE steps \(steps.times.count), every \(intervals[intervals.count / 2]) ms median, "
              + "p95 \(intervals[intervals.count * 95 / 100]) ms, max \(intervals.last!) ms; screen \(refresh) Hz; "
              + "preview grew \(Double(updates) / 2) times a second")
        XCTAssertGreaterThan(steps.times.count, 60)
        // Each frame joins on; with a window of OCRFlow's in them, few would.
        XCTAssertGreaterThan(updates, 60)
        XCTAssertLessThan(intervals[intervals.count * 95 / 100], 1500 / Double(refresh))

        try clickBar(25)   // ✓
        let (parts, finish) = await session.value
        XCTAssertEqual(finish, .copy)
        let long = try XCTUnwrap(parts.first)
        XCTAssertGreaterThan(long.height, first.height * 2)
        if let dump = ProcessInfo.processInfo.environment["OCRFLOW_LIVE_DUMP"] {
            _ = ScreenshotFormat.png.write(long, to: URL(fileURLWithPath: dump).appending(path: "area.png"), pixelsPerPoint: 2)
            _ = ScreenshotFormat.png.write(first, to: URL(fileURLWithPath: dump).appending(path: "area-first.png"), pixelsPerPoint: 2)
        }
        // Not a row of the black panel in it.
        let gray = ScrollStitcher.Gray(long)
        let middle = (gray.width / 2 - 60)..<(gray.width / 2 + 60)
        let dark = (0..<gray.height).filter { y in middle.allSatisfy { gray.values[y * gray.width + $0] < 40 } }
        XCTAssertTrue(dark.isEmpty, "OCRFlow's own window in the picture, rows \(dark.first ?? 0)…")
    }

    /// Pointing at the floating button opens out Queue Screenshots and Record
    /// Actions; moving away closes them again.
    func testTheFloatingButtonOpensOutUnderThePointer() async throws {
        let vm = try model()
        let floating = FloatingCaptureButton(model: vm)
        defer { floating.close() }
        try await Task.sleep(for: .milliseconds(300))
        // The frontmost: earlier tests' models may have floating buttons of
        // their own in the same place, when the setting is on.
        let front = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? Int }
        let buttons = NSApp.windows.filter { $0 is NSPanel && $0.isVisible && $0.frame.width == FloatingCaptureButton.side }
        let panel = try XCTUnwrap(front.lazy.compactMap { number in buttons.first { $0.windowNumber == number } }.first)
        let resting = panel.frame
        let top = NSScreen.screens[0].frame.maxY
        func move(to point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        move(to: CGPoint(x: resting.midX - 80, y: top - resting.midY))
        try await Task.sleep(for: .milliseconds(300))
        move(to: CGPoint(x: resting.midX, y: top - resting.midY))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(panel.frame.height, FloatingCaptureButton.side + FloatingCaptureButton.extrasHeight)
        // Onto the first of the others, where its name shows.
        let opened = panel.frame
        let downward = opened.minY < resting.minY
        let firstY = resting.midY + (downward ? -1 : 1) * ((FloatingCaptureButton.diameter + FloatingCaptureButton.extraDiameter) / 2 + FloatingCaptureButton.gap)
        move(to: CGPoint(x: resting.midX, y: top - firstY))
        try await Task.sleep(for: .milliseconds(500))
        if let dump = ProcessInfo.processInfo.environment["OCRFLOW_LIVE_DUMP"] {
            let picture = try await ScreenGrabber.capture(.window(CGWindowID(panel.windowNumber)))
            _ = ScreenshotFormat.png.write(picture, to: URL(fileURLWithPath: dump).appending(path: "floating.png"), pixelsPerPoint: 2)
        }
        XCTAssertEqual(panel.frame, opened, "still open over one of the others")
        move(to: CGPoint(x: resting.midX - 400, y: top - resting.midY))
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(panel.frame, resting)
    }

    private func model() throws -> OCRViewModel {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OCRFLOW_LIBRARY_DIR"] != nil,
                          "Set OCRFLOW_LIBRARY_DIR to a scratch folder: the app's list is kept there")
        let vm = OCRViewModel()
        vm.removeItems(ids: Set(vm.items.map(\.id)))
        return vm
    }
}

/// How many lines the helper's long page has.
private enum LongPageLines {
    static let count = 120
}
