import Foundation
import CoreGraphics
import PDFKit

/// A PDF page drawn to pixels, and the way back from pixels to the page.
struct RenderedPDFPage {
    let image: CGImage
    /// PDFKit page space — points, origin at the bottom left, unrotated — to
    /// pixels in `image`, origin at the top left.
    let pageToPixel: CGAffineTransform

    var pixelToPage: CGAffineTransform { pageToPixel.inverted() }
}

/// Opens PDFs and renders their pages, one caller at a time.
///
/// PDFKit documents are not safe to use from two threads at once, and the
/// recognisers read pages concurrently; every access goes through the lock.
final class PDFSource: @unchecked Sendable {
    /// 144 dpi: enough for the detectors to see small print, small enough that
    /// a page stays a few megabytes.
    static let renderScale: CGFloat = 2

    private let document: PDFDocument
    private let lock = NSLock()

    init?(url: URL) {
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
        self.document = document
    }

    var pageCount: Int {
        lock.lock(); defer { lock.unlock() }
        return document.pageCount
    }

    /// Draws the page as a viewer shows it: the crop box, turned by the
    /// page's own rotation. Drawing the media box unrotated, as the first
    /// version did, read rotated scans sideways and margins that are not
    /// meant to be seen.
    func render(page index: Int, scale: CGFloat = renderScale) -> RenderedPDFPage? {
        lock.lock(); defer { lock.unlock() }
        guard let page = document.page(at: index) else { return nil }
        return Self.render(page, scale: scale)
    }

    /// Whether the page's own text can be trusted, and why not if it cannot.
    func verdict(page index: Int) -> PDFTextLayer.Verdict {
        lock.lock(); defer { lock.unlock() }
        guard let page = document.page(at: index) else { return .none }
        return PDFTextLayer.verdict(for: page)
    }

    /// What the page's own text layer says about the given pixel regions —
    /// one string per region — together with whether that text can be
    /// trusted. Nil regions means the whole page's text as one string.
    func nativeText(page index: Int, rendering: RenderedPDFPage, regions: [CGRect]?,
                    policy: PDFTextPolicy) -> (verdict: PDFTextLayer.Verdict, texts: [String]) {
        lock.lock(); defer { lock.unlock() }
        guard let page = document.page(at: index) else { return (.none, []) }
        let verdict = PDFTextLayer.verdict(for: page)
        guard policy.trusts(verdict) else { return (verdict, []) }
        guard let regions else { return (verdict, [page.string ?? ""]) }
        let toPage = rendering.pixelToPage
        return (verdict, regions.map { rect in
            let pageRect = rect.applying(toPage).standardized
            return PDFTextLayer.cleaned(page.selection(for: pageRect)?.string ?? "")
        })
    }

    static func render(_ page: PDFPage, scale: CGFloat) -> RenderedPDFPage? {
        let box = page.bounds(for: .cropBox)
        let quarterTurns = ((page.rotation % 360) + 360) % 360 / 90
        let size = quarterTurns % 2 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        // `draw(with:to:)` applies `transform(for:)` — crop and rotation — so
        // that same transform maps text positions onto these pixels.
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { return nil }

        let flip = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                                     tx: 0, ty: CGFloat(height))
        return RenderedPDFPage(image: image,
                               pageToPixel: page.transform(for: .cropBox).concatenating(flip))
    }
}

/// How far a PDF's own text is trusted in place of reading the page again.
enum PDFTextPolicy: String, CaseIterable, Identifiable, Codable {
    /// Text the page draws itself; scans with an OCR layer are read again.
    case digitalOnly
    /// Any text layer, including one a scanner's OCR left behind.
    case anyTextLayer
    /// Always read the pixels.
    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .digitalOnly:  return "仅原生文字（推荐）"
        case .anyTextLayer: return "任何文字层（含扫描件的 OCR 层）"
        case .never:        return "从不使用，总是重新识别"
        }
    }

    func trusts(_ verdict: PDFTextLayer.Verdict) -> Bool {
        switch self {
        case .digitalOnly:  return verdict == .digital
        case .anyTextLayer: return verdict == .digital || verdict == .scanned
        case .never:        return false
        }
    }
}

/// Decides whether a PDF page's text layer can stand in for OCR.
///
/// Having text is not the same as having *right* text. A scanner's OCR layer
/// is text too — invisible, laid under the page image, and only as good as
/// whatever produced it. Only text the page actually draws, on top of
/// whatever images it has, counts as born-digital; everything else is read
/// again.
enum PDFTextLayer {
    enum Verdict: Equatable {
        /// Nothing worth extracting.
        case none
        /// Text the page draws itself: exact, and taken as it is.
        case digital
        /// An OCR layer over a page image.
        case scanned
        /// Text that does not decode to readable characters — a font without
        /// a usable Unicode mapping, typically.
        case garbled

        var description: String {
            switch self {
            case .none:    return "无文字层"
            case .digital: return "原生文字层"
            case .scanned: return "扫描件上的 OCR 文字层"
            case .garbled: return "文字层无法正确解码"
            }
        }
    }

    static func verdict(for page: PDFPage) -> Verdict {
        let text = page.string ?? ""
        var readable = 0, broken = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            if scalar == "\u{FFFD}" || scalar.properties.generalCategory == .privateUse
                || scalar.properties.generalCategory == .control {
                broken += 1
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                readable += 1
            }
        }
        guard readable >= 8 else { return .none }
        // A few stray symbols are normal; a page where one character in
        // twenty will not decode is a font whose text cannot be trusted.
        if broken * 20 > readable + broken { return .garbled }

        guard let stats = page.pageRef.map(ContentStats.init(page:)) else { return .digital }
        let shown = stats.visibleRuns + stats.invisibleRuns
        if shown > 0, stats.invisibleRuns * 2 >= shown { return .scanned }
        // A page-sized image with no text drawn over it: whatever text the
        // page has is underneath, which is where an OCR layer goes.
        if stats.coveringImageDrawn, stats.visibleRunsOverImage == 0 { return .scanned }
        return .digital
    }

    /// PDFKit's selection text, tidied: lines it splits with a bare carriage
    /// return come back as newlines, and soft hyphens are dropped.
    static func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Walks a page's content stream — and the forms it draws — counting text
    /// by how it is rendered and noting any image that covers the page.
    private final class ContentStats {
        var visibleRuns = 0
        var invisibleRuns = 0
        var visibleRunsOverImage = 0
        var coveringImageDrawn = false

        private var ctm = CGAffineTransform.identity
        private var renderMode = 0
        private var saved: [(CGAffineTransform, Int)] = []
        private let pageArea: CGFloat
        private var depth = 0

        init(page: CGPDFPage) {
            let box = page.getBoxRect(.mediaBox)
            pageArea = max(1, box.width * box.height)
            let stream = CGPDFContentStreamCreateWithPage(page)
            scan(stream)
        }

        private func scan(_ stream: CGPDFContentStreamRef) {
            guard depth < 6, let table = Self.table else { return }
            depth += 1
            let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            depth -= 1
        }

        private static func stats(_ info: UnsafeMutableRawPointer?) -> ContentStats? {
            info.map { Unmanaged<ContentStats>.fromOpaque($0).takeUnretainedValue() }
        }

        private func showText() {
            // Mode 3 is "neither fill nor stroke", and mode 7 only clips: the
            // glyphs are there for selection and search but never seen.
            if renderMode == 3 || renderMode == 7 {
                invisibleRuns += 1
            } else {
                visibleRuns += 1
                if coveringImageDrawn { visibleRunsOverImage += 1 }
            }
        }

        private func drawXObject(named name: UnsafePointer<CChar>, scanner: CGPDFScannerRef) {
            let content = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }

            switch String(cString: subtype) {
            case "Image":
                // An image fills the unit square, mapped through the CTM.
                let area = abs(ctm.a * ctm.d - ctm.b * ctm.c)
                if area >= pageArea * 0.85 { coveringImageDrawn = true }
            case "Form":
                var resources: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                // A form without resources of its own inherits its parent's,
                // which the parent stream passed alongside provides.
                let form = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content)
                let outer = (ctm, renderMode)
                var matrix: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix,
                   CGPDFArrayGetCount(matrix) == 6 {
                    var values = [CGPDFReal](repeating: 0, count: 6)
                    for index in 0..<6 { _ = CGPDFArrayGetNumber(matrix, index, &values[index]) }
                    ctm = CGAffineTransform(a: values[0], b: values[1], c: values[2],
                                            d: values[3], tx: values[4], ty: values[5])
                        .concatenating(ctm)
                }
                scan(form)
                (ctm, renderMode) = outer
                CGPDFContentStreamRelease(form)
            default:
                break
            }
        }

        private static let table: CGPDFOperatorTableRef? = {
            guard let table = CGPDFOperatorTableCreate() else { return nil }
            CGPDFOperatorTableSetCallback(table, "q") { _, info in
                guard let s = ContentStats.stats(info) else { return }
                s.saved.append((s.ctm, s.renderMode))
            }
            CGPDFOperatorTableSetCallback(table, "Q") { _, info in
                guard let s = ContentStats.stats(info), let last = s.saved.popLast() else { return }
                (s.ctm, s.renderMode) = last
            }
            CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
                guard let s = ContentStats.stats(info) else { return }
                var v = [CGPDFReal](repeating: 0, count: 6)
                for index in (0..<6).reversed() {
                    guard CGPDFScannerPopNumber(scanner, &v[index]) else { return }
                }
                s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                    .concatenating(s.ctm)
            }
            CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
                guard let s = ContentStats.stats(info) else { return }
                var mode: CGPDFInteger = 0
                if CGPDFScannerPopInteger(scanner, &mode) { s.renderMode = mode }
            }
            for op in ["Tj", "TJ", "'", "\""] {
                CGPDFOperatorTableSetCallback(table, op) { _, info in
                    ContentStats.stats(info)?.showText()
                }
            }
            CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
                guard let s = ContentStats.stats(info) else { return }
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopName(scanner, &name), let name else { return }
                s.drawXObject(named: name, scanner: scanner)
            }
            return table
        }()
    }
}
