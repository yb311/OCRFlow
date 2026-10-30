import AppKit
import SwiftUI

/// The small panel shown while OCRFlow records or repeats what the user does:
/// over every app, never taking the keys from the one being worked in.
@MainActor
enum HUDPanel {
    /// Near the bottom of the screen, clear of what is being captured where
    /// possible: a recorded click must land on the page, not on the panel.
    static func show(_ content: some View, avoiding target: CGRect?) -> NSPanel {
        let host = FirstMouseHostingView(rootView: content
            .padding(14)
            .frame(width: 340, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)))
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = host

        let center = target.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let candidates = [
            CGPoint(x: area.midX - size.width / 2, y: area.minY + 24),
            CGPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 24),
            CGPoint(x: area.maxX - size.width - 24, y: area.minY + 24),
        ]
        let origin = candidates.first { origin in
            guard let target else { return true }
            return !CGRect(origin: origin, size: size).intersects(target)
        } ?? candidates[0]
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        return panel
    }
}

/// The panel never becomes key, so the first click on a button has to count.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
