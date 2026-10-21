// GUI regression check using the real AppDelegate and settings window.
// Run only in the isolated bundle produced by settings-flow-check.py.
// Codex discovery is read-only; consent is always aborted, never accepted.
import AppKit
import SwiftUI

@main
@MainActor
struct SettingsFlowCheck {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier!
        precondition(domain == "com.agentnotch.SettingsFlowCheck")
        defaults.removePersistentDomain(forName: domain)
        defaults.set(["codex"], forKey: "island.widgets")
        let delegate = AppDelegate()
        delegate.settings.language = .turkish
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let controller = delegate.island!
        let state = field(controller, "state") as! IslandState
        let panel = field(controller, "panel") as! NSPanel
        state.isEditingWidgets = true
        state.expanded = true
        state.progress = 1
        state.contentProgress = 1
        state.openCodexSettings?()

        func finish(_ message: String?, status: Int32) -> Never {
            if let message { print(message) }
            delegate.island?.hide()
            delegate.codex.stop()
            defaults.removePersistentDomain(forName: domain)
            exit(status)
        }
        let check = Timer(timeInterval: 0.6, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard !state.expanded, state.progress == 0, state.contentProgress == 0,
                      !state.isEditingWidgets, panel.ignoresMouseEvents else {
                    finish("FAIL settings did not collapse the drawer or release mouse input", status: 1)
                }
                state.openCodex?()
                guard !state.expanded else { finish("FAIL settings allowed the drawer to reopen", status: 1) }
                guard let window = NSApp.windows.first(where: {
                    $0.title == delegate.settings.localization.text(.settingsTitle) && $0.isVisible
                }), window.isKeyWindow else { finish("FAIL settings is not visible and key", status: 1) }
                try? capture(window, to: output.appendingPathComponent("settings.png"))
                print("PASS widget connect opens settings, collapses editing, and suppresses expansion")
                let deadline = Date().addingTimeInterval(8)
                let cancel = Timer(timeInterval: 0.1, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        if let modal = NSApp.modalWindow {
                            try? capture(modal, to: output.appendingPathComponent("consent.png"))
                            guard !state.expanded, modal.isKeyWindow else {
                                NSApp.abortModal()
                                timer.invalidate()
                                finish("FAIL consent is not accessible above the collapsed drawer", status: 1)
                            }
                            NSApp.abortModal()
                            timer.invalidate()
                            print("PASS settings consent is key and unobstructed; automatically cancelled")
                            window.close()
                            state.openCodex?()
                            guard state.expanded else { finish("FAIL closing settings did not restore expansion", status: 1) }
                            finish("PASS closing settings restores the drawer", status: 0)
                        } else if Date() >= deadline {
                            timer.invalidate()
                            finish("FAIL no consent dialog appeared", status: 1)
                        }
                    }
                }
                RunLoop.main.add(cancel, forMode: .common)
                RunLoop.main.add(cancel, forMode: .modalPanel)
                delegate.codex.connect(localization: delegate.settings.localization)
            }
        }
        RunLoop.main.add(check, forMode: .common)
        app.run()
    }

    static func field(_ object: Any, _ name: String) -> Any? {
        Mirror(reflecting: object).children.first { $0.label == name }?.value
    }

    static func capture(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
