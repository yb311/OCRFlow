import SwiftUI

// MARK: - Model

/// A parsed piece of LaTeX maths.
///
/// PaddleOCR-VL answers a formula region with LaTeX, which used to be shown as
/// the LaTeX itself: correct, and unreadable. This is enough of the language to
/// set the formulas an OCR of a textbook or an exam paper actually produces —
/// fractions, roots, scripts, big operators, matrices and the usual symbols.
///
/// Anything outside that subset is kept as `unknown` and drawn as the source
/// text, marked, rather than dropped or silently mangled: a formula that is
/// half-rendered and half-visible is still readable, one that has quietly lost
/// a term is not.
indirect enum MathNode: Equatable {
    /// Literal characters, already mapped out of LaTeX into Unicode.
    case run(String)
    case sequence([MathNode])
    case fraction(numerator: MathNode, denominator: MathNode)
    case radical(index: MathNode?, radicand: MathNode)
    /// `limits` puts the scripts above and below instead of beside, which is
    /// what a display-style `\sum_{i=1}^{n}` wants.
    case scripted(base: MathNode, superscript: MathNode?, subscript: MathNode?, limits: Bool)
    case styled(MathNode, MathTextStyle)
    case delimited(open: String, body: MathNode, close: String)
    case matrix(rows: [[MathNode]], open: String, close: String)
    /// Horizontal space, in ems.
    case space(Double)
    case unknown(String)

    var isEmpty: Bool {
        switch self {
        case let .run(text):      return text.isEmpty
        case let .sequence(list): return list.allSatisfy(\.isEmpty)
        default:                  return false
        }
    }
}

enum MathTextStyle: Equatable {
    /// `\mathrm`, `\operatorname` — upright, still maths.
    case upright
    case bold
    case italic
    /// `\text` — prose inside a formula.
    case prose
}

// MARK: - Parsing

enum MathParser {

    /// Parses one formula. Delimiters (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`) are
    /// stripped if present.
    static func parse(_ latex: String) -> MathNode {
        var scanner = Scanner(source: Array(stripDelimiters(latex)))
        let node = scanner.parseSequence(stopAt: [])
        return node
    }

    /// The body of a formula, without whatever wrapped it.
    static func stripDelimiters(_ latex: String) -> String {
        var text = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")]
        where text.hasPrefix(open) && text.hasSuffix(close) && text.count > open.count + close.count {
            text = String(text.dropFirst(open.count).dropLast(close.count))
            break
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the string looks like it is meant to be maths at all. Used to
    /// decide whether a `$…$` run in a paragraph is a formula or a price.
    static func looksLikeMath(_ body: String) -> Bool {
        guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if body.contains("\\") || body.contains("^") || body.contains("_") { return true }
        // A bare `$12.50$` is not a formula; a bare `x + 1` is.
        return body.contains { "+-=<>*/".contains($0) }
    }

    // MARK: Scanner

    private struct Scanner {
        let source: [Character]
        var index = 0

        var isAtEnd: Bool { index >= source.count }

        /// `stopAtBracket` is for a root's degree — `\sqrt[3]{8}` — where the
        /// closing bracket ends the argument. Everywhere else `]` is an
        /// ordinary character, as in an interval.
        mutating func parseSequence(stopAt stoppers: Set<String>,
                                    stopAtBracket: Bool = false,
                                    stopAtRowBreak: Bool = false) -> MathNode {
            var nodes: [MathNode] = []
            while !isAtEnd {
                // Before the stop checks, not after: `a & b \\ c` has a space
                // in front of the row break, and looking at that space instead
                // of the break is how a matrix ends up as a single row.
                skipSpaces()
                if let next = peekCommand(), stoppers.contains(next) { break }
                if let character = peek() {
                    if character == "}" || character == "&" { break }
                    if stopAtBracket, character == "]" { break }
                    // `\\` ends a row of a matrix; left to the atom parser it
                    // would be swallowed as a line break inside the cell, and
                    // the whole matrix would come out as one crooked row.
                    if stopAtRowBreak, character == "\\", peekNext() == "\\" { break }
                }
                guard let atom = parseScripted(stopAt: stoppers) else { break }
                nodes.append(atom)
            }
            return nodes.count == 1 ? nodes[0] : .sequence(merged(nodes))
        }

        /// Runs of literal characters are merged so a formula is not built out
        /// of one view per character.
        private func merged(_ nodes: [MathNode]) -> [MathNode] {
            var out: [MathNode] = []
            for node in nodes {
                if case let .run(text) = node, case let .run(previous)? = out.last {
                    out[out.count - 1] = .run(previous + text)
                } else {
                    out.append(node)
                }
            }
            return out
        }

        /// An atom plus whatever `^`/`_` follows it.
        private mutating func parseScripted(stopAt stoppers: Set<String>) -> MathNode? {
            guard var base = parseAtom(stopAt: stoppers) else { return nil }
            var superscript: MathNode?
            var subscriptNode: MathNode?
            var limits = false

            if case let .run(text) = base, Self.bigOperators.contains(text) { limits = true }

            while let character = peek(), character == "^" || character == "_" {
                index += 1
                skipSpaces()
                let script = parseAtom(stopAt: stoppers) ?? .run("")
                if character == "^" { superscript = script } else { subscriptNode = script }
            }
            guard superscript != nil || subscriptNode != nil else { return base }
            // `\limits` / `\nolimits` were consumed as commands by parseAtom.
            if case let .styled(inner, .upright) = base, case .run = inner { base = .styled(inner, .upright) }
            return .scripted(base: base, superscript: superscript,
                             subscript: subscriptNode, limits: limits)
        }

        private mutating func parseAtom(stopAt stoppers: Set<String>) -> MathNode? {
            skipSpaces()
            guard let character = peek() else { return nil }

            switch character {
            case "{":
                index += 1
                let body = parseSequence(stopAt: stoppers)
                expect("}")
                return body
            case "}", "&":
                return nil
            case "\\":
                return parseCommand(stopAt: stoppers)
            default:
                index += 1
                return .run(String(character))
            }
        }

        private mutating func parseCommand(stopAt stoppers: Set<String>) -> MathNode? {
            index += 1                                  // the backslash
            guard let first = peek() else { return .run("\\") }

            // `\\` is a row break; `\,` and friends are spacing.
            if !first.isLetter {
                index += 1
                if let width = Self.spacing[String(first)] { return .space(width) }
                if first == "\\" { return .run("\n") }
                return .run(String(first))
            }

            var name = ""
            while let character = peek(), character.isLetter {
                name.append(character)
                index += 1
            }

            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                let numerator = parseAtom(stopAt: stoppers) ?? .run("")
                let denominator = parseAtom(stopAt: stoppers) ?? .run("")
                return .fraction(numerator: numerator, denominator: denominator)

            case "sqrt":
                var degree: MathNode?
                skipSpaces()
                if peek() == "[" {
                    index += 1
                    degree = parseSequence(stopAt: [], stopAtBracket: true)
                    expect("]")
                }
                let radicand = parseAtom(stopAt: stoppers) ?? .run("")
                return .radical(index: degree, radicand: radicand)

            case "text", "textrm", "textnormal", "mbox":
                // Prose, taken verbatim: the spaces in `\text{if }` are part of
                // the sentence, and parsing it as maths would eat them.
                return .styled(.run(parseBracedRaw()), .prose)
            case "mathrm", "operatorname", "mathsf", "mathtt":
                return .styled(parseAtom(stopAt: stoppers) ?? .run(""), .upright)
            case "mathbf", "textbf", "bm", "boldsymbol":
                return .styled(parseAtom(stopAt: stoppers) ?? .run(""), .bold)
            case "mathit", "textit":
                return .styled(parseAtom(stopAt: stoppers) ?? .run(""), .italic)

            case "left":
                let open = parseDelimiter()
                let body = parseSequence(stopAt: ["right"])
                var close = ""
                if peekCommand() == "right" {
                    skipCommand()
                    close = parseDelimiter()
                }
                return .delimited(open: open, body: body, close: close)

            case "right":
                // Unbalanced; treated as a literal so nothing disappears.
                return .run(parseDelimiter())

            case "begin":
                return parseEnvironment()
            case "end":
                _ = parseBracedName()
                return nil

            case "limits", "nolimits", "displaystyle", "textstyle", "scriptstyle", "!":
                return .space(0)

            case "quad":  return .space(1)
            case "qquad": return .space(2)

            default:
                if let symbol = Self.symbols[name] { return .run(symbol) }
                if Self.functionNames.contains(name) { return .styled(.run(name), .upright) }
                return .unknown("\\" + name)
            }
        }

        /// `\begin{pmatrix} a & b \\ c & d \end{pmatrix}` and its relatives.
        private mutating func parseEnvironment() -> MathNode {
            let name = parseBracedName()
            // `array` carries a column spec — `{cc}` — which only affects
            // alignment, and every column is centred here anyway.
            if name == "array" { _ = parseBracedGroupRaw() }

            var rows: [[MathNode]] = [[]]
            while !isAtEnd {
                if peekCommand() == "end" {
                    skipCommand()
                    _ = parseBracedName()
                    break
                }
                let cell = parseSequence(stopAt: ["end"], stopAtRowBreak: true)
                rows[rows.count - 1].append(cell)
                skipSpaces()
                if peek() == "&" {
                    index += 1
                    continue
                }
                if peek() == "\\" && peekNext() == "\\" {
                    index += 2
                    rows.append([])
                    continue
                }
                if peek() == "}" { index += 1; continue }
                if peekCommand() == nil, peek() != nil, peek() != "&" { index += 1 }
            }
            // A trailing `\\` leaves an empty row behind.
            if let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }

            let fence = Self.matrixFences[name] ?? ("", "")
            return .matrix(rows: rows, open: fence.0, close: fence.1)
        }

        private mutating func parseDelimiter() -> String {
            skipSpaces()
            guard let character = peek() else { return "" }
            if character == "\\" {
                index += 1
                var name = ""
                while let next = peek(), next.isLetter { name.append(next); index += 1 }
                if name.isEmpty, let next = peek() { index += 1; return String(next) }
                if name == "left" || name == "right" { return "" }
                return Self.symbols[name] ?? ""
            }
            index += 1
            return character == "." ? "" : String(character)
        }

        private mutating func parseBracedName() -> String {
            skipSpaces()
            guard peek() == "{" else { return "" }
            index += 1
            var name = ""
            while let character = peek(), character != "}" { name.append(character); index += 1 }
            expect("}")
            return name.trimmingCharacters(in: .whitespaces)
        }

        private mutating func parseBracedGroupRaw() -> String { parseBracedName() }

        /// The literal contents of `{…}`, nesting included, with nothing
        /// interpreted.
        private mutating func parseBracedRaw() -> String {
            skipSpaces()
            guard peek() == "{" else {
                guard let character = peek() else { return "" }
                index += 1
                return String(character)
            }
            index += 1
            var depth = 1
            var body = ""
            while let character = peek() {
                index += 1
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                body.append(character)
            }
            return body
        }

        // MARK: Primitives

        private func peek() -> Character? { isAtEnd ? nil : source[index] }
        private func peekNext() -> Character? {
            index + 1 < source.count ? source[index + 1] : nil
        }

        /// The name of the command at the cursor, without consuming it.
        private func peekCommand() -> String? {
            guard peek() == "\\" else { return nil }
            var cursor = index + 1
            var name = ""
            while cursor < source.count, source[cursor].isLetter {
                name.append(source[cursor])
                cursor += 1
            }
            return name.isEmpty ? nil : name
        }

        private mutating func skipCommand() {
            guard peek() == "\\" else { return }
            index += 1
            while let character = peek(), character.isLetter { index += 1 }
        }

        private mutating func skipSpaces() {
            while let character = peek(), character == " " || character == "\t" { index += 1 }
        }

        private mutating func expect(_ character: Character) {
            if peek() == character { index += 1 }
        }

        // MARK: Tables

        static let bigOperators: Set<String> = ["∑", "∏", "∐", "⋃", "⋂", "lim"]

        static let spacing: [String: Double] = [
            ",": 0.17, ";": 0.28, ":": 0.22, " ": 0.25, "!": -0.17,
        ]

        static let matrixFences: [String: (String, String)] = [
            "matrix": ("", ""),
            "pmatrix": ("(", ")"),
            "bmatrix": ("[", "]"),
            "Bmatrix": ("{", "}"),
            "vmatrix": ("|", "|"),
            "Vmatrix": ("‖", "‖"),
            "cases": ("{", ""),
            "array": ("", ""),
            "aligned": ("", ""),
            "align": ("", ""),
        ]

        static let functionNames: Set<String> = [
            "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan",
            "sinh", "cosh", "tanh", "log", "ln", "lg", "exp", "det", "dim", "ker",
            "deg", "gcd", "hom", "arg", "max", "min", "sup", "inf", "mod",
        ]

        static let symbols: [String: String] = [
            // Greek, lower case
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ",
            "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
            "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
            "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ",
            "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ",
            "chi": "χ", "psi": "ψ", "omega": "ω",
            // Greek, upper case
            "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
            "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
            // Operators
            "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬",
            "iiint": "∭", "oint": "∮", "bigcup": "⋃", "bigcap": "⋂", "lim": "lim",
            "times": "×", "div": "÷", "pm": "±", "mp": "∓", "cdot": "·", "cdots": "⋯",
            "ldots": "…", "dots": "…", "vdots": "⋮", "ddots": "⋱", "ast": "∗", "star": "⋆",
            "circ": "∘", "bullet": "∙", "oplus": "⊕", "ominus": "⊖", "otimes": "⊗",
            "cup": "∪", "cap": "∩", "setminus": "∖", "wedge": "∧", "vee": "∨",
            // Relations
            "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
            "approx": "≈", "sim": "∼", "simeq": "≃", "cong": "≅", "equiv": "≡",
            "propto": "∝", "ll": "≪", "gg": "≫", "subset": "⊂", "supset": "⊃",
            "subseteq": "⊆", "supseteq": "⊇", "in": "∈", "notin": "∉", "ni": "∋",
            "perp": "⊥", "parallel": "∥", "mid": "∣",
            // Arrows
            "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
            "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔",
            "uparrow": "↑", "downarrow": "↓", "mapsto": "↦", "implies": "⟹",
            // Misc
            "infty": "∞", "partial": "∂", "nabla": "∇", "forall": "∀", "exists": "∃",
            "nexists": "∄", "emptyset": "∅", "varnothing": "∅", "angle": "∠",
            "triangle": "△", "square": "□", "degree": "°", "prime": "′",
            "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ",
            "therefore": "∴", "because": "∵", "checkmark": "✓", "dagger": "†",
            "%": "%", "&": "&", "#": "#", "{": "{", "}": "}", "|": "|",
            "langle": "⟨", "rangle": "⟩", "lceil": "⌈", "rceil": "⌉",
            "lfloor": "⌊", "rfloor": "⌋", "backslash": "\\",
        ]
    }
}

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

        case let .unknown(command):
            Text(command)
                .font(.system(size: size * 0.85, design: .monospaced))
                .foregroundStyle(.orange)
                .help("这个 LaTeX 命令暂不支持渲染，已按原文显示")
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
    let source: String
    var size: CGFloat = 13

    var body: some View {
        segments.reduce(Text("")) { $0 + $1 }
    }

    private var segments: [Text] {
        MathInlineText.split(source).map { segment in
            switch segment {
            case let .prose(text):
                return Text(MDParser.inline(text))
            case let .math(latex):
                return MathTextBuilder.text(for: MathParser.parse(latex), size: size)
                    ?? Text(latex).font(.system(size: size, design: .monospaced))
            }
        }
    }

    enum Segment: Equatable {
        case prose(String)
        case math(String)
    }

    /// Splits a paragraph on `$…$`, leaving anything that is not plausibly
    /// maths — a price, a lone dollar sign — as prose.
    static func split(_ source: String) -> [Segment] {
        guard source.contains("$") else { return [.prose(source)] }
        var segments: [Segment] = []
        var prose = ""
        var rest = Substring(source)

        while let open = rest.firstIndex(of: "$") {
            let after = rest.index(after: open)
            guard after < rest.endIndex, let close = rest[after...].firstIndex(of: "$") else { break }
            let body = String(rest[after..<close])
            if MathParser.looksLikeMath(body) {
                prose += rest[..<open]
                if !prose.isEmpty { segments.append(.prose(prose)); prose = "" }
                segments.append(.math(body))
            } else {
                prose += rest[...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        prose += rest
        if !prose.isEmpty { segments.append(.prose(prose)) }
        return segments.isEmpty ? [.prose(source)] : segments
    }

    /// True when the paragraph has maths worth setting.
    static func hasInlineMath(_ source: String) -> Bool {
        split(source).contains { if case .math = $0 { return true } else { return false } }
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

        case let .unknown(command):
            return Text(command)
                .font(.system(size: size * 0.9, design: .monospaced))
                .foregroundColor(.orange)

        case .fraction, .radical, .matrix:
            // Two-dimensional; it cannot be a run of text in a paragraph.
            return nil
        }
    }
}
