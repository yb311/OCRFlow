import XCTest
import Vision
@testable import OCRFlow

/// Capture, recording and repeating on the real screen, against a small
/// five-page "document" app. They take over the mouse and keyboard for a
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
        slides = try await launch(helper)
    }

    override func tearDown() async throws {
        slides?.process.terminate()
        slides = nil
    }

    private func launch(_ helper: String) async throws -> Slides {
        let info = URL.temporaryDirectory.appending(path: "slides-\(UUID().uuidString).json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = [info.path]
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
}
