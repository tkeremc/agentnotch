import Foundation

/// The small, local-only envelope emitted by the AgentNotch hook helper.
/// Dates always use Unix seconds, independently of a JSONDecoder's date strategy.
struct CodexHookEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case permissionRequest = "PermissionRequest"
        case postToolUse = "PostToolUse"
        case stop = "Stop"
        case interrupt = "Interrupt"
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

    init(schemaVersion: Int = 1, id: String = UUID().uuidString, kind: Kind,
         timestamp: Date = Date(), sessionID: String, turnID: String? = nil,
         agentID: String? = nil, project: String, toolName: String? = nil,
         toolUseID: String? = nil, permissionSummary: String? = nil, toolFingerprint: String? = nil) {
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
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, kind, timestamp, sessionID, turnID, agentID
        case project, toolName, toolUseID, permissionSummary, toolFingerprint
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
                  toolFingerprint: try values.decodeIfPresent(String.self, forKey: .toolFingerprint))
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
    }

    private static func projectName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed as NSString).lastPathComponent
    }
}

enum CodexAgentStatus: String, Equatable {
    case working, approvalRequested, finished, interrupted, failed, unknown, idle
}

struct CodexAgentSnapshot: Identifiable, Equatable {
    let id: String
    let project: String
    let name: String?
    let status: CodexAgentStatus
    let updatedAt: Date
    var parentID: String? = nil
    var turnID: String? = nil
    var turnStartedAt: Date? = nil
    var hasIssue = false
    var conversationTitle: String? = nil
    var sessionEndedAt: Date? = nil

    var displayTitle: String { conversationTitle ?? name ?? project }
    var displaySubtitle: String {
        if conversationTitle != nil, isSubagent, let name { return "\(project) · \(name)" }
        return project
    }
    var isSubagent: Bool { parentID != nil || name != nil }

    /// Presentation follows lifecycle evidence, rather than showing recent history.
    /// Readers already expire unverified hook/log activity to `unknown`; a
    /// validated runtime can remain busy for a long time without a heartbeat.
    func isActive(at now: Date) -> Bool {
        updatedAt <= now && (status == .working || status == .approvalRequested)
    }

    func closingSession(at date: Date) -> Self {
        Self(id: id, project: project, name: name, status: .finished,
             updatedAt: max(updatedAt, date), parentID: parentID, turnID: turnID,
             turnStartedAt: turnStartedAt, conversationTitle: conversationTitle, sessionEndedAt: date)
    }

    static func closeEndedSessions(in agents: inout [String: Self]) {
        for id in Array(agents.keys) {
            var current: String? = id
            var visited: Set<String> = []
            while let key = current, visited.count < 32, visited.insert(key).inserted,
                  let ancestor = agents[key] {
                if let end = ancestor.sessionEndedAt {
                    agents[id] = agents[id]?.closingSession(at: end)
                    break
                }
                current = ancestor.parentID
            }
        }
    }
}

struct CodexApprovalSnapshot: Identifiable, Equatable {
    let id: String
    let sessionID: String
    let turnID: String?
    let project: String
    let summary: String?
    let toolName: String?
    let requestedAt: Date
    var agentID: String? = nil

    var targetID: String { agentID ?? sessionID }
}

/// Conservative hook projection: an approval request is not proof that a human
/// prompt is still open, and the absence of recent events is not task completion.
struct CodexActivityState {
    private struct Approval {
        let snapshot: CodexApprovalSnapshot
        let toolUseID: String?
    }

    private struct Agent {
        let sessionID: String
        let agentID: String?
        var project: String
        var status: CodexAgentStatus = .unknown
        var updatedAt: Date
        var turnID: String?
        var startedAt: Date?
        var endedAt: Date?
        var closedTurns: [String] = []
        var approvals: [Approval] = []
        var tools: [(id: String, name: String?, fingerprint: String)] = []
    }

    private var records: [String: Agent] = [:]
    private var seenIDs: Set<String> = []
    private var seenOrder: [String] = []
    private let staleAfter: TimeInterval
    private let maximumAgents = 256

    init(staleAfter: TimeInterval = 5 * 60) {
        self.staleAfter = max(1, staleAfter)
    }

    mutating func consume(_ event: CodexHookEvent) {
        guard event.schemaVersion == 1, !event.sessionID.isEmpty, !event.id.isEmpty,
              event.timestamp.timeIntervalSince1970.isFinite,
              !seenIDs.contains(event.id) else { return }
        seenIDs.insert(event.id)
        seenOrder.append(event.id)
        if seenOrder.count > 4096 { seenIDs.remove(seenOrder.removeFirst()) }

        // Subagent lifecycle hooks carry the parent's session ID. Never close
        // the parent just because one of its children has finished.
        if event.kind == .subagentStart || event.kind == .subagentStop {
            guard let agentID = event.agentID, !agentID.isEmpty else { return }
        }
        let key = Self.key(sessionID: event.sessionID, agentID: event.agentID)
        let parentStart = event.agentID == nil && (event.kind == .sessionStart || event.kind == .userPromptSubmit)
        if let ended = records[event.sessionID]?.endedAt,
           !parentStart || event.timestamp <= ended { return }
        var agent = records[key] ?? Agent(sessionID: event.sessionID, agentID: event.agentID,
                                         project: event.project, updatedAt: .distantPast)
        guard event.timestamp >= agent.updatedAt else { return }
        if event.kind != .sessionEnd, let turn = event.turnID, agent.closedTurns.contains(turn) {
            // Reusing a child inside the same parent turn is a new run.
            guard event.kind == .subagentStart, event.timestamp > agent.updatedAt else { return }
            agent.closedTurns.removeAll { $0 == turn }
        }
        // Terminal events win timestamp ties, including delayed permission hooks.
        if event.kind != .sessionEnd, event.timestamp == agent.updatedAt,
           agent.status == .finished || agent.status == .interrupted { return }

        if event.kind == .userPromptSubmit || event.kind == .subagentStart {
            if agent.turnID != event.turnID { closeTurn(&agent) }
            agent.turnID = event.turnID
            agent.startedAt = event.timestamp
            agent.approvals.removeAll()
            agent.tools.removeAll()
        } else if event.kind != .sessionEnd, let turn = event.turnID {
            if let current = agent.turnID, current != turn { return }
            if agent.status == .finished || agent.status == .interrupted {
                // Only an explicit start can resume a terminal agent.
                return
            }
            agent.turnID = turn
        } else if (agent.status == .finished || agent.status == .interrupted),
                  event.kind != .sessionStart && event.kind != .sessionEnd { return }

        agent.project = event.project
        agent.updatedAt = event.timestamp
        if parentStart || event.kind == .userPromptSubmit || event.kind == .subagentStart { agent.endedAt = nil }
        if event.kind == .sessionEnd { agent.endedAt = event.timestamp }
        switch event.kind {
        case .sessionStart:
            // Session creation/resume alone does not mean a model is working.
            if agent.status != .working { agent.status = .unknown }
        case .userPromptSubmit, .subagentStart:
            agent.status = .working
        case .permissionRequest:
            agent.status = .working
            let snapshot = CodexApprovalSnapshot(id: event.id, sessionID: event.sessionID,
                turnID: event.turnID, project: event.project, summary: event.permissionSummary,
                toolName: event.toolName, requestedAt: event.timestamp, agentID: event.agentID)
            let matching = agent.tools.filter {
                $0.name == event.toolName && $0.fingerprint == event.toolFingerprint
            }
            let correlatedID = event.toolUseID ?? (matching.count == 1 ? matching.first?.id : nil)
            agent.approvals.append(Approval(snapshot: snapshot, toolUseID: correlatedID))
            if agent.approvals.count > 32 { agent.approvals.removeFirst() }
        case .preToolUse, .postToolUse:
            agent.status = .working
            if event.kind == .preToolUse, let id = event.toolUseID, let fingerprint = event.toolFingerprint {
                agent.tools.removeAll { $0.id == id }
                agent.tools.append((id, event.toolName, fingerprint))
                if agent.tools.count > 64 { agent.tools.removeFirst() }
            }
            if event.kind == .postToolUse {
                resolveMatchingApproval(event, in: &agent)
                agent.tools.removeAll { $0.id == event.toolUseID }
            }
        case .stop, .subagentStop, .sessionEnd:
            agent.status = .finished
            closeTurn(&agent)
        case .interrupt:
            agent.status = .interrupted
            closeTurn(&agent)
        }
        records[key] = agent
        if event.kind == .sessionEnd && event.agentID == nil {
            for childKey in Array(records.keys) where childKey != key {
                guard var child = records[childKey], child.sessionID == event.sessionID,
                      child.updatedAt <= event.timestamp else { continue }
                child.status = .finished
                child.updatedAt = event.timestamp
                closeTurn(&child)
                records[childKey] = child
            }
        }
        if records.count > maximumAgents,
           let oldest = records.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
            records.removeValue(forKey: oldest)
        }
    }

    func agents(at now: Date) -> [CodexAgentSnapshot] {
        records.map { key, agent in
            let status: CodexAgentStatus
            if agent.status == .finished || agent.status == .interrupted {
                status = agent.status
            } else if !agent.approvals.isEmpty {
                status = agent.approvals.contains { isFresh($0.snapshot.requestedAt, at: now) }
                    ? .approvalRequested : .unknown
            } else {
                status = isFresh(agent.updatedAt, at: now) ? agent.status : .unknown
            }
            return CodexAgentSnapshot(id: agent.agentID ?? agent.sessionID, project: agent.project,
                name: agent.agentID.map { String($0.prefix(8)) }, status: status, updatedAt: agent.updatedAt,
                parentID: agent.agentID == nil ? nil : agent.sessionID,
                turnID: agent.turnID ?? agent.closedTurns.last, turnStartedAt: agent.startedAt,
                sessionEndedAt: agent.endedAt)
        }.sorted { lhs, rhs in
            lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt > rhs.updatedAt
        }
    }

    func pendingApprovals(at now: Date) -> [CodexApprovalSnapshot] {
        records.values.flatMap(\.approvals).map(\.snapshot)
            .filter { isFresh($0.requestedAt, at: now) }
            .sorted { $0.requestedAt == $1.requestedAt ? $0.id < $1.id : $0.requestedAt < $1.requestedAt }
    }

    private func isFresh(_ date: Date, at now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= 0 && age <= staleAfter
    }

    private static func key(sessionID: String, agentID: String?) -> String {
        guard let agentID else { return sessionID }
        return "\(sessionID)::\(agentID)"
    }

    private func closeTurn(_ agent: inout Agent) {
        if let turn = agent.turnID, !agent.closedTurns.contains(turn) {
            agent.closedTurns.append(turn)
            if agent.closedTurns.count > 64 { agent.closedTurns.removeFirst() }
        }
        agent.turnID = nil
        agent.approvals.removeAll()
        agent.tools.removeAll()
    }

    private func resolveMatchingApproval(_ event: CodexHookEvent, in agent: inout Agent) {
        let candidates = agent.approvals.indices.filter { index in
            let approval = agent.approvals[index]
            guard approval.snapshot.turnID == event.turnID else { return false }
            // Tool names are not identities: another parallel call to the same
            // tool may finish while this request remains unresolved. Without a
            // request ID, only a turn boundary or expiry can clear the warning.
            guard let requestID = approval.toolUseID, !requestID.isEmpty,
                  let outputID = event.toolUseID, !outputID.isEmpty else { return false }
            return requestID == outputID
        }
        if candidates.count == 1, let index = candidates.first {
            agent.approvals.remove(at: index)
        }
    }
}


/// Session files provide recovery and progress while hook delivery is unavailable.
/// Only lifecycle metadata is retained; prompts, tool arguments and output are discarded.
struct CodexSessionActivity {
    var id: String
    var project: String
    var name: String?
    var parentID: String?
    private(set) var turnID: String?
    private(set) var startedAt: Date?
    private var updatedAt = Date.distantPast
    private var status: CodexAgentStatus = .unknown
    private var hasIssue = false
    private var closedTurns: [String] = []

    init(id: String, project: String, name: String?, parentID: String?) {
        self.id = id; self.project = project; self.name = name; self.parentID = parentID
    }

    @discardableResult
    mutating func consume(_ payload: [String: Any], at: Date) -> Bool {
        guard at >= updatedAt, let kind = payload["type"] as? String else { return false }
        let turn = payload["turn_id"] as? String
        switch kind {
        case "task_started":
            guard let turn, !turn.isEmpty, !closedTurns.contains(turn) else { return false }
            if let previous = turnID, previous != turn {
                closedTurns.append(previous)
                if closedTurns.count > 64 { closedTurns.removeFirst() }
            }
            if turnID != turn { startedAt = at }
            turnID = turn
            status = .working
            hasIssue = false
        case "task_complete", "turn_aborted":
            guard let turn, turn == turnID else { return false }
            if kind == "turn_aborted" { status = .interrupted }
            else { status = payload["error"].map { !($0 is NSNull) } == true ? .failed : .finished }
            closedTurns.append(turn)
            if closedTurns.count > 64 { closedTurns.removeFirst() }
            hasIssue = false
        case "token_count", "item_started", "item_completed":
            guard status == .working, turn == nil || turn == turnID else { return false }
            if kind == "item_completed", let item = payload["item"] as? [String: Any] {
                // A failed tool is an issue within a running task, not a failed turn.
                if let exit = item["exitCode"] as? Int { hasIssue = exit != 0 }
                else if let error = item["isError"] as? Bool { hasIssue = error }
            }
        default: return false
        }
        updatedAt = at
        return true
    }

    func snapshot(at now: Date) -> CodexAgentSnapshot? {
        guard updatedAt != .distantPast, updatedAt <= now else { return nil }
        let age = now.timeIntervalSince(updatedAt)
        // Silence never means completion. A fresh log write keeps long turns current.
        let visibleStatus: CodexAgentStatus = status == .working && age > 300 ? .unknown : status
        return CodexAgentSnapshot(id: id, project: project, name: name, status: visibleStatus,
            updatedAt: updatedAt, parentID: parentID, turnID: turnID,
            turnStartedAt: startedAt, hasIssue: hasIssue)
    }
}

struct CodexActivityProjection {
    let agents: [CodexAgentSnapshot]
    let approvals: [CodexApprovalSnapshot]

    init(observed: [CodexAgentSnapshot], hooked: [CodexAgentSnapshot],
         approvals: [CodexApprovalSnapshot]) {
        let sessions = Dictionary(observed.map { ($0.id, $0) }, uniquingKeysWith: {
            $0.updatedAt >= $1.updatedAt ? $0 : $1
        })
        var merged = sessions
        for hook in hooked {
            if let session = sessions[hook.id] {
                if let end = hook.sessionEndedAt {
                    if session.turnStartedAt.map({ $0 > end }) != true {
                        merged[hook.id] = session.closingSession(at: end)
                    }
                    continue
                }
                // A new prompt can reach hooks before its rollout is flushed.
                // A later delivery time alone cannot establish a new turn.
                let newTurn = hook.turnStartedAt.map { $0 > session.updatedAt } == true
                    && (hook.turnID == nil || session.turnID == nil || hook.turnID != session.turnID)
                if let hookTurn = hook.turnID, let sessionTurn = session.turnID,
                   hookTurn != sessionTurn, !newTurn { continue }
                let terminal = [.finished, .interrupted, .failed].contains(session.status)
                if terminal && !newTurn && ((hook.turnID != nil && hook.turnID == session.turnID)
                    || session.updatedAt >= hook.updatedAt) { continue }
                if let start = session.turnStartedAt, hook.updatedAt < start { continue }
                // Log heartbeats must not hide a still-pending approval.
                if hook.status == .approvalRequested || hook.updatedAt > session.updatedAt {
                    let value = CodexAgentSnapshot(id: session.id, project: session.project,
                        name: session.name, status: hook.status, updatedAt: max(session.updatedAt, hook.updatedAt),
                        parentID: session.parentID, turnID: newTurn ? hook.turnID : session.turnID,
                        turnStartedAt: newTurn ? hook.turnStartedAt : session.turnStartedAt,
                        hasIssue: newTurn ? hook.hasIssue : session.hasIssue,
                        conversationTitle: session.conversationTitle)
                    merged[hook.id] = value
                }
            } else { merged[hook.id] = hook }
        }
        CodexAgentSnapshot.closeEndedSessions(in: &merged)
        self.approvals = approvals.filter { approval in
            guard merged[approval.sessionID]?.sessionEndedAt == nil else { return false }
            guard let session = merged[approval.targetID] else { return true }
            if let hookTurn = approval.turnID, let sessionTurn = session.turnID,
               hookTurn != sessionTurn { return false }
            if let start = session.turnStartedAt, approval.requestedAt < start { return false }
            let terminal = [.finished, .interrupted, .failed].contains(session.status)
            return !terminal
        }
        self.agents = merged.values.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
    }
}
