import AppKit
import SwiftUI

@main
struct NotchLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("NotchLab", systemImage: "capsule.tophalf.filled") {
            Button("Adayı göster") { delegate.island?.show() }
            Button("Adayı gizle") { delegate.island?.hide() }
            Divider()
            Button("NotchLab’den çık") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var island: IslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        island = IslandController()
        island?.show()
    }
}
