import AppKit
import SwiftUI

struct NotchMenu: View {
    @ObservedObject var settings: NotchSettings
    let openSettings: () -> Void

    var body: some View {
        Toggle("leagent notch etkin", isOn: $settings.isEnabled)
        Button("Ayarlar…", action: openSettings)
            .keyboardShortcut(",")
        Divider()
        Button("leagent notch’tan çık") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
