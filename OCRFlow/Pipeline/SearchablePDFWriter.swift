import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit

/// Writes results out as PDFs that look like the originals and can be searched
/// and copied from.
///
/// Each page is the source page itself — a PDF's own page drawn as vectors,
/// never rasterised, or the image at its own resolution — with the recognised
/// text laid over it invisibly, where it was found.
///
/// "Where it was found" is only ever a box some engine actually reported:
/// PP-OCRv6's and Apple Vision's lines carry their own boxes, and are placed
/// line by line. A region read by PaddleOCR-VL, or corrected by hand, has no
/// lines of its own, so its text is spread over the region's box — coarser,
/// but real. A page a born-digital PDF already carries text for gets nothing
/// added: it is searchable already.
enum SearchablePDFWriter {

    enum WriteError: LocalizedError {
        case cannotCreate(URL)
        case nothingWritten

        var errorDescription: String? {
            switch self {
            case let .cannotCreate(url): return String(localized: "Couldn't create \(url.lastPathComponent)")
            case .nothingWritten:        return String(localized: "There are no pages to write")
            }
        }
    }

    /// Writes every page of every item, in order, into one PDF.
    static func write(_ items: [ImageItem], to url: URL) throws {
        guard let context = CGContext(url as CFURL, mediaBox: nil, [
            kCGPDFContextCreator: "OCRFlow",
        ] as CFDictionary) else { throw WriteError.cannotCreate(url) }
        var pages = 0
        for item in items {
            pages += item.isPDF ? writePDF(item, into: context) : writeImages(item, into: context)
        }
        context.closePDF()
        if pages == 0 {
            try? FileManager.default.removeItem(at: url)
            throw WriteError.nothingWritten
        }
    }

    // MARK: - Sources

    private static func writePDF(_ item: ImageItem, into context: CGContext) -> Int {
        guard let document = PDFDocument(url: item.url) else { return 0 }
        var written = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let source = page.pageRef else { continue }
            let box = page.bounds(for: .cropBox)
            let quarterTurns = ((page.rotation % 360) + 360) % 360 / 90
            let size = quarterTurns % 2 == 0 ? box.size : CGSize(width: box.height, height: box.width)
            var media = CGRect(origin: .zero, size: size)

            context.beginPage(mediaBox: &media)
            context.saveGState()
            context.clip(to: media)
            context.concatenate(source.getDrawingTransform(.cropBox, rect: media, rotate: 0,
                                                           preserveAspectRatio: true))
            context.drawPDFPage(source)
            context.restoreGState()
            if item.pages.indices.contains(index) {
                overlay(item.pages[index], in: context, size: size)
            }
            context.endPage()
            written += 1
        }
        return written
    }

    private static func writeImages(_ item: ImageItem, into context: CGContext) -> Int {
        var written = 0
        for index in 0..<max(item.pages.count, 1) {
            let result = item.pages.indices.contains(index) ? item.pages[index] : nil
            // The boxes belong to the flattened page when there is one.
            let image = result?.rectified?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                ?? PageImages.image(at: item.url, frame: index)
            guard let image else { continue }
            let dpi = resolution(of: item.url, frame: index)
            let size = CGSize(width: CGFloat(image.width) * 72 / dpi,
                              height: CGFloat(image.height) * 72 / dpi)
            var media = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &media)
            context.draw(image, in: media)
            if let result { overlay(result, in: context, size: size) }
            context.endPage()
            written += 1
        }
        return written
    }

    /// The resolution an image says it was scanned at, so a 300 dpi A4 scan
    /// becomes an A4 page rather than a poster. Screenshots and photos, which
    /// carry 72 or nothing, come out at 72.
    private static func resolution(of url: URL, frame: Int) -> CGFloat {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any],
              let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi >= 72 else { return 72 }
        return CGFloat(dpi)
    }

    // MARK: - Text layer

    /// Lays one page's text over it, invisibly.
    static func overlay(_ page: PageResult, in context: CGContext, size: CGSize) {
        guard page.size.width > 0, page.size.height > 0 else { return }
        let sx = size.width / page.size.width, sy = size.height / page.size.height
        // Page pixels, origin at the top left, to PDF points, origin at the
        // bottom left.
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sx, y: size.height - p.y * sy) }

        context.saveGState()
        context.setTextDrawingMode(.invisible)
        defer { context.restoreGState() }

        // Regions whose text did not come from the lines inside them.
        var placedByRegion: [CGRect] = []
        for block in page.blocks {
            let source = block.source ?? page.blockSource
            // Already in the source PDF.
            if source == .pdfTextLayer && !block.isCorrected { continue }
            guard source == .visionLanguageModel || block.isCorrected else { continue }
            let text = plain(block.text)
            guard !text.isEmpty else { continue }
            placedByRegion.append(block.rect)
            place(text, in: block.rect, point: point, context: context)
        }

        for line in page.lines {
            let box = line.boundingBox
            let centre = CGPoint(x: box.midX, y: box.midY)
            guard !placedByRegion.contains(where: { $0.contains(centre) }) else { continue }
            place(line, point: point, context: context)
        }

        // A whole-page reading has neither lines nor regions: its text covers
        // the page.
        if page.blocks.isEmpty, page.lines.isEmpty, page.blockSource != .pdfTextLayer {
            let text = plain(page.rawText)
            if !text.isEmpty {
                place(text, in: CGRect(origin: .zero, size: page.size), point: point, context: context)
            }
        }
    }

    /// One recognised line along its own baseline, stretched to its own width.
    private static func place(_ line: PPTextLine, point: (CGPoint) -> CGPoint, context: CGContext) {
        guard line.quad.count == 4, !line.text.isEmpty else { return }
        let topLeft = point(line.quad[0]), topRight = point(line.quad[1])
        let bottomRight = point(line.quad[2]), bottomLeft = point(line.quad[3])
        let run = CGPoint(x: bottomRight.x - bottomLeft.x, y: bottomRight.y - bottomLeft.y)
        let width = hypot(run.x, run.y)
        let height = (hypot(topLeft.x - bottomLeft.x, topLeft.y - bottomLeft.y)
                      + hypot(topRight.x - bottomRight.x, topRight.y - bottomRight.y)) / 2
        guard width > 1, height > 1 else { return }
        draw(line.text, baselineStart: bottomLeft, angle: atan2(run.y, run.x),
             width: width, height: height, context: context)
    }

    /// Text without boxes of its own, set inside its region.
    ///
    /// Wrapped by CoreText at the largest size that fits the region, so the
    /// glyphs keep their natural spacing: stretching a short row across a
    /// wide box is what made readers extract "T a b l e" — every letter apart
    /// — and miss every search.
    private static func place(_ text: String, in rect: CGRect, point: (CGPoint) -> CGPoint,
                              context: CGContext) {
        let topLeft = point(CGPoint(x: rect.minX, y: rect.minY))
        let bottomRight = point(CGPoint(x: rect.maxX, y: rect.maxY))
        let frame = CGRect(x: topLeft.x, y: bottomRight.y,
                           width: bottomRight.x - topLeft.x, height: topLeft.y - bottomRight.y)
        guard frame.width > 2, frame.height > 2 else { return }

        func setter(_ size: CGFloat) -> CTFramesetter {
            let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
            return CTFramesetterCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: font]))
        }
        func fits(_ size: CGFloat) -> Bool {
            let needed = CTFramesetterSuggestFrameSizeWithConstraints(
                setter(size), CFRange(), nil, CGSize(width: frame.width, height: .greatestFiniteMagnitude), nil)
            return needed.height <= frame.height
        }
        // The largest size, to a tenth of a point, at which it all fits.
        var low: CGFloat = 1, high = max(1, min(frame.height, 72))
        if fits(high) { low = high }
        while high - low > 0.1 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        context.textMatrix = .identity
        let path = CGPath(rect: frame, transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(setter(low), CFRange(), path, nil), context)
    }

    /// One line of text on a baseline, as wide as the box it was found in.
    ///
    /// The font is scaled as a whole to reach that width; only a line far
    /// shorter than its box is stretched as well, and then by no more than it
    /// must be.
    private static func draw(_ text: String, baselineStart: CGPoint, angle: CGFloat,
                             width: CGFloat, height: CGFloat, context: CGContext) {
        let reference = max(1, height * 0.9)
        let natural = lineWidth(text, size: reference)
        guard natural > 0 else { return }
        let scale = width / natural
        let size = max(1, reference * min(scale, 2))
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        let stretch = scale > 2 ? scale / 2 : 1
        let descent = min(CTFontGetDescent(font), height * 0.25)
        context.textMatrix = CGAffineTransform(rotationAngle: angle).scaledBy(x: stretch, y: 1)
        let up = CGPoint(x: -sin(angle) * descent, y: cos(angle) * descent)
        context.textPosition = CGPoint(x: baselineStart.x + up.x, y: baselineStart.y + up.y)
        CTLineDraw(line, context)
    }

    private static func lineWidth(_ text: String, size: CGFloat) -> CGFloat {
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// What a reader searching the page would type: no HTML, no maths
    /// delimiters.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "</tr>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "$$", with: "")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
