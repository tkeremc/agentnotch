import CryptoKit
import Foundation
@testable import AgentNotch

struct CodexHookInstallerTests {
    static let cases: [(String, @MainActor () throws -> Void)] = [
        ("Codex hook install merges, is idempotent and preserves trust/config", installMerge),
        ("Codex hook removal preserves unrelated hooks and event history", removeMerge),
        ("Codex hook malformed files fail before writing", malformed),
        ("Codex hook modified helper or definition is never overwritten", conflicts),
        ("Codex hook installer rejects symlinks and unowned helper", unsafe),
        ("Codex hook empty installation removes only owned artifacts", cleanRemoval),
        ("Codex hook removal does not recreate a deleted hook file", missingHookRemoval),
        ("Codex hook reinstall repairs a missing spool without modifying bundled files", repair),
        ("Codex legacy quarantined copies migrate to direct bundled execution", legacyMigration),
        ("Codex moved app and updated helper are repairable", movedOrUpdated),
        ("Codex modified legacy binary or hook is preserved", legacyConflicts),
        ("Codex unsafe bundled helper and manifest paths are rejected", sourceSafety),
        ("Codex hook installer quotes paths with spaces and apostrophes", quoting)
    ]
    private struct Failure: Error { let message: String }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message: message) }
    }
    private static func fixture(_ body: (URL, URL, CodexHookInstaller) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Codex hooks 'fixture \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("bundled-helper")
        try Data("fixture helper".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        let home = directory.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try body(home, source, CodexHookInstaller(codexHome: home, helperSource: source))
    }
    private static func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    private static func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
    private static func mustFail(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw Failure(message: "operation unexpectedly succeeded")
    }
    private static let foreign: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "echo existing"]]]

    private static func installMerge() throws {
        try fixture { home, source, installer in
            let config = home.appendingPathComponent("config.toml")
            let trust = home.appendingPathComponent("hooks-trust.json")
            let configBytes = Data("[hooks]\ninline = 'must remain'\n".utf8)
            let trustBytes = Data("trusted existing definition hash".utf8)
            try configBytes.write(to: config); try trustBytes.write(to: trust)
            try write(["custom": ["value": 7], "hooks": ["PermissionRequest": [foreign]]], to: installer.hooksURL)
            try installer.install()
            try expect(installer.isInstalled && !installer.needsRepair, "installation state")
            try expect(installer.executionURL == source, "hooks must execute the bundled source")
            try expect(!FileManager.default.fileExists(atPath: installer.helperURL.path), "installation copied executable into Codex")
            let installedManifest = try json(installer.integrationDirectory.appendingPathComponent("installation.json"))
            try expect(installedManifest["schemaVersion"] as? Int == 2 && installedManifest["helperPath"] as? String == source.path,
                       "v2 manifest must identify the bundled source")
            let root = try json(installer.hooksURL)
            let groups = (root["hooks"] as! [String: Any])["PermissionRequest"] as! [[String: Any]]
            try expect(groups.count == 2 && NSDictionary(dictionary: groups[0]).isEqual(to: foreign), "existing group changed")
            try expect((root["custom"] as? [String: Int])?["value"] == 7, "top-level field lost")
            let hooksBytes = try Data(contentsOf: installer.hooksURL)
            let manifest = installer.integrationDirectory.appendingPathComponent("installation.json")
            let manifestBytes = try Data(contentsOf: manifest)
            try installer.install()
            try expect(try Data(contentsOf: installer.hooksURL) == hooksBytes, "idempotence rewrote hooks")
            try expect(try Data(contentsOf: manifest) == manifestBytes, "idempotence rewrote manifest")
            try expect(try Data(contentsOf: config) == configBytes, "inline config changed")
            try expect(try Data(contentsOf: trust) == trustBytes, "trust changed")
            let mode = try FileManager.default.attributesOfItem(atPath: installer.eventsDirectory.path)[.posixPermissions] as! Int
            try expect(mode == 0o700, "spool must be private")
        }
    }

    private static func removeMerge() throws {
        try fixture { _, _, installer in
            try installer.install()
            let history = installer.eventsDirectory.appendingPathComponent("keep.json")
            try Data("history".utf8).write(to: history)
            var root = try json(installer.hooksURL)
            var hooks = root["hooks"] as! [String: Any]
            var groups = hooks["PermissionRequest"] as! [[String: Any]]
            groups.append(foreign); hooks["PermissionRequest"] = groups
            root["hooks"] = hooks
            try write(root, to: installer.hooksURL)
            try installer.remove()
            let after = (try json(installer.hooksURL))["hooks"] as! [String: Any]
            try expect(after.count == 1 && (after["PermissionRequest"] as! [[String: Any]]).count == 1, "unrelated hook removed")
            try expect(FileManager.default.fileExists(atPath: history.path), "history removed")
            try expect(!installer.isInstalled && !FileManager.default.fileExists(atPath: installer.helperURL.path), "owned helper remained")
            try installer.remove()
        }
    }

    private static func malformed() throws {
        for bytes in [Data("{broken".utf8), Data("{\"hooks\":{\"Stop\":\"invalid\"}}".utf8)] {
            try fixture { _, _, installer in
                try bytes.write(to: installer.hooksURL)
                try mustFail { try installer.install() }
                try expect(try Data(contentsOf: installer.hooksURL) == bytes, "malformed hooks changed")
                try expect(!FileManager.default.fileExists(atPath: installer.integrationDirectory.path), "failed install left artifacts")
            }
        }
    }

    private static func conflicts() throws {
        try fixture { _, _, installer in
            try installer.install()
            let original = try Data(contentsOf: installer.hooksURL)
            try FileManager.default.createDirectory(at: installer.helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("user added legacy executable".utf8).write(to: installer.helperURL)
            try mustFail { try installer.install() }
            try mustFail { try installer.remove() }
            try expect(try Data(contentsOf: installer.hooksURL) == original, "conflict changed hooks")
        }
        try fixture { _, _, installer in
            try installer.install()
            var root = try json(installer.hooksURL)
            var hooks = root["hooks"] as! [String: Any]
            var groups = hooks["Stop"] as! [[String: Any]]
            groups[0]["matcher"] = "user changed"
            hooks["Stop"] = groups; root["hooks"] = hooks
            try write(root, to: installer.hooksURL)
            let bytes = try Data(contentsOf: installer.hooksURL)
            try mustFail { try installer.remove() }
            try expect(try Data(contentsOf: installer.hooksURL) == bytes, "modified definition changed")
        }
    }

    private static func unsafe() throws {
        try fixture { home, _, installer in
            let target = home.appendingPathComponent("outside.json")
            try Data("{}".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: installer.hooksURL, withDestinationURL: target)
            try mustFail { try installer.install() }
            try expect(try Data(contentsOf: target) == Data("{}".utf8), "symlink target changed")
        }
        try fixture { _, _, installer in
            try FileManager.default.createDirectory(at: installer.helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data("not ours".utf8)
            try bytes.write(to: installer.helperURL)
            try mustFail { try installer.install() }
            try expect(try Data(contentsOf: installer.helperURL) == bytes, "unowned helper changed")
        }
    }

    private static func cleanRemoval() throws {
        try fixture { _, _, installer in
            try installer.install(); try installer.remove()
            try expect(!FileManager.default.fileExists(atPath: installer.hooksURL.path), "created empty hook file remained")
            try expect(!FileManager.default.fileExists(atPath: installer.integrationDirectory.appendingPathComponent("installation.json").path), "manifest remained")
        }
    }

    private static func quoting() throws {
        try fixture { _, _, installer in
            try installer.install()
            let root = try json(installer.hooksURL)
            let hooks = root["hooks"] as! [String: Any]
            let group = (hooks["PermissionRequest"] as! [[String: Any]])[0]
            let handler = (group["hooks"] as! [[String: Any]])[0]
            let command = handler["command"] as! String
            try expect(command.contains("'\\''") && command.contains(" --events-dir '"), "shell quoting missing")
            try expect((handler["timeout"] as? Int) == 3, "bounded hook timeout")
        }
    }

    private static func missingHookRemoval() throws {
        try fixture { _, _, installer in
            try write(["hooks": ["Stop": [foreign]]], to: installer.hooksURL)
            try installer.install()
            try FileManager.default.removeItem(at: installer.hooksURL)
            try installer.remove()
            try expect(!FileManager.default.fileExists(atPath: installer.hooksURL.path), "deleted hooks recreated")
        }
    }

    private static func repair() throws {
        try fixture { _, _, installer in
            try installer.install()
            try FileManager.default.removeItem(at: installer.eventsDirectory)
            try expect(!installer.isInstalled, "missing spool treated as functional")
            try installer.install()
            try expect(installer.isInstalled, "missing spool not repaired")
            guard let source = installer.executionURL else { throw Failure(message: "fixture source missing") }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
            try expect(!installer.isInstalled && installer.needsRepair, "nonexecutable bundle source treated as functional")
            try mustFail { try installer.install() }
            let mode = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as! Int
            try expect(mode == 0o600, "installer modified bundled source permissions")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
            try installer.install()
            try expect(installer.isInstalled, "restored source not recognized")
        }
    }

    /// Materialize a historical v1 fixture, without invoking its executable.
    private static func legacy(_ installer: CodexHookInstaller, source: URL) throws {
        let events = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse",
                      "Stop", "Interrupt", "SubagentStart", "SubagentStop", "SessionEnd"]
        try FileManager.default.createDirectory(at: installer.helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installer.eventsDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let bytes = try Data(contentsOf: source)
        try bytes.write(to: installer.helperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installer.helperURL.path)
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "\(quote(installer.helperURL.path)) --events-dir \(quote(installer.eventsDirectory.path))"
        let group: [String: Any] = ["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": 3]]]
        var hooks: [String: Any] = [:]
        for event in events { hooks[event] = [group] }
        hooks["PermissionRequest"] = [foreign, group]
        try write(["hooks": hooks], to: installer.hooksURL)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try write(["schemaVersion": 1, "command": command, "events": events,
                   "helperSHA256": hash, "createdHooksFile": false],
                  to: installer.integrationDirectory.appendingPathComponent("installation.json"))
    }

    private static func legacyMigration() throws {
        try fixture { home, source, installer in
            try legacy(installer, source: source)
            let trust = home.appendingPathComponent("hooks-trust.json")
            let trustBytes = Data("keep user trust decisions".utf8)
            try trustBytes.write(to: trust)
            let sourceBytes = try Data(contentsOf: source)
            try expect(!installer.isInstalled && installer.needsRepair, "v1 must request repair")
            try installer.install()
            try expect(installer.isInstalled && !installer.needsRepair, "v1 did not migrate")
            try expect(!FileManager.default.fileExists(atPath: installer.helperURL.path), "owned legacy executable remained")
            try expect(try Data(contentsOf: source) == sourceBytes, "bundled executable changed")
            try expect(try Data(contentsOf: trust) == trustBytes, "migration changed trust decisions")
            let hooks = (try json(installer.hooksURL))["hooks"] as! [String: Any]
            try expect(hooks["PreToolUse"] != nil, "migration omitted new event")
            try expect((hooks["PermissionRequest"] as! [[String: Any]]).contains { NSDictionary(dictionary: $0).isEqual(to: foreign) },
                       "migration removed unrelated hook")
            try installer.remove()
            try expect(try Data(contentsOf: source) == sourceBytes, "removal changed bundled executable")
        }
        try fixture { _, source, installer in
            try legacy(installer, source: source)
            try installer.remove()
            try expect(!FileManager.default.fileExists(atPath: installer.helperURL.path), "legacy removal left owned copy")
            try expect(FileManager.default.fileExists(atPath: source.path), "legacy removal deleted bundle")
        }
    }

    private static func movedOrUpdated() throws {
        try fixture { home, source, installer in
            try installer.install()
            let moved = source.deletingLastPathComponent().appendingPathComponent("Moved App")
                .appendingPathComponent(source.lastPathComponent)
            try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: moved)
            let relocated = CodexHookInstaller(codexHome: home, helperSource: moved)
            try expect(!relocated.isInstalled && relocated.needsRepair, "app move should be repairable")
            try relocated.install()
            try expect(relocated.isInstalled, "moved app did not repair")
            let hooks = try Data(contentsOf: relocated.hooksURL)
            try Data("updated signed resource fixture".utf8).write(to: moved)
            try expect(!relocated.isInstalled && relocated.needsRepair, "app update should be repairable")
            try relocated.install()
            try expect(relocated.isInstalled, "updated app did not repair")
            try expect(try Data(contentsOf: relocated.hooksURL) == hooks, "same command update changed hook trust bytes")
            let updated = try Data(contentsOf: moved)
            try relocated.remove()
            try expect(try Data(contentsOf: moved) == updated, "removal modified relocated bundle")
        }
    }

    private static func legacyConflicts() throws {
        for changeBinary in [true, false] {
            try fixture { _, source, installer in
                try legacy(installer, source: source)
                if changeBinary {
                    try Data("user modified legacy binary".utf8).write(to: installer.helperURL)
                } else {
                    var root = try json(installer.hooksURL)
                    var hooks = root["hooks"] as! [String: Any]
                    var groups = hooks["Stop"] as! [[String: Any]]
                    groups[0]["matcher"] = "modified by user"
                    hooks["Stop"] = groups; root["hooks"] = hooks
                    try write(root, to: installer.hooksURL)
                }
                let hookBytes = try Data(contentsOf: installer.hooksURL)
                let helperBytes = try Data(contentsOf: installer.helperURL)
                let manifest = installer.integrationDirectory.appendingPathComponent("installation.json")
                let manifestBytes = try Data(contentsOf: manifest)
                try expect(!installer.needsRepair, "modified legacy install must not be automatically repairable")
                try mustFail { try installer.install() }
                try mustFail { try installer.remove() }
                try expect(try Data(contentsOf: installer.hooksURL) == hookBytes, "conflict changed hooks")
                try expect(try Data(contentsOf: installer.helperURL) == helperBytes, "conflict changed helper")
                try expect(try Data(contentsOf: manifest) == manifestBytes, "conflict changed manifest")
            }
        }
    }

    private static func sourceSafety() throws {
        try fixture { home, source, installer in
            let link = source.deletingLastPathComponent().appendingPathComponent("linked-helper")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            let linked = CodexHookInstaller(codexHome: home, helperSource: link)
            try mustFail { try linked.install() }
            try expect(!FileManager.default.fileExists(atPath: installer.integrationDirectory.path), "symlink source left files")
            try installer.install()
            let manifestURL = installer.integrationDirectory.appendingPathComponent("installation.json")
            var manifest = try json(manifestURL)
            manifest["helperPath"] = "/usr/bin/false"
            try write(manifest, to: manifestURL)
            let before = try Data(contentsOf: installer.hooksURL)
            try mustFail { try installer.install() }
            try mustFail { try installer.remove() }
            try expect(try Data(contentsOf: installer.hooksURL) == before, "unsafe manifest changed hooks")
        }
    }

}
