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

    // MARK: - Page by page

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
        #expect(PageByPageCapture.assemble(pages, into: document))
        #expect(PageImages.frameCount(of: document) == 3)
        #expect(DocumentRecognizer.pageCount(of: document) == 3)
        for (index, size) in sizes.enumerated() {
            let image = try #require(PageImages.image(at: document, frame: index))
            #expect(image.width == size.0)
            #expect(image.height == size.1)
        }
    }
}
