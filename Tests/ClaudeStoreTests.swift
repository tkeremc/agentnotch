import Darwin
import Foundation
@testable import AgentNotch

@MainActor
enum ClaudeStoreTests {
    static let cases: [(String, @MainActor () throws -> Void)] = [
        ("Claude discovers real and configured homes without symlinks", discovery),
        ("Claude connection installation requires explicit consent", consent),
        ("Claude spool safely reads lifecycle and official quota events", monitor),
        ("Claude monitor retains idle quota across ticks and cache reconstruction", idleQuota),
        ("Claude compact agents retain provider and hierarchy through store updates", compactRoles),
        ("Claude spool rejects links and oversized files", safety),
        ("Claude runtime metadata requires a matching live process and transition time", runtime),
        ("Claude newer runtime state reconciles denied permissions", projection),
        ("Claude native PID matching uses UTC process start and rejects reused identities", nativeProcess),
        ("Claude lost runtime identity cannot resurrect parent or child hooks", lostRuntime)
    ]
    private struct Failure: Error { let message: String }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    private static func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private static func helper() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["AGENTNOTCH_TEST_CLAUDE_HELPER"] else {
            throw Failure(message: "Tests/run.sh must supply Claude helper")
        }
        return URL(fileURLWithPath: path)
    }
    private static func waitUntil(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try expect(condition(), "background operation timed out")
    }
    private static func discovery() throws {
        try fixture { root in
            let custom = root.appendingPathComponent("custom")
            try expect(ClaudeLocations.configuredHome(environment: ["CLAUDE_CONFIG_DIR": custom.path], standardHome: root).path == custom.path, "explicit config dir")
            try expect(ClaudeLocations.configuredHome(environment: ["CLAUDE_CONFIG_DIR": "relative"], standardHome: root).path == root.path, "relative override rejected")
            try expect(ClaudeLocations.discover(home: custom) == nil, "missing custom dir is not created")
            try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: custom)
            try expect(ClaudeLocations.discover(home: link) == nil, "symlink home not followed")
        }
    }
    private static func consent() throws {
        try fixture { home in
            let source = try helper()
            let store = ClaudeStore(claudeHome: home, helperSource: source)
            store.refreshConnection()
            store.connect { _ in false }
            try waitUntil { !store.isChangingConnection }
            try expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("settings.json").path), "cancelled connection writes nothing")
            store.connect { _ in true }
            try waitUntil { !store.isChangingConnection }
            try expect(ClaudeHookInstaller(claudeHome: home, helperSource: source).isInstalled, "consented fixture installation")
            store.disconnect()
            try waitUntil { !store.isChangingConnection }
            try expect(!ClaudeHookInstaller(claudeHome: home, helperSource: source).isInstalled, "fixture integration removed")
        }
    }
    private static func spool(_ event: ClaudeHookEvent, home: URL) throws {
        let directory = home.appendingPathComponent("agentnotch/events")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(event).write(to: directory.appendingPathComponent("\(event.id).json"))
    }
    private static func monitor() throws {
        try fixture { home in
            let source = try helper()
            try ClaudeHookInstaller(claudeHome: home, helperSource: source).install()
            let now = Date()
            try spool(ClaudeHookEvent(kind: .userPromptSubmit, timestamp: now.addingTimeInterval(-2), sessionID: "main", project: "fixture"), home: home)
            try spool(ClaudeHookEvent(kind: .statusLine, timestamp: now.addingTimeInterval(-1), sessionID: "main", project: "fixture",
                fiveHourUsedPercent: 25, fiveHourResetsAt: now.addingTimeInterval(60).timeIntervalSince1970), home: home)
            let monitor = ClaudeMonitor(home: home, helperSource: source)
            let result = monitor.poll(now: now)
            try expect(result.connection == .receiving && result.agents.first?.status == .working, "hook reaches live state")
            try expect(result.usage.snapshot?.primary?.remainingPercent == 75, "quota reaches monitor")
            let expired = monitor.poll(now: now.addingTimeInterval(301))
            try expect(expired.usage.snapshot == nil && expired.agents.first?.status == .unknown, "expired data is honest")
            try expect(expired.connection == .waitingForEvents, "silence does not indicate connection failure")
        }
    }
    private static func idleQuota() throws {
        try fixture { home in
            let source = try helper()
            try ClaudeHookInstaller(claudeHome: home, helperSource: source).install()
            let now = Date()
            try spool(ClaudeHookEvent(kind: .statusLine, timestamp: now, sessionID: "main", project: "fixture",
                fiveHourUsedPercent: 25, fiveHourResetsAt: now.addingTimeInterval(5 * 3600).timeIntervalSince1970,
                sevenDayUsedPercent: 60, sevenDayResetsAt: now.addingTimeInterval(7 * 86400).timeIntervalSince1970), home: home)
            let monitor = ClaudeMonitor(home: home, helperSource: source)
            _ = monitor.poll(now: now)
            let later = now.addingTimeInterval(3600)
            let idle = monitor.poll(now: later, changes: MonitorChanges())
            try expect(idle.usage.snapshot?.primary?.remainingPercent == 75 && idle.usage.availability == .available,
                       "memory-only tick retains quota beyond fifteen minutes")
            try expect(idle.connection == .waitingForEvents, "idle quota is independent of activity freshness")
            try expect(monitor.eventScanCount == 1, "retaining quota adds no spool scans")
            let rebuilt = ClaudeMonitor(home: home, helperSource: source).poll(now: later)
            try expect(rebuilt.usage.snapshot == idle.usage.snapshot,
                       "reopening the widget reconstructs the same quota from local events")
            let reset = monitor.poll(now: now.addingTimeInterval(5 * 3600), changes: MonitorChanges())
            try expect(reset.usage.snapshot?.primary == nil && reset.usage.snapshot?.secondary?.usedPercent == 60,
                       "only the expired window is removed")
        }
    }
    private static func compactRoles() throws {
        try fixture { home in
            let source = try helper()
            try ClaudeHookInstaller(claudeHome: home, helperSource: source).install()
            let now = Date().addingTimeInterval(-3)
            try spool(ClaudeHookEvent(kind: .userPromptSubmit, timestamp: now,
                sessionID: "main", project: "fixture"), home: home)
            try spool(ClaudeHookEvent(kind: .subagentStart, timestamp: now.addingTimeInterval(1),
                sessionID: "main", agentID: "child", project: "fixture", agentType: "Reviewer"), home: home)
            try spool(ClaudeHookEvent(kind: .permissionRequest, timestamp: now.addingTimeInterval(2),
                sessionID: "main", agentID: "child", project: "fixture", toolName: "Bash"), home: home)
            let store = ClaudeStore(claudeHome: home, helperSource: source)
            store.start()
            defer { store.stop() }
            try waitUntil { store.compactAgents.count == 2 }
            try expect(store.compactAgents.map(\.role) == [.main, .subagent],
                       "Claude branding preserves main/child roles")
            try expect(store.compactAgents.allSatisfy { $0.iconName == "ClaudeMark" },
                       "both roles retain Claude identity")
            try expect(store.compactAgents.map(\.indicator) == [.working, .approval],
                       "only the child receives the permission badge")
        }
    }

    private static func safety() throws {
        try fixture { home in
            let target = home.appendingPathComponent("event.json")
            try Data("{}".utf8).write(to: target)
            let link = home.appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let linked = try ClaudeMonitor.readEventData(link)
            try expect(linked == nil, "symlink rejected")
            try Data(repeating: 0, count: 8193).write(to: target)
            let oversized = try ClaudeMonitor.readEventData(target)
            try expect(oversized == nil, "bounded spool read")
        }
    }
    private static func runtime() throws {
        try fixture { home in
            let directory = home.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("123.json")
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var payload: [String: Any] = ["pid": 123, "pidDomain": "darwin", "sessionId": "runtime", "procStart": "fixture",
                "cwd": "/tmp/project", "status": "busy", "statusUpdatedAt": now.timeIntervalSince1970 * 1000,
                "updatedAt": now.timeIntervalSince1970 * 1000]
            try JSONSerialization.data(withJSONObject: payload).write(to: file)
            payload["status"] = "idle"
            try JSONSerialization.data(withJSONObject: payload).write(to: file)
            let idle = ClaudeRuntimeReader(home: home, processMatches: { _, _ in true })
            try expect(idle.poll(now: now).first?.status == .idle, "open idle session is ready, not a completed task")
            payload["status"] = "busy"
            try JSONSerialization.data(withJSONObject: payload).write(to: file)
            let rejected = ClaudeRuntimeReader(home: home, processMatches: { _, _ in false })
            try expect(rejected.poll(now: now).isEmpty, "PID reuse or inaccessible process never accepted")
            let accepted = ClaudeRuntimeReader(home: home, processMatches: { $0 == 123 && $1 == "fixture" })
            try expect(accepted.poll(now: now).first?.status == .working, "verified fresh busy status")
            payload["statusUpdatedAt"] = now.addingTimeInterval(-301).timeIntervalSince1970 * 1000
            try JSONSerialization.data(withJSONObject: payload).write(to: file)
            let longRunning = accepted.poll(now: now)
            try expect(longRunning.first?.status == .working, "verified long-running processes do not expire without a heartbeat")
            try expect(longRunning.first?.isActive(at: now) == true,
                       "verified long-running Claude stays in the widget activity list")
            try expect(CodexCompactAgent.make(agents: longRunning, approvals: [], connection: .receiving,
                now: now).count == 1, "verified long-running Claude retains its notch icon")
            payload["status"] = "shell"
            try JSONSerialization.data(withJSONObject: payload).write(to: file)
            try expect(accepted.poll(now: now).first?.status == .working, "background shell work remains visible")
            payload["status"] = "waiting"
            payload["waitingFor"] = "permission prompt"
            try JSONSerialization.data(withJSONObject: payload).write(to: file)
            try expect(accepted.poll(now: now).first?.status == .approvalRequested, "verified long-lived permission prompt remains visible")
            payload["statusUpdatedAt"] = now.addingTimeInterval(1).timeIntervalSince1970 * 1000
            try JSONSerialization.data(withJSONObject: payload).write(to: file)
            try expect(accepted.poll(now: now).isEmpty, "future transition state is deferred")
        }
    }
    private static func nativeProcess() throws {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let pid = getpid()
        try expect(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, "own process metadata is available")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let expected = formatter.string(from: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec)))
        try expect(ClaudeRuntimeReader.processMatches(pid, expected), "Claude UTC procStart matches native process")
        let changed = formatter.string(from: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) - 1))
        try expect(!ClaudeRuntimeReader.processMatches(pid, changed), "same PID with different start is never accepted")
    }
    private static func lostRuntime() throws {
        try fixture { home in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let directory = home.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("123.json")
            try JSONSerialization.data(withJSONObject: ["pid": 123, "pidDomain": "darwin", "procStart": "original",
                "sessionId": "main", "statusUpdatedAt": now.timeIntervalSince1970 * 1000, "status": "busy"]).write(to: file)
            var alive = true
            let reader = ClaudeRuntimeReader(home: home, processMatches: { _, _ in alive })
            let main = CodexAgentSnapshot(id: "main", project: "fixture", name: nil, status: .working, updatedAt: now)
            let child = CodexAgentSnapshot(id: "child", project: "fixture", name: "child", status: .working,
                updatedAt: now, parentID: "main")
            let request = CodexApprovalSnapshot(id: "request", sessionID: "main", turnID: nil,
                project: "fixture", summary: nil, toolName: nil, requestedAt: now, agentID: "child")
            try expect(reader.poll(now: now).count == 1, "process is initially verified")
            alive = false
            let live = reader.poll(now: now.addingTimeInterval(1), refreshFiles: false)
            let result = ClaudeActivityProjection(runtime: live, hooked: [main, child], approvals: [request],
                                                  unavailableSessions: reader.unavailableSessionIDs)
            try expect(result.agents.isEmpty && result.approvals.isEmpty,
                       "old hooks cannot undo loss of the previously verified process identity")
            try expect(reader.fileScanCount == 1, "process loss is detected without scanning files")
            alive = true
            try expect(reader.poll(now: now.addingTimeInterval(2), refreshFiles: false).count == 1
                && reader.unavailableSessionIDs.isEmpty, "reverified process clears the conservative fence")
            try FileManager.default.removeItem(at: file)
            try expect(reader.poll(now: now.addingTimeInterval(3)).isEmpty
                && reader.unavailableSessionIDs == ["main"], "removed registry also prevents hook fallback")
            _ = reader.poll(now: now.addingTimeInterval(304), refreshFiles: false)
            try expect(reader.unavailableSessionIDs.isEmpty, "loss fences expire with stale hook evidence")
        }
    }
    private static func projection() throws {
        let now = Date()
        let hook = CodexAgentSnapshot(id: "main", project: "fixture", name: nil, status: .approvalRequested, updatedAt: now.addingTimeInterval(-1))
        let runtime = CodexAgentSnapshot(id: "main", project: "fixture", name: nil, status: .idle, updatedAt: now)
        let approval = CodexApprovalSnapshot(id: "request", sessionID: "main", turnID: nil, project: "fixture", summary: nil, toolName: "Bash", requestedAt: now.addingTimeInterval(-1))
        let projection = ClaudeActivityProjection(runtime: [runtime], hooked: [hook], approvals: [approval])
        try expect(projection.approvals.isEmpty && projection.agents.first?.status == .idle, "newer validated runtime clears denied/interrupted request")
        try expect(projection.agents.allSatisfy { !$0.isActive(at: now) },
                   "idle Claude disappears immediately from the widget list/count")
        try expect(CodexCompactAgent.make(agents: projection.agents, approvals: projection.approvals,
            connection: .receiving, now: now).isEmpty, "idle Claude also disappears from the notch")
        let child = CodexAgentSnapshot(id: "child", project: "fixture", name: "Reviewer", status: .working,
            updatedAt: now.addingTimeInterval(-1), parentID: "main")
        let background = ClaudeActivityProjection(runtime: [runtime], hooked: [hook, child], approvals: [approval])
        try expect(background.agents.filter { $0.isActive(at: now) }.map(\.id) == ["child"],
                   "idle parent alone cannot finish a separately running background child")
    }
}
