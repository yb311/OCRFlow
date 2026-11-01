import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OCRFlow

struct MacroTests {

    // MARK: - Pictures

    private func context(width: Int, height: Int) -> CGContext {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    /// A long page of "text": dark bars of differing lengths, in lines.
    private func longPage(width: Int = 480, height: Int = 3000, seed: Int = 1) -> CGImage {
        let context = context(width: width, height: height)
        context.setFillColor(CGColor(gray: 0.15, alpha: 1))
        var line = 0
        for top in stride(from: 12, to: height - 20, by: 28) {
            line += 1
            // A blank line now and then, as between paragraphs.
            if (line * 7 + seed) % 9 == 0 { continue }
            let start = 16 + (line * 37 + seed * 11) % 60
            let length = 60 + (line * 131 + seed * 53) % (width - 140)
            // Drawn from the top: the context's y runs upward.
            context.fill(CGRect(x: start, y: height - top - 12, width: length, height: 12))
            context.fill(CGRect(x: start + length + 10, y: height - top - 12, width: (line * 17) % 40 + 8, height: 12))
        }
        return context.makeImage()!
    }

    private struct Layout {
        var width = 480
        var header = 50
        var footer = 30
        var middle = 420
        var sidebar = 0
        var height: Int { header + middle + footer }
    }

    /// The window showing `page` scrolled to `offset`, between a toolbar and
    /// a status bar, beside a sidebar when there is one.
    private func frame(of page: CGImage, at offset: Int, _ layout: Layout) -> CGImage {
        let width = layout.sidebar + layout.width
        let context = context(width: width, height: layout.height)
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: layout.height - layout.header, width: width, height: layout.header))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 12, y: layout.height - 35, width: 180, height: 18))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: layout.footer))
        if layout.sidebar > 0 {
            context.setFillColor(CGColor(gray: 0.85, alpha: 1))
            context.fill(CGRect(x: 0, y: layout.footer, width: layout.sidebar, height: layout.middle))
            context.setFillColor(CGColor(gray: 0.2, alpha: 1))
            for row in 0..<10 { context.fill(CGRect(x: 10, y: layout.footer + 20 + row * 36, width: 80, height: 10)) }
        }
        let visible = page.cropping(to: CGRect(x: 0, y: offset, width: layout.width, height: layout.middle))!
        context.draw(visible, in: CGRect(x: layout.sidebar, y: layout.footer, width: layout.width, height: layout.middle))
        return context.makeImage()!
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let context = context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: context.bytesPerRow * image.height))
    }

    // MARK: - Joining scrolled pictures

    @Test func joinsScrolledPicturesKeepingTheToolbarOnce() throws {
        let page = longPage()
        let layout = Layout()
        // Uneven steps, the last one short: the bottom of the page.
        let offsets = [0, 300, 590, 880, 1170, 1460, 1750, 2040, 2330, 2580]
        let frames = offsets.map { frame(of: page, at: $0, layout) }
        let joined = try #require(ScrollStitcher.stitch(frames))
        #expect(joined.count == 1)
        let long = try #require(joined.first)

        // The toolbar, the whole page down to where the last picture ends,
        // the status bar.
        let shown = offsets.last! + layout.middle
        let expected = context(width: layout.width, height: layout.header + shown + layout.footer)
        let top = frames[0].cropping(to: CGRect(x: 0, y: 0, width: layout.width, height: layout.header))!
        expected.draw(top, in: CGRect(x: 0, y: shown + layout.footer, width: layout.width, height: layout.header))
        let body = page.cropping(to: CGRect(x: 0, y: 0, width: layout.width, height: shown))!
        expected.draw(body, in: CGRect(x: 0, y: layout.footer, width: layout.width, height: shown))
        let bottom = frames[0].cropping(to: CGRect(x: 0, y: layout.height - layout.footer, width: layout.width,
                                                   height: layout.footer))!
        expected.draw(bottom, in: CGRect(x: 0, y: 0, width: layout.width, height: layout.footer))

        #expect(long.width == layout.width)
        #expect(long.height == layout.header + shown + layout.footer)
        let a = pixels(long), b = pixels(expected.makeImage()!)
        let differing = zip(a, b).filter { abs(Int($0) - Int($1)) > 2 }.count
        #expect(differing == 0)
    }

    @Test func leavesOutASidebarThatStaysPut() throws {
        let page = longPage()
        var layout = Layout()
        layout.sidebar = 120
        let offsets = [0, 350, 700, 1050]
        let joined = try #require(ScrollStitcher.stitch(offsets.map { frame(of: page, at: $0, layout) }))
        let long = try #require(joined.first)
        #expect(long.width < layout.sidebar + layout.width)
        #expect(long.width >= layout.width - 40)
        #expect(long.height == layout.header + offsets.last! + layout.middle + layout.footer)
    }

    /// A title bar is lighter while its window is in the background — as it
    /// is for the first picture, taken while choosing what to capture — and
    /// draws a line under itself once something has scrolled beneath it.
    @Test func aTitleBarThatChangesFaintlyStaysPut() throws {
        let page = longPage()
        let layout = Layout()
        let offsets = [0, 300, 600, 900]
        let frames = offsets.enumerated().map { index, offset -> CGImage in
            let plain = frame(of: page, at: offset, layout)
            let context = context(width: plain.width, height: plain.height)
            context.draw(plain, in: CGRect(x: 0, y: 0, width: plain.width, height: plain.height))
            if index == 0 {
                context.setFillColor(CGColor(gray: 1, alpha: 0.3))
                context.fill(CGRect(x: 0, y: layout.height - layout.header, width: plain.width, height: layout.header))
            } else {
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(CGRect(x: 0, y: layout.height - layout.header - 1, width: plain.width, height: 1))
            }
            return context.makeImage()!
        }
        let long = try #require(ScrollStitcher.stitch(frames)?.first)
        #expect(long.height == layout.header + offsets.last! + layout.middle + layout.footer)
    }

    /// Scrolled too far at once, then back a little: the screenful that does
    /// not join is left out, and joining goes on from the next that does.
    @Test func aScreenfulThatDoesNotJoinIsLeftOut() throws {
        let page = longPage()
        let layout = Layout()
        let offsets = [0, 300, 600, 1500, 800, 1100]
        let frames = offsets.map { frame(of: page, at: $0, layout) }
        let joined = try #require(ScrollStitcher.join(count: frames.count) { frames[$0] })
        #expect(joined.usesLast)
        #expect(joined.parts.first?.height == layout.header + 1100 + layout.middle + layout.footer)

        // The last too far: left out, and said so.
        let stranded = [0, 300, 600, 1500].map { frame(of: page, at: $0, layout) }
        let partly = try #require(ScrollStitcher.join(count: stranded.count) { stranded[$0] })
        #expect(!partly.usesLast)
        #expect(partly.parts.first?.height == layout.header + 600 + layout.middle + layout.footer)
    }

    // MARK: - Joining as it scrolls

    private func expectedLong(_ page: CGImage, to offset: Int, _ layout: Layout, frame: CGImage) -> CGImage {
        let shown = offset + layout.middle
        let expected = context(width: layout.width, height: layout.header + shown + layout.footer)
        let top = frame.cropping(to: CGRect(x: 0, y: 0, width: layout.width, height: layout.header))!
        expected.draw(top, in: CGRect(x: 0, y: shown + layout.footer, width: layout.width, height: layout.header))
        let body = page.cropping(to: CGRect(x: 0, y: 0, width: layout.width, height: shown))!
        expected.draw(body, in: CGRect(x: 0, y: layout.footer, width: layout.width, height: shown))
        let bottom = frame.cropping(to: CGRect(x: 0, y: layout.height - layout.footer, width: layout.width, height: layout.footer))!
        expected.draw(bottom, in: CGRect(x: 0, y: 0, width: layout.width, height: layout.footer))
        return expected.makeImage()!
    }

    /// Frame after frame of a smooth scroll, a few rows apart: joined as they
    /// come, exactly.
    @Test func joinsASmoothScrollFrameByFrame() throws {
        let page = longPage()
        let layout = Layout()
        let stitcher = LiveStitcher()
        var offset = 0
        var offsets: [Int] = []
        while offset <= 1500 {
            offsets.append(offset)
            offset += 11 + offsets.count % 7
        }
        for offset in offsets { _ = stitcher.add(frame(of: page, at: offset, layout)) }
        let long = try #require(stitcher.finish().first)
        let expected = expectedLong(page, to: offsets.last!, layout, frame: frame(of: page, at: 0, layout))
        #expect(long.height == expected.height)
        let differing = zip(pixels(long), pixels(expected)).filter { abs(Int($0) - Int($1)) > 2 }.count
        #expect(differing == 0)
    }

    /// As wide as the area chosen, every column of it: here a margin down
    /// the left that never changes as the page scrolls past it.
    @Test func keepsTheWholeWidthChosen() throws {
        let page = longPage()
        let layout = Layout()
        let margin = 60
        func framed(_ offset: Int) -> CGImage {
            let inner = frame(of: page, at: offset, layout)
            let context = context(width: margin + inner.width, height: inner.height)
            context.setFillColor(CGColor(gray: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: margin, height: inner.height))
            context.draw(inner, in: CGRect(x: margin, y: 0, width: inner.width, height: inner.height))
            return context.makeImage()!
        }
        let stitcher = LiveStitcher()
        let offsets = Array(stride(from: 0, through: 600, by: 12))
        for offset in offsets { _ = stitcher.add(framed(offset)) }
        let long = try #require(stitcher.finish().first)
        #expect(long.width == margin + layout.width)
        #expect(long.height == layout.header + offsets.last! + layout.middle + layout.footer)
    }

    /// The view redrawn where it is before anything scrolls — its window
    /// coming to the front as the capture begins: not "too fast", and the
    /// picture begins from it as it looks now.
    @Test func aChangeInPlaceIsNotAScrollTooFar() throws {
        let page = longPage()
        let layout = Layout()
        // A selection on the page, in another colour once its window is
        // in front.
        let selected = context(width: page.width, height: page.height)
        selected.draw(page, in: CGRect(x: 0, y: 0, width: page.width, height: page.height))
        selected.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 1, alpha: 0.5))
        selected.fill(CGRect(x: 0, y: page.height - 230, width: page.width, height: 30))
        let front = selected.makeImage()!

        let stitcher = LiveStitcher()
        var outcomes = [stitcher.add(frame(of: page, at: 0, layout))]
        for offset in stride(from: 0, through: 400, by: 20) { outcomes.append(stitcher.add(frame(of: front, at: offset, layout))) }
        #expect(outcomes[1] == .unchanged)
        #expect(!outcomes.contains(.lost))
        let long = try #require(stitcher.finish().first)
        let expected = expectedLong(front, to: 400, layout, frame: frame(of: front, at: 0, layout))
        #expect(long.height == expected.height)
        let differing = zip(pixels(long), pixels(expected)).filter { abs(Int($0) - Int($1)) > 2 }.count
        #expect(differing == 0)
    }

    /// A window's rounded corners, see-through, at the bottom of each frame:
    /// at the bottom of the picture once, not brought along by every strip.
    @Test func aWindowsRoundedCornersAreNotJoinedOnDownItsSides() throws {
        let page = longPage()
        let layout = Layout(footer: 0)
        let stitcher = LiveStitcher()
        let offsets = Array(stride(from: 0, through: 600, by: 20))
        for offset in offsets {
            let plain = frame(of: page, at: offset, layout)
            let context = context(width: plain.width, height: plain.height)
            context.draw(plain, in: CGRect(x: 0, y: 0, width: plain.width, height: plain.height))
            context.clear(CGRect(x: 0, y: 0, width: 6, height: 10))
            context.clear(CGRect(x: plain.width - 6, y: 0, width: 6, height: 10))
            _ = stitcher.add(context.makeImage()!)
        }
        let long = try #require(stitcher.finish().first)
        #expect(long.height == layout.header + offsets.last! + layout.middle)
        // See-through only in the last ten rows.
        let drawn = CGContext(data: nil, width: long.width, height: long.height, bitsPerComponent: 8, bytesPerRow: long.width * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        drawn.draw(long, in: CGRect(x: 0, y: 0, width: long.width, height: long.height))
        let bytes = drawn.data!.assumingMemoryBound(to: UInt8.self)
        let clear = (0..<long.height).filter { bytes[$0 * long.width * 4 + 3] < 250 }
        #expect(clear == Array((long.height - 10)..<long.height))
    }

    /// An area that takes in the bottom of a window, and the desktop under
    /// it: the window's rounded corners, and its border, drawn faintly over
    /// the lines that scroll under it. At the bottom of the picture once, not
    /// a line across it at every join.
    @Test func aWindowsEdgeAtTheBottomIsNotJoinedOnAtEveryStrip() throws {
        let page = longPage()
        var layout = Layout()
        layout.footer = 8
        func edged(_ offset: Int) -> CGImage {
            let plain = frame(of: page, at: offset, layout)
            let context = context(width: plain.width, height: plain.height)
            context.draw(plain, in: CGRect(x: 0, y: 0, width: plain.width, height: plain.height))
            // Desktop, the border over the page's last rows, the corners.
            context.setFillColor(CGColor(red: 0.4, green: 0.3, blue: 0.45, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: plain.width, height: layout.footer))
            for corner in [0, plain.width - 8] {
                context.fill(CGRect(x: corner, y: layout.footer, width: 8, height: 10))
            }
            context.setFillColor(CGColor(gray: 0.3, alpha: 0.6))
            context.fill(CGRect(x: 0, y: layout.footer, width: plain.width, height: 2))
            return context.makeImage()!
        }
        // Rows with the border's grey across them, where the page is blank.
        let border = pixels(edged(0))[(layout.height - layout.footer - 1) * layout.width * 4 + 12 * 4]
        func borders(in long: CGImage) -> Int {
            let bytes = pixels(long)
            let rowBytes = bytes.count / long.height
            return (0..<long.height).filter { y in
                (0..<long.width).filter { bytes[y * rowBytes + $0 * 4] == border }.count > 20
            }.count
        }

        let stitcher = LiveStitcher()
        let offsets = Array(stride(from: 0, through: 600, by: 20))
        for offset in offsets { _ = stitcher.add(edged(offset)) }
        let long = try #require(stitcher.finish().first)
        #expect(long.height == layout.header + offsets.last! + layout.middle + layout.footer)
        #expect(borders(in: long) == 2)

        let joined = try #require(ScrollStitcher.stitch([0, 290, 580, 870].map(edged))?.first)
        #expect(joined.height == layout.header + 870 + layout.middle + layout.footer)
        #expect(borders(in: joined) == 2)
    }

    /// The same frame twice, a step back up, a jump too far: passed over,
    /// and joining goes on from the next that carries on.
    @Test func passesOverFramesThatDoNotCarryOn() throws {
        let page = longPage()
        let layout = Layout()
        let stitcher = LiveStitcher()
        var outcomes: [LiveStitcher.Outcome] = []
        for offset in [0, 40, 40, 80, 60, 900, 120, 160] {
            outcomes.append(stitcher.add(frame(of: page, at: offset, layout)))
        }
        #expect(outcomes[2] == .unchanged)
        #expect(outcomes[5] == .lost)
        #expect(outcomes.last == .grew(by: 40))
        let long = try #require(stitcher.finish().first)
        #expect(long.height == layout.header + 160 + layout.middle + layout.footer)
    }

    /// A long picture and the same reaching further are the same; another
    /// page is not.
    @Test func samePictureReachingFurtherIsTheSame() {
        let page = longPage(height: 3000)
        let short = page.cropping(to: CGRect(x: 0, y: 0, width: 480, height: 1600))!
        let longer = page.cropping(to: CGRect(x: 0, y: 0, width: 480, height: 2400))!
        #expect(OCRViewModel.isSamePicture(short, longer))
        #expect(!OCRViewModel.isSamePicture(short, longPage(height: 3000, seed: 7).cropping(to: CGRect(x: 0, y: 0, width: 480, height: 1600))!))
    }

    @Test func slidesTurnedOneByOneAreNotJoined() {
        let layout = Layout()
        let frames = (1...4).map { frame(of: longPage(seed: $0), at: 0, layout) }
        #expect(ScrollStitcher.stitch(frames) == nil)
    }

    @Test func blankPicturesAreNotJoined() {
        let blank = context(width: 400, height: 300).makeImage()!
        #expect(ScrollStitcher.stitch([blank, blank, blank]) == nil)
    }

    @Test func aVeryLongPictureComesInParts() throws {
        let page = longPage(height: 3000)
        let layout = Layout()
        let offsets = Array(stride(from: 0, through: 2580, by: 300)) + [2580]
        let frames = offsets.reduce(into: [Int]()) { if $0.last != $1 { $0.append($1) } }.map { frame(of: page, at: $0, layout) }
        let whole = try #require(ScrollStitcher.stitch(frames))
        #expect(whole.count == 1)
        let total = try #require(whole.first).height
        // With a limit of about a third of the whole: three parts or so.
        let parts = try #require(ScrollStitcher.stitch(frames, maxHeight: total / 3 + layout.header + layout.footer + 10))
        #expect(parts.count >= 3)
        for part in parts {
            #expect(part.height <= total / 3 + layout.header + layout.footer + 10)
            #expect(part.width == layout.width)
        }
    }

    // MARK: - Long pictures read as pages

    @Test func cutsBetweenLinesOfText() {
        // Lines 20 rows tall with 10 blank between.
        let ink = (0..<1000).map { $0 % 30 < 20 ? 100 : 0 }
        let pages = LongImagePages.cut(height: 1000, pageHeight: 300, ink: ink)
        #expect(pages.first?.lowerBound == 0)
        #expect(pages.last?.upperBound == 1000)
        for (a, b) in zip(pages, pages.dropFirst()) {
            #expect(a.upperBound == b.lowerBound)
            #expect(ink[b.lowerBound] == 0, "cut across a line at \(b.lowerBound)")
        }
        for page in pages.dropLast() { #expect(page.count <= 300 && page.count >= 210) }
    }

    @Test func cutsAcrossTheLightestRowWhenThereIsNoGap() {
        var ink = Array(repeating: 100, count: 800)
        ink[250] = 3
        let pages = LongImagePages.cut(height: 800, pageHeight: 300, ink: ink)
        #expect(pages.first == 0..<250)
    }

    @Test func aLongScreenshotIsReadAsPages() throws {
        let folder = URL.temporaryDirectory.appending(path: "long-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func save(_ image: CGImage, _ name: String) -> URL {
            let url = folder.appending(path: name)
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            return url
        }
        let long = save(longPage(width: 480, height: 3000), "long.png")
        let count = PageImages.frameCount(of: long)
        #expect(count >= 4)
        let pages = (0..<count).compactMap { PageImages.image(at: long, frame: $0) }
        #expect(pages.count == count)
        #expect(pages.allSatisfy { $0.width == 480 && $0.height <= Int(480 * LongImagePages.pageShape * 1.13) })
        #expect(pages.reduce(0) { $0 + $1.height } == 3000)

        let ordinary = save(longPage(width: 480, height: 800), "ordinary.png")
        #expect(PageImages.frameCount(of: ordinary) == 1)
        #expect(PageImages.image(at: ordinary)?.height == 800)
    }

    // MARK: - Making steps of what the user did

    private let window = WindowPlace(bundleID: "com.example.viewer", appName: "Viewer", title: "Deck",
                                     frame: CGRect(x: 100, y: 50, width: 800, height: 600))

    private func input(_ kind: RecordedInput.Kind, at point: CGPoint = .zero, modifiers: CGEventFlags = [],
                       element: ElementDescription? = nil) -> RecordedInput {
        RecordedInput(kind: kind, location: point, modifiers: modifiers.rawValue, window: window, element: element)
    }

    @Test func aPressAndReleaseInPlaceIsAClickInTheWindow() throws {
        let next = ElementDescription(role: "AXButton", title: "Next", center: CGPoint(x: 700, y: 560))
        let steps = MacroStepBuilder.steps(from: [
            input(.mouseDown(.left, clickCount: 1), at: CGPoint(x: 800, y: 610), element: next),
            input(.mouseUp, at: CGPoint(x: 801, y: 610)),
        ])
        #expect(steps.count == 1)
        guard case let .click(click) = try #require(steps.first).action else { Issue.record("not a click"); return }
        #expect(click.point == CGPoint(x: 700, y: 560))
        #expect(click.count == 1)
        #expect(click.findsElement)
        #expect(steps.first?.window == window)
    }

    @Test func aSecondClickInPlaceMakesADoubleClick() throws {
        let steps = MacroStepBuilder.steps(from: [
            input(.mouseDown(.left, clickCount: 1), at: CGPoint(x: 300, y: 300)), input(.mouseUp, at: CGPoint(x: 300, y: 300)),
            input(.mouseDown(.left, clickCount: 2), at: CGPoint(x: 301, y: 300)), input(.mouseUp, at: CGPoint(x: 301, y: 300)),
        ])
        #expect(steps.count == 1)
        guard case let .click(click) = try #require(steps.first).action else { Issue.record("not a click"); return }
        #expect(click.count == 2)
    }

    @Test func aPressMovedFarIsADrag() throws {
        let steps = MacroStepBuilder.steps(from: [
            input(.mouseDown(.left, clickCount: 1), at: CGPoint(x: 200, y: 200)),
            input(.mouseDragged, at: CGPoint(x: 230, y: 200)),
            input(.mouseDragged, at: CGPoint(x: 260, y: 210)),
            input(.mouseUp, at: CGPoint(x: 300, y: 220)),
        ])
        guard case let .drag(drag) = try #require(steps.first).action else { Issue.record("not a drag"); return }
        #expect(drag.path.first == CGPoint(x: 100, y: 150))
        #expect(drag.path.last == CGPoint(x: 200, y: 170))
    }

    @Test func oneSwipeIsOneScroll() throws {
        let steps = MacroStepBuilder.steps(from: [
            input(.scroll(dx: 0, dy: -10, continues: false), at: CGPoint(x: 400, y: 400)),
            input(.scroll(dx: 0, dy: -30, continues: true), at: CGPoint(x: 400, y: 400)),
            input(.scroll(dx: 0, dy: -60, continues: true), at: CGPoint(x: 400, y: 400)),
            input(.scroll(dx: 0, dy: -5, continues: false), at: CGPoint(x: 400, y: 400)),
        ])
        #expect(steps.count == 2)
        guard case let .scroll(scroll) = try #require(steps.first).action else { Issue.record("not a scroll"); return }
        #expect(scroll.dy == -100)
        #expect(scroll.point == CGPoint(x: 300, y: 350))
    }

    @Test func keysTypedInARowAreText() throws {
        let steps = MacroStepBuilder.steps(from: [
            input(.key(code: 4, characters: "h")), input(.key(code: 34, characters: "i")),
            input(.key(code: 49, characters: " ")), input(.key(code: 13, characters: "w")),
            input(.key(code: 36, characters: "\r")),
            // A space alone is a page turn, not typing.
            input(.key(code: 49, characters: " ")),
            input(.key(code: 8, characters: "c"), modifiers: .maskCommand),
            input(.key(code: 124, characters: "\u{F703}")),
        ])
        #expect(steps.count == 5)
        guard case let .type(text) = steps[0].action else { Issue.record("not typing: \(steps[0])"); return }
        #expect(text.text == "hi w")
        #expect(text.keyCodes == [4, 34, 49, 13])
        guard case let .key(enter) = steps[1].action, case let .key(space) = steps[2].action,
              case let .key(copy) = steps[3].action, case let .key(arrow) = steps[4].action else {
            Issue.record("not keys: \(steps)")
            return
        }
        #expect(enter.keyCode == 36)
        #expect(space.keyCode == 49)
        #expect(MacroStepDescription.keyName(copy) == "⌘C")
        #expect(MacroStepDescription.keyName(arrow) == "→")
    }

    @Test func capturesStayWhereTheyWereTaken() {
        let area = CaptureArea(rect: CGRect(x: 10, y: 60, width: 500, height: 400))
        let steps = MacroStepBuilder.steps(from: [
            input(.capture(area)),
            input(.key(code: 124, characters: "\u{F703}")),
        ])
        #expect(steps.count == 2)
        #expect(steps.first?.action == .capture(area))
    }

    /// In Stage Manager the window server lists a window in the strip at
    /// the side as it is drawn there, a thumbnail, under the same title —
    /// and before the real one. The one the size it was recorded at is the
    /// window the steps happened in.
    @Test func theWindowWithItsTitleAndSizeIsTheOne() {
        func window(_ id: CGWindowID, _ title: String?, _ frame: CGRect) -> ScreenWindow {
            ScreenWindow(id: id, pid: 1, appName: "Notes", title: title, frame: frame, layer: 0)
        }
        let place = WindowPlace(bundleID: "com.apple.Notes", appName: "Notes", title: "Draft",
                                frame: CGRect(x: 200, y: 100, width: 900, height: 700))
        let thumbnail = window(1, "Draft", CGRect(x: 8, y: 300, width: 81, height: 101))
        let real = window(2, "Draft", CGRect(x: 240, y: 90, width: 900, height: 700))
        let other = window(3, "Other", CGRect(x: 200, y: 100, width: 900, height: 700))
        #expect(ScreenWindows.pick([thumbnail, other, real], for: place)?.id == 2)
        // Only the thumbnail: that, to be brought forward.
        #expect(ScreenWindows.pick([thumbnail, other], for: place)?.id == 1)
        // No title to go by: the one its size, else the frontmost.
        var untitled = place
        untitled.title = nil
        #expect(ScreenWindows.pick([thumbnail, other], for: untitled)?.id == 3)
        #expect(ScreenWindows.pick([thumbnail], for: untitled)?.id == 1)
    }

    @Test func aMacroIsKeptAsItWas() throws {
        var macro = Macro(name: "Deck", steps: MacroStepBuilder.steps(from: [
            input(.capture(CaptureArea(rect: nil))),
            input(.mouseDown(.left, clickCount: 1), at: CGPoint(x: 800, y: 610)), input(.mouseUp, at: CGPoint(x: 800, y: 610)),
            input(.key(code: 4, characters: "h")), input(.key(code: 34, characters: "i")),
        ]))
        macro.steps.append(MacroStep(action: .wait(seconds: 1.5)))
        macro.repetition = .times(12)
        macro.urls = ["example.com/a", "https://example.com/b", ""]
        macro.output = .longImage
        let decoded = try JSONDecoder().decode(Macro.self, from: JSONEncoder().encode(macro))
        #expect(decoded == macro)
        #expect(decoded.openableURLs.map(\.absoluteString) == ["https://example.com/a", "https://example.com/b"])
    }

    // MARK: - Files

    private func folder() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "macro-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func save(_ image: CGImage, to url: URL) {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// Joined from files, read a pair at a time, as from pictures in memory.
    @Test func joinsScrolledPicturesFromFiles() throws {
        let page = longPage()
        let layout = Layout()
        let frames = [0, 300, 600, 900].map { frame(of: page, at: $0, layout) }
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = frames.enumerated().map { index, frame in
            let url = folder.appending(path: "\(index).png")
            save(frame, to: url)
            return url
        }
        let fromFiles = try #require(ScrollStitcher.stitch(files)?.first)
        let fromMemory = try #require(ScrollStitcher.stitch(frames)?.first)
        #expect(fromFiles.height == fromMemory.height)
        #expect(pixels(fromFiles) == pixels(fromMemory))
    }

    @Test func theCaptureShortcutsAreNotSteps() {
        let held: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate]
        #expect(GlobalHotKey.isOwn(keyCode: 19, flags: held))
        #expect(GlobalHotKey.isOwn(keyCode: 19, flags: held.union(.maskNonCoalesced)))
        // ⌥⇧⌘3 is no longer OCRFlow's.
        #expect(!GlobalHotKey.isOwn(keyCode: 20, flags: held))
        #expect(!GlobalHotKey.isOwn(keyCode: 19, flags: [.maskCommand, .maskShift]))
        #expect(!GlobalHotKey.isOwn(keyCode: 124, flags: held))
    }

    /// What a step captured while recorded is kept until the step goes.
    @MainActor @Test func aRecordedCaptureGoesWithItsStep() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = MacroLibrary(directory: folder)
        let capture = MacroStep(action: .capture(CaptureArea(rect: nil)))
        let key = MacroStep(action: .key(MacroStep.Key(keyCode: 124)))
        library.macros = [Macro(name: "Deck", steps: [capture, key])]
        library.keep(longPage(height: 600), for: capture.id, pixelsPerPoint: 2)
        #expect(library.recordedCaptures(of: library.macros[0]).count == 1)

        // Kept across launches.
        #expect(MacroLibrary(directory: folder).recordedCapture(for: capture.id) != nil)

        library.macros[0].steps.removeAll { $0.id == capture.id }
        #expect(library.recordedCapture(for: capture.id) == nil)
    }

    @MainActor @Test func aRunTakesTheRecordedCapturesIn() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = MacroLibrary(directory: folder)
        let capture = MacroStep(action: .capture(CaptureArea(rect: nil)))
        library.macros = [Macro(name: "Deck", steps: [capture])]
        library.keep(longPage(height: 600), for: capture.id, pixelsPerPoint: 2)
        library.discardRecordedCaptures(of: library.macros[0])
        #expect(library.recordedCaptures(of: library.macros[0]).isEmpty)
        #expect(library.macros[0].steps.count == 1)
    }

    /// A capture of several pages comes out as a picture a page; any other
    /// file as it is, under a name not taken.
    @Test func originalsAreExportedAsTheyWere() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let tiff = folder.appending(path: "Pages.tiff")
        #expect(ScrollingCapture.assemble((1...3).map { longPage(height: 500, seed: $0) }, into: tiff))
        let pages = try OCRViewModel.exportOriginal(tiff, into: out)
        let written = try FileManager.default.contentsOfDirectory(atPath: pages.path(percentEncoded: false)).sorted()
        #expect(written == ["Pages 1.png", "Pages 2.png", "Pages 3.png"])

        let png = folder.appending(path: "Shot.png")
        save(longPage(height: 3000), to: png)
        let first = try OCRViewModel.exportOriginal(png, into: out)
        let second = try OCRViewModel.exportOriginal(png, into: out)
        #expect(first.lastPathComponent == "Shot.png")
        #expect(second.lastPathComponent == "Shot 2.png")
        // The long screenshot whole, not cut into the pages it is read as.
        #expect(PageImages.wholeImage(at: first)?.height == 3000)
    }
}
