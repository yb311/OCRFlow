import SwiftUI
import AppKit

// MARK: - Layout

/// Where the horizontal rule of a fraction sits, so everything on a line lines
/// up on the same axis rather than on its own centre.
extension VerticalAlignment {
    private enum MathAxis: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
            dimensions[VerticalAlignment.center]
        }
    }
    static let mathAxis = VerticalAlignment(MathAxis.self)
}

/// Renders a parsed formula.
struct MathNodeView: View {
    let node: MathNode
    var size: CGFloat = 15
    /// Display style sets big operators' limits above and below.
    var display = true

    /// Type-erased on purpose. A formula is a tree, so this view contains
    /// itself — and a SwiftUI view whose body type mentions its own body type
    /// makes the runtime expand that type forever and blow the stack. `AnyView`
    /// is the break in the chain; a formula is a few dozen nodes, so the cost
    /// of erasing them is nothing.
    var body: some View {
        AnyView(content)
    }

    /// The axis sits a little above the baseline — about where a minus sign is
    /// drawn — which is what a fraction bar aligns to.
    private var axisOffset: CGFloat { size * 0.3 }

    @ViewBuilder
    private var content: some View {
        switch node {
        case let .run(text):
            MathRunView(text: text, size: size)
                .alignmentGuide(.mathAxis) { $0[.firstTextBaseline] - axisOffset }

        case let .sequence(nodes):
            HStack(alignment: .mathAxis, spacing: 0) {
                ForEach(Array(nodes.enumerated()), id: \.offset) { _, child in
                    MathNodeView(node: child, size: size, display: display)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

        case let .fraction(numerator, denominator):
            VStack(spacing: size * 0.12) {
                MathNodeView(node: numerator, size: size * 0.92, display: false)
                Rectangle()
                    .frame(height: max(1, size * 0.055))
                MathNodeView(node: denominator, size: size * 0.92, display: false)
            }
            // Without this the rule inside stretches to whatever width is
            // going, and a fraction ends up as wide as the pane.
            .fixedSize()
            .padding(.horizontal, size * 0.12)
            .alignmentGuide(.mathAxis) { dimensions in
                // The bar's own centre, measured through the stack.
                dimensions[VerticalAlignment.center]
            }

        case let .radical(index, radicand):
            HStack(alignment: .mathAxis, spacing: 0) {
                if let index {
                    MathNodeView(node: index, size: size * 0.6, display: false)
                        .offset(y: -size * 0.35)
                        .padding(.trailing, -size * 0.16)
                }
                RadicalShape()
                    .stroke(lineWidth: max(1, size * 0.06))
                    .frame(width: size * 0.5)
                MathNodeView(node: radicand, size: size, display: display)
                    .padding(.horizontal, size * 0.1)
                    .overlay(alignment: .top) {
                        Rectangle().frame(height: max(1, size * 0.06))
                    }
            }
            .fixedSize()

        case let .scripted(base, superscript, subscriptNode, limits):
            if limits && display {
                VStack(spacing: 0) {
                    if let superscript {
                        MathNodeView(node: superscript, size: size * 0.62, display: false)
                    }
                    MathNodeView(node: base, size: size * 1.25, display: display)
                        .alignmentGuide(.mathAxis) { $0[VerticalAlignment.center] }
                    if let subscriptNode {
                        MathNodeView(node: subscriptNode, size: size * 0.62, display: false)
                    }
                }
                .alignmentGuide(.mathAxis) { $0[VerticalAlignment.center] }
            } else {
                HStack(alignment: .mathAxis, spacing: size * 0.03) {
                    MathNodeView(node: base, size: size, display: display)
                    VStack(alignment: .leading, spacing: size * 0.05) {
                        if let superscript {
                            MathNodeView(node: superscript, size: size * 0.68, display: false)
                        }
                        if let subscriptNode {
                            MathNodeView(node: subscriptNode, size: size * 0.68, display: false)
                        }
                    }
                    // Padding rather than `offset`, so a raised superscript
                    // still takes up the room it occupies: with an offset the
                    // layout box stays put and the script collides with
                    // whatever is above — a fraction bar, usually.
                    .padding(.bottom, subscriptNode == nil ? size * 0.42 : 0)
                    .padding(.top, superscript == nil ? size * 0.42 : 0)
                    .alignmentGuide(.mathAxis) { $0[VerticalAlignment.center] }
                }
            }

        case let .styled(child, style):
            MathNodeView(node: child, size: size, display: display)
                .environment(\.mathTextStyle, style)

        case let .delimited(open, body, close):
            HStack(alignment: .mathAxis, spacing: 0) {
                MathDelimiterView(text: open, size: size)
                MathNodeView(node: body, size: size, display: display)
                MathDelimiterView(text: close, size: size)
            }

        case let .matrix(rows, open, close):
            // Rows of columns rather than a `Grid`: every cell here is
            // type-erased (see `body`), and `Grid` cannot see cells through
            // that — it laid a 2×2 matrix out as one crooked row.
            HStack(alignment: .mathAxis, spacing: size * 0.1) {
                MathDelimiterView(text: open, size: size, stretchRows: rows.count)
                VStack(alignment: .leading, spacing: size * 0.35) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .mathAxis, spacing: size * 0.9) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                MathNodeView(node: cell, size: size, display: false)
                                    .frame(minWidth: size * 0.6, alignment: .center)
                            }
                        }
                    }
                }
                .fixedSize()
                .alignmentGuide(.mathAxis) { $0[VerticalAlignment.center] }
                MathDelimiterView(text: close, size: size, stretchRows: rows.count)
            }

        case let .space(width):
            Color.clear.frame(width: size * width, height: 1)

        case let .decorated(base, mark, above):
            // Combining marks do the work where the font has them; where it
            // does not, the mark is drawn over or under the atom instead.
            VStack(spacing: 0) {
                if above {
                    Text(mark).font(.system(size: size * 0.9))
                    MathNodeView(node: base, size: size, display: false)
                } else {
                    MathNodeView(node: base, size: size, display: false)
                    Text(mark).font(.system(size: size * 0.9))
                }
            }
            .fixedSize()
            .alignmentGuide(.mathAxis) { dimensions in
                above ? dimensions[VerticalAlignment.bottom] - size * 0.3
                      : dimensions[VerticalAlignment.top] + size * 0.3
            }

        case let .binomial(top, bottom):
            HStack(alignment: .mathAxis, spacing: 0) {
                MathDelimiterView(text: "(", size: size, stretchRows: 2)
                VStack(spacing: size * 0.1) {
                    MathNodeView(node: top, size: size * 0.9, display: false)
                    MathNodeView(node: bottom, size: size * 0.9, display: false)
                }
                .fixedSize()
                .alignmentGuide(.mathAxis) { $0[VerticalAlignment.center] }
                MathDelimiterView(text: ")", size: size, stretchRows: 2)
            }

        case let .unknown(name):
            // The name, set the way a function name is. Never the backslash:
            // a command this renderer has not heard of is still not something
            // to show the reader as source.
            Text(name)
                .font(.system(size: size, design: .serif))
                .alignmentGuide(.mathAxis) { $0[.firstTextBaseline] - axisOffset }
        }
    }
}

/// A run of literal characters. Variables are set in italic serif and
/// everything else upright, which is the convention maths is read in.
private struct MathRunView: View {
    @Environment(\.mathTextStyle) private var style
    let text: String
    let size: CGFloat

    var body: some View {
        Text(text)
            .font(font)
            .italic(isItalic)
    }

    private var font: Font {
        switch style {
        case .prose: return .system(size: size)
        case .bold:  return .system(size: size, weight: .bold, design: .serif)
        default:     return .system(size: size, design: .serif)
        }
    }

    private var isItalic: Bool {
        switch style {
        case .upright, .prose, .bold: return false
        case .italic:                 return true
        case .none:
            // A single letter is a variable; `sin` or a number is not.
            return text.count == 1 && (text.first?.isLetter ?? false)
        }
    }
}

/// A bracket that grows with what it encloses.
private struct MathDelimiterView: View {
    let text: String
    let size: CGFloat
    var stretchRows = 1

    var body: some View {
        if text.isEmpty {
            EmptyView()
        } else {
            Text(text)
                .font(.system(size: size * scale, design: .serif))
                .alignmentGuide(.mathAxis) { $0[VerticalAlignment.center] }
        }
    }

    private var scale: CGFloat { stretchRows > 1 ? CGFloat(stretchRows) * 0.9 : 1.4 }
}

private struct RadicalShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.width * 0.35, y: rect.height * 0.7))
        path.addLine(to: CGPoint(x: rect.width * 0.62, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        return path
    }
}

private struct MathTextStyleKey: EnvironmentKey {
    static let defaultValue: MathTextStyle? = nil
}

extension EnvironmentValues {
    var mathTextStyle: MathTextStyle? {
        get { self[MathTextStyleKey.self] }
        set { self[MathTextStyleKey.self] = newValue }
    }
}

// MARK: - Entry points

/// A display formula: centred, on the page's own background, with the LaTeX
/// and a copy button appearing only under the pointer.
///
/// The tinted panel it used to sit in made every formula look like a callout;
/// a formula is body content, and the reference renderer sets it as such.
struct MathBlockView: View {
    let latex: String
    @State private var showsSource = false
    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                MathNodeView(node: MathParser.parse(latex), size: 18, display: true)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity)
            }
            if showsSource {
                Text(latex)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            if isHovering {
                HStack(spacing: 4) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(latex, forType: .string)
                        didCopy = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { didCopy = false }
                    } label: {
                        Label(didCopy ? "已复制" : "复制", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                    }
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showsSource.toggle() }
                    } label: {
                        Label("LaTeX", systemImage: showsSource ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}

/// A paragraph that may have `$…$` in it, laid out as text with the maths set
/// inline.
///
/// Inline formulas are rendered as `Text` so the paragraph still wraps like a
/// paragraph. That rules out fractions and roots, which need real layout — for
/// those the source is shown instead, which is what the whole pane used to do.
struct MathInlineText: View {
    @Environment(\.colorScheme) private var colorScheme
    let source: String
    var size: CGFloat = 13

    var body: some View {
        segments.reduce(Text("")) { $0 + $1 }
    }

    private var segments: [Text] {
        MathInlineSplitter.split(source).map { segment in
            switch segment {
            case let .prose(text):
                return Text(MDParser.inline(text))
            case let .math(latex):
                let node = MathParser.parse(latex)
                // Simple maths is set as text, so the line still wraps and the
                // glyphs still match the prose around them. Anything
                // two-dimensional — a fraction, a root — is drawn and embedded
                // as an image, because the one thing that must never happen is
                // the LaTeX itself showing up in the middle of a sentence.
                if let text = MathTextBuilder.text(for: node, size: size) { return text }
                if let image = MathInlineImage.image(for: node, size: size, scheme: colorScheme) {
                    return Text(Image(nsImage: image))
                        .baselineOffset(-MathInlineImage.descent(of: image, size: size))
                }
                // Never the source. If it could not be set and could not be
                // drawn, it is at least read out in characters.
                return Text(MathLinearizer.text(for: latex)).font(.system(size: size))
            }
        }
    }

    /// True when the paragraph has maths worth setting.
    static func hasInlineMath(_ source: String) -> Bool {
        MathInlineSplitter.hasInlineMath(source)
    }
}

/// Draws a piece of maths that cannot be a run of text, so it can be embedded
/// in one anyway.
///
/// A fraction has no textual form; `Text` cannot lay one out, and the fallback
/// of printing its source is exactly the failure this exists to prevent. It is
/// drawn once and cached — a page has a handful of distinct inline formulas,
/// and they are re-rendered on every layout pass otherwise.
@MainActor
enum MathInlineImage {
    private static var cache: [String: NSImage] = [:]

    static func image(for node: MathNode, size: CGFloat, scheme: ColorScheme) -> NSImage? {
        let key = "\(size)#\(scheme)#\(node)"
        if let cached = cache[key] { return cached }
        // `ImageRenderer` starts from a blank environment, so the appearance
        // has to be handed to it: rendered in the light one, a formula on a
        // dark page comes out black on black.
        let renderer = ImageRenderer(content:
            MathNodeView(node: node, size: size, display: false)
                .padding(.horizontal, 1)
                .fixedSize()
                .environment(\.colorScheme, scheme)
                .foregroundStyle(scheme == .dark ? Color.white : Color.black))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        cache[key] = image
        return image
    }

    /// How far the image has to drop for its axis to sit on the text baseline.
    static func descent(of image: NSImage, size: CGFloat) -> CGFloat {
        max(0, image.size.height / 2 - size * 0.3)
    }
}

/// Builds `Text` for the part of the language that can live inside a line of
/// prose: symbols, scripts and styling. Returns nil for anything needing
/// two-dimensional layout.
enum MathTextBuilder {

    static func text(for node: MathNode, size: CGFloat) -> Text? {
        switch node {
        case let .run(body):
            let italic = body.count == 1 && (body.first?.isLetter ?? false)
            var text = Text(body).font(.system(size: size, design: .serif))
            if italic { text = text.italic() }
            return text

        case let .sequence(nodes):
            var result = Text("")
            for child in nodes {
                guard let piece = text(for: child, size: size) else { return nil }
                result = result + piece
            }
            return result

        case let .styled(child, style):
            guard let piece = text(for: child, size: size) else { return nil }
            switch style {
            case .bold:            return piece.bold()
            case .italic:          return piece.italic()
            case .upright, .prose: return piece
            }

        case let .scripted(base, superscript, subscriptNode, _):
            guard let baseText = text(for: base, size: size) else { return nil }
            var result = baseText
            if let subscriptNode, let piece = text(for: subscriptNode, size: size * 0.72) {
                result = result + piece.baselineOffset(-size * 0.22)
            }
            if let superscript, let piece = text(for: superscript, size: size * 0.72) {
                result = result + piece.baselineOffset(size * 0.36)
            }
            return result

        case let .delimited(open, body, close):
            guard let inner = text(for: body, size: size) else { return nil }
            return Text(open).font(.system(size: size, design: .serif))
                + inner
                + Text(close).font(.system(size: size, design: .serif))

        case let .space(width):
            return Text(String(repeating: " ", count: max(0, Int(width * 2))))

        case let .unknown(name):
            return Text(name).font(.system(size: size, design: .serif))

        case let .decorated(base, mark, _):
            // A combining mark rides along with the character it marks, so this
            // one *can* be a run of text.
            guard let piece = text(for: base, size: size) else { return nil }
            return piece + Text(mark)

        case .fraction, .radical, .matrix, .binomial:
            // Two-dimensional; it cannot be a run of text in a paragraph.
            return nil
        }
    }
}
