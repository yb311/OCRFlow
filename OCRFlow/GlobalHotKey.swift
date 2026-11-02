import AppKit
import Carbon.HIToolbox

/// A key combination that works while any app is in front.
///
/// Registered with the Carbon hot-key API, which macOS still keeps for exactly
/// this: unlike watching every key press, it needs no Accessibility or Input
/// Monitoring permission, and the keys never reach the app in front.
@MainActor
final class GlobalHotKey {
    /// The capture shortcuts, as the menu would write them.
    static let captureTitle = "⌥⇧⌘2"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// ⌥⇧⌘2: the in-app capture shortcut, ⇧⌘2, with ⌥ added so it does not
    /// take the plain one from whichever app is in front.
    static func capture(_ action: @escaping () -> Void) -> GlobalHotKey {
        GlobalHotKey(id: 1, keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey | shiftKey | cmdKey), action: action)
    }

    /// Keys taken for as long as a capture asks something — Escape, Return
    /// and the like, with or without modifiers (Carbon's `cmdKey`,
    /// `shiftKey`) — so they act on it while the app in front stays in
    /// front, and never reach that app. Released with `release(_:)`.
    ///
    /// A key claimed again, while it already is, goes to the newest claim
    /// until that is released, then back to the one before: the size being
    /// typed takes Return and Escape from the bar meanwhile.
    static func claim(_ keys: [(keyCode: Int, modifiers: Int, action: () -> Void)]) -> [GlobalHotKey] {
        keys.compactMap { key in
            nextClaimID += 1
            let hotKey = GlobalHotKey(id: nextClaimID, keyCode: UInt32(key.keyCode),
                                      modifiers: UInt32(key.modifiers), action: key.action)
            let claims = self.claims[hotKey.combination, default: []]
            guard claims.isEmpty ? hotKey.register() : true else { return nil }
            self.claims[hotKey.combination] = claims + [hotKey]
            return hotKey
        }
    }

    static func release(_ hotKeys: [GlobalHotKey]) {
        for hotKey in hotKeys {
            var claims = self.claims[hotKey.combination, default: []]
            claims.removeAll { $0 === hotKey }
            // The one registered goes: the one before it takes its place.
            if hotKey.hotKey != nil {
                hotKey.unregister()
                if let first = claims.first, !first.register() { claims.removeAll() }
            }
            self.claims[hotKey.combination] = claims.isEmpty ? nil : claims
        }
    }

    /// Past the fixed ones: each claimed key its own.
    private static var nextClaimID: UInt32 = 100
    /// Each key claimed, oldest first: the oldest registered, the newest
    /// acting.
    private static var claims: [UInt64: [GlobalHotKey]] = [:]

    private var combination: UInt64 { UInt64(keyCode) << 32 | UInt64(modifiers) }

    private func fire() {
        let claims = Self.claims[combination] ?? []
        (claims.contains { $0 === self } ? claims.last ?? self : self).action()
    }

    /// Whether a key press is one of OCRFlow's own shortcuts: while
    /// recording, it takes a capture rather than being a step.
    nonisolated static func isOwn(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        let held = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        return held == [.maskCommand, .maskShift, .maskAlternate]
            && keyCode == UInt16(kVK_ANSI_2)
    }

    private let id: UInt32
    private let keyCode: UInt32
    private let modifiers: UInt32

    init(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.id = id
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
    }

    /// Claims the keys. False when another app holds them already.
    func register() -> Bool {
        guard hotKey == nil else { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            // Every hot key's handler hears every press; each takes only its own.
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            // Delivered through the main run loop.
            MainActor.assumeIsolated { hotKey.fire() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return false }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F43_5246), id: id)   // 'OCRF'
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKey) == noErr else {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
