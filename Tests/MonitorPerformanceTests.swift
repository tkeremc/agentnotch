import Foundation
@testable import AgentNotch

@MainActor
enum MonitorPerformanceTests {
    static let cases: [(String, @MainActor () throws -> Void)] = [
        ("Codex expiry ticks perform no scans, file reads or installation validation", codexIdle),
        ("Codex event and configuration changes invalidate independent work", invalidation),
        ("Codex changed-file reads preserve unrelated accounts and detect replacement", targetedReads),
        ("Codex deferred records and rollback work without routine scans", deferredRecords),
        ("Codex targeted reads do not follow replaced parent symlinks", symlinkParent),
        ("Claude quota expiry ticks perform no scans or installation validation", claudeIdle),
        ("Claude cached runtime still verifies process liveness", runtimeLiveness),
        ("Native notifications deliver nested writes and atomic replacements before recovery", notifications),
        ("Metadata fallback delivers changes beyond the native descriptor budget", fallbackDelivery),
        ("Codex discovers new nested sessions and their atomic replacement", newSessions),
        ("Future hook events become eligible without another filesystem event", futureHook),
        ("Periodic recovery finds writes without a notification hint", recovery),
        ("Codex removed widget releases cached state and rebuilds from disk", codexCacheLifecycle),
        ("Claude removed widget releases cached state and rebuilds from disk", claudeCacheLifecycle),
        ("Inactive cache retention expires, cancels and responds to pressure", cacheRetention)
    ]
    private struct Failure: Error { let message: String }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    private static func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MonitorPerformance-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private static func helper(_ provider: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["AGENTNOTCH_TEST_\(provider)_HELPER"] else {
            throw Failure(message: "run through Tests/run.sh")
        }
        return URL(fileURLWithPath: path)
    }
    private static func record(_ type: String, _ payload: [String: Any], at: Date) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload,
            "timestamp": ISO8601DateFormatter().string(from: at)])
        data.append(10)
        return data
    }
    private static func session(_ id: String, account: String = "a", at: Date) throws -> Data {
        try record("session_meta", ["id": id, "cwd": "/tmp/fixture", "creator_account_id": account,
            "creator_user_id": "user"], at: at)
    }
    private static func quota(_ used: Int, at: Date) throws -> Data {
        try record("event_msg", ["type": "token_count", "rate_limits": ["limit_id": "codex",
            "primary": ["used_percent": used, "window_minutes": 300]]], at: at)
    }
    private static func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
    private static func codexIdle() throws {
        try fixture { home in
            let now = Date()
            try (session("s", at: now.addingTimeInterval(-2))
                + record("event_msg", ["type": "task_started", "turn_id": "turn"], at: now.addingTimeInterval(-1)))
                .write(to: home.appendingPathComponent("sessions/a.jsonl"))
            let monitor = CodexMonitor(home: home, helperSource: try helper("CODEX"))
            try expect(monitor.poll(now: now).agents.first?.status == .working, "initial activity")
            for second in 1...301 {
                _ = monitor.poll(now: now.addingTimeInterval(Double(second)), changes: MonitorChanges())
            }
            let result = monitor.poll(now: now.addingTimeInterval(302), changes: MonitorChanges())
            try expect(result.agents.first?.status == .unknown, "silence still expires from memory")
            try expect(monitor.usageScanCount == 1 && monitor.usageFileReadCount == 1,
                       "302 expiry ticks must not discover or reopen session files")
            try expect(monitor.validationCount == 1 && monitor.eventScanCount == 1,
                       "expiry ticks must not hash helpers or enumerate the spool")
        }
    }
    private static func invalidation() throws {
        try fixture { home in
            let binary = try helper("CODEX")
            let installer = CodexHookInstaller(codexHome: home, helperSource: binary)
            try installer.install()
            let now = Date()
            let monitor = CodexMonitor(home: home, helperSource: binary)
            _ = monitor.poll(now: now)
            let event = CodexHookEvent(kind: .userPromptSubmit, timestamp: now, sessionID: "s", turnID: "t", project: "p")
            let file = installer.eventsDirectory.appendingPathComponent("\(event.id).json")
            try JSONEncoder().encode(event).write(to: file)
            let result = monitor.poll(now: now.addingTimeInterval(1), changes: MonitorChanges(paths: [file.path]))
            try expect(result.agents.first?.status == .working && result.connection == .receiving, "event delivery")
            try expect(monitor.validationCount == 1 && monitor.usageScanCount == 1,
                       "a tool event must not validate installation or rediscover history")
            try FileManager.default.removeItem(at: installer.hooksURL)
            let broken = monitor.poll(now: now.addingTimeInterval(2), changes: MonitorChanges(paths: [installer.hooksURL.path]))
            try expect(broken.connection == .repairRequired && monitor.validationCount == 2, "configuration invalidation")
            try expect(monitor.eventScanCount == 2 && monitor.usageScanCount == 1, "unrelated IO remains cached")
        }
    }
    private static func targetedReads() throws {
        try fixture { home in
            let root = home.appendingPathComponent("sessions")
            let now = Date()
            for index in 0..<40 {
                try (session("s\(index)", at: now.addingTimeInterval(-2)) + quota(20, at: now.addingTimeInterval(-1)))
                    .write(to: root.appendingPathComponent("\(index).jsonl"))
            }
            let reader = CodexUsageReader(sessionsDirectory: root)
            _ = reader.refresh(now: now)
            let file = root.appendingPathComponent("0.jsonl")
            try append(quota(35, at: now), to: file)
            let result = reader.refresh(now: now.addingTimeInterval(1), changedPaths: [file.path])
            try expect(result.snapshot?.primary?.usedPercent == 35, "new quota")
            try expect(reader.fullScanCount == 1 && reader.fileReadCount == 41, "only changed file is opened")
            let second = root.appendingPathComponent("new.jsonl")
            try (session("other", account: "b", at: now) + quota(10, at: now)).write(to: second)
            try expect(reader.refresh(now: now.addingTimeInterval(2), changedPaths: [second.path]).availability == .ambiguousAccounts,
                       "unchanged account evidence must survive incremental refresh")
            try FileManager.default.removeItem(at: second)
            try expect(reader.refresh(now: now.addingTimeInterval(3), changedPaths: [second.path]).availability == .available,
                       "deleted file removes its account evidence")
            try (session("replacement", at: now) + quota(75, at: now.addingTimeInterval(4))).write(to: file, options: .atomic)
            try expect(reader.refresh(now: now.addingTimeInterval(5), changedPaths: [file.path]).snapshot?.primary?.usedPercent == 75,
                       "atomic replacement resets the offset and identity")
        }
    }
    private static func deferredRecords() throws {
        try fixture { home in
            let root = home.appendingPathComponent("sessions")
            let now = Date()
            try (session("s", at: now) + quota(60, at: now.addingTimeInterval(20)))
                .write(to: root.appendingPathComponent("a.jsonl"))
            let reader = CodexUsageReader(sessionsDirectory: root)
            try expect(reader.refresh(now: now).snapshot == nil, "future observation is deferred")
            try expect(reader.advance(now: now.addingTimeInterval(21)).snapshot?.primary?.usedPercent == 60,
                       "future observation becomes available without IO")
            try expect(reader.fileReadCount == 1, "projection must not reopen files")
            try expect(reader.advance(now: now.addingTimeInterval(1)).snapshot == nil, "clock rollback drops future evidence")
            try expect(reader.fullScanCount == 2, "rollback explicitly reconciles")
        }
    }
    private static func symlinkParent() throws {
        try fixture { home in
            let root = home.appendingPathComponent("sessions")
            let nested = root.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let now = Date()
            try (session("safe", at: now) + quota(20, at: now)).write(to: nested.appendingPathComponent("a.jsonl"))
            let reader = CodexUsageReader(sessionsDirectory: root)
            _ = reader.refresh(now: now)
            let outside = home.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: nested, to: outside)
            try (session("external", account: "external", at: now) + quota(90, at: now))
                .write(to: outside.appendingPathComponent("a.jsonl"))
            try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)
            let result = reader.refresh(now: now.addingTimeInterval(1), changedPaths: [nested.appendingPathComponent("a.jsonl").path])
            try expect(result.availability != .ambiguousAccounts && result.snapshot?.primary?.usedPercent != 90,
                       "file hints must not traverse substituted directory links")
        }
    }
    private static func claudeIdle() throws {
        try fixture { home in
            let binary = try helper("CLAUDE")
            let installer = ClaudeHookInstaller(claudeHome: home, helperSource: binary)
            try installer.install()
            let now = Date()
            let event = ClaudeHookEvent(kind: .statusLine, timestamp: now.addingTimeInterval(-1), sessionID: "s", project: "p",
                fiveHourUsedPercent: 25, fiveHourResetsAt: now.addingTimeInterval(2).timeIntervalSince1970)
            try JSONEncoder().encode(event).write(to: installer.eventsDirectory.appendingPathComponent("\(event.id).json"))
            let monitor = ClaudeMonitor(home: home, helperSource: binary)
            try expect(monitor.poll(now: now).usage.snapshot != nil, "initial quota")
            for second in 1...120 {
                _ = monitor.poll(now: now.addingTimeInterval(Double(second)), changes: MonitorChanges())
            }
            try expect(monitor.poll(now: now.addingTimeInterval(121), changes: MonitorChanges()).usage.snapshot == nil,
                       "quota expires without another write")
            try expect(monitor.eventScanCount == 1 && monitor.validationCount == 1 && monitor.runtimeScanCount == 1,
                       "expiry ticks must not scan the spool/runtime or validate the helper")
        }
    }
    private static func runtimeLiveness() throws {
        try fixture { home in
            // Exact seconds avoid JSON millisecond round-trips placing the
            // fixture fractionally in the future, before liveness is checked.
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let file = home.appendingPathComponent("sessions/123.json")
            try JSONSerialization.data(withJSONObject: ["pid": 123, "pidDomain": "darwin", "procStart": "start",
                "sessionId": "s", "statusUpdatedAt": now.timeIntervalSince1970 * 1000, "status": "busy"])
                .write(to: file)
            var alive = true
            let reader = ClaudeRuntimeReader(home: home, processMatches: { _, _ in alive })
            try expect(reader.poll(now: now).first?.status == .working, "initial runtime")
            alive = false
            try expect(reader.poll(now: now.addingTimeInterval(1), refreshFiles: false).isEmpty,
                       "dead/reused process must not survive cached metadata")
            try expect(reader.fileScanCount == 1, "liveness check does not enumerate or parse runtime files")
        }
    }
    private final class Deliveries {
        private let lock = NSLock()
        private var values: [MonitorChanges] = []
        func append(_ value: MonitorChanges) { lock.lock(); values.append(value); lock.unlock() }
        func contains(_ file: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return values.contains { !$0.reconcile && !$0.paths.isEmpty && $0.affects(file) }
        }
        func clear() { lock.lock(); values = []; lock.unlock() }
    }
    private static func waitUntil(_ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(6)
        while !predicate(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try expect(predicate(), "notification did not arrive before the 60-second recovery scan")
    }
    private static func notifications() throws {
        try fixture { home in
            let directory = home.appendingPathComponent("sessions")
            let file = directory.appendingPathComponent("a.jsonl")
            try Data("first\n".utf8).write(to: file)
            let log = Deliveries()
            let queue = DispatchQueue(label: "MonitorPerformance.notifications")
            let driver = LocalMonitorDriver(home: home, observed: [directory, file], queue: queue) { log.append($0) }
            driver.start()
            queue.sync {}
            defer { driver.stop(); queue.sync {} }
            try append(Data("append\n".utf8), to: file)
            try waitUntil { log.contains(file) }
            log.clear()
            try Data("replacement\n".utf8).write(to: file, options: .atomic)
            try waitUntil { log.contains(file) }
        }
    }
    private static func recovery() throws {
        try fixture { home in
            let now = Date()
            let file = home.appendingPathComponent("sessions/a.jsonl")
            try (session("s", at: now) + quota(20, at: now)).write(to: file)
            let monitor = CodexMonitor(home: home)
            _ = monitor.poll(now: now)
            try append(quota(70, at: now.addingTimeInterval(1)), to: file)
            try expect(monitor.poll(now: now.addingTimeInterval(2), changes: MonitorChanges()).usage.snapshot?.primary?.usedPercent == 20,
                       "memory-only ticks do not secretly read files")
            try expect(monitor.poll(now: now.addingTimeInterval(3), changes: .all).usage.snapshot?.primary?.usedPercent == 70,
                       "explicit recovery finds missed writes")
        }
    }

    private static func fallbackDelivery() throws {
        try fixture { home in
            let directory = home.appendingPathComponent("sessions")
            let files = (0..<140).map { directory.appendingPathComponent("\($0).jsonl") }
            for file in files { try Data("initial\n".utf8).write(to: file) }
            let log = Deliveries()
            let queue = DispatchQueue(label: "MonitorPerformance.fallback")
            let driver = LocalMonitorDriver(home: home, observed: [directory] + files, queue: queue) { log.append($0) }
            driver.start(); queue.sync {}
            defer { driver.stop(); queue.sync {} }
            let last = files.last!
            try append(Data("changed\n".utf8), to: last)
            try waitUntil { log.contains(last) }
        }
    }

    private static func newSessions() throws {
        try fixture { home in
            let now = Date().addingTimeInterval(-1)
            @MainActor func bytes(_ id: String) throws -> Data {
                try session(id, at: now)
                    + record("event_msg", ["type": "task_started", "turn_id": "t"], at: now)
            }
            try bytes("seed").write(to: home.appendingPathComponent("sessions/seed.jsonl"))
            let store = CodexStore(codexHome: home)
            store.start()
            defer { store.stop() }
            try waitUntil { store.agents.contains { $0.id == "seed" && $0.status == .working } }
            let file = home.appendingPathComponent("sessions/new/year/day/live.jsonl")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes("new-session").write(to: file)
            try waitUntil { store.agents.contains { $0.id == "new-session" && $0.status == .working } }
            try bytes("replaced-session").write(to: file, options: .atomic)
            try waitUntil { store.agents.contains { $0.id == "replaced-session" && $0.status == .working } }
            try expect(!store.agents.contains { $0.id == "new-session" }, "replacement removes previous identity")
        }
    }

    private static func futureHook() throws {
        try fixture { home in
            let binary = try helper("CODEX")
            let installer = CodexHookInstaller(codexHome: home, helperSource: binary)
            try installer.install()
            let now = Date()
            let event = CodexHookEvent(kind: .permissionRequest, timestamp: now.addingTimeInterval(2),
                sessionID: "s", turnID: "t", project: "p")
            try JSONEncoder().encode(event).write(to: installer.eventsDirectory.appendingPathComponent("\(event.id).json"))
            let monitor = CodexMonitor(home: home, helperSource: binary)
            try expect(monitor.poll(now: now).approvals.isEmpty, "future permission is deferred")
            let result = monitor.poll(now: now.addingTimeInterval(3), changes: MonitorChanges())
            try expect(result.approvals.count == 1 && result.connection == .receiving,
                       "deferred permission must be retried when eligible")
            try expect(monitor.validationCount == 1, "retrying an event does not revalidate configuration")
        }
    }

    private static func codexCacheLifecycle() throws {
        try fixture { home in
            let now = Date().addingTimeInterval(-1)
            let file = home.appendingPathComponent("sessions/a.jsonl")
            try (session("original", at: now)
                + record("event_msg", ["type": "task_started", "turn_id": "first"], at: now)
                + quota(28, at: now)).write(to: file)
            let store = CodexStore(codexHome: home)
            try expect(!store.hasCachedMonitor, "unused widget allocates no reader")
            store.start()
            defer { store.stop() }
            try waitUntil { store.usage?.primary?.usedPercent == 28 }
            store.stop(releaseCaches: false)
            try expect(store.hasCachedMonitor && store.usage != nil, "brief hiding retains a warm reader")
            store.start()
            try waitUntil { store.agents.contains { $0.id == "original" } }
            store.stop()
            try expect(!store.hasCachedMonitor && store.agents.isEmpty && store.usage == nil,
                       "widget removal drops reader and presentation snapshots")
            try expect(store.lastHookAt == nil && store.approvals.isEmpty && store.compactAgents.isEmpty,
                       "stopped widget keeps no stale hook or approval presentation")
            try (session("replacement", at: now)
                + record("event_msg", ["type": "task_started", "turn_id": "next"], at: now)
                + quota(61, at: now)).write(to: file, options: .atomic)
            store.start()
            try waitUntil { store.usage?.primary?.usedPercent == 61 && store.agents.contains { $0.id == "replacement" } }
            try expect(!store.agents.contains { $0.id == "original" }, "fresh reader does not revive discarded state")
        }
    }

    private static func claudeCacheLifecycle() throws {
        try fixture { home in
            let binary = try helper("CLAUDE")
            let installer = ClaudeHookInstaller(claudeHome: home, helperSource: binary)
            try installer.install()
            let now = Date().addingTimeInterval(-1)
            let event = ClaudeHookEvent(kind: .statusLine, timestamp: now, sessionID: "original", project: "fixture",
                fiveHourUsedPercent: 28, fiveHourResetsAt: Date().addingTimeInterval(3600).timeIntervalSince1970)
            let file = installer.eventsDirectory.appendingPathComponent("\(event.id).json")
            try JSONEncoder().encode(event).write(to: file)
            let store = ClaudeStore(claudeHome: home, helperSource: binary)
            try expect(!store.hasCachedMonitor, "unused widget allocates no reader")
            store.start()
            defer { store.stop() }
            try waitUntil { store.usage?.primary?.usedPercent == 28 }
            store.stop(releaseCaches: false)
            try expect(store.hasCachedMonitor && store.usage != nil, "brief hiding retains the quota cache")
            store.stop()
            try expect(!store.hasCachedMonitor && store.agents.isEmpty && store.usage == nil && store.lastHookAt == nil,
                       "removal releases runtime, quota and event-reader ownership")
            try expect(store.usageAvailability == .noData && store.connection != .receiving, "discarded cache is not advertised as current")
            try FileManager.default.removeItem(at: file)
            let replacement = ClaudeHookEvent(kind: .statusLine, timestamp: now, sessionID: "replacement", project: "fixture",
                fiveHourUsedPercent: 61, fiveHourResetsAt: Date().addingTimeInterval(3600).timeIntervalSince1970)
            try JSONEncoder().encode(replacement).write(to: installer.eventsDirectory.appendingPathComponent("\(replacement.id).json"))
            store.start()
            try waitUntil { store.usage?.primary?.usedPercent == 61 }
        }
    }

    private static func cacheRetention() throws {
        var releases = 0
        let retention = MonitorCacheRetention(delay: .milliseconds(100)) { releases += 1 }
        retention.schedule()
        retention.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try expect(releases == 0, "a resumed reader cancels its old expiry")
        retention.schedule()
        try waitUntil { releases == 1 }
        retention.schedule()
        retention.releaseNow() // Same entry point used by the pressure source.
        try expect(releases == 2, "pressure discards an inactive reader immediately")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try expect(releases == 2, "pressure also cancels the scheduled expiry")
    }
}
