import Foundation
import CoreGraphics
import PDFKit
import Synchronization

/// One line of a PDF's text layer, in the pixels of a rendered page.
struct PDFTextLine: Equatable {
    var rect: CGRect
    var text: String
}

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
/// recognisers read pages concurrently; every access goes through the mutex.
final class PDFSource: Sendable {
    /// 144 dpi: enough for the detectors to see small print, small enough that
    /// a page stays a few megabytes.
    static let renderScale: CGFloat = 2

    private let document: Mutex<PDFDocument>

    init?(url: URL) {
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
        self.document = Mutex(document)
    }

    var pageCount: Int {
        document.withLock { $0.pageCount }
    }

    /// Draws the page as a viewer shows it: the crop box, turned by the
    /// page's own rotation. Drawing the media box unrotated, as the first
    /// version did, read rotated scans sideways and margins that are not
    /// meant to be seen.
    func render(page index: Int, scale: CGFloat = renderScale) -> RenderedPDFPage? {
        document.withLock { document in
            document.page(at: index).flatMap { Self.render($0, scale: scale) }
        }
    }

    /// Whether the page's own text can be trusted, and why not if it cannot.
    func verdict(page index: Int) -> PDFTextLayer.Verdict {
        document.withLock { document in
            document.page(at: index).map(PDFTextLayer.verdict(for:)) ?? .none
        }
    }

    /// What the page's own text layer says about the given pixel regions —
    /// one string per region — together with whether that text can be
    /// trusted. Nil regions means the whole page's text as one string.
    func nativeText(page index: Int, rendering: RenderedPDFPage, regions: [CGRect]?,
                    policy: PDFTextPolicy) -> (verdict: PDFTextLayer.Verdict, texts: [String]) {
        document.withLock { document in
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
    }

    /// The page's text layer line by line, each line where it sits in the
    /// rendered page's pixels.
    func textLines(page index: Int, rendering: RenderedPDFPage) -> [PDFTextLine] {
        document.withLock { document in
            guard let page = document.page(at: index),
                  let all = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
            let toPixel = rendering.pageToPixel
            return all.selectionsByLine().compactMap { line in
                let text = PDFTextLayer.cleaned(line.string ?? "")
                guard !text.isEmpty else { return nil }
                return PDFTextLine(rect: line.bounds(for: page).applying(toPixel).standardized, text: text)
            }
        }
    }

    static func render(_ page: PDFPage, scale: CGFloat) -> RenderedPDFPage? {
        // Drawn the way its text reads, which is not always the way the PDF
        // says to turn it; the page is put back as it was afterwards.
        let stated = page.rotation
        let upright = uprightRotation(of: page)
        if upright != stated { page.rotation = upright }
        defer { page.rotation = stated }

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
        // Link annotations are drawn as the red or blue boxes LaTeX's hyperref
        // puts round every citation and reference. They are not on the page a
        // reader prints, they look like the app's own markings in the preview,
        // and they are noise to OCR — so they are left out. Every other
        // annotation, a filled-in form field above all, is drawn as it is.
        let links = page.annotations.filter { $0.type == "Link" && $0.shouldDisplay }
        links.forEach { $0.shouldDisplay = false }
        defer { links.forEach { $0.shouldDisplay = true } }
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

extension PDFSource {
    /// The quarter turn, in degrees, that puts the page's text the right way
    /// up — the page's own `/Rotate` unless its text says otherwise.
    ///
    /// A page can be marked as turned when what it draws is already upright:
    /// a portrait page saved with `/Rotate 90` shows sideways in every viewer,
    /// and the orientation classifier is not asked about pages a PDF draws
    /// itself. Which way the characters advance settles it. Vertical CJK
    /// writing advances downwards on an upright page, so for CJK text only a
    /// page whose lines run right to left — upside down — is turned.
    static func uprightRotation(of page: PDFPage) -> Int {
        let stated = ((page.rotation % 360) + 360) % 360
        guard let (direction, cjk) = TextAdvance.dominant(on: page) else { return stated }
        switch direction {
        case .right: return 0
        case .left:  return 180
        case .up:    return cjk ? stated : 90
        case .down:  return cjk ? stated : 270
        }
    }

    /// Which way most of a page's text runs, in unrotated page space.
    enum TextAdvance {
        case right, left, up, down

        /// Nil when the page has too little text, or no clear majority, to tell.
        static func dominant(on page: PDFPage) -> (TextAdvance, cjk: Bool)? {
            guard let string = page.string, !string.isEmpty else { return nil }
            let text = string as NSString
            let length = text.length
            // Enough pairs to outvote a rotated figure label or a margin stamp,
            // spread over the page, without measuring every character.
            let stride = max(1, length / 300)
            var votes: [TextAdvance: Int] = [:]
            var cjkCount = 0, sampled = 0
            var index = 0
            while index + 1 < length {
                defer { index += stride }
                guard let a = UnicodeScalar(text.character(at: index)),
                      let b = UnicodeScalar(text.character(at: index + 1)),
                      CharacterSet.alphanumerics.contains(a), CharacterSet.alphanumerics.contains(b)
                else { continue }
                // A one-character selection, not `characterBounds(at:)`: the
                // latter reports a turned glyph in the text's own frame, so
                // sideways text looked as if it ran left to right.
                guard let first = page.selection(for: NSRange(location: index, length: 1))?.bounds(for: page),
                      let second = page.selection(for: NSRange(location: index + 1, length: 1))?.bounds(for: page),
                      !first.isEmpty, !second.isEmpty else { continue }
                let dx = second.midX - first.midX, dy = second.midY - first.midY
                let size = max(min(first.width, first.height), 0.5)
                // Neighbours on the same line advance by about a character;
                // anything else is a line break or a jump between columns.
                guard max(abs(dx), abs(dy)) > size * 0.2, max(abs(dx), abs(dy)) < size * 3 else { continue }
                let direction: TextAdvance = abs(dx) >= abs(dy) ? (dx > 0 ? .right : .left)
                                                                 : (dy > 0 ? .up : .down)
                votes[direction, default: 0] += 1
                sampled += 1
                if a.properties.isIdeographic || (0x3040...0x30FF).contains(a.value) { cjkCount += 1 }
            }
            guard sampled >= 20, let (winner, count) = votes.max(by: { $0.value < $1.value }),
                  Double(count) >= Double(sampled) * 0.6 else { return nil }
            return (winner, cjkCount * 2 > sampled)
        }
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
        case .digitalOnly:  return String(localized: "Native text only (recommended)")
        case .anyTextLayer: return String(localized: "Any text layer (including OCR layers on scans)")
        case .never:        return String(localized: "Never; always recognize again")
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
    enum Verdict: String, Codable {
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
            case .none:    return String(localized: "no text layer")
            case .digital: return String(localized: "native text layer")
            case .scanned: return String(localized: "OCR text layer on a scan")
            case .garbled: return String(localized: "text layer can't be decoded correctly")
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

        /// Filled in once and only read afterwards.
        nonisolated(unsafe) private static let table: CGPDFOperatorTableRef? = {
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
