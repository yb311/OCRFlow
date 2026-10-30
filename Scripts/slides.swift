import AppKit

// A five-page "document" for testing page-by-page capture. → or the Next
// button turns the page; the last page does not turn. SIGUSR1 moves the window;
// SIGUSR2 moves the Next button to the window's other side.
// With "scroll" after the path: one long page of 120 lines to scroll instead.
// Writes its window id, frame and button centre (event coordinates) to argv[1].
let infoPath = CommandLine.arguments[1]
let scrolling = CommandLine.arguments.dropFirst(2).first == "scroll"

final class LongPage: NSView {
    static let lines = 120
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); dirtyRect.fill()
        for line in 1...Self.lines {
            let top = CGFloat(line - 1) * 34 + 16
            guard top + 34 >= dirtyRect.minY, top <= dirtyRect.maxY else { continue }
            let text = "Line \(line): " + String(repeating: "text\(line % 7) ", count: 2 + (line * 5) % 9)
            (text as NSString).draw(at: NSPoint(x: 30, y: top),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])
        }
    }
}

final class Slide: NSView {
    var page = 1 { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        let title = "Page \(page)" as NSString
        title.draw(at: NSPoint(x: 40, y: bounds.height - 110),
                   withAttributes: [.font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.black])
        for row in 0..<8 {
            let line = "Line \(row + 1) of page \(page): " + String(repeating: "word\(page) ", count: 3 + (row * 7 + page * 5) % 9)
            (line as NSString).draw(at: NSPoint(x: 40, y: bounds.height - 170 - CGFloat(row) * 40),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.darkGray])
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 124 { next() }
        else { super.keyDown(with: event) }
    }
    @objc func next() {
        guard page < 5 else { return }
        // Like a web viewer: the new page arrives after a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.page += 1 }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.title = "OCRFlow Test Slides"
let slide = Slide(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
let button = NSButton(title: "Next", target: slide, action: #selector(Slide.next))
button.frame = NSRect(x: 780, y: 20, width: 90, height: 32)
// Keys stay with the page after the button is clicked.
button.refusesFirstResponder = true
slide.addSubview(button)
if scrolling {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    scroll.hasVerticalScroller = true
    scroll.documentView = LongPage(frame: NSRect(x: 0, y: 0, width: 880, height: CGFloat(LongPage.lines) * 34 + 40))
    window.contentView = scroll
} else {
    window.contentView = slide
}
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(scrolling ? window.contentView : slide)

func report() {
    let top = NSScreen.screens[0].frame.maxY
    let f = window.frame
    let b = window.convertToScreen(button.convert(button.bounds, to: nil))
    let info: [String: Double] = ["id": Double(window.windowNumber),
        "x": f.minX, "y": top - f.maxY, "w": f.width, "h": f.height,
        "bx": b.midX, "by": top - b.midY]
    try! JSONSerialization.data(withJSONObject: info).write(to: URL(fileURLWithPath: infoPath))
}
DispatchQueue.main.async { report(); app.activate(ignoringOtherApps: true) }
signal(SIGUSR1, SIG_IGN)
let move = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
move.setEventHandler {
    window.setFrameOrigin(NSPoint(x: window.frame.minX + 60, y: window.frame.minY - 40))
    report()
}
move.resume()
signal(SIGUSR2, SIG_IGN)
let shift = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
shift.setEventHandler {
    button.setFrameOrigin(NSPoint(x: 20, y: 20))
    report()
}
shift.resume()
app.run()
