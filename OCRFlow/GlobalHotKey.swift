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
    static let captureAgainTitle = "⌥⇧⌘3"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// ⌥⇧⌘2: the in-app capture shortcut, ⇧⌘2, with ⌥ added so it does not
    /// take the plain one from whichever app is in front.
    static func capture(_ action: @escaping () -> Void) -> GlobalHotKey {
        GlobalHotKey(id: 1, keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey | shiftKey | cmdKey), action: action)
    }

    /// ⌥⇧⌘3: the same place as the last capture, again.
    static func captureAgain(_ action: @escaping () -> Void) -> GlobalHotKey {
        GlobalHotKey(id: 2, keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(optionKey | shiftKey | cmdKey), action: action)
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
            MainActor.assumeIsolated { hotKey.action() }
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
