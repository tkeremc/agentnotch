import AppKit
import SwiftUI

struct NotchMenu: View {
    @ObservedObject var settings: NotchSettings
    let openSettings: () -> Void

    var body: some View {
        Group {
            Toggle(settings.localization.text(.menuEnabled), isOn: $settings.isEnabled)
            Button(settings.localization.text(.menuSettings), action: openSettings)
                .keyboardShortcut(",")
            Divider()
            Button(settings.localization.text(.menuQuit)) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .environment(\.locale, settings.localization.locale)
    }
}
