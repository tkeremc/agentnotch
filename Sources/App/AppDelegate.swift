import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let settings = NotchSettings()
    let codex = CodexStore()
    let claude = ClaudeStore()
    private let settingsNavigation = SettingsNavigation()
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
        island = IslandController(settings: settings, codex: codex, claude: claude,
            openCodexSettings: { [weak self] in self?.showCodexSettings() },
            openClaudeSettings: { [weak self] in self?.showClaudeSettings() }
        ) { [weak self] in self?.showSettings() }
        if settings.isEnabled { island?.show() }
    }

    func showSettings() {
        island?.setSettingsPresented(true)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: NotchSettingsView(settings: settings, codex: codex, claude: claude, navigation: settingsNavigation)
            ))
            window.title = settings.localization.text(.settingsTitle)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 540, height: 780))
            window.center()
            settingsWindow = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.window?.deminiaturize(nil)
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private func showCodexSettings() {
        showSettings()
        settingsNavigation.focusCodex()
    }

    private func showClaudeSettings() {
        showSettings()
        settingsNavigation.focusClaude()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow?.window else { return }
        island?.setSettingsPresented(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow?.window else { return }
        island?.setSettingsPresented(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow?.window else { return }
        island?.setSettingsPresented(true)
    }
}
