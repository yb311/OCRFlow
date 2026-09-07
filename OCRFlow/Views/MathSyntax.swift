import Foundation

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
    /// `\vec`, `\hat`, `\overline` and friends: a mark set above or below.
    case decorated(MathNode, mark: String, above: Bool)
    /// `\binom{n}{k}` — a fraction without its rule.
    case binomial(top: MathNode, bottom: MathNode)
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

    /// Whether a backslash command in a sentence begins maths.
    ///
    /// It always does. Keeping a list of commands worth rendering was the wrong
    /// shape for this problem: every command missing from the list came out as
    /// its own source text in the middle of a paragraph, and the list could
    /// only ever grow one complaint at a time. A backslash followed by letters
    /// is LaTeX — the renderer sets what it knows and reads the rest out by
    /// name, and either way no backslash reaches the reader.
    static func knows(_ command: String) -> Bool {
        !command.isEmpty && command.allSatisfy(\.isLetter)
    }

    /// True when the string looks like it is meant to be maths at all. Used to
    /// decide whether a `$…$` run in a paragraph is a formula or a price.
    static func looksLikeMath(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("\\") || trimmed.contains("^") || trimmed.contains("_") { return true }
        if trimmed.contains(where: { "+-=<>*/".contains($0) }) { return true }
        // `$f$` is a variable someone set in maths; `$2 per square foot, the
        // wood $` is a pair of prices with a sentence between them, and the
        // spaces are what tell them apart.
        return !trimmed.contains(where: \.isWhitespace) && trimmed.count <= 24
    }

    // MARK: Scanner

    struct Scanner {
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

            case "binom", "dbinom", "tbinom":
                let top = parseAtom(stopAt: stoppers) ?? .run("")
                let bottom = parseAtom(stopAt: stoppers) ?? .run("")
                return .binomial(top: top, bottom: bottom)

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

            case "limits", "nolimits", "displaystyle", "textstyle", "scriptstyle",
                 "nonumber", "notag", "smallskip", "medskip", "bigskip", "noindent":
                return .space(0)

            // Anything that only labels or numbers an equation takes its
            // argument with it and contributes nothing to what is read.
            case "tag", "label", "ref", "eqref", "cite", "color", "textcolor":
                _ = parseBracedRaw()
                return .space(0)

            case "phantom", "hphantom", "vphantom":
                _ = parseBracedRaw()
                return .space(0.5)

            case "hspace", "vspace", "kern", "mskip", "mkern":
                _ = parseBracedRaw()
                return .space(0.5)

            case let name where Self.accents[name] != nil:
                let mark = Self.accents[name]!
                return .decorated(parseAtom(stopAt: stoppers) ?? .run(""),
                                  mark: mark.glyph, above: mark.above)

            case let name where Self.blackboard.contains(name):
                // `\mathbb{R}` and its relatives have real characters; using
                // them beats inventing a font style that macOS may not have.
                let inner = parseBracedRaw()
                return .run(Self.stylised(inner, style: name))

            case "big", "Big", "bigg", "Bigg", "bigl", "Bigl", "biggl", "Biggl",
                 "bigr", "Bigr", "biggr", "Biggr", "left.", "middle":
                // A sizing hint in front of a delimiter; the delimiter itself
                // is the next atom and speaks for itself.
                return .space(0)

            case "quad":  return .space(1)
            case "qquad": return .space(2)

            default:
                if let symbol = Self.symbols[name] { return .run(symbol) }
                if Self.functionNames.contains(name) { return .styled(.run(name), .upright) }
                // A command nothing here knows is still not printed as source:
                // its name is what it means often enough — `\foo` reads as
                // "foo" — and a stray backslash on screen reads as a bug.
                return .unknown(name)
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

        /// Marks set over or under an atom.
        static let accents: [String: (glyph: String, above: Bool)] = [
            "hat": ("\u{0302}", true), "widehat": ("\u{0302}", true),
            "bar": ("\u{0304}", true), "overline": ("\u{0304}", true),
            "vec": ("\u{20D7}", true), "overrightarrow": ("\u{20D7}", true),
            "tilde": ("\u{0303}", true), "widetilde": ("\u{0303}", true),
            "dot": ("\u{0307}", true), "ddot": ("\u{0308}", true),
            "check": ("\u{030C}", true), "breve": ("\u{0306}", true),
            "acute": ("\u{0301}", true), "grave": ("\u{0300}", true),
            "mathring": ("\u{030A}", true),
            "underline": ("\u{0332}", false), "underbrace": ("\u{23DF}", false),
            "overbrace": ("\u{23DE}", true),
        ]

        /// Alphabet styles that exist as real Unicode characters.
        static let blackboard: Set<String> = ["mathbb", "mathcal", "mathfrak", "mathscr"]

        /// Maps A–Z into the requested Unicode alphabet, leaving anything
        /// without a character in it alone.
        static func stylised(_ text: String, style: String) -> String {
            let bases: [String: (upper: UInt32, lower: UInt32?)] = [
                "mathbb":   (0x1D538, 0x1D552),
                "mathcal":  (0x1D49C, 0x1D4B6),
                "mathscr":  (0x1D49C, 0x1D4B6),
                "mathfrak": (0x1D504, 0x1D51E),
            ]
            guard let base = bases[style] else { return text }
            return String(text.map { character -> Character in
                guard let ascii = character.asciiValue else { return character }
                if ascii >= 65, ascii <= 90,
                   let scalar = Unicode.Scalar(base.upper + UInt32(ascii - 65)) {
                    return Character(scalar)
                }
                if let lower = base.lower, ascii >= 97, ascii <= 122,
                   let scalar = Unicode.Scalar(lower + UInt32(ascii - 97)) {
                    return Character(scalar)
                }
                return character
            })
        }

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
            // More of the same, so that "the renderer did not know this one"
            // stops being a thing that happens on real documents.
            "lbrace": "{", "rbrace": "}", "lbrack": "[", "rbrack": "]",
            "vert": "|", "Vert": "‖", "lVert": "‖", "rVert": "‖",
            "lvert": "|", "rvert": "|", "colon": ":", "semicolon": ";",
            "neg": "¬", "lnot": "¬", "land": "∧", "lor": "∨",
            "oslash": "⊘", "odot": "⊙", "bigoplus": "⊕", "bigotimes": "⊗",
            "sqcup": "⊔", "sqcap": "⊓", "uplus": "⊎", "amalg": "⨿",
            "subsetneq": "⊊", "supsetneq": "⊋", "nsubseteq": "⊈", "nsupseteq": "⊉",
            "preceq": "≼", "succeq": "≽", "prec": "≺", "succ": "≻",
            "lesssim": "≲", "gtrsim": "≳", "asymp": "≍", "doteq": "≐",
            "models": "⊨", "vdash": "⊢", "dashv": "⊣", "top": "⊤", "bot": "⊥",
            "longrightarrow": "⟶", "longleftarrow": "⟵",
            "longleftrightarrow": "⟷", "Longrightarrow": "⟹",
            "Longleftarrow": "⟸", "Longleftrightarrow": "⟺",
            "nearrow": "↗", "searrow": "↘", "swarrow": "↙", "nwarrow": "↖",
            "rightharpoonup": "⇀", "leftharpoonup": "↼", "hookrightarrow": "↪",
            "iff": "⟺", "impliedby": "⟸", "mapsfrom": "↤",
            "limsup": "lim sup", "liminf": "lim inf",
            "pmod": "mod", "bmod": "mod", "mod": "mod",
            "cdotp": "·", "ldotp": ".", "colonequals": "≔",
            "surd": "√", "wp": "℘", "Finv": "Ⅎ", "Game": "⅁", "complement": "∁",
            "circledast": "⊛", "boxtimes": "⊠", "boxplus": "⊞",
            "triangleq": "≜", "equivalent": "≡", "ncong": "≇",
            "nless": "≮", "ngtr": "≯", "nleq": "≰", "ngeq": "≱",
            "nmid": "∤", "nparallel": "∦", "nsim": "≁", "napprox": "≉",
            "sqsubseteq": "⊑", "sqsupseteq": "⊒",
            "smile": "⌣", "frown": "⌢", "sharp": "♯", "flat": "♭", "natural": "♮",
            "clubsuit": "♣", "diamondsuit": "♢", "heartsuit": "♡", "spadesuit": "♠",
            "S": "§", "P": "¶", "copyright": "©", "pounds": "£", "yen": "¥",
            "euro": "€", "textdegree": "°", "celsius": "℃", "permil": "‰",
            "AA": "Å", "ae": "æ", "oe": "œ", "ss": "ß", "o": "ø", "O": "Ø",
            "lll": "⋘", "ggg": "⋙",
            "ddagger": "‡",
            "circledcirc": "⊚", "divideontimes": "⋇", "leftthreetimes": "⋋",
            "imath": "ı", "jmath": "ȷ",
            "Alpha": "Α", "Beta": "Β", "Epsilon": "Ε", "Zeta": "Ζ", "Eta": "Η",
            "Iota": "Ι", "Kappa": "Κ", "Mu": "Μ", "Nu": "Ν", "Omicron": "Ο",
            "Rho": "Ρ", "Tau": "Τ", "Chi": "Χ", "omicron": "ο",
            "digamma": "ϝ", "varkappa": "ϰ", "backepsilon": "϶",
            "dprime": "″", "trprime": "‴",
            "blacksquare": "■", "triangleleft": "◁",
            "triangleright": "▷", "bigtriangleup": "△", "bigtriangledown": "▽",
            "diamond": "⋄",
        ]
    }
}

/// Reads a formula out as plain characters.
///
/// This is the floor under every other renderer: the plain-text pane, the
/// plain-text export, and the last resort if drawing ever fails. Whatever
/// happens, what reaches the reader is `(n-1)/2` and never `\frac{n-1}{2}` —
/// the source is available in the Markdown and in the 源码 pane, which is
/// where someone who wants LaTeX goes to find it.
enum MathLinearizer {

    static func text(for latex: String) -> String {
        string(for: MathParser.parse(latex))
    }

    static func string(for node: MathNode) -> String {
        switch node {
        case let .run(text):
            return text
        case let .sequence(nodes):
            return nodes.map(string(for:)).joined()
        case let .fraction(numerator, denominator):
            return "\(parenthesised(numerator))/\(parenthesised(denominator))"
        case let .radical(index, radicand):
            let degree = index.map { "[\(string(for: $0))]" } ?? ""
            return "√\(degree)\(parenthesised(radicand))"
        case let .scripted(base, superscript, subscriptNode, _):
            var out = string(for: base)
            if let subscriptNode { out += subscripted(string(for: subscriptNode)) }
            if let superscript { out += superscripted(string(for: superscript)) }
            return out
        case let .styled(child, _):
            return string(for: child)
        case let .delimited(open, body, close):
            return open + string(for: body) + close
        case let .matrix(rows, open, close):
            let body = rows.map { $0.map(string(for:)).joined(separator: ", ") }
                .joined(separator: "; ")
            return "\(open.isEmpty ? "[" : open)\(body)\(close.isEmpty ? "]" : close)"
        case let .decorated(base, mark, _):
            return string(for: base) + mark
        case let .binomial(top, bottom):
            return "C(\(string(for: top)), \(string(for: bottom)))"
        case .space:
            return " "
        case let .unknown(name):
            return name
        }
    }

    /// Brackets a compound so `a+b` over `c` does not read as `a+b/c`.
    private static func parenthesised(_ node: MathNode) -> String {
        let body = string(for: node)
        let atomic = body.count <= 1
            || body.allSatisfy { $0.isNumber || $0.isLetter }
        return atomic ? body : "(\(body))"
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵",
        "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻",
        "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ",
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅",
        "6": "₆", "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋",
        "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "i": "ᵢ", "j": "ⱼ",
        "n": "ₙ", "x": "ₓ", "k": "ₖ", "m": "ₘ", "t": "ₜ",
    ]

    private static func superscripted(_ text: String) -> String {
        let mapped = text.map { superscripts[$0] }
        guard !mapped.contains(where: { $0 == nil }) else { return "^\(text)" }
        return String(mapped.compactMap { $0 })
    }

    private static func subscripted(_ text: String) -> String {
        let mapped = text.map { subscripts[$0] }
        guard !mapped.contains(where: { $0 == nil }) else { return "_\(text)" }
        return String(mapped.compactMap { $0 })
    }
}


/// Cuts a paragraph into the prose and the maths in it.
///
/// Separate from the view that draws the result, so the guarantee it carries —
/// that no markup ever reaches a reader — can be checked by a script rather
/// than by looking at screenshots. See `Scripts/check-markup-leaks.swift`.
enum MathInlineSplitter {

    enum Segment: Equatable {
        case prose(String)
        case math(String)
    }

    /// Splits a paragraph into prose and maths.
    ///
    /// `$…$` and `\(…\)` are the easy case. The hard one is that the model
    /// sometimes writes the LaTeX with no delimiters at all — a sentence comes
    /// back reading "after one complete round, \left\lfloor\frac{n-1}{2}
    /// \right\rfloor players remain" — and printing that verbatim is the
    /// worst of both worlds. A run that starts at a LaTeX command is therefore
    /// treated as maths whether or not anything marked it as such.
    static func split(_ source: String) -> [Segment] {
        var segments: [Segment] = []
        for piece in splitOnDelimiters(source) {
            switch piece {
            case .math:
                segments.append(piece)
            case let .prose(text):
                segments.append(contentsOf: splitOnBareCommands(text))
            }
        }
        return segments.isEmpty ? [.prose(source)] : segments
    }

    /// The delimited case: `$…$` and `\(…\)`.
    private static func splitOnDelimiters(_ source: String) -> [Segment] {
        // The paired LaTeX forms are rewritten to dollars first, so one scanner
        // handles all three rather than three nearly-identical ones.
        let source = source
            .replacingOccurrences(of: #"\["#, with: "$")
            .replacingOccurrences(of: #"\]"#, with: "$")
            .replacingOccurrences(of: #"\("#, with: "$")
            .replacingOccurrences(of: #"\)"#, with: "$")
            // `$\[x\]$` — the model doubles them up often enough — would
            // otherwise read as an empty formula followed by loose source.
            .replacingOccurrences(of: "[$]{2,}", with: "$", options: .regularExpression)
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

    /// The undelimited case: a run beginning at a command this renderer knows.
    private static func splitOnBareCommands(_ source: String) -> [Segment] {
        guard source.contains("\\") else { return source.isEmpty ? [] : [.prose(source)] }
        let characters = Array(source)
        var segments: [Segment] = []
        var prose = ""
        var index = 0

        while index < characters.count {
            guard characters[index] == "\\",
                  let end = mathRunEnd(in: characters, from: index) else {
                prose.append(characters[index])
                index += 1
                continue
            }
            if !prose.isEmpty { segments.append(.prose(prose)); prose = "" }
            segments.append(.math(String(characters[index..<end])))
            index = end
        }
        if !prose.isEmpty { segments.append(.prose(prose)) }
        return segments
    }

    /// Where the maths starting at `start` ends, or nil when what starts there
    /// is not maths at all.
    private static func mathRunEnd(in characters: [Character], from start: Int) -> Int? {
        guard let firstCommand = command(in: characters, at: start),
              MathParser.knows(firstCommand.name) else { return nil }

        var index = firstCommand.end
        var lastMath = index

        loop: while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                guard let next = command(in: characters, at: index) else { break loop }
                index = next.end
                // `\left(` and `\right]` carry their delimiter with them, and
                // the delimiter is often a command of its own — `\right\rfloor`.
                if ["left", "right"].contains(next.name), index < characters.count {
                    if let delimiter = command(in: characters, at: index) {
                        index = delimiter.end
                    } else {
                        index += 1
                    }
                }
                lastMath = index
            case "{":
                guard let close = balancedBrace(in: characters, from: index) else { break loop }
                index = close
                lastMath = index
            case "^", "_":
                index += 1
                if index < characters.count, characters[index] == "{",
                   let close = balancedBrace(in: characters, from: index) {
                    index = close
                } else if index < characters.count {
                    index += 1
                }
                lastMath = index
            case " ":
                // A space only continues the run if maths follows it.
                index += 1
            case let c where c.isNumber || "+-*/=<>()[]|,.':;!".contains(c):
                index += 1
                lastMath = index
            case let c where c.isLetter:
                // A single letter is a variable; a word is prose and ends it.
                let wordEnd = characters[index...].prefix(while: { $0.isLetter }).count + index
                guard wordEnd - index == 1 else { break loop }
                index = wordEnd
                lastMath = index
            default:
                break loop
            }
        }

        // Trailing sentence punctuation belongs to the sentence.
        while lastMath > firstCommand.end,
              let last = characters[safe: lastMath - 1],
              ",.;:! ".contains(last) {
            lastMath -= 1
        }
        return lastMath > start ? lastMath : nil
    }

    private static func command(in characters: [Character], at index: Int) -> (name: String, end: Int)? {
        guard index < characters.count, characters[index] == "\\" else { return nil }
        var cursor = index + 1
        var name = ""
        while cursor < characters.count, characters[cursor].isLetter {
            name.append(characters[cursor])
            cursor += 1
        }
        guard !name.isEmpty else { return nil }
        return (name, cursor)
    }

    private static func balancedBrace(in characters: [Character], from index: Int) -> Int? {
        var depth = 0
        var cursor = index
        while cursor < characters.count {
            if characters[cursor] == "{" { depth += 1 }
            if characters[cursor] == "}" {
                depth -= 1
                if depth == 0 { return cursor + 1 }
            }
            cursor += 1
        }
        return nil
    }

    /// True when the paragraph has maths worth setting.
    static func hasInlineMath(_ source: String) -> Bool {
        split(source).contains { if case .math = $0 { return true } else { return false } }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

