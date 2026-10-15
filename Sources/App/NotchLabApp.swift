import SwiftUI

@main
struct LeagentNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("leagent notch", image: "NotchMark") {
            NotchMenu(settings: delegate.settings, openSettings: delegate.showSettings)
        }
    }
}
