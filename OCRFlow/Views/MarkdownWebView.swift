import SwiftUI
import WebKit

/// The Markdown pane: the page's document rendered as a document.
///
/// Drawn by WebKit with markdown-it and KaTeX, bundled under
/// `Resources/MarkdownViewer`, rather than by the app's own renderer: every
/// table — merged cells included — and every formula KaTeX knows comes out
/// right the first time, instead of one construct at a time as each turned up
/// unrendered. Nothing is fetched; the page only reads its own folder.
struct MarkdownWebView: NSViewRepresentable {
    /// One region's Markdown, whether it is flagged for review, and — when it
    /// can be corrected — its own text and what kind of text that is, which
    /// is what a double-click edits in place.
    struct Fragment: Encodable, Equatable {
        var block: Int?
        var markdown: String
        var flagged = false
        var text: String?
        /// "text", "table" or "formula".
        var kind: String?
    }

    let fragments: [Fragment]
    /// Crops for the figure placeholders, in document order.
    let figures: [NSImage?]
    var selected: Int?
    var onSelect: (Int) -> Void = { _ in }
    /// A region edited in place, with its new text.
    var onSave: (Int, String) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Takes the click that brings the window forward as a click too, like the
    /// native panes beside it — otherwise the first click on an inactive
    /// window only activates it, and a double-click arrives as one.
    final class FirstMouseWebView: WKWebView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "ocrflow")
        let view = FirstMouseWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        if let page = Bundle.main.url(forResource: "viewer", withExtension: "html",
                                      subdirectory: "MarkdownViewer") {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.onSave = onSave
        // Encoding the figures is the costly part, so the document is sent
        // again only when it is a different document.
        let key = DocumentKey(fragments: fragments, figures: figures)
        if coordinator.renderedKey != key {
            coordinator.renderedKey = key
            coordinator.pending = Payload(fragments: fragments,
                                          figures: figures.map { $0.flatMap(Self.dataURL) },
                                          selected: selected,
                                          accent: Self.accentHex(),
                                          figureLabel: String(localized: "Image"))
            coordinator.selected = selected
            coordinator.flush()
        } else if coordinator.selected != selected {
            coordinator.selected = selected
            coordinator.run("OCRFlow.select(\(selected.map(String.init) ?? "null"))")
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "ocrflow")
    }

    fileprivate struct DocumentKey: Equatable {
        let fragments: [Fragment]
        /// The crops themselves, compared by identity. Held rather than only
        /// identified: a freed image's identifier can be handed to the next
        /// one, which would then pass for the crop it replaced.
        let figures: [NSImage?]

        static func == (a: Self, b: Self) -> Bool {
            a.fragments == b.fragments && a.figures.count == b.figures.count
                && zip(a.figures, b.figures).allSatisfy { $0 === $1 }
        }
    }

    struct Payload: Encodable {
        let fragments: [Fragment]
        let figures: [String?]
        let selected: Int?
        let accent: String
        /// What an uncaptioned figure is called, in the app's language.
        let figureLabel: String
    }

    /// Each crop's inline image, kept for as long as the crop is in use: an
    /// edit sends the whole document again, and only a crop not seen before
    /// needs encoding. Keyed by the image itself — `NSImage` compares by
    /// identity — and held, so a freed crop's address can't stand for a new one.
    @MainActor private static let encodedFigures: NSCache<NSImage, NSString> = {
        let cache = NSCache<NSImage, NSString>()
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    /// A crop as an inline image the page can show without file access.
    @MainActor private static func dataURL(_ image: NSImage) -> String? {
        if let cached = encodedFigures.object(forKey: image) { return cached as String }
        // Straight from the crop's pixels, not by way of a TIFF copy of them.
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let jpeg = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        let url = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        encodedFigures.setObject(url as NSString, forKey: image, cost: url.utf8.count)
        return url
    }

    /// The app's own accent — not the system's — in the page's terms, so links
    /// and the selection match the rest of the window in either appearance.
    private static func accentHex() -> String {
        guard let color = NSColor(named: "AccentColor")?.usingColorSpace(.sRGB) else { return "#0D9888" }
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255),
                      Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var view: WKWebView?
        var onSelect: (Int) -> Void = { _ in }
        var onSave: (Int, String) -> Void = { _, _ in }
        fileprivate var renderedKey: DocumentKey?
        var selected: Int?
        var pending: Payload?
        private var isReady = false

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if body["ready"] != nil {
                isReady = true
                flush()
            } else if let block = body["select"] as? Int {
                onSelect(block)
            } else if let block = body["save"] as? Int, let text = body["text"] as? String {
                onSave(block, text)
            }
        }

        /// Sends the waiting document once the page can take it.
        func flush() {
            guard isReady, let payload = pending,
                  let data = try? JSONEncoder().encode(payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            pending = nil
            run("OCRFlow.render(\(json))")
        }

        func run(_ script: String) {
            guard isReady else { return }
            view?.evaluateJavaScript(script, completionHandler: nil)
        }

        /// Links in a document open in the browser, not in the pane.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                // Only web and mail links: a link in a recognised page is
                // text from the page, and `file:` or a custom scheme would
                // open an app or a document on this Mac.
                if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
