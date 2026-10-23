import Foundation
@testable import AgentNotch

@MainActor
struct ClaudeActivityTests {
    static let cases: [(String, @MainActor () throws -> Void)] = [
        ("Claude hook wire dates and project privacy", wire),
        ("Claude permissions correlate only with matching tool IDs", permission),
        ("Claude missing permission ID uses unique input fingerprint", fingerprint),
        ("Claude child completion and parent session end keep scope", children),
        ("Claude duplicate and delayed events cannot reopen terminal work", ordering),
        ("Claude status line and stale events never fabricate running work", freshness),
        ("Claude tool errors and terminal failures remain distinct", failures),
        ("Claude official quota windows expire without fabricated reset values", usage),
        ("Claude quota survives idle time until each reported reset", idleUsage),
        ("Claude partial quota updates preserve the other reported window", partialUsage),
        ("Claude active records remain bounded", bounds),
        ("Claude session end fences unknown late children until an explicit restart", sessionClosure),
        ("Claude new tool execution after a vetoed stop resumes activity", continuation),
        ("Claude question tools and input notifications use a separate status", questions)
    ]
    private struct Failure: Error { let message: String }
    private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private static func questions() throws {
        var state = ClaudeActivityState()
        state.consume(event(.userPromptSubmit, 0))
        state.consume(ClaudeHookEvent(kind: .preToolUse, timestamp: epoch.addingTimeInterval(1),
            sessionID: "main", project: "p", toolName: "AskUserQuestion", toolUseID: "question"))
        state.consume(event(.postToolUse, 2, toolID: "parallel"))
        let waiting = state.agents(at: epoch.addingTimeInterval(2))
        try expect(waiting.first?.status == .awaitingInput, "parallel output cannot answer AskUserQuestion")
        try expect(CodexCompactAgent.make(agents: waiting, approvals: [], connection: .receiving,
            now: epoch.addingTimeInterval(2)).first?.indicator == .question, "question reaches compact badge")
        state.consume(event(.postToolUse, 3, toolID: "question"))
        try expect(state.agents(at: epoch.addingTimeInterval(3)).first?.status == .working, "matching answer resumes")
        state.consume(ClaudeHookEvent(kind: .notification, timestamp: epoch.addingTimeInterval(4),
            sessionID: "main", project: "p", notificationType: "elicitation_dialog"))
        try expect(state.agents(at: epoch.addingTimeInterval(4)).first?.status == .awaitingInput, "MCP input notification is a question")
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(4)).isEmpty, "elicitation is not permission")
        state.consume(event(.preToolUse, 5, toolID: "next"))
        try expect(state.agents(at: epoch.addingTimeInterval(5)).first?.status == .working, "new execution resolves uncorrelated input notification")
        state.consume(event(.stopFailure, 6))
        let failed = state.agents(at: epoch.addingTimeInterval(6))
        let other = CodexAgentSnapshot(id: "other", project: "p", name: nil, status: .working, updatedAt: epoch)
        let icons = CodexCompactAgent.make(agents: failed + [other], approvals: [], connection: .receiving,
            now: epoch.addingTimeInterval(6))
        try expect(icons.first { $0.id == "main" }?.indicator == .failed, "failure retains the agent identity beside another worker")
    }
    private static func sessionClosure() throws {
        var state = ClaudeActivityState()
        state.consume(event(.userPromptSubmit, 0))
        state.consume(event(.subagentStart, 1, agent: "known"))
        state.consume(event(.sessionEnd, 2))
        state.consume(event(.preToolUse, 3, agent: "unknown"))
        state.consume(event(.subagentStart, 4, agent: "later"))
        state.consume(event(.permissionRequest, 5, agent: "unknown"))
        let now = epoch.addingTimeInterval(5)
        try expect(state.agents(at: now).allSatisfy { !$0.isActive(at: now) } && state.pendingApprovals(at: now).isEmpty,
                   "late child events cannot recreate work under an ended session")
        state.consume(event(.userPromptSubmit, 6))
        state.consume(event(.subagentStart, 7, agent: "later"))
        try expect(state.agents(at: epoch.addingTimeInterval(7)).filter { $0.isActive(at: epoch.addingTimeInterval(7)) }.count == 2,
                   "new explicit parent start allows new children")
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    private static func event(_ kind: ClaudeHookEvent.Kind, _ seconds: Double,
                              session: String = "main", agent: String? = nil,
                              toolID: String? = nil, fingerprint: String? = nil,
                              id: String = UUID().uuidString) -> ClaudeHookEvent {
        ClaudeHookEvent(id: id, kind: kind, timestamp: epoch.addingTimeInterval(seconds),
            sessionID: session, agentID: agent, project: "/private/project", toolName: "Bash",
            toolUseID: toolID, toolFingerprint: fingerprint)
    }
    private static func wire() throws {
        let source = event(.permissionRequest, 0.25)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(source)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try expect(object["timestamp"] as? Double == epoch.timeIntervalSince1970 + 0.25, "epoch wire date")
        try expect(object["project"] as? String == "project", "project basename only")
        let decoded = try JSONDecoder().decode(ClaudeHookEvent.self, from: data)
        try expect(decoded == source, "round trip")
    }
    private static func permission() throws {
        var state = ClaudeActivityState()
        state.consume(event(.userPromptSubmit, 0))
        state.consume(event(.permissionRequest, 1, toolID: "requested"))
        state.consume(event(.postToolUse, 2, toolID: "parallel"))
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(2)).count == 1, "parallel tool cannot clear permission")
        state.consume(event(.postToolUseFailure, 3, toolID: "requested"))
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(3)).isEmpty, "matching failure resolves permission")
    }
    private static func fingerprint() throws {
        var state = ClaudeActivityState()
        state.consume(event(.preToolUse, 0, toolID: "a", fingerprint: "hash"))
        state.consume(event(.permissionRequest, 1, fingerprint: "hash"))
        state.consume(event(.postToolUse, 2, toolID: "a"))
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(2)).isEmpty, "unique fingerprint correlates missing ID")
        state.consume(event(.preToolUse, 3, toolID: "b", fingerprint: "same"))
        state.consume(event(.preToolUse, 4, toolID: "c", fingerprint: "same"))
        state.consume(event(.permissionRequest, 5, fingerprint: "same"))
        state.consume(event(.postToolUse, 6, toolID: "b"))
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(6)).count == 1, "ambiguous input never guesses")
    }
    private static func children() throws {
        var state = ClaudeActivityState()
        state.consume(event(.userPromptSubmit, 0))
        state.consume(event(.subagentStart, 1, agent: "child"))
        state.consume(event(.subagentStop, 2, agent: "child"))
        try expect(state.agents(at: epoch.addingTimeInterval(2)).first { !$0.isSubagent }?.status == .working, "child stop preserves parent")
        state.consume(event(.subagentStart, 3, agent: "child"))
        state.consume(event(.subagentStart, 4, session: "other", agent: "child"))
        try expect(Set(state.agents(at: epoch.addingTimeInterval(4)).map(\.id)).count == 3, "child IDs are session scoped")
        state.consume(event(.sessionEnd, 5))
        let snapshots = state.agents(at: epoch.addingTimeInterval(5))
        try expect(snapshots.filter { $0.parentID == "main" || $0.id == "main" }.allSatisfy { $0.status == .finished }, "session end closes children")
        try expect(snapshots.first { $0.parentID == "other" }?.status == .working, "other session preserved")
    }
    private static func ordering() throws {
        var state = ClaudeActivityState()
        state.consume(event(.userPromptSubmit, 0))
        let stop = event(.stop, 3)
        state.consume(stop); state.consume(stop)
        state.consume(event(.permissionRequest, 1))
        state.consume(event(.preToolUse, 3))
        state.consume(event(.postToolUse, 4))
        state.consume(event(.userPromptSubmit, 3))
        try expect(state.agents(at: epoch.addingTimeInterval(4)).first?.status == .finished, "late and tied hooks cannot reopen")
        state.consume(event(.userPromptSubmit, 5))
        try expect(state.agents(at: epoch.addingTimeInterval(5)).first?.status == .working, "explicit newer prompt opens new work")
    }
    private static func freshness() throws {
        var state = ClaudeActivityState(staleAfter: 10)
        state.consume(event(.statusLine, 0))
        try expect(state.agents(at: epoch).isEmpty, "idle statusline creates no phantom agent")
        state.consume(event(.userPromptSubmit, 1))
        state.consume(event(.statusLine, 9))
        try expect(state.agents(at: epoch.addingTimeInterval(12)).first?.status == .unknown, "statusline never prolongs active work")
        state.consume(event(.permissionRequest, 13))
        try expect(state.pendingApprovals(at: epoch.addingTimeInterval(24)).isEmpty, "old permissions expire")
        try expect(state.agents(at: epoch.addingTimeInterval(24)).first?.status == .unknown, "silence is unknown, not complete")
    }
    private static func continuation() throws {
        var state = ClaudeActivityState()
        state.consume(event(.userPromptSubmit, 0))
        state.consume(event(.stop, 1))
        state.consume(event(.preToolUse, 2, toolID: "new"))
        try expect(state.agents(at: epoch.addingTimeInterval(2)).first?.status == .working,
                   "a Stop hook can be vetoed; a strictly newer tool start proves continuation")
        state.consume(event(.stop, 3))
        state.consume(event(.permissionRequest, 4, toolID: "permission"))
        try expect(state.agents(at: epoch.addingTimeInterval(4)).first?.status == .approvalRequested,
                   "a new permission request proves an agent is waiting again")
        state.consume(event(.sessionEnd, 5))
        state.consume(event(.preToolUse, 6))
        try expect(state.agents(at: epoch.addingTimeInterval(6)).first?.status == .finished,
                   "a completed session cannot continue without an explicit parent restart")
    }
    private static func failures() throws {
        var state = ClaudeActivityState()
        state.consume(event(.postToolUseFailure, 0))
        try expect(state.agents(at: epoch).first?.status == .working && state.agents(at: epoch).first?.hasIssue == true, "tool failure is a running issue")
        state.consume(event(.stopFailure, 1))
        try expect(state.agents(at: epoch.addingTimeInterval(1)).first?.status == .failed, "terminal model error")
    }
    private static func usage() throws {
        var state = ClaudeUsageState()
        let event = ClaudeHookEvent(kind: .statusLine, timestamp: epoch, sessionID: "main", project: "fixture",
            fiveHourUsedPercent: 35, fiveHourResetsAt: epoch.addingTimeInterval(60).timeIntervalSince1970,
            sevenDayUsedPercent: 80, sevenDayResetsAt: epoch.addingTimeInterval(120).timeIntervalSince1970)
        state.consume(event, now: epoch)
        try expect(state.current(at: epoch)?.primary?.remainingPercent == 65, "official used percentage is converted accurately")
        try expect(state.current(at: epoch.addingTimeInterval(61))?.primary == nil, "expired window is unknown")
        try expect(state.current(at: epoch.addingTimeInterval(61))?.secondary?.usedPercent == 80, "other window retained")
        try expect(state.current(at: epoch.addingTimeInterval(121)) == nil, "reset never fabricates zero")
        try expect(state.current(at: epoch.addingTimeInterval(-1)) == nil, "future snapshot hidden")
        let invalid = ClaudeHookEvent(kind: .statusLine, timestamp: epoch.addingTimeInterval(1), sessionID: "main", project: "fixture",
            fiveHourUsedPercent: 101, fiveHourResetsAt: epoch.addingTimeInterval(100).timeIntervalSince1970)
        state.consume(invalid, now: epoch.addingTimeInterval(1))
        try expect(state.current(at: epoch.addingTimeInterval(1))?.primary?.usedPercent == 35, "invalid percentages cannot replace valid snapshot")
    }
    private static func bounds() throws {
        var state = ClaudeActivityState()
        for index in 0..<300 { state.consume(event(.userPromptSubmit, Double(index), session: "s\(index)")) }
        try expect(state.agents(at: epoch.addingTimeInterval(300)).count == 256, "bounded records")
    }

    private static func idleUsage() throws {
        var state = ClaudeUsageState()
        let reset = epoch.addingTimeInterval(5 * 3600)
        let weeklyReset = epoch.addingTimeInterval(7 * 86400)
        state.consume(ClaudeHookEvent(kind: .statusLine, timestamp: epoch, sessionID: "main", project: "fixture",
            fiveHourUsedPercent: 35, fiveHourResetsAt: reset.timeIntervalSince1970,
            sevenDayUsedPercent: 80, sevenDayResetsAt: weeklyReset.timeIntervalSince1970), now: epoch)
        for seconds: TimeInterval in [900, 901, 3600, 5 * 3600 - 1] {
            let snapshot = state.current(at: epoch.addingTimeInterval(seconds))
            try expect(snapshot?.primary?.usedPercent == 35 && snapshot?.secondary?.usedPercent == 80,
                       "idle time must not discard unexpired reported limits")
            try expect(snapshot?.observedAt == epoch, "retaining quota must not pretend it was refreshed")
        }
        try expect(state.current(at: reset)?.primary == nil, "five-hour quota expires exactly at its reset")
        try expect(state.current(at: reset)?.secondary?.usedPercent == 80, "weekly quota survives the five-hour reset")
        try expect(state.current(at: weeklyReset) == nil, "no fabricated usage after both resets")
    }

    private static func partialUsage() throws {
        var state = ClaudeUsageState()
        let reset = epoch.addingTimeInterval(5 * 3600).timeIntervalSince1970
        let weeklyReset = epoch.addingTimeInterval(7 * 86400).timeIntervalSince1970
        state.consume(ClaudeHookEvent(kind: .statusLine, timestamp: epoch, sessionID: "main", project: "fixture",
            fiveHourUsedPercent: 35, fiveHourResetsAt: reset,
            sevenDayUsedPercent: 80, sevenDayResetsAt: weeklyReset), now: epoch)
        let next = epoch.addingTimeInterval(1000)
        state.consume(ClaudeHookEvent(kind: .statusLine, timestamp: next, sessionID: "other", project: "fixture",
            fiveHourUsedPercent: 40, fiveHourResetsAt: reset), now: next)
        try expect(state.current(at: next)?.primary?.usedPercent == 40, "new reported window replaces its old value")
        try expect(state.current(at: next)?.secondary?.usedPercent == 80, "omitted window retains its last reported value")
        let later = next.addingTimeInterval(1)
        state.consume(ClaudeHookEvent(kind: .statusLine, timestamp: later, sessionID: "other", project: "fixture",
            fiveHourUsedPercent: 101, fiveHourResetsAt: reset,
            sevenDayUsedPercent: 81, sevenDayResetsAt: weeklyReset), now: later)
        try expect(state.current(at: later)?.primary?.usedPercent == 40, "invalid partial window cannot erase valid data")
        try expect(state.current(at: later)?.secondary?.usedPercent == 81, "weekly-only update is applied")
        state.consume(ClaudeHookEvent(kind: .statusLine, timestamp: later.addingTimeInterval(1),
            sessionID: "empty", project: "fixture"), now: later.addingTimeInterval(1))
        try expect(state.current(at: later.addingTimeInterval(1))?.primary?.usedPercent == 40,
                   "a status line without quota cannot erase reported usage")
        state.consume(ClaudeHookEvent(kind: .statusLine, timestamp: epoch, sessionID: "delayed", project: "fixture",
            fiveHourUsedPercent: 10, fiveHourResetsAt: reset), now: later)
        try expect(state.current(at: later)?.primary?.usedPercent == 40, "delayed quota cannot overwrite newer evidence")
    }
}
