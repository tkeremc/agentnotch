import Foundation
@testable import AgentNotch

@MainActor
struct CodexUsageTests {
    static let cases: [(String, @MainActor () throws -> Void)] = [
        ("Codex quota preserves observed windows and expired reset", observation),
        ("Codex quota tails complete lines without duplicating history", incremental),
        ("Codex quota resets truncated and replaced files", replacement),
        ("Codex quota rejects ambiguous recorded accounts", accounts),
        ("Codex quota isolates unattributed files", unattributed),
        ("Codex quota uses first metadata and excludes inherited child history", copiedHistory),
        ("Codex quota excludes unknown child history boundaries", unsupportedChild),
        ("Codex quota prefers main bucket without joining windows", buckets),
        ("Codex quota ignores invalid values and handles unknown optional fields", invalidValues),
        ("Codex quota skips symlink files and directories", symlinks),
        ("Codex quota bounds oversized lines and recovers after malformed records", longLines),
        ("Codex quota distinguishes missing and empty roots and keeps last observation", missingRoot),
        ("Codex quota reports per-file permission failure", permissionDenied),
        ("Codex quota does not carry last account quota into a replacement account", replacementAccount),
        ("Codex quota defers future observations and promotes them without source writes", futureObservations),
        ("Codex quota reports no data until first observation becomes eligible", futureOnly),
        ("Codex session reader recovers parent and child activity from current logs", lifecycle),
        ("Codex session reader keeps heartbeats and later turns separate", activityHeartbeat),
        ("Codex session reader defers future lifecycle and rejects malformed evidence", activityUncertainty),
        ("Codex block reader preserves UTF8 partial records across chunk and refresh boundaries", blockBoundaries),
        ("Codex block reader accepts the exact line limit and discards oversized partial input", lineLimit),
        ("Codex reader releases removed file and account indices without losing last quota", cachePruning)
    ]

    private static func lifecycle() throws {
        try fixture { root, reader in
            let parent = root.appendingPathComponent("parent.jsonl")
            let child = root.appendingPathComponent("child.jsonl")
            try (encoded("session_meta", ["id": "parent", "cwd": "/tmp/project"])
                + encoded("event_msg", ["type": "task_started", "turn_id": "parent-turn"], time: 2)).write(to: parent)
            try (encoded("session_meta", ["id": "child", "cwd": "/tmp/project",
                    "parent_thread_id": "parent", "agent_nickname": "Goodall",
                    "subagent_history_start_ordinal": 2])
                + encoded("session_meta", ["id": "parent"])
                + encoded("event_msg", ["type": "task_started", "turn_id": "copied-parent"], time: 2)
                + encoded("event_msg", ["type": "task_started", "turn_id": "child-turn"], time: 3)).write(to: child)
            let now = ISO8601DateFormatter().date(from: "2026-10-20T00:00:10Z")!
            _ = reader.refresh(now: now)
            let agents = reader.activitySnapshots(now: now)
            try expect(agents.count == 2, "one parent and one child, no inherited duplicates")
            try expect(agents.first { $0.id == "child" }?.name == "Goodall", "child name retained")
            try expect(agents.first { $0.id == "child" }?.parentID == "parent", "tree relation retained")
            try expect(agents.allSatisfy { $0.status == .working }, "active tasks recovered without hooks")
            try append(encoded("event_msg", ["type": "task_complete", "turn_id": "child-turn"], time: 11), to: child)
            _ = reader.refresh(now: now.addingTimeInterval(2))
            let after = reader.activitySnapshots(now: now.addingTimeInterval(2))
            try expect(after.first { $0.id == "child" }?.status == .finished, "child closes")
            try expect(after.first { $0.id == "parent" }?.status == .working, "parent remains active")
        }
    }

    private static func activityHeartbeat() throws {
        try fixture { root, reader in
            let file = root.appendingPathComponent("a.jsonl")
            try (encoded("session_meta", ["id": "s", "cwd": "/tmp/project"])
                + encoded("event_msg", ["type": "task_started", "turn_id": "t"], time: 2)).write(to: file)
            let now = ISO8601DateFormatter().date(from: "2026-10-20T00:00:10Z")!
            _ = reader.refresh(now: now)
            try expect(reader.activitySnapshots(now: now.addingTimeInterval(301)).first?.status == .unknown,
                       "silence is unknown, never finished")
            let heartbeat: [String: Any] = ["type": "event_msg", "timestamp": "2026-10-20T00:06:00Z",
                "payload": ["type": "token_count"]]
            var bytes = try JSONSerialization.data(withJSONObject: heartbeat); bytes.append(10)
            try append(bytes, to: file)
            _ = reader.refresh(now: now.addingTimeInterval(360))
            try expect(reader.activitySnapshots(now: now.addingTimeInterval(360)).first?.status == .working,
                       "ongoing token activity refreshes a long task")
            var terminal = try JSONSerialization.data(withJSONObject: ["type": "event_msg",
                "timestamp": "2026-10-20T00:06:11Z", "payload": ["type": "turn_aborted", "turn_id": "t"]]); terminal.append(10)
            try append(terminal, to: file)
            _ = reader.refresh(now: now.addingTimeInterval(362))
            try expect(reader.activitySnapshots(now: now.addingTimeInterval(362)).first?.status == .interrupted,
                       "abort is distinct from failure")
        }
    }

    private static func activityUncertainty() throws {
        try fixture { root, reader in
            let file = root.appendingPathComponent("a.jsonl")
            try (encoded("session_meta", ["id": "s", "cwd": "/tmp/p"])
                + encoded("event_msg", ["type": "task_started", "turn_id": "t"], time: 30)).write(to: file)
            let now = ISO8601DateFormatter().date(from: "2026-10-20T00:00:10Z")!
            _ = reader.refresh(now: now)
            try expect(reader.activitySnapshots(now: now).isEmpty, "future starts are not live activity")
            _ = reader.refresh(now: now.addingTimeInterval(21))
            try expect(reader.activitySnapshots(now: now.addingTimeInterval(21)).first?.status == .working,
                       "future start becomes eligible without another write")
            try append(Data("broken JSON\n".utf8), to: file)
            _ = reader.refresh(now: now.addingTimeInterval(22))
            try expect(reader.activitySnapshots(now: now.addingTimeInterval(22)).isEmpty,
                       "corrupt lifecycle cannot be advertised as live")
            try append(encoded("event_msg", ["type": "task_started", "turn_id": "next-turn"], time: 34), to: file)
            _ = reader.refresh(now: now.addingTimeInterval(25))
            try expect(reader.activitySnapshots(now: now.addingTimeInterval(25)).first?.status == .working,
                       "a new explicit start recovers after corrupt history")
        }
    }

    private static let fixtureNow = ISO8601DateFormatter().date(from: "2026-10-21T00:00:00Z")!

    private struct Failure: Error { let message: String }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    private static func fixture(_ body: (URL, CodexUsageReader) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentNotch.CodexUsage.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, CodexUsageReader(sessionsDirectory: root))
    }

    private static func encoded(_ type: String, _ payload: [String: Any], time: Int = 1) throws -> Data {
        var result = try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload,
            "timestamp": "2026-10-20T00:00:\(String(format: "%02d", time))Z"], options: [.sortedKeys])
        result.append(10)
        return result
    }

    private static func meta(account: String? = "account-a", childBoundary: Int? = nil,
                             child: Bool = false) throws -> Data {
        var payload: [String: Any] = [:]
        if let account { payload["creator_account_id"] = account; payload["creator_user_id"] = "user-a" }
        if child { payload["parent_thread_id"] = "parent" }
        if let childBoundary { payload["subagent_history_start_ordinal"] = childBoundary }
        return try encoded("session_meta", payload)
    }

    private static func quota(_ used: Any = 20, secondary: Any? = 40,
                              bucket: String = "codex", time: Int = 2,
                              extra: [String: Any] = [:]) throws -> Data {
        var limits: [String: Any] = ["limit_id": bucket,
            "primary": ["used_percent": used, "window_minutes": 300, "resets_at": 1000], "plan_type": "plus"]
        if let secondary { limits["secondary"] = ["used_percent": secondary, "window_minutes": 10080] }
        limits.merge(extra) { _, new in new }
        return try encoded("event_msg", ["type": "token_count", "rate_limits": limits], time: time)
    }

    private static func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func observation() throws {
        try fixture { root, reader in
            try (meta() + quota()).write(to: root.appendingPathComponent("a.jsonl"))
            let result = reader.refresh(now: Date(timeIntervalSince1970: 2_000_000_000))
            try expect(result.availability == .available && result.scannedFiles == 1, "readable observation")
            try expect(result.snapshot?.primary?.remainingPercent == 80, "remaining percentage")
            try expect(result.snapshot?.secondary?.usedPercent == 40, "secondary window")
            try expect(result.snapshot?.primary?.windowMinutes == 300, "duration from evidence")
            try expect(result.snapshot?.primary?.resetsAt == Date(timeIntervalSince1970: 1000), "expired reset must survive")
            try expect(result.snapshot?.planType == "plus", "recorded plan")
            try expect(result.snapshot?.identityKey != nil && result.snapshot?.identityKey != "account-a", "opaque account")
            try expect(reader.refresh(now: .distantFuture).snapshot == result.snapshot, "time does not replenish quota")
        }
    }

    private static func incremental() throws {
        try fixture { root, reader in
            let file = root.appendingPathComponent("a.jsonl")
            let next = try quota(55, time: 3)
            try (meta() + quota() + next.prefix(next.count / 2)).write(to: file)
            let first = reader.refresh(now: fixtureNow)
            try expect(first.snapshot?.primary?.usedPercent == 20, "half record ignored")
            try expect(reader.refresh(now: fixtureNow) == first, "unchanged tail")
            try append(next.suffix(next.count - next.count / 2), to: file)
            let second = reader.refresh(now: fixtureNow)
            try expect(second.snapshot?.primary?.usedPercent == 55, "completed record read exactly once")
            try expect(second.snapshot?.identityKey == first.snapshot?.identityKey, "stable identity across append")
            try expect(reader.refresh(now: fixtureNow) == second, "repeat read remains stable")
        }
    }

    private static func replacement() throws {
        try fixture { root, reader in
            let file = root.appendingPathComponent("a.jsonl")
            try (meta() + quota() + Data(repeating: 32, count: 100)).write(to: file)
            _ = reader.refresh(now: fixtureNow)
            try (meta() + quota(70, time: 4)).write(to: file)
            try expect(reader.refresh(now: fixtureNow).snapshot?.primary?.usedPercent == 70, "truncation resets pending data")
            try (meta() + quota(85, time: 5)).write(to: file, options: .atomic)
            try expect(reader.refresh(now: fixtureNow).snapshot?.primary?.usedPercent == 85, "atomic replacement")
            try (meta() + quota(90, time: 6)).write(to: file)
            try expect(reader.refresh(now: fixtureNow).snapshot?.primary?.usedPercent == 90, "same-size overwrite")
        }
    }

    private static func accounts() throws {
        try fixture { root, reader in
            try (meta() + quota()).write(to: root.appendingPathComponent("a.jsonl"))
            try (meta() + quota(35, time: 3)).write(to: root.appendingPathComponent("b.jsonl"))
            try expect(reader.refresh(now: fixtureNow).snapshot?.primary?.usedPercent == 35, "same recorded account can combine observations")
            // A new recorded identity is ambiguous even before its first quota.
            try meta(account: "account-b").write(to: root.appendingPathComponent("c.jsonl"))
            let result = reader.refresh(now: fixtureNow)
            try expect(result.availability == .ambiguousAccounts && result.snapshot == nil, "never choose newest distinct account")
        }
    }

    private static func unattributed() throws {
        try fixture { root, reader in
            try (meta(account: nil) + quota()).write(to: root.appendingPathComponent("a.jsonl"))
            try expect(reader.refresh(now: fixtureNow).snapshot?.identityKey == nil, "unknown identity stays unknown")
            try (meta(account: nil) + quota(35, time: 3)).write(to: root.appendingPathComponent("b.jsonl"))
            try expect(reader.refresh(now: fixtureNow).availability == .ambiguousAccounts, "unattributed files cannot be merged")
        }
    }

    private static func copiedHistory() throws {
        try fixture { root, reader in
            let data = try meta(childBoundary: 3, child: true)
                + meta(account: "copied-parent") + quota(95, time: 10)
                + encoded("response_item", ["content": "private prompt"])
                + quota(30, time: 5)
            try data.write(to: root.appendingPathComponent("child.jsonl"))
            let result = reader.refresh(now: fixtureNow)
            try expect(result.snapshot?.primary?.usedPercent == 30, "physical ordinal suppresses newer inherited quota")
            try expect(result.snapshot?.identityKey != nil, "first metadata is identity")
            try (meta() + quota(40, time: 6)).write(to: root.appendingPathComponent("parent.jsonl"))
            try expect(reader.refresh(now: fixtureNow).snapshot?.primary?.usedPercent == 40, "copied metadata did not replace identity")
        }
    }

    private static func unsupportedChild() throws {
        try fixture { root, reader in
            try (meta(child: true) + quota()).write(to: root.appendingPathComponent("child.jsonl"))
            let result = reader.refresh(now: fixtureNow)
            try expect(result.snapshot == nil && result.availability == .noData, "unknown copied boundary is not own evidence")
        }
    }

    private static func buckets() throws {
        try fixture { root, reader in
            let data = try meta() + quota(20, secondary: 65) + quota(70, secondary: nil, time: 3)
                + quota(90, bucket: "codex_spark", time: 4)
            try data.write(to: root.appendingPathComponent("a.jsonl"))
            let snapshot = reader.refresh(now: fixtureNow).snapshot
            try expect(snapshot?.primary?.usedPercent == 70 && snapshot?.limitID == "codex", "main bucket wins")
            try expect(snapshot?.secondary == nil, "cannot borrow secondary from older observation")
        }
    }

    private static func invalidValues() throws {
        try fixture { root, reader in
            let data = try meta() + quota() + quota(true, secondary: -1, time: 3)
                + quota(101, secondary: "20", time: 4)
                + quota(60, secondary: nil, time: 5, extra: ["primary": ["used_percent": 60,
                    "window_minutes": true, "resets_at": "unknown"], "plan_type": NSNull()])
            try data.write(to: root.appendingPathComponent("a.jsonl"))
            let snapshot = reader.refresh(now: fixtureNow).snapshot
            try expect(snapshot?.primary?.usedPercent == 60, "valid later value")
            try expect(snapshot?.primary?.windowMinutes == nil && snapshot?.primary?.resetsAt == nil, "optional invalid fields stay unknown")
            try expect(snapshot?.planType == nil, "unknown plan")
        }
    }

    private static func symlinks() throws {
        try fixture { root, reader in
            let nested = root.appendingPathComponent("normal")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let regular = nested.appendingPathComponent("a.jsonl")
            try (meta() + quota()).write(to: regular)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.jsonl"), withDestinationURL: regular)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
            let result = reader.refresh(now: fixtureNow)
            try expect(result.scannedFiles == 1 && result.availability == .available, "symlinks skipped including loops")
            let linkedReader = CodexUsageReader(sessionsDirectory: root.appendingPathComponent("loop"))
            try expect(linkedReader.refresh(now: fixtureNow).availability == .notFound, "symlink root skipped")
        }
    }

    private static func longLines() throws {
        try fixture { root, reader in
            let file = root.appendingPathComponent("a.jsonl")
            try (meta() + Data(repeating: 65, count: 1_100_000)).write(to: file)
            try expect(reader.refresh(now: fixtureNow).snapshot == nil, "oversized partial line ignored")
            try append(Data("\n{broken}\n".utf8) + quota(45), to: file)
            try expect(reader.refresh(now: fixtureNow).snapshot?.primary?.usedPercent == 45, "recover after long and malformed lines")
        }
    }

    private static func blockBoundaries() throws {
        try fixture { root, reader in
            let file = root.appendingPathComponent("a.jsonl")
            let metadata = try encoded("session_meta", ["id": "block-test", "creator_account_id": "a", "creator_user_id": "u"])
                + encoded("event_msg", ["type": "task_started", "turn_id": "t"])
            // Padding places a multibyte character across the 64 KiB read edge.
            let start = Data("{\"noise\":\"".utf8)
            let padding = 65_535 - metadata.count - start.count
            var line = start + Data(repeating: 65, count: padding)
            line.append(Data("ş\",\"payload\":{},\"type\":\"ignored\"}\n".utf8))
            let quotaLine = try quota(37)
            let split = quotaLine.count / 2
            try (metadata + line + quotaLine.prefix(split)).write(to: file)
            try expect(reader.refresh(now: fixtureNow).snapshot == nil, "incomplete quota is deferred")
            let activityNow = ISO8601DateFormatter().date(from: "2026-10-20T00:00:10Z")!
            try expect(reader.activitySnapshots(now: activityNow).first?.status == .working,
                       "valid UTF8 spanning chunks does not invalidate lifecycle evidence")
            try expect(reader.retainedStateCounts.pendingBytes == split, "only the partial tail is kept")
            try append(Data(quotaLine.dropFirst(split)), to: file)
            try expect(reader.refresh(now: fixtureNow).snapshot?.primary?.usedPercent == 37,
                       "UTF8 split and multi-chunk record do not corrupt the following quota")
            try expect(reader.retainedStateCounts.pendingBytes == 0, "completed tail releases scratch data")
            try append(Data("\n\n".utf8) + quota(68, time: 3), to: file)
            try expect(reader.refresh(now: fixtureNow).snapshot?.primary?.usedPercent == 68,
                       "empty lines and multiple complete records in one chunk stay aligned")
        }
    }

    private static func lineLimit() throws {
        try fixture { root, reader in
            let file = root.appendingPathComponent("a.jsonl")
            let prefix = Data("{\"type\":\"event_msg\",\"timestamp\":\"2026-10-20T00:00:02Z\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":44}}},\"padding\":\"".utf8)
            let suffix = Data("\"}".utf8)
            let exact = prefix + Data(repeating: 65, count: 1_048_576 - prefix.count - suffix.count) + suffix
            // Exact limit without a newline is still a legitimate partial line.
            try (meta() + exact).write(to: file)
            _ = reader.refresh(now: fixtureNow)
            try expect(reader.retainedStateCounts.pendingBytes == 1_048_576, "exact limit remains eligible")
            try append(Data([10]), to: file)
            try expect(reader.refresh(now: fixtureNow).snapshot?.primary?.usedPercent == 44, "limit-sized line completes")
            try expect(reader.retainedStateCounts.pendingBytes == 0, "large completed scratch is released")
            try append(Data(repeating: 65, count: 1_048_577), to: file)
            _ = reader.refresh(now: fixtureNow)
            try expect(reader.retainedStateCounts.pendingBytes == 0, "oversized unfinished line holds no large buffer")
            try append(Data([10]) + quota(73, time: 3), to: file)
            try expect(reader.refresh(now: fixtureNow).snapshot?.primary?.usedPercent == 73,
                       "reader resumes at the next newline after oversized input")
        }
    }

    private static func cachePruning() throws {
        try fixture { root, reader in
            for index in 0..<12 {
                let file = root.appendingPathComponent("\(index).jsonl")
                try (meta(account: "account-\(index)") + quota(index)).write(to: file)
                _ = reader.refresh(now: fixtureNow)
                try expect(reader.retainedStateCounts.files == 1 && reader.retainedStateCounts.fileKeys == 1,
                           "only existing files retain state and opaque file indices")
                try expect(reader.retainedStateCounts.identities == 1, "replaced accounts do not accumulate identity keys")
                try FileManager.default.removeItem(at: file)
            }
            let last = reader.refresh(now: fixtureNow)
            try expect(last.snapshot?.primary?.usedPercent == 11, "dated last observation survives source removal")
            try expect(reader.retainedStateCounts.files == 0 && reader.retainedStateCounts.fileKeys == 0,
                       "deleted source states are released")
            try expect(reader.retainedStateCounts.identities == 1, "only the last observation identity is retained")
        }
    }

    private static func missingRoot() throws {
        try fixture { root, reader in
            try expect(reader.refresh(now: fixtureNow).availability == .noData, "empty root differs from missing")
            let file = root.appendingPathComponent("a.jsonl")
            try (meta() + quota()).write(to: file)
            let snapshot = reader.refresh(now: fixtureNow).snapshot
            try FileManager.default.removeItem(at: root)
            let result = reader.refresh(now: fixtureNow)
            try expect(result.availability == .notFound && !result.readErrors.isEmpty, "missing root reported")
            try expect(result.snapshot == snapshot, "last observation remains dated and available to stale UI")
        }
    }

    private static func permissionDenied() throws {
        guard NSUserName() != "root" else { return }
        try fixture { root, reader in
            let file = root.appendingPathComponent("a.jsonl")
            try (meta() + quota()).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            let result = reader.refresh(now: fixtureNow)
            try expect(result.availability == .permissionDenied && result.snapshot == nil, "denial differs from no quota")
            try expect(result.readErrors.count == 1 && result.readErrors[0].fileKey != nil, "per-file opaque error")
            try expect(result.readErrors[0].kind == .permissionDenied, "classified denial")
        }
    }

    private static func replacementAccount() throws {
        try fixture { root, reader in
            let file = root.appendingPathComponent("a.jsonl")
            try (meta() + quota()).write(to: file)
            try expect(reader.refresh(now: fixtureNow).snapshot != nil, "first account has quota")
            try meta(account: "account-b").write(to: file, options: .atomic)
            let result = reader.refresh(now: fixtureNow)
            try expect(result.availability == .noData && result.snapshot == nil, "new account must not inherit previous account quota")
        }
    }

    private static func futureObservations() throws {
        try fixture { root, reader in
            let origin = ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z")!
            let file = root.appendingPathComponent("a.jsonl")
            try (meta() + quota(20, time: 2) + quota(90, time: 30) + quota(40, time: 4)).write(to: file)
            try expect(reader.refresh(now: origin.addingTimeInterval(5)).snapshot?.primary?.usedPercent == 40,
                       "future observation cannot shadow newer eligible evidence")
            try append(quota(50, time: 6), to: file)
            try expect(reader.refresh(now: origin.addingTimeInterval(7)).snapshot?.primary?.usedPercent == 50,
                       "new current observation stays eligible while future is deferred")
            try expect(reader.refresh(now: origin.addingTimeInterval(30)).snapshot?.primary?.usedPercent == 90,
                       "future observation promotes without append at exact observation time")
            try expect(reader.refresh(now: origin.addingTimeInterval(5)).snapshot?.primary?.usedPercent == 40,
                       "clock rollback must not retain a now-future observation")
        }
    }

    private static func futureOnly() throws {
        try fixture { root, reader in
            let origin = ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z")!
            try (meta() + quota(20, time: 2)).write(to: root.appendingPathComponent("a.jsonl"))
            let first = reader.refresh(now: origin.addingTimeInterval(1))
            try expect(first.availability == .noData && first.snapshot == nil, "future-only data stays unavailable")
            try expect(reader.refresh(now: origin.addingTimeInterval(2)).snapshot?.primary?.usedPercent == 20,
                       "eligible later without source write")
        }
    }
}
