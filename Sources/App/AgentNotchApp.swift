import SwiftUI

@main
struct AgentNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("agentnotch", image: "NotchMark") {
            NotchMenu(settings: delegate.settings, openSettings: delegate.showSettings)
        }
    }
}
