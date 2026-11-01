import AppKit
import ServiceManagement

/// The app's Dock icon, there only while one of its windows is open.
///
/// Screenshots live in the menu bar and need no window; recognizing images
/// happens in the main window. Closing it leaves only the menu bar icon. An
/// app with no Dock icon also has no menus at the top of the screen and
/// drops behind other apps' windows, which would leave a window half usable,
/// so the icon comes back with the first window.
@MainActor
final class DockIcon {
    static let shared = DockIcon()

    private var observers: [NSObjectProtocol] = []

    /// Watches the windows from now on.
    func start() {
        update()
    }

    private init() {
        let center = NotificationCenter.default
        // Windows can appear without ever becoming key — those macOS restores
        // at launch, in an app opened in the background — so the end of
        // launching and occlusion changes are watched too.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didFinishLaunchingNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // A closing window still counts as visible while it closes,
                // so look again once it has gone.
                Task { @MainActor in self?.update() }
            })
        }
    }

    private func update() {
        let policy: NSApplication.ActivationPolicy = hasOpenWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Coming back from .accessory, the menus at the top only show for an
        // app that is active.
        if policy == .regular { NSApp.activate() }
    }

    /// A minimised window counts: with no Dock icon there would be nowhere to
    /// bring it back from. Panels — the floating button, open and save
    /// dialogs — do not, nor do the helper windows SwiftUI keeps off screen,
    /// nor the screen held still for a screenshot, which sits above
    /// everything rather than among other windows.
    private var hasOpenWindow: Bool {
        NSApp.windows.contains { window in
            guard !(window is NSPanel), window.canBecomeMain, window.level == .normal else { return false }
            if window.isMiniaturized { return true }
            return window.isVisible && NSScreen.screens.contains { $0.frame.intersects(window.frame) }
        }
    }
}

/// Opening the app when the user logs in. The system keeps this setting, not
/// the app, so it is read back rather than stored.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registered, but waiting for the user to allow it in System Settings.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
