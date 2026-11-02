import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import OCRFlow

struct CaptureTests {

    /// A selection on a Retina display to the left of and above the main
    /// one: screen coordinates grow upward from the main display's corner,
    /// pictures downward from their own display's.
    @Test func selectionIsMeasuredFromItsOwnDisplaysTopLeft() {
        let display = CGRect(x: -1920, y: 982, width: 1920, height: 1080)
        let selection = CGRect(x: -1820, y: 1000, width: 200, height: 100)
        let (points, pixels) = CaptureOverlay.place(selection, on: display, pixelWidth: 3840)
        #expect(points == CGRect(x: 100, y: 962, width: 200, height: 100))
        #expect(pixels == CGRect(x: 200, y: 1924, width: 400, height: 200))
    }

    @Test func wholeDisplayIsTheWholePicture() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let (points, pixels) = CaptureOverlay.place(display, on: display, pixelWidth: 3024)
        #expect(points == CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(pixels == CGRect(x: 0, y: 0, width: 3024, height: 1964))
    }

    /// A selection on half points still cuts whole pixels, and never less
    /// than was selected.
    @Test func halfPointsRoundOutward() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let selection = CGRect(x: 10.25, y: 20.25, width: 30.5, height: 40.5)
        let (_, pixels) = CaptureOverlay.place(selection, on: display, pixelWidth: 1000)
        #expect(pixels == CGRect(x: 10, y: 939, width: 31, height: 41))
    }

    /// The pointer between points: the area dragged out is on whole points,
    /// whichever way it was dragged, and is what is taken — not a point more.
    @Test func aDraggedAreaIsOnWholePoints() {
        let area = CGRect(draggedFrom: CGPoint(x: 600.6, y: 500.4), to: CGPoint(x: 200.3, y: 300.7))
        #expect(area == CGRect(x: 200, y: 301, width: 401, height: 199))
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let (points, pixels) = CaptureOverlay.place(area, on: display, pixelWidth: 3840)
        #expect(points.size == area.size)
        #expect(pixels.size == CGSize(width: 802, height: 398))
    }

    // MARK: - Adjusting what was chosen

    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    /// Near an edge, inside or out, a drag takes it; near two, the corner;
    /// in the middle, the whole; away from it, nothing.
    @Test func whatADragTakesHoldOf() {
        let area = CGRect(x: 100, y: 100, width: 300, height: 200)
        #expect(AreaGrip.at(CGPoint(x: 97, y: 200), of: area) == .left)
        #expect(AreaGrip.at(CGPoint(x: 404, y: 200), of: area) == .right)
        #expect(AreaGrip.at(CGPoint(x: 250, y: 302), of: area) == .top)
        #expect(AreaGrip.at(CGPoint(x: 402, y: 98), of: area) == [.right, .bottom])
        #expect(AreaGrip.at(CGPoint(x: 250, y: 200), of: area) == [])
        #expect(AreaGrip.at(CGPoint(x: 80, y: 200), of: area) == nil)
        // Too small to have a middle: the nearest edges.
        let small = CGRect(x: 100, y: 100, width: 8, height: 8)
        #expect(AreaGrip.at(CGPoint(x: 103, y: 106), of: small) == [.left, .top])
    }

    /// An edge dragged by the pointer between points lands on a whole one;
    /// the edges across from it stay.
    @Test func aDraggedEdgeIsOnWholePoints() {
        let area = CGRect(x: 100, y: 100, width: 300, height: 200)
        #expect(area.adjusted(.right, by: CGVector(dx: 20.6, dy: 7), within: screen)
                == CGRect(x: 100, y: 100, width: 321, height: 200))
        #expect(area.adjusted([.left, .top], by: CGVector(dx: -10.4, dy: 5.5), within: screen)
                == CGRect(x: 90, y: 100, width: 310, height: 206))
    }

    /// Dragged past the edge across from it, it turns inside out, as when
    /// it was dragged out; never less than a point.
    @Test func anEdgeDraggedPastTheOtherTurnsItOver() {
        let area = CGRect(x: 100, y: 100, width: 300, height: 200)
        #expect(area.adjusted(.left, by: CGVector(dx: 350, dy: 0), within: screen)
                == CGRect(x: 400, y: 100, width: 50, height: 200))
        #expect(area.adjusted(.bottom, by: CGVector(dx: 0, dy: 200), within: screen)
                == CGRect(x: 100, y: 300, width: 300, height: 1))
    }

    /// Kept to the screen it is on, dragged by an edge or moved whole.
    @Test func anAdjustedAreaStaysOnItsScreen() {
        let area = CGRect(x: 100, y: 100, width: 300, height: 200)
        #expect(area.adjusted(.right, by: CGVector(dx: 5000, dy: 0), within: screen).maxX == screen.maxX)
        #expect(area.adjusted([.left, .bottom], by: CGVector(dx: -500, dy: -500), within: screen)
                == CGRect(x: 0, y: 0, width: 400, height: 300))
        // Moved whole, it stops at the edge, as large as it was.
        #expect(area.moved(by: CGVector(dx: -150, dy: 900), within: screen)
                == CGRect(x: 0, y: 782, width: 300, height: 200))
        #expect(area.moved(by: CGVector(dx: 0.4, dy: -1), within: screen)
                == CGRect(x: 100, y: 99, width: 300, height: 200))
        // A window partly off the screen, the part on it.
        let window = CGRect(x: -40.5, y: 900, width: 600, height: 400)
        #expect(window.kept(within: screen) == CGRect(x: 0, y: 900, width: 560, height: 82))
    }

    /// A size typed in: the top-left corner stays where it is, unless the
    /// screen ends first, and it is never larger than the screen.
    @Test func aTypedSizeKeepsTheTopLeftCorner() {
        let area = CGRect(x: 100, y: 100, width: 300, height: 200)
        #expect(area.resized(to: CGSize(width: 640, height: 200), within: screen)
                == CGRect(x: 100, y: 100, width: 640, height: 200))
        // Taller: it grows down from its top.
        #expect(area.resized(to: CGSize(width: 300, height: 250), within: screen)
                == CGRect(x: 100, y: 50, width: 300, height: 250))
        // More than there is room for: moved to fit.
        #expect(area.resized(to: CGSize(width: 1500, height: 400), within: screen)
                == CGRect(x: 12, y: 0, width: 1500, height: 400))
        #expect(area.resized(to: CGSize(width: 9999, height: 9999), within: screen) == screen)
    }

    // MARK: - Pages

    /// A page of "text": dark bars on white, in rows that depend on `seed`.
    private func page(width: Int = 1200, height: Int = 800, seed: Int, dot: CGRect? = nil) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        for row in 0..<20 {
            let length = 200 + (row * 37 + seed * 101) % 800
            context.fill(CGRect(x: 60, y: 40 + row * 36, width: length, height: 16))
        }
        if let dot { context.fill(dot) }
        return context.makeImage()!
    }

    @Test func theSamePageIsTheSamePage() throws {
        let a = try #require(PageFingerprint(page(seed: 1)))
        let b = try #require(PageFingerprint(page(seed: 1)))
        #expect(a.change(from: b) == 0)
        #expect(a.isSamePage(as: b))
    }

    /// A caret blinking, or a clock changing, is not a new page.
    @Test func aSmallChangeIsNotANewPage() throws {
        let a = try #require(PageFingerprint(page(seed: 1)))
        let b = try #require(PageFingerprint(page(seed: 1, dot: CGRect(x: 1000, y: 700, width: 2, height: 18))))
        #expect(a.isSamePage(as: b))
    }

    @Test func theNextPageIsANewPage() throws {
        let a = try #require(PageFingerprint(page(seed: 1)))
        let b = try #require(PageFingerprint(page(seed: 2)))
        #expect(!a.isSamePage(as: b))
    }

    /// A small look taken while waiting matches the full capture of the same
    /// page.
    @Test func aSmallLookMatchesTheFullPage() throws {
        let full = page(width: 2400, height: 1600, seed: 3)
        let context = CGContext(data: nil, width: 640, height: 427, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: 640, height: 427))
        let a = try #require(PageFingerprint(full))
        let b = try #require(PageFingerprint(context.makeImage()!))
        #expect(a.isSamePage(as: b), "change \(a.change(from: b))")
    }

    /// The pages become one multi-page file, read as one document, each page
    /// at its own size.
    @Test func pagesBecomeOneDocument() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sizes = [(1200, 800), (1200, 800), (900, 1400)]
        let pages = try sizes.enumerated().map { index, size in
            let url = folder.appending(path: "\(index).png")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, page(width: size.0, height: size.1, seed: index), nil)
            #expect(CGImageDestinationFinalize(destination))
            return url
        }
        let document = folder.appending(path: "Pages.tiff")
        #expect(ScrollingCapture.assemble(pages, into: document))
        #expect(PageImages.frameCount(of: document) == 3)
        #expect(DocumentRecognizer.pageCount(of: document) == 3)
        for (index, size) in sizes.enumerated() {
            let image = try #require(PageImages.image(at: document, frame: index))
            #expect(image.width == size.0)
            #expect(image.height == size.1)
        }
    }

    // MARK: - Long screenshot controls

    /// The button in the middle of the area; the preview beside it, its
    /// top level with the area's, as tall — never over it.
    @MainActor @Test func theScrollButtonIsInTheMiddleAndThePreviewBeside() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1050)
        let area = CGRect(x: 300, y: 200, width: 659, height: 600)
        let frames = CaptureMarks.scrollFrames(for: area, on: screen, buttonSize: CGSize(width: 130, height: 32))
        #expect(abs(frames.button.midX - area.midX) <= 0.5 && abs(frames.button.midY - area.midY) <= 0.5)
        #expect(frames.button.size == CGSize(width: 130, height: 32))
        #expect(frames.preview.width == CaptureMarks.columnWidth)
        #expect(frames.preview.maxY == area.maxY && frames.preview.minY == area.minY)
        // More room to the right: there.
        #expect(frames.preview.minX == area.maxX + 8)
        #expect(!frames.preview.intersects(area))
    }

    @MainActor @Test func theScrollPreviewGoesWhereThereIsRoom() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1050)
        let button = CGSize(width: 130, height: 32)
        // Near the right edge: to the left.
        let right = CGRect(x: 1200, y: 100, width: 700, height: 800)
        #expect(CaptureMarks.scrollFrames(for: right, on: screen, buttonSize: button).preview.maxX == right.minX - 8)
        // Little room either side: narrower, still on screen.
        let wide = CGRect(x: 100, y: 100, width: 1720, height: 800)
        let narrow = CaptureMarks.scrollFrames(for: wide, on: screen, buttonSize: button).preview
        #expect(narrow.width == CaptureMarks.minimumColumnWidth)
        #expect(screen.contains(narrow))
        // A short area: the preview keeps a usable height, from its top.
        let short = CGRect(x: 300, y: 500, width: 400, height: 60)
        let low = CaptureMarks.scrollFrames(for: short, on: screen, buttonSize: button).preview
        #expect(low.height == CaptureMarks.minimumPreviewHeight && low.maxY == short.maxY)
        // At the top of the screen: below its top edge.
        let top = CGRect(x: 300, y: 600, width: 400, height: 450)
        #expect(CaptureMarks.scrollFrames(for: top, on: screen, buttonSize: button).preview.maxY == screen.maxY - 8)
    }

    // MARK: - Naming

    /// One alone keeps its name; several taken together are numbered in
    /// order, the numbers padded so they sort as taken.
    @Test func severalTakenTogetherAreNumberedInOrder() {
        #expect(OCRViewModel.numberedNames("截图 2026-11-01 10.57.08", count: 1) == ["截图 2026-11-01 10.57.08"])
        #expect(OCRViewModel.numberedNames("截图", count: 3) == ["截图 1", "截图 2", "截图 3"])
        let twelve = OCRViewModel.numberedNames("截图", count: 12)
        #expect(twelve.first == "截图 01" && twelve.last == "截图 12")
        #expect(twelve == twelve.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func jpegIsSavedAsJpg() {
        #expect(ScreenshotFormat.jpeg.pathExtension == "jpg")
        #expect(ScreenshotFormat.png.pathExtension == "png")
        #expect(ScreenshotFormat.heic.pathExtension == "heic")
    }

    // MARK: - Saving

    /// Each format is written as what it says, at the resolution of the
    /// screen it was taken on — 144 pixels an inch on a Retina one — and
    /// JPEG as `.jpg`; JPEG, which keeps no transparency, shows what was
    /// see-through as white.
    @Test func screenshotsAreSavedInTheChosenFormat() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        let image = context.makeImage()!
        for format in ScreenshotFormat.allCases {
            let url = folder.appending(path: "shot").appendingPathExtension(format.pathExtension)
            #expect(format.write(image, to: url, pixelsPerPoint: 2))
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            #expect(CGImageSourceGetType(source) as String? == format.type.identifier)
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyDPIWidth] as? Double == 144)
            #expect(properties[kCGImagePropertyDPIHeight] as? Double == 144)
            #expect(ScreenshotFormat.pixelsPerPoint(of: url) == 2)
            if format == .jpeg {
                let read = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                let pixel = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                pixel.draw(read, in: CGRect(x: 0, y: 0, width: 40, height: 40))
                let corner = pixel.data!.assumingMemoryBound(to: UInt8.self)[0]
                #expect(corner > 240, "corner \(corner)")
            }
        }
    }
}
