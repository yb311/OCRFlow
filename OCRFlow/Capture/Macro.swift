import CoreGraphics
import Foundation

/// Something the user showed OCRFlow how to do once, to be done again: a
/// row of plain actions — clicks, keys, scrolls, typing, captures — and how
/// often to repeat them.
///
/// Nothing in it is about one app or site. A click remembers the window it
/// landed in, so it lands in the same place when the window has moved, and
/// the control it landed on, so it can be found again when the layout has
/// changed.
struct Macro: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var steps: [MacroStep] = []
    var repetition = Repetition.untilUnchanged
    /// Pages to open one after another, the steps done on each. Empty: the
    /// steps are done once, wherever things are.
    var urls: [String] = []
    var output = Output.document

    enum Repetition: Codable, Hashable, Sendable {
        case once
        case times(Int)
        /// Until a round leaves the screen as it was: the last page.
        case untilUnchanged
    }

    /// What the captures of one run become.
    enum Output: String, Codable, CaseIterable, Identifiable, Sendable {
        /// One document, a page each, read together.
        case document
        /// Joined into one long picture — for captures of something scrolled.
        case longImage
        /// Each read on its own.
        case images

        var id: String { rawValue }
    }

    /// The addresses in `urls` that can be opened.
    var openableURLs: [URL] {
        urls.compactMap { text in
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if let url = URL(string: text), url.scheme != nil { return url }
            return URL(string: "https://" + text)
        }
    }
}

struct MacroStep: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var action: Action
    /// The window it happened in, when it happened in one.
    var window: WindowPlace?

    enum Action: Codable, Hashable, Sendable {
        case click(Click)
        case drag(Drag)
        case key(Key)
        case type(TypedText)
        case scroll(Scroll)
        case capture(CaptureArea)
        case wait(seconds: Double)
    }
}

/// Positions are in the coordinates events use: points from the main
/// display's top-left corner, y down. Inside a window, they are measured
/// from the window's top-left corner instead.
struct WindowPlace: Codable, Hashable, Sendable {
    var bundleID: String?
    var appName: String
    var title: String?
    /// Where the window was, and how large. Zero for a menu, the menu bar
    /// or a pop-up, which come and go: positions in one are on the screen.
    var frame: CGRect

    /// Only the app, for a menu or pop-up of it.
    var isFloating: Bool { frame == .zero }
}

extension MacroStep {
    struct Click: Codable, Hashable, Sendable {
        enum Button: String, Codable, Sendable { case left, right, other }

        var point: CGPoint
        var button = Button.left
        /// 2 for a double click.
        var count = 1
        /// Held keys, as `CGEventFlags`.
        var modifiers: UInt64 = 0
        /// The control clicked, when it could be told.
        var element: ElementDescription?
        /// Look for the control first, rather than go by the position.
        var findsElement = false
    }

    struct Drag: Codable, Hashable, Sendable {
        var path: [CGPoint]
        var button = Click.Button.left
        var modifiers: UInt64 = 0
    }

    struct Key: Codable, Hashable, Sendable {
        var keyCode: UInt16
        var modifiers: UInt64 = 0
        /// What the key typed, to show.
        var characters = ""
    }

    struct TypedText: Codable, Hashable, Sendable {
        var text: String
        /// The keys pressed, one a character, while the text is as typed: they
        /// reach apps that ignore typed characters without a key.
        var keyCodes: [UInt16] = []
    }

    struct Scroll: Codable, Hashable, Sendable {
        var point: CGPoint
        /// Points; positive is up and to the left, as the wheel reports.
        var dx: Double
        var dy: Double
    }
}

/// What a capture step takes.
struct CaptureArea: Codable, Hashable, Sendable {
    /// Part of a window, measured from its top-left; or, outside any window,
    /// part of the screen. Nil: the whole window.
    var rect: CGRect?
    /// Scrolled on this far, in points, and joined into one long picture —
    /// as far as the user scrolled while recording. Nil: as it is.
    var scrollDistance: Double?
}

/// A control, told apart the way the Accessibility interface describes it.
struct ElementDescription: Codable, Hashable, Sendable {
    var role: String
    var subrole: String?
    var title: String?
    var label: String?
    var identifier: String?
    /// Its centre, from the window's top-left — the tie-breaker when several
    /// controls answer to the description.
    var center: CGPoint

    /// What it says, for showing and for matching.
    var name: String? {
        [title, label, identifier].compactMap { $0 }.first { !$0.isEmpty }
    }
}
