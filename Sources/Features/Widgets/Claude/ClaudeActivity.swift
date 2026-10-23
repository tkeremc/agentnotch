import Foundation

/// The small, local-only envelope emitted by the AgentNotch hook helper.
/// Dates always use Unix seconds, independently of a JSONDecoder's date strategy.
struct ClaudeHookEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case permissionRequest = "PermissionRequest"
        case postToolUse = "PostToolUse"
        case stop = "Stop"
        case postToolUseFailure = "PostToolUseFailure"
        case notification = "Notification"
        case stopFailure = "StopFailure"
        case statusLine = "StatusLine"
        case subagentStart = "SubagentStart"
        case subagentStop = "SubagentStop"
        case sessionEnd = "SessionEnd"
    }

    let schemaVersion: Int
    let id: String
    let kind: Kind
    let timestamp: Date
    let sessionID: String
    let turnID: String?
    let agentID: String?
    let project: String
    let toolName: String?
    let toolUseID: String?
    let permissionSummary: String?
    let toolFingerprint: String?
    let notificationType: String?
    let agentType: String?
    let fiveHourUsedPercent: Double?
    let fiveHourResetsAt: Double?
    let sevenDayUsedPercent: Double?
    let sevenDayResetsAt: Double?

    init(schemaVersion: Int = 1, id: String = UUID().uuidString, kind: Kind,
         timestamp: Date = Date(), sessionID: String, turnID: String? = nil,
         agentID: String? = nil, project: String, toolName: String? = nil,
         toolUseID: String? = nil, permissionSummary: String? = nil, toolFingerprint: String? = nil,
         notificationType: String? = nil, agentType: String? = nil,
         fiveHourUsedPercent: Double? = nil, fiveHourResetsAt: Double? = nil,
         sevenDayUsedPercent: Double? = nil, sevenDayResetsAt: Double? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.turnID = turnID
        self.agentID = agentID
        self.project = Self.projectName(project)
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.permissionSummary = permissionSummary
        self.toolFingerprint = toolFingerprint
        self.notificationType = notificationType
        self.agentType = agentType
        self.fiveHourUsedPercent = fiveHourUsedPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayUsedPercent = sevenDayUsedPercent
        self.sevenDayResetsAt = sevenDayResetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, kind, timestamp, sessionID, turnID, agentID
        case project, toolName, toolUseID, permissionSummary, toolFingerprint
        case notificationType, agentType, fiveHourUsedPercent, fiveHourResetsAt, sevenDayUsedPercent, sevenDayResetsAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let seconds = try values.decode(Double.self, forKey: .timestamp)
        guard seconds.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .timestamp, in: values,
                                                  debugDescription: "Expected finite Unix seconds")
        }
        self.init(schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
                  id: try values.decode(String.self, forKey: .id),
                  kind: try values.decode(Kind.self, forKey: .kind),
                  timestamp: Date(timeIntervalSince1970: seconds),
                  sessionID: try values.decode(String.self, forKey: .sessionID),
                  turnID: try values.decodeIfPresent(String.self, forKey: .turnID),
                  agentID: try values.decodeIfPresent(String.self, forKey: .agentID),
                  project: try values.decode(String.self, forKey: .project),
                  toolName: try values.decodeIfPresent(String.self, forKey: .toolName),
                  toolUseID: try values.decodeIfPresent(String.self, forKey: .toolUseID),
                  permissionSummary: try values.decodeIfPresent(String.self, forKey: .permissionSummary),
                  toolFingerprint: try values.decodeIfPresent(String.self, forKey: .toolFingerprint),
                  notificationType: try values.decodeIfPresent(String.self, forKey: .notificationType),
                  agentType: try values.decodeIfPresent(String.self, forKey: .agentType),
                  fiveHourUsedPercent: try values.decodeIfPresent(Double.self, forKey: .fiveHourUsedPercent),
                  fiveHourResetsAt: try values.decodeIfPresent(Double.self, forKey: .fiveHourResetsAt),
                  sevenDayUsedPercent: try values.decodeIfPresent(Double.self, forKey: .sevenDayUsedPercent),
                  sevenDayResetsAt: try values.decodeIfPresent(Double.self, forKey: .sevenDayResetsAt))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        try values.encode(timestamp.timeIntervalSince1970, forKey: .timestamp)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encodeIfPresent(turnID, forKey: .turnID)
        try values.encodeIfPresent(agentID, forKey: .agentID)
        try values.encode(project, forKey: .project)
        try values.encodeIfPresent(toolName, forKey: .toolName)
        try values.encodeIfPresent(toolUseID, forKey: .toolUseID)
        try values.encodeIfPresent(permissionSummary, forKey: .permissionSummary)
        try values.encodeIfPresent(toolFingerprint, forKey: .toolFingerprint)
        try values.encodeIfPresent(notificationType, forKey: .notificationType)
        try values.encodeIfPresent(agentType, forKey: .agentType)
        try values.encodeIfPresent(fiveHourUsedPercent, forKey: .fiveHourUsedPercent)
        try values.encodeIfPresent(fiveHourResetsAt, forKey: .fiveHourResetsAt)
        try values.encodeIfPresent(sevenDayUsedPercent, forKey: .sevenDayUsedPercent)
        try values.encodeIfPresent(sevenDayResetsAt, forKey: .sevenDayResetsAt)
    }

    private static func projectName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed as NSString).lastPathComponent
    }
}

/// Claude supplies session and agent IDs, but no turn ID. New tool starts and
/// permission requests can prove continuation after another hook vetoes Stop.
struct ClaudeActivityState {
    private struct Approval {
        let snapshot: CodexApprovalSnapshot
        var toolID: String?
        let notification: Bool
    }
    private struct Agent {
        let sessionID: String
        let agentID: String?
        var name: String?
        var project: String
        var status: CodexAgentStatus = .unknown
        var updatedAt = Date.distantPast
        var startedAt: Date?
        var endedAt: Date?
        var hasIssue = false
        var approvals: [Approval] = []
        var tools: [(id: String, name: String?, fingerprint: String)] = []
    }
    private var records: [String: Agent] = [:]
    private var seen: Set<String> = []
    private var order: [String] = []
    private let staleAfter: TimeInterval

    init(staleAfter: TimeInterval = 300) { self.staleAfter = max(1, staleAfter) }

    mutating func consume(_ event: ClaudeHookEvent) {
        guard event.schemaVersion == 1, !event.id.isEmpty, !event.sessionID.isEmpty,
              event.sessionID.utf8.count <= 512,
              event.agentID.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true,
              event.timestamp.timeIntervalSince1970.isFinite, seen.insert(event.id).inserted else { return }
        order.append(event.id)
        if order.count > 8192 { seen.remove(order.removeFirst()) }
        if event.kind == .subagentStart || event.kind == .subagentStop {
            guard event.agentID != nil else { return }
        }
        if event.kind == .notification && event.notificationType != "permission_prompt" { return }
        let key = Self.key(event.sessionID, event.agentID)
        let parentStart = event.agentID == nil && (event.kind == .sessionStart || event.kind == .userPromptSubmit)
        if let ended = records[event.sessionID]?.endedAt,
           !parentStart || event.timestamp <= ended { return }
        var agent = records[key] ?? Agent(sessionID: event.sessionID, agentID: event.agentID,
                                          project: event.project)
        guard event.timestamp >= agent.updatedAt else { return }
        let terminal = [.finished, .interrupted, .failed].contains(agent.status)
        let start = event.kind == .userPromptSubmit || event.kind == .subagentStart
        // Delayed same-timestamp hooks must never revive completed work.
        let continuing = event.kind == .preToolUse || event.kind == .permissionRequest
        if terminal && event.kind != .sessionEnd
            && (event.timestamp == agent.updatedAt || !start && !continuing && event.kind != .sessionStart) { return }
        // Status lines also render when idle; they never prove active work.
        if event.kind == .statusLine { return }
        agent.project = event.project
        if let name = event.agentType { agent.name = String(name.prefix(128)) }
        agent.updatedAt = event.timestamp
        if parentStart || start { agent.endedAt = nil }
        if event.kind == .sessionEnd { agent.endedAt = event.timestamp }
        if start || terminal && continuing {
            agent.startedAt = event.timestamp
            agent.approvals.removeAll()
            agent.tools.removeAll()
            agent.hasIssue = false
        }
        switch event.kind {
        case .sessionStart:
            agent.status = .unknown
        case .userPromptSubmit, .subagentStart:
            agent.status = .working
        case .permissionRequest, .notification:
            let matching = agent.tools.filter { $0.name == event.toolName && $0.fingerprint == event.toolFingerprint }
            let toolID = event.toolUseID ?? (matching.count == 1 ? matching.first?.id : nil)
            // Notification is a fallback and must not duplicate a real request.
            if event.kind != .notification || agent.approvals.isEmpty {
                if event.kind == .permissionRequest {
                    agent.approvals.removeAll { $0.notification || (toolID != nil && $0.toolID == toolID) }
                }
                let snapshot = CodexApprovalSnapshot(id: event.id, sessionID: event.sessionID,
                    turnID: nil, project: event.project, summary: nil, toolName: event.toolName,
                    requestedAt: event.timestamp, agentID: event.agentID.map { Self.key(event.sessionID, $0) })
                agent.approvals.append(Approval(snapshot: snapshot, toolID: toolID, notification: event.kind == .notification))
                if agent.approvals.count > 32 { agent.approvals.removeFirst() }
            }
            agent.status = .working
        case .preToolUse:
            agent.status = .working
            if let id = event.toolUseID, let fingerprint = event.toolFingerprint {
                agent.tools.removeAll { $0.id == id }
                agent.tools.append((id, event.toolName, fingerprint))
                if agent.tools.count > 64 { agent.tools.removeFirst() }
            }
        case .postToolUse, .postToolUseFailure:
            agent.status = .working
            agent.hasIssue = event.kind == .postToolUseFailure
            if let toolID = event.toolUseID, !toolID.isEmpty {
                agent.approvals.removeAll { $0.toolID == toolID }
                agent.tools.removeAll { $0.id == toolID }
            }
        case .stop, .subagentStop, .sessionEnd, .stopFailure:
            agent.status = event.kind == .stopFailure ? .failed : .finished
            agent.hasIssue = event.kind == .stopFailure
            agent.approvals.removeAll()
            agent.tools.removeAll()
        case .statusLine: break
        }
        records[key] = agent
        if event.kind == .sessionEnd && event.agentID == nil {
            for childKey in Array(records.keys) where childKey != key {
                guard var child = records[childKey], child.sessionID == event.sessionID,
                      child.updatedAt <= event.timestamp else { continue }
                child.status = .finished
                child.updatedAt = event.timestamp
                child.approvals.removeAll()
                child.tools.removeAll()
                records[childKey] = child
            }
        }
        if records.count > 256, let oldest = records.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
            records.removeValue(forKey: oldest)
        }
    }

    func agents(at now: Date) -> [CodexAgentSnapshot] {
        records.compactMap { key, agent -> CodexAgentSnapshot? in
            guard agent.updatedAt <= now else { return nil }
            let terminal = [.finished, .interrupted, .failed].contains(agent.status)
            let status: CodexAgentStatus
            if terminal { status = agent.status }
            else if !agent.approvals.isEmpty {
                status = agent.approvals.contains { fresh($0.snapshot.requestedAt, now) } ? .approvalRequested : .unknown
            } else { status = fresh(agent.updatedAt, now) ? agent.status : .unknown }
            return CodexAgentSnapshot(id: key, project: agent.project,
                name: agent.agentID.map { agent.name ?? String($0.prefix(8)) },
                status: status, updatedAt: agent.updatedAt,
                parentID: agent.agentID == nil ? nil : agent.sessionID,
                turnStartedAt: agent.startedAt, hasIssue: agent.hasIssue, sessionEndedAt: agent.endedAt)
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }

    func pendingApprovals(at now: Date) -> [CodexApprovalSnapshot] {
        records.values.flatMap(\.approvals).map(\.snapshot).filter { fresh($0.requestedAt, now) }
            .sorted { $0.requestedAt == $1.requestedAt ? $0.id < $1.id : $0.requestedAt < $1.requestedAt }
    }
    private func fresh(_ at: Date, _ now: Date) -> Bool {
        let age = now.timeIntervalSince(at)
        return age >= 0 && age <= staleAfter
    }
    private static func key(_ session: String, _ agent: String?) -> String {
        // Length-prefixed IDs cannot collide across sessions or main/child IDs.
        guard let agent else { return session }
        return "\(session.utf8.count):\(session):\(agent)"
    }
}

/// Retain the last reported quota until each window's reset, even when the
/// event-driven status line goes quiet or omits a window in a later update.
/// Expired windows remain unknown until new evidence; a reset never implies 0%.
struct ClaudeUsageState {
    private(set) var snapshot: CodexUsageSnapshot?
    mutating func consume(_ event: ClaudeHookEvent, now: Date) {
        guard event.kind == .statusLine, event.schemaVersion == 1,
              event.timestamp <= now,
              snapshot.map({ event.timestamp >= $0.observedAt }) ?? true else { return }
        let primary = window(event.fiveHourUsedPercent, reset: event.fiveHourResetsAt, minutes: 300)
        let secondary = window(event.sevenDayUsedPercent, reset: event.sevenDayResetsAt, minutes: 10080)
        guard primary != nil || secondary != nil else { return }
        snapshot = CodexUsageSnapshot(primary: primary ?? snapshot?.primary,
            secondary: secondary ?? snapshot?.secondary, observedAt: event.timestamp,
            planType: nil, limitID: "claude", identityKey: nil)
    }
    func current(at now: Date) -> CodexUsageSnapshot? {
        guard let snapshot, now >= snapshot.observedAt else { return nil }
        let primary = snapshot.primary.flatMap { $0.resetsAt.map { $0 <= now } == true ? nil : $0 }
        let secondary = snapshot.secondary.flatMap { $0.resetsAt.map { $0 <= now } == true ? nil : $0 }
        guard primary != nil || secondary != nil else { return nil }
        return CodexUsageSnapshot(primary: primary, secondary: secondary, observedAt: snapshot.observedAt,
            planType: nil, limitID: "claude", identityKey: nil)
    }
    private func window(_ percent: Double?, reset: Double?, minutes: Int) -> CodexUsageWindow? {
        guard let percent, percent.isFinite, (0...100).contains(percent),
              let reset, reset.isFinite, reset > 0, reset < 253_402_300_800 else { return nil }
        return CodexUsageWindow(usedPercent: percent, windowMinutes: minutes,
                                resetsAt: Date(timeIntervalSince1970: reset))
    }
}
