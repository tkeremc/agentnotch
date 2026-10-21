import Foundation
@testable import AgentNotch

@MainActor
struct CodexActivityTests {
    static let cases: [(String, @MainActor () throws -> Void)] = [
        ("Codex hook envelope uses Unix seconds and strips project paths", wireFormat),
        ("Codex permission requests only close on matching output", approvalCorrelation),
        ("Codex ambiguous same-tool requests remain unresolved", ambiguousApproval),
        ("Codex stale requests become unknown rather than completed", staleApproval),
        ("Codex future events are not reported as current activity", futureFreshness),
        ("Codex repeated and delayed hooks cannot resurrect closed turns", ordering),
        ("Codex subagent completion preserves the parent", subagents),
        ("Codex a child can be reassigned inside the same parent turn", childRestart),
        ("Codex session evidence reconciles approvals without duplicates", projection),
        ("Codex session errors and tool issues remain distinct", sessionErrors),
        ("Codex compact indicator prioritizes approvals and errors", indicator),
        ("Codex missing approval IDs correlate only with unique pre-tool calls", preToolCorrelation),
        ("Codex interrupt and session end clear only their scope", interruption),
        ("Codex active records and replay deduplication stay bounded", bounds)
    ]

    private struct Failure: Error { let message: String }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private static func event(_ kind: CodexHookEvent.Kind, _ seconds: TimeInterval,
                              session: String = "session", turn: String? = "turn-1",
                              agent: String? = nil, tool: String? = nil,
                              toolID: String? = nil, id: String = UUID().uuidString) -> CodexHookEvent {
        CodexHookEvent(id: id, kind: kind, timestamp: epoch.addingTimeInterval(seconds),
                       sessionID: session, turnID: turn, agentID: agent, project: "/Users/example/agentnotch",
                       toolName: tool, toolUseID: toolID, permissionSummary: "Network access")
    }

    private static func wireFormat() throws {
        let source = event(.permissionRequest, 0.25, tool: "shell", toolID: "call-1")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601 // Envelope deliberately overrides this.
        let data = try encoder.encode(source)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try expect(object["timestamp"] as? Double == epoch.timeIntervalSince1970 + 0.25, "Unix seconds")
        try expect(object["kind"] as? String == "PermissionRequest", "Pascal wire name")
        try expect(object["project"] as? String == "agentnotch", "project must not contain full path")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CodexHookEvent.self, from: data)
        try expect(decoded == source, "envelope must round-trip without decoder configuration")
        var state = CodexActivityState()
        state.consume(CodexHookEvent(schemaVersion: 2, kind: .userPromptSubmit,
                                    sessionID: "future", project: "future"))
        try expect(state.agents(at: epoch).isEmpty, "unsupported schemas must not change state")
    }

    private static func approvalCorrelation() throws {
        var state = CodexActivityState()
        state.consume(event(.userPromptSubmit, 0))
        state.consume(event(.permissionRequest, 1, tool: "shell", toolID: "shell-1", id: "request-1"))
        state.consume(event(.permissionRequest, 2, tool: "read", toolID: "read-1", id: "request-2"))
        state.consume(event(.postToolUse, 3, tool: "shell", toolID: "shell-other"))
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(3)).count == 2,
                   "unrelated output must not acknowledge requests")
        state.consume(event(.postToolUse, 4, tool: "shell", toolID: "shell-1"))
        let approvals = state.pendingApprovals(at: epoch.addingTimeInterval(4))
        try expect(approvals.map(\.id) == ["request-2"], "only the matched tool request closes")
        try expect(state.agents(at: epoch.addingTimeInterval(4)).first?.status == .approvalRequested,
                   "other pending request keeps the warning")
        state.consume(event(.postToolUse, 5, tool: "read", toolID: "read-1"))
        try expect(state.agents(at: epoch.addingTimeInterval(5)).first?.status == .working,
                   "tool output resumes working without declaring the whole task finished")
    }

    private static func ambiguousApproval() throws {
        var state = CodexActivityState()
        state.consume(event(.permissionRequest, 0, tool: "shell"))
        state.consume(event(.permissionRequest, 1, tool: "shell"))
        state.consume(event(.postToolUse, 2, tool: "shell", toolID: "output-1"))
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(2)).count == 2,
                   "ambiguous requests without IDs cannot safely be cleared")
        state.consume(event(.stop, 3))
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(3)).isEmpty, "stop closes its requests")
        var single = CodexActivityState()
        single.consume(event(.permissionRequest, 0, tool: "shell"))
        single.consume(event(.postToolUse, 1, tool: "shell", toolID: "parallel-output"))
        single.consume(event(.postToolUse, 2, tool: "shell"))
        try expect(single.pendingApprovals(at: epoch.addingTimeInterval(2)).count == 1,
                   "even a single ID-less request cannot be resolved by another same-tool output")
        single.consume(event(.userPromptSubmit, 3, turn: "turn-2"))
        try expect(single.pendingApprovals(at: epoch.addingTimeInterval(3)).isEmpty,
                   "explicit new turn clears unresolved ID-less requests")
    }

    private static func staleApproval() throws {
        var state = CodexActivityState()
        state.consume(event(.permissionRequest, 0, tool: "shell"))
        try expect(state.agents(at: epoch.addingTimeInterval(299)).first?.status == .approvalRequested,
                   "fresh request is visible")
        try expect(state.agents(at: epoch.addingTimeInterval(301)).first?.status == .unknown,
                   "replayed or stale approval is unknown, never finished")
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(301)).isEmpty,
                   "stale warnings must not remain urgent")
        state.consume(event(.postToolUse, 302, tool: "read"))
        try expect(state.agents(at: epoch.addingTimeInterval(302)).first?.status == .unknown,
                   "unrelated fresh work does not confirm an old permission was resolved")
    }

    private static func futureFreshness() throws {
        var state = CodexActivityState()
        state.consume(event(.permissionRequest, 30, tool: "shell"))
        try expect(state.pendingApprovals(at: epoch).isEmpty,
                   "a future request is not a fresh warning")
        try expect(state.agents(at: epoch).first?.status == .unknown,
                   "future activity is unknown until its timestamp is reached")
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(30)).count == 1,
                   "a request becomes fresh once its timestamp is reached")
        var working = CodexActivityState()
        working.consume(event(.userPromptSubmit, 30))
        try expect(working.agents(at: epoch).first?.status == .unknown,
                   "future working state is not currently working")
    }

    private static func ordering() throws {
        var state = CodexActivityState()
        let request = event(.permissionRequest, 1, tool: "shell", id: "request")
        state.consume(event(.userPromptSubmit, 0))
        state.consume(request)
        state.consume(request)
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(1)).count == 1, "id deduplication")
        state.consume(event(.stop, 2))
        state.consume(event(.permissionRequest, 1.5, tool: "shell"))
        state.consume(event(.permissionRequest, 3, tool: "shell"))
        try expect(state.agents(at: epoch.addingTimeInterval(3)).first?.status == .finished,
                   "delayed events from a closed turn cannot restart it")
        state.consume(event(.userPromptSubmit, 4, turn: "turn-2"))
        state.consume(event(.permissionRequest, 5, tool: "shell"))
        try expect(state.agents(at: epoch.addingTimeInterval(5)).first?.status == .working,
                   "an old-turn request cannot overwrite the new turn")
        state.consume(event(.permissionRequest, 6, turn: "turn-2", tool: "read"))
        state.consume(event(.postToolUse, 5.5, turn: "turn-2", tool: "read"))
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(6)).count == 1,
                   "an output older than a request cannot dismiss it")
        state.consume(event(.stop, 6, turn: "turn-2"))
        state.consume(event(.permissionRequest, 6, turn: nil, tool: "shell"))
        try expect(state.agents(at: epoch.addingTimeInterval(6)).first?.status == .finished,
                   "terminal state wins tied timestamps")
    }

    private static func subagents() throws {
        var state = CodexActivityState()
        state.consume(event(.userPromptSubmit, 0))
        state.consume(event(.subagentStart, 1, agent: "reviewer"))
        state.consume(event(.subagentStop, 2, agent: "reviewer"))
        let snapshots = state.agents(at: epoch.addingTimeInterval(2))
        try expect(snapshots.count == 2, "parent and child have separate identities")
        try expect(snapshots.first { $0.id == "session" }?.status == .working,
                   "SubagentStop must not finish the parent")
        try expect(snapshots.first { $0.name == "reviewer" }?.status == .finished, "child finishes")
        state.consume(event(.subagentStop, 3))
        try expect(state.agents(at: epoch.addingTimeInterval(3)).first { $0.id == "session" }?.status == .working,
                   "malformed child events must not affect the parent")
    }

    private static func preToolCorrelation() throws {
        var state = CodexActivityState()
        func call(_ kind: CodexHookEvent.Kind, _ time: Double, _ id: String?) -> CodexHookEvent {
            CodexHookEvent(kind: kind, timestamp: epoch.addingTimeInterval(time), sessionID: "s",
                turnID: "t", project: "p", toolName: "Bash", toolUseID: id, toolFingerprint: "opaque")
        }
        state.consume(call(.preToolUse, 0, "call-a"))
        state.consume(call(.permissionRequest, 1, nil))
        state.consume(call(.postToolUse, 2, "call-b"))
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(2)).count == 1,
                   "unrelated parallel call does not clear request")
        state.consume(call(.postToolUse, 3, "call-a"))
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(3)).isEmpty,
                   "unique pre-tool identity resolves ID-less request")
        var ambiguous = CodexActivityState()
        ambiguous.consume(call(.preToolUse, 0, "a"))
        ambiguous.consume(call(.preToolUse, 1, "b"))
        ambiguous.consume(call(.permissionRequest, 2, nil))
        ambiguous.consume(call(.postToolUse, 3, "a"))
        try expect(ambiguous.pendingApprovals(at: epoch.addingTimeInterval(3)).count == 1,
                   "identical parallel inputs cannot be guessed")
    }

    private static func childRestart() throws {
        var state = CodexActivityState()
        state.consume(event(.subagentStart, 1, agent: "child"))
        state.consume(event(.subagentStop, 2, agent: "child"))
        state.consume(event(.subagentStart, 3, agent: "child"))
        try expect(state.agents(at: epoch.addingTimeInterval(3)).first?.status == .working,
                   "follow-up child work in the same parent turn must resume")
        state.consume(event(.subagentStop, 2.5, agent: "child"))
        try expect(state.agents(at: epoch.addingTimeInterval(3)).first?.status == .working,
                   "an older terminal event must not finish the new run")
    }

    private static func projection() throws {
        let now = epoch.addingTimeInterval(20)
        let session = CodexAgentSnapshot(id: "child", project: "project", name: "Goodall",
            status: .working, updatedAt: now, parentID: "parent", turnID: "child-turn",
            turnStartedAt: epoch)
        let hook = CodexAgentSnapshot(id: "child", project: "project", name: "child",
            status: .approvalRequested, updatedAt: epoch.addingTimeInterval(10), parentID: "parent")
        let approval = CodexApprovalSnapshot(id: "request", sessionID: "child", turnID: "child-turn",
            project: "project", summary: nil, toolName: "Bash", requestedAt: epoch.addingTimeInterval(10))
        let pending = CodexActivityProjection(observed: [session], hooked: [hook], approvals: [approval])
        try expect(pending.agents.count == 1 && pending.agents[0].name == "Goodall",
                   "child thread metadata and hook identity must merge")
        try expect(pending.agents[0].status == .approvalRequested && pending.approvals.count == 1,
                   "a later log heartbeat cannot clear approval")
        var finished = session
        finished = CodexAgentSnapshot(id: "child", project: "project", name: "Goodall",
            status: .finished, updatedAt: now, parentID: "parent", turnID: "child-turn", turnStartedAt: epoch)
        let old = CodexAgentSnapshot(id: "child", project: "project", name: "child",
            status: .finished, updatedAt: now.addingTimeInterval(1), parentID: "parent", turnID: "older-turn")
        let unchanged = CodexActivityProjection(observed: [session], hooked: [old], approvals: [])
        try expect(unchanged.agents[0].status == .working,
                   "late old-turn hook cannot finish a newer logged turn")
        let childApproval = CodexApprovalSnapshot(id: "child-approval", sessionID: "parent", turnID: "child-turn",
            project: "project", summary: nil, toolName: nil, requestedAt: epoch.addingTimeInterval(10), agentID: "child")
        let childClosed = CodexActivityProjection(observed: [finished], hooked: [], approvals: [childApproval])
        try expect(childClosed.approvals.isEmpty, "child completion resolves its own approval")
        let closed = CodexActivityProjection(observed: [finished], hooked: [hook], approvals: [approval])
        try expect(closed.agents[0].status == .finished && closed.approvals.isEmpty,
                   "matching logged completion clears stale hook state")
        let lateHook = CodexAgentSnapshot(id: "child", project: "project", name: "child",
            status: .approvalRequested, updatedAt: now.addingTimeInterval(5), parentID: "parent", turnID: "child-turn")
        let lateRequest = CodexApprovalSnapshot(id: "late", sessionID: "child", turnID: "child-turn",
            project: "project", summary: nil, toolName: nil, requestedAt: now.addingTimeInterval(5))
        let late = CodexActivityProjection(observed: [finished], hooked: [lateHook], approvals: [lateRequest])
        try expect(late.agents[0].status == .finished && late.approvals.isEmpty,
                   "same-turn terminal evidence wins over a later-delivered hook")
    }

    private static func sessionErrors() throws {
        var session = CodexSessionActivity(id: "s", project: "p", name: nil, parentID: nil)
        session.consume(["type": "task_started", "turn_id": "t"], at: epoch)
        session.consume(["type": "item_completed", "turn_id": "t",
            "item": ["exitCode": 1]], at: epoch.addingTimeInterval(1))
        try expect(session.snapshot(at: epoch.addingTimeInterval(1))?.hasIssue == true,
                   "nonzero tool exit is visible")
        try expect(session.snapshot(at: epoch.addingTimeInterval(1))?.status == .working,
                   "tool failure does not finish a working agent")
        session.consume(["type": "task_complete", "turn_id": "other", "error": "old"],
                        at: epoch.addingTimeInterval(2))
        try expect(session.snapshot(at: epoch.addingTimeInterval(2))?.status == .working,
                   "unrelated turn completion is ignored")
        session.consume(["type": "task_complete", "turn_id": "t", "error": "limit"],
                        at: epoch.addingTimeInterval(3))
        try expect(session.snapshot(at: epoch.addingTimeInterval(3))?.status == .failed,
                   "terminal task failure is distinct from success")
    }

    private static func indicator() throws {
        let working = CodexAgentSnapshot(id: "s", project: "p", name: nil,
            status: .working, updatedAt: epoch)
        try expect(CodexIndicator.resolve(agents: [working], approvals: [], connection: .notInstalled,
            now: epoch) == .working, "local session activity is visible before hook installation")
        let approval = CodexApprovalSnapshot(id: "p", sessionID: "s", turnID: nil,
            project: "p", summary: nil, toolName: nil, requestedAt: epoch)
        try expect(CodexIndicator.resolve(agents: [working], approvals: [approval], connection: .receiving,
            now: epoch) == .approval, "approval takes priority over working")
        let failed = CodexAgentSnapshot(id: "s", project: "p", name: nil,
            status: .failed, updatedAt: epoch)
        try expect(CodexIndicator.resolve(agents: [failed], approvals: [], connection: .receiving,
            now: epoch) == .failed, "failure is shown compactly")
        try expect(CodexIndicator.resolve(agents: [failed], approvals: [], connection: .receiving,
            now: epoch.addingTimeInterval(301)) == .none, "old failures do not keep the notch alert forever")
    }

    private static func interruption() throws {
        var state = CodexActivityState()
        state.consume(event(.permissionRequest, 0, session: "one", tool: "shell"))
        state.consume(event(.permissionRequest, 1, session: "two", tool: "read"))
        state.consume(event(.interrupt, 2, session: "one"))
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(2)).map(\.sessionID) == ["two"],
                   "interrupt must preserve other sessions")
        try expect(state.agents(at: epoch.addingTimeInterval(2)).first { $0.id == "one" }?.status == .interrupted,
                   "interrupt is distinct from successful completion")
        state.consume(event(.subagentStart, 3, session: "two", agent: "child"))
        state.consume(event(.sessionEnd, 4, session: "two", turn: nil))
        try expect(state.agents(at: epoch.addingTimeInterval(4)).filter { $0.id.hasPrefix("two") }
            .allSatisfy { $0.status == .finished }, "session end closes its children")
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(4)).isEmpty, "session end clears warnings")
    }

    private static func bounds() throws {
        var state = CodexActivityState()
        for index in 0..<300 {
            state.consume(event(.userPromptSubmit, Double(index), session: "session-\(index)"))
        }
        try expect(state.agents(at: epoch.addingTimeInterval(300)).count == 256, "agent state is bounded")
        try expect(!state.agents(at: epoch.addingTimeInterval(300)).contains { $0.id == "session-0" },
                   "oldest record is evicted first")
        for index in 0..<40 {
            state.consume(event(.permissionRequest, 400 + Double(index), session: "pending", tool: "tool-\(index)"))
        }
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(440)).count == 32,
                   "pending requests are bounded per agent")
    }
}
