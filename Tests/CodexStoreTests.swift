import AppKit
import Foundation
@testable import AgentNotch

@MainActor
enum CodexStoreTests {
    static let cases: [(String, @MainActor () throws -> Void)] = [
        ("Codex discovers known homes without following symlinks", discovery),
        ("Codex automatic connection writes only after consent", consent),
        ("Codex packaged helper feeds the store without touching real Codex", integration),
        ("Codex permission wing preserves notch geometry beside media", geometry),
        ("Codex current sessions remain visible before hook repair", readOnlyActivity)
    ]
    private struct Failure: Error { let message: String }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    private static func waitUntil(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try expect(condition(), "timed out waiting for the background monitor")
    }

    private static func discovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexDiscovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let standard = root.appendingPathComponent(".codex")
        let custom = root.appendingPathComponent("custom")
        try expect(CodexLocations.configuredHome(environment: [:], standardHome: standard).path == standard.path,
                   "standard location requires no configuration")
        try expect(CodexLocations.configuredHome(environment: ["CODEX_HOME": custom.path], standardHome: standard).path == custom.path,
                   "an inherited explicit Codex home takes precedence")
        try expect(CodexLocations.discover(home: custom) == nil, "missing custom home is not created or replaced")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try expect(CodexLocations.discover(home: custom)?.path == custom.path, "existing home is discovered with metadata alone")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: custom)
        try expect(CodexLocations.discover(home: link) == nil, "symlink cannot redirect an automatic installation")
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        try expect(CodexLocations.discover(home: file) == nil, "a regular file is not a Codex home")
    }

    private static func consent() throws {
        guard let binary = ProcessInfo.processInfo.environment["AGENTNOTCH_TEST_CODEX_HELPER"] else {
            throw Failure(message: "Tests/run.sh must supply the packaged helper")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexConsent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "CodexConsent.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Match production's explicitly directory-typed defaultHome URL; URL
        // equality must not mistake its trailing slash for a different path.
        let directoryHome = URL(fileURLWithPath: root.path, isDirectory: true)
        let store = CodexStore(codexHome: directoryHome, helperSource: URL(fileURLWithPath: binary), defaults: defaults)
        let installer = CodexHookInstaller(codexHome: directoryHome, helperSource: URL(fileURLWithPath: binary))
        store.refreshConnection()
        var confirmations = 0
        store.connect { _ in
            confirmations += 1
            return false
        }
        try waitUntil { !store.isChangingConnection }
        try expect(confirmations == 1, "automatic discovery asks for one confirmation")
        try expect(!FileManager.default.fileExists(atPath: installer.integrationDirectory.path),
                   "cancellation leaves no helper, manifest, or event folder")
        try expect(!FileManager.default.fileExists(atPath: installer.hooksURL.path), "cancellation leaves hooks unchanged")
        try expect(store.connectionFailure == nil, "cancellation is not an installation failure")
        var selectedHome: URL?
        var wroteBeforeConsent = false
        store.connect { selected in
            confirmations += 1
            selectedHome = selected
            wroteBeforeConsent = FileManager.default.fileExists(atPath: installer.hooksURL.path)
            return true
        }
        store.connect { _ in confirmations += 1; return true }
        try waitUntil { !store.isChangingConnection }
        try expect(confirmations == 2 && selectedHome?.path == root.path, "discovered location is used and duplicate clicks are ignored")
        try expect(!wroteBeforeConsent && installer.isInstalled, "installation happens after affirmative consent")
        try expect(store.connection == .waitingForEvents, "connection waits honestly for Codex trust and events")
        store.disconnect()
        try waitUntil { !store.isChangingConnection }
        try expect(!installer.isInstalled, "automatic connection can be removed normally")

        let missing = CodexStore(codexHome: root.appendingPathComponent("missing"), defaults: defaults)
        var askedForMissing = false
        missing.connect { _ in askedForMissing = true; return true }
        try waitUntil { !missing.isChangingConnection }
        try expect(!askedForMissing && missing.connectionFailure == .codexNotFound,
                   "missing installation gives a clear error without an empty confirmation or folder picker")
    }

    private static func integration() throws {
        guard let binary = ProcessInfo.processInfo.environment["AGENTNOTCH_TEST_CODEX_HELPER"] else {
            throw Failure(message: "Tests/run.sh must supply the packaged helper")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexStore 'fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = CodexHookInstaller(codexHome: root, helperSource: URL(fileURLWithPath: binary))
        try installer.install()
        let source = root.appendingPathComponent("sessions/fixture.jsonl")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let observed = Date().addingTimeInterval(-1)
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "fixture", "source": "cli",
                "creator_account_id": "fixture-account", "creator_user_id": "fixture-user"]],
            ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: observed),
             "payload": ["type": "token_count", "rate_limits": ["limit_id": "codex",
                "primary": ["used_percent": 25, "window_minutes": 300,
                            "resets_at": observed.addingTimeInterval(600).timeIntervalSince1970]]]]
        ]
        var bytes = Data()
        for record in records { bytes.append(try JSONSerialization.data(withJSONObject: record)); bytes.append(10) }
        try bytes.write(to: source)
        let suite = "CodexStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CodexStore(codexHome: root, helperSource: URL(fileURLWithPath: binary), defaults: defaults)
        defer { store.stop() }
        store.refreshConnection()
        try waitUntil { store.connection == .waitingForEvents }
        try expect(store.usage == nil, "settings inspection does not start the usage monitor")
        store.start()
        try waitUntil { store.usage?.primary?.remainingPercent == 75 }
        try expect(store.connection == .waitingForEvents, "installed hooks still need first activity")

        func emit(_ kind: String, toolID: String? = nil) throws {
            var payload: [String: Any] = ["hook_event_name": kind, "session_id": "session",
                "turn_id": "turn", "cwd": "/private/fixture-project", "tool_name": "Bash",
                "tool_input": ["command": "PRIVATE COMMAND", "description": "Fixture permission"]]
            if let toolID { payload["tool_use_id"] = toolID }
            let process = Process()
            let hookRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: installer.hooksURL)) as! [String: Any]
            let groups = (hookRoot["hooks"] as! [String: Any])[kind] as! [[String: Any]]
            let handler = (groups[0]["hooks"] as! [[String: Any]])[0]
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", handler["command"] as! String]
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            try expect(process.terminationStatus == 0, "helper must not affect Codex execution")
            try expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty, "helper stdout is not model context")
            try expect(errors.fileHandleForReading.readDataToEndOfFile().isEmpty, "helper diagnostics must not leak arguments")
        }

        try emit("UserPromptSubmit")
        try emit("PermissionRequest", toolID: "request-a")
        try waitUntil { store.approvals.count == 1 && store.connection == .receiving }
        try expect(store.agents.contains { $0.status == .approvalRequested }, "permission event reaches presentation state")
        let previousHook = store.lastHookAt
        try emit("PostToolUse", toolID: "unrelated")
        try waitUntil { store.lastHookAt != previousHook }
        try expect(store.approvals.count == 1, "unrelated output cannot clear the permission bubble")
        try emit("PostToolUse", toolID: "request-a")
        try waitUntil { store.approvals.isEmpty && store.agents.contains { $0.status == .working } }
        try emit("PermissionRequest")
        try waitUntil { store.approvals.count == 1 }
        try emit("Stop")
        try waitUntil { store.approvals.isEmpty && store.agents.contains { $0.status == .finished } }
        store.stop()
        try expect(store.approvals.isEmpty, "stopped monitoring removes its compact alert")
        let stoppedHook = store.lastHookAt
        try emit("UserPromptSubmit")
        RunLoop.main.run(until: Date().addingTimeInterval(2.3))
        try expect(store.lastHookAt == stoppedHook, "stopped or queued polling cannot publish new activity")
        let after = try Data(contentsOf: source)
        try expect(after == bytes, "usage files remain byte-for-byte unchanged")
        try installer.remove()
        try expect(!installer.isInstalled, "fixture uninstall removes only the integration")
    }

    private static func readOnlyActivity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexReadOnly-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let at = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-1))
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "main", "cwd": "/tmp/working-project"]],
            ["type": "event_msg", "timestamp": at, "payload": ["type": "task_started", "turn_id": "live-turn"]]
        ]
        var bytes = Data()
        for record in records { bytes.append(try JSONSerialization.data(withJSONObject: record)); bytes.append(10) }
        let file = root.appendingPathComponent("sessions/live.jsonl")
        try bytes.write(to: file)
        let suite = "CodexReadOnly.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CodexStore(codexHome: root, defaults: defaults)
        store.start()
        defer { store.stop() }
        try waitUntil { store.agents.contains { $0.id == "main" && $0.status == .working } }
        try expect(store.connection == .notInstalled && store.indicator == .working,
                   "working session remains visible without trusted hooks")
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("hooks.json").path),
                   "monitoring never installs hooks")
        let after = try Data(contentsOf: file)
        try expect(after == bytes, "live sessions remain read-only")
    }

    private static func geometry() throws {
        let state = IslandState()
        state.hasCodexAlert = true
        state.codexAlertProgress = 1
        try expect(state.surfaceWidth == state.collapsedWidth + IslandState.codexWingWidth,
                   "permission bubble occupies a right wing")
        try expect(state.surfaceOffsetX - state.surfaceWidth / 2 == -state.collapsedWidth / 2,
                   "permission wing leaves the physical left notch edge fixed")
        state.mediaProgress = 1
        for step in 0...60 {
            state.progress = CGFloat(step) / 60
            let left = state.surfaceOffsetX - state.surfaceWidth / 2
            let right = state.surfaceOffsetX + state.surfaceWidth / 2
            try expect(left >= -state.canvasSize.width / 2 && right <= state.canvasSize.width / 2,
                       "both wings remain inside the native canvas throughout expansion")
        }
        try expect(state.surfaceOffsetX == 0 && state.surfaceWidth == state.expandedWidth,
                   "expanded surface is centered without residual permission width")
        let suite = "CodexGeometry.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["clock"], forKey: "island.widgets")
        let settings = NotchSettings(defaults: defaults)
        settings.addWidget(.codex)
        try expect(NotchSettings(defaults: defaults).widgets == [.clock, .codex],
                   "Codex can be added without replacing previous widget choices")
    }
}
