import SwiftUI

struct CodexWidgetView: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var store: CodexStore
    var onConnect: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            CodexWidgetContent(settings: settings, usage: store.usage,
                availability: store.usageAvailability, agents: store.agents,
                approvals: store.approvals, connection: store.connection,
                connectionFailure: store.connectionFailure, isBusy: store.isChangingConnection,
                now: context.date,
                onConnect: onConnect,
                onRetry: { store.retry() })
        }
    }
}

/// Pure presentation also makes every connection/permission state renderable
/// with synthetic data, without installing hooks or running a Codex task.
struct CodexWidgetContent: View {
    @ObservedObject var settings: NotchSettings
    var isClaude = false
    var usage: CodexUsageSnapshot?
    var availability: CodexUsageAvailability = .noData
    var agents: [CodexAgentSnapshot] = []
    var approvals: [CodexApprovalSnapshot] = []
    var connection: CodexConnection = .notInstalled
    var connectionFailure: L10nKey?
    var isBusy = false
    var now = Date()
    var onConnect: () -> Void = {}
    var onRetry: () -> Void = {}

    private var text: AppLocalization { settings.localization }
    private var foreground: Color { settings.foregroundColor }
    private var accent: Color { isClaude
        ? Color(red: 0.89, green: 0.62, blue: 0.47)
        : Color(red: 0.50, green: 0.85, blue: 0.67) }
    private var active: [CodexAgentSnapshot] {
        agents.filter { $0.isActive(at: now) }
    }
    private var visibleAgents: [CodexAgentSnapshot] {
        let sorted = agents.filter { $0.isActive(at: now) || $0.hasRecentTerminalAlert(at: now) }.sorted {
            let a = priority($0.status), b = priority($1.status)
            return a == b ? $0.updatedAt > $1.updatedAt : a < b
        }
        var result: [CodexAgentSnapshot] = []
        var visited: Set<String> = []
        func append(_ agent: CodexAgentSnapshot) {
            guard visited.insert(agent.id).inserted else { return }
            result.append(agent)
            for child in sorted where child.parentID == agent.id { append(child) }
        }
        for agent in sorted where agent.parentID == nil { append(agent) }
        for agent in sorted { append(agent) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .top, spacing: 12) {
                quotaSection.frame(width: 142, alignment: .leading)
                Rectangle().fill(foreground.opacity(0.09)).frame(width: 1)
                activitySection.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(foreground)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(isClaude ? "ClaudeMark" : "GPTMark")
                .resizable().scaledToFit()
                .frame(width: 18, height: 18)
                .frame(width: 22, height: 22)
            Text(isClaude ? "Claude" : "Codex").font(.system(size: 14, weight: .semibold))
            if let plan = usage?.planType, ["plus", "pro", "team", "business", "enterprise", "free", "edu"].contains(plan.lowercased()) {
                Text(plan.capitalized)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.45))
            }
            Spacer(minLength: 0)
            Circle().fill(connectionFailure != nil || connection == .repairRequired || connection == .unavailable
                ? Color.orange : connection == .receiving || connection == .waitingForEvents
                ? accent : foreground.opacity(0.3))
                .frame(width: 5, height: 5)
                .help(text.text(connectionFailure ?? connection.title))
                .accessibilityLabel(text.text(connectionFailure == nil ? connection.title : .agentConnectionFailed))
            Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                .font(.system(size: 10))
                .buttonStyle(.plain).foregroundStyle(foreground.opacity(0.4))
                .help(text.text(isClaude ? .claudeRetry : .codexRetry))
                .accessibilityLabel(text.text(isClaude ? .claudeRetry : .codexRetry))
                .disabled(isBusy)
        }
    }

    @ViewBuilder
    private var quotaSection: some View {
        if let usage, usage.primary != nil || usage.secondary != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let window = usage.primary { quota(window) }
                if let window = usage.secondary { quota(window) }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(text.text(.codexQuota))
                    .font(.system(size: 9, weight: .medium))
                HStack(spacing: 5) {
                    Text("—").font(.system(size: 17, weight: .medium, design: .rounded))
                    if availability == .ambiguousAccounts || availability == .permissionDenied {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
            }
            .foregroundStyle(foreground.opacity(0.45))
            .help(text.text(availability == .ambiguousAccounts ? .codexAmbiguousAccount
                : availability == .permissionDenied ? (isClaude ? .claudeAccessRequired : .codexAccessRequired)
                : (isClaude ? .claudeNoQuota : .codexNoQuota)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text.text(availability == .ambiguousAccounts ? .codexAmbiguousAccount
                : availability == .permissionDenied ? (isClaude ? .claudeAccessRequired : .codexAccessRequired)
                : (isClaude ? .claudeNoQuota : .codexNoQuota)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func quota(_ window: CodexUsageWindow) -> some View {
        let remaining = window.remainingPercent / 100
        let tint: Color = remaining < 0.2 ? .orange : accent
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(windowTitle(window))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.5))
                Spacer(minLength: 0)
                Text(remaining, format: .percent.precision(.fractionLength(0)).locale(text.locale))
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .monospacedDigit().tracking(-0.4)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel("\(remaining.formatted(.percent.precision(.fractionLength(0)).locale(text.locale))) \(text.text(.codexRemaining))")
            }
            GeometryReader { geometry in
                Capsule().fill(foreground.opacity(0.09))
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint).frame(width: geometry.size.width * remaining)
                    }
            }
            .frame(height: 3)
            if let reset = window.resetsAt, reset > now {
                Label(duration(max(60, reset.timeIntervalSince(now))), systemImage: "arrow.clockwise")
                    .font(.system(size: 9))
                    .foregroundStyle(foreground.opacity(0.4))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityLabel(text.text(.codexResetsIn, duration(max(60, reset.timeIntervalSince(now)))))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Label(active.count.formatted(.number.locale(text.locale)), systemImage: "person.2")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.5))
                    .accessibilityLabel(text.text(.codexAgentCount, active.count))
                Spacer(minLength: 0)
                if connection == .notInstalled || connection == .repairRequired {
                    Button(text.text(connection == .repairRequired ? .codexRepair : .codexConnect), action: onConnect)
                        .font(.system(size: 9, weight: .semibold))
                        .buttonStyle(.plain).foregroundStyle(connection == .repairRequired ? Color.orange : accent)
                        .disabled(isBusy)
                }
            }
            if let approval = approvals.first {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text.text(.codexPermissionRequested))
                            .foregroundStyle(.orange).fontWeight(.semibold)
                        Text(approval.summary ?? approval.project)
                            .foregroundStyle(foreground.opacity(0.65)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if approvals.count > 1 { Text("+\(approvals.count - 1)").foregroundStyle(.orange) }
                }
                .font(.system(size: 9))
                .help(approval.summary ?? text.text(isClaude ? .claudePermissionDescription : .codexPermissionDescription))
            }
            if visibleAgents.isEmpty {
                Text("—")
                    .font(.system(size: 10)).foregroundStyle(foreground.opacity(0.3))
                    .frame(maxHeight: .infinity, alignment: .center)
                    .accessibilityLabel(text.text(.codexNoAgents))
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(visibleAgents) { agent in
                            HStack(spacing: 5) {
                                Image(systemName: agent.isSubagent ? "arrow.triangle.branch" : "terminal")
                                    .font(.system(size: 9)).foregroundStyle(foreground.opacity(0.45))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(agent.displayTitle)
                                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                                    if agent.conversationTitle != nil || agent.isSubagent {
                                        Text(agent.displaySubtitle).font(.system(size: 8))
                                            .foregroundStyle(foreground.opacity(0.4)).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                Text(text.text(agent.hasIssue && agent.status == .working
                                    ? .codexToolIssue : statusTitle(agent.status)))
                                    .font(.system(size: 9)).foregroundStyle(statusColor(agent))
                            }
                            .padding(.leading, agent.isSubagent ? 6 : 0)
                            .help("\(agent.displayTitle)\n\(agent.displaySubtitle)")
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private func statusColor(_ agent: CodexAgentSnapshot) -> Color {
        if agent.status == .failed || agent.hasIssue { return .red }
        if agent.status == .approvalRequested || agent.status == .awaitingInput || agent.status == .interrupted { return .orange }
        return agent.status == .working ? accent : foreground.opacity(0.45)
    }

    private func windowTitle(_ value: CodexUsageWindow) -> String {
        switch value.windowMinutes {
        case 300: return text.text(.codexFiveHours)
        case 10080: return text.text(.codexWeekly)
        case .some(let minutes): return text.text(.codexWindowMinutes, minutes)
        case .none: return text.text(.codexQuota)
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return text.text(.codexNow) }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        var calendar = Calendar.current
        calendar.locale = text.locale
        formatter.calendar = calendar
        return formatter.string(from: seconds) ?? text.text(.codexUnknown)
    }

    private func statusTitle(_ value: CodexAgentStatus) -> L10nKey {
        switch value {
        case .working: return .codexWorking
        case .approvalRequested: return .codexPermissionRequested
        case .awaitingInput: return .agentAwaitingInput
        case .finished: return .codexFinished
        case .interrupted: return .codexInterrupted
        case .failed: return .codexFailed
        case .unknown: return .codexUnknown
        case .idle: return .claudeIdle
        }
    }

    private func priority(_ value: CodexAgentStatus) -> Int {
        switch value {
        case .failed: return 0
        case .approvalRequested: return 0
        case .awaitingInput: return 0
        case .working: return 1
        case .unknown: return 2
        default: return 3
        }
    }
}
