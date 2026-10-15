import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = NotchSettings()
    var island: IslandController?
    private var settingsWindow: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        island = IslandController(settings: settings) { [weak self] in self?.showSettings() }
        if settings.isEnabled { island?.show() }
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: NotchSettingsView(settings: settings)
            ))
            window.title = "agentnotch Ayarları"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 540, height: 720))
            window.center()
            settingsWindow = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
}
