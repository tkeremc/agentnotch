import AppKit
import SwiftUI

struct NotchMenu: View {
    @ObservedObject var settings: NotchSettings
    let openSettings: () -> Void

    var body: some View {
        Toggle("agentnotch etkin", isOn: $settings.isEnabled)
        Button("Ayarlar…", action: openSettings)
            .keyboardShortcut(",")
        Divider()
        Button("agentnotch’tan çık") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
