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
        agents.filter { $0.status == .working || $0.status == .approvalRequested }
    }
    private var visibleAgents: [CodexAgentSnapshot] {
        let recent = agents.filter { now.timeIntervalSince($0.updatedAt) < 3600
            || $0.status == .working || $0.status == .approvalRequested }
        let sorted = recent.sorted {
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
            footer
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
            HStack(spacing: 5) {
                Circle().fill(connection == .receiving ? accent : foreground.opacity(0.3))
                    .frame(width: 5, height: 5)
                Text(text.text(.codexLocal)).font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(foreground.opacity(0.55))
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
            VStack(alignment: .leading, spacing: 6) {
                Text(text.text(availability == .ambiguousAccounts ? .codexAmbiguousAccount
                    : availability == .permissionDenied ? (isClaude ? .claudeAccessRequired : .codexAccessRequired) : (isClaude ? .claudeNoQuota : .codexNoQuota)))
                    .font(.system(size: 10, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(text.text(isClaude ? .claudeNoQuotaHint : .codexNoQuotaHint))
                    .font(.system(size: 9)).foregroundStyle(foreground.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                Text(text.text(.codexRemaining))
                    .font(.system(size: 8)).foregroundStyle(foreground.opacity(0.4))
            }
            GeometryReader { geometry in
                Capsule().fill(foreground.opacity(0.09))
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint).frame(width: geometry.size.width * remaining)
                    }
            }
            .frame(height: 3)
            Text(resetText(window))
                .font(.system(size: 9))
                .foregroundStyle(window.resetsAt.map { $0 <= now } == true ? Color.orange : foreground.opacity(0.4))
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(text.text(.codexAgentCount, active.count))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.5))
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
                VStack(alignment: .leading, spacing: 5) {
                    Text(text.text(connection == .repairRequired ? (isClaude ? .claudeRepairHint : .codexRepairHint)
                        : connection == .notInstalled ? (isClaude ? .claudeConnectDescription : .codexConnectDescription)
                        : connection == .waitingForEvents ? (isClaude ? .claudeWaitingForEvents : .codexWaitingForEvents) : .codexNoAgents))
                        .font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                    if connection == .waitingForEvents {
                        Link(text.text(isClaude ? .claudeTrustHelp : .codexTrustHelp), destination: URL(string: isClaude ? "https://code.claude.com/docs/en/hooks" : "https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks")!)
                            .font(.system(size: 9))
                    }
                }
                .foregroundStyle(foreground.opacity(0.5))
                .frame(maxHeight: .infinity, alignment: .center)
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
        if agent.status == .approvalRequested { return .orange }
        return agent.status == .working ? accent : foreground.opacity(0.45)
    }

    private var footer: some View {
        HStack {
            if let connectionFailure {
                Text(text.text(connectionFailure)).foregroundStyle(.orange)
            } else if connection == .repairRequired {
                Text(text.text(isClaude ? .claudeRepairHint : .codexRepairHint)).foregroundStyle(.orange)
            } else if connection == .waitingForEvents {
                Text(text.text(isClaude ? .claudeTrustHint : .codexTrustHint)).foregroundStyle(foreground.opacity(0.5))
                    .help(text.text(isClaude ? .claudeTrustHint : .codexTrustHint))
            } else if connection == .unavailable {
                Text(text.text(isClaude ? .claudeConnectionFailed : .codexConnectionFailed)).foregroundStyle(.orange)
            } else if availability == .permissionDenied {
                Text(text.text(isClaude ? .claudeAccessRequired : .codexAccessRequired)).foregroundStyle(.orange)
            } else if let usage {
                Text(now.timeIntervalSince(usage.observedAt) < 60 ? text.text(.codexUpdatedNow)
                    : text.text(.codexLastUpdate, duration(now.timeIntervalSince(usage.observedAt))))
                    .foregroundStyle(now.timeIntervalSince(usage.observedAt) > 600 ? Color.orange : foreground.opacity(0.3))
            } else { Text(text.text(isClaude ? .claudeHistory : .codexHistory)).foregroundStyle(foreground.opacity(0.3)) }
            Spacer(minLength: 0)
            Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(foreground.opacity(0.4))
                .help(text.text(isClaude ? .claudeRetry : .codexRetry)).accessibilityLabel(text.text(isClaude ? .claudeRetry : .codexRetry))
        }
        .font(.system(size: 9))
        .lineLimit(1)
    }

    private func windowTitle(_ value: CodexUsageWindow) -> String {
        switch value.windowMinutes {
        case 300: return text.text(.codexFiveHours)
        case 10080: return text.text(.codexWeekly)
        case .some(let minutes): return text.text(.codexWindowMinutes, minutes)
        case .none: return text.text(.codexQuota)
        }
    }

    private func resetText(_ value: CodexUsageWindow) -> String {
        guard let reset = value.resetsAt, reset > now else { return text.text(.codexResetUnconfirmed) }
        return text.text(.codexResetsIn, duration(max(60, reset.timeIntervalSince(now))))
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
        case .working: return 1
        case .unknown: return 2
        default: return 3
        }
    }
}
