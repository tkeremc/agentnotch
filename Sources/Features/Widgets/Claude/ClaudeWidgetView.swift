import SwiftUI

/// Uses the same quota and activity layout as Codex, with Claude's own data and guidance.
struct ClaudeWidgetView: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var store: ClaudeStore
    var onConnect: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            CodexWidgetContent(settings: settings, isClaude: true, usage: store.usage,
                availability: store.usageAvailability, agents: store.agents,
                approvals: store.approvals, connection: store.connection,
                connectionFailure: store.connectionFailure, isBusy: store.isChangingConnection,
                now: context.date, onConnect: onConnect, onRetry: { store.retry() })
        }
    }
}
