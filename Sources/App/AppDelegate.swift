import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = NotchSettings()
    var island: IslandController?
    private var settingsWindow: NSWindowController?
    private var languageObserver: AnyCancellable?

    override init() {
        super.init()
        languageObserver = settings.$localization.sink { [weak self] localization in
            self?.settingsWindow?.window?.title = localization.text(.settingsTitle)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        island = IslandController(settings: settings) { [weak self] in self?.showSettings() }
        if settings.isEnabled { island?.show() }
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: NotchSettingsView(settings: settings)
            ))
            window.title = settings.localization.text(.settingsTitle)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 540, height: 780))
            window.center()
            settingsWindow = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
}
