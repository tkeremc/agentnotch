import CryptoKit
import Foundation
@testable import AgentNotch

struct ClaudeHookInstallerTests {
    static let cases: [(String, @MainActor () throws -> Void)] = [
        ("Claude install preserves settings, hooks and complete status line", installMerge),
        ("Claude removal restores original status line and preserves new user settings", removeMerge),
        ("Claude install and removal without existing settings are reversible", cleanRemoval),
        ("Claude malformed settings fail without modifications", malformed),
        ("Claude changed hooks and status line fail without modifications", conflicts),
        ("Claude installer rejects unsafe paths and helper sources", unsafePaths),
        ("Claude missing spool and missing definitions can be explicitly repaired", repair),
        ("Claude moved app and updated bundled helper can be repaired", movedOrUpdated),
        ("Claude deleted settings and status line are not resurrected on removal", deletedSettings),
        ("Claude missing manifest with owned commands is a safe conflict", orphaned),
        ("Claude installer preserves hook disabling and unrelated status line fields", preservation),
        ("Claude malformed or modified manifest is never overwritten", manifestConflict),
        ("Claude user replacement status line is preserved on disconnect", replacedStatusLine),
        ("Claude private installer lock prevents concurrent modifications", busy),
        ("Claude hook commands quote paths with spaces and apostrophes", quoting)
    ]
    private struct Failure: Error { let message: String }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message: message) }
    }
    private static func mustFail(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw Failure(message: "operation unexpectedly succeeded")
    }
    private static let foreign: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "echo existing"]]]
    private static let originalLine: [String: Any] = ["type": "command", "command": "echo 'existing line'", "padding": 3,
                                                     "futureField": ["preserve": true]]
    private static func fixture(_ body: (URL, URL, ClaudeHookInstaller) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Claude hooks 'fixture \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("agentnotch-claude-hook")
        try Data("bundled helper fixture".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        let home = directory.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try body(home, source, ClaudeHookInstaller(claudeHome: home, helperSource: source))
    }
    private static func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    private static func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
    private static func equal(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool { NSDictionary(dictionary: lhs).isEqual(to: rhs) }
    private static func manifestURL(_ installer: ClaudeHookInstaller) -> URL {
        installer.integrationDirectory.appendingPathComponent("installation.json")
    }

    private static func installMerge() throws {
        try fixture { home, source, installer in
            let credentials = home.appendingPathComponent("credentials-test-fixture.json")
            let authBytes = Data("fixture: must never be read or changed".utf8)
            try authBytes.write(to: credentials)
            try write(["model": "custom-model", "permissions": ["deny": ["Bash(rm *)"]], "statusLine": originalLine,
                       "hooks": ["Stop": [foreign]]], to: installer.settingsURL)
            try installer.install()
            try expect(installer.isInstalled && !installer.needsRepair, "installation state")
            try expect(installer.executionURL == source, "helper must run directly from bundle")
            let root = try json(installer.settingsURL)
            let hooks = root["hooks"] as! [String: Any]
            try expect((hooks["Stop"] as! [[String: Any]]).contains { equal($0, foreign) }, "foreign hook lost")
            var status = root["statusLine"] as! [String: Any]
            try expect((status["command"] as! String).hasSuffix(" --statusline"), "statusline not wrapped")
            status["command"] = originalLine["command"]
            try expect(equal(status, originalLine), "statusline fields changed")
            try expect(root["model"] as? String == "custom-model", "model changed")
            let saved = try json(manifestURL(installer))
            let original = try JSONSerialization.jsonObject(with: Data(base64Encoded: saved["originalStatusLine"] as! String)!) as! [String: Any]
            try expect(equal(original, originalLine), "original statusline not saved")
            let settingsBytes = try Data(contentsOf: installer.settingsURL)
            let manifestBytes = try Data(contentsOf: manifestURL(installer))
            try installer.install()
            try expect(try Data(contentsOf: installer.settingsURL) == settingsBytes, "idempotence rewrote settings")
            try expect(try Data(contentsOf: manifestURL(installer)) == manifestBytes, "idempotence rewrote manifest")
            try expect(try Data(contentsOf: credentials) == authBytes, "unrelated file changed")
            let mode = try FileManager.default.attributesOfItem(atPath: installer.eventsDirectory.path)[.posixPermissions] as! Int
            try expect(mode == 0o700, "events not private")
            try expect((try FileManager.default.attributesOfItem(atPath: manifestURL(installer).path)[.posixPermissions] as! Int) == 0o600,
                       "manifest not private")
        }
    }
    private static func removeMerge() throws {
        try fixture { _, source, installer in
            try write(["statusLine": originalLine, "hooks": ["Stop": [foreign]]], to: installer.settingsURL)
            try installer.install()
            let history = installer.eventsDirectory.appendingPathComponent("user-file.json")
            try Data("keep".utf8).write(to: history)
            var root = try json(installer.settingsURL)
            root["newSetting"] = "user value"
            var hooks = root["hooks"] as! [String: Any]
            hooks["NewFutureEvent"] = [foreign]; root["hooks"] = hooks
            try write(root, to: installer.settingsURL)
            try installer.remove()
            let after = try json(installer.settingsURL)
            try expect(equal(after["statusLine"] as! [String: Any], originalLine), "original status line not restored")
            try expect(after["newSetting"] as? String == "user value", "new setting removed")
            try expect((after["hooks"] as! [String: Any]).count == 2, "foreign hooks removed")
            try expect(try Data(contentsOf: history) == Data("keep".utf8), "history removed")
            try expect(FileManager.default.fileExists(atPath: source.path), "bundled source removed")
            try expect(!FileManager.default.fileExists(atPath: manifestURL(installer).path), "manifest remains")
            try installer.remove()
        }
    }
    private static func cleanRemoval() throws {
        try fixture { _, _, installer in
            try installer.install(); try installer.remove()
            try expect(!FileManager.default.fileExists(atPath: installer.settingsURL.path), "created empty settings remain")
        }
        try fixture { _, _, installer in
            let empty = Data("{}".utf8)
            try empty.write(to: installer.settingsURL)
            try installer.install(); try installer.remove()
            try expect(try json(installer.settingsURL).isEmpty, "preexisting empty settings removed")
        }
    }
    private static func malformed() throws {
        for bytes in [Data("{broken".utf8), Data("{\"hooks\":{\"Stop\":\"invalid\"}}".utf8),
                      Data("{\"statusLine\":\"invalid\"}".utf8), Data("{\"statusLine\":{\"type\":\"command\"}}".utf8)] {
            try fixture { _, _, installer in
                try bytes.write(to: installer.settingsURL)
                try mustFail { try installer.install() }
                try expect(try Data(contentsOf: installer.settingsURL) == bytes, "malformed file changed")
                try expect(!FileManager.default.fileExists(atPath: installer.integrationDirectory.path), "failed install left artifacts")
            }
        }
    }
    private static func conflicts() throws {
        for changeStatus in [true, false] {
            try fixture { _, _, installer in
                try write(["statusLine": originalLine], to: installer.settingsURL)
                try installer.install()
                var root = try json(installer.settingsURL)
                if changeStatus {
                    var status = root["statusLine"] as! [String: Any]
                    status["padding"] = 99; root["statusLine"] = status
                } else {
                    var hooks = root["hooks"] as! [String: Any]
                    var groups = hooks["Stop"] as! [[String: Any]]
                    groups[0]["matcher"] = "changed"; hooks["Stop"] = groups; root["hooks"] = hooks
                }
                try write(root, to: installer.settingsURL)
                let before = try Data(contentsOf: installer.settingsURL)
                try expect(!installer.isInstalled && !installer.needsRepair, "modified installation repairable")
                try mustFail { try installer.install() }; try mustFail { try installer.remove() }
                try expect(try Data(contentsOf: installer.settingsURL) == before, "modified settings overwritten")
            }
        }
    }
    private static func unsafePaths() throws {
        try fixture { home, source, installer in
            let target = home.appendingPathComponent("other.json")
            try Data("{}".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: installer.settingsURL, withDestinationURL: target)
            try mustFail { try installer.install() }
            try expect(try Data(contentsOf: target) == Data("{}".utf8), "symlink target changed")
            let linked = source.deletingLastPathComponent().appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: source)
            try FileManager.default.removeItem(at: installer.settingsURL)
            try mustFail { try ClaudeHookInstaller(claudeHome: home, helperSource: linked).install() }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
            try mustFail { try installer.install() }
        }
        try fixture { _, _, installer in
            let foreign = installer.claudeHome.appendingPathComponent("foreign")
            try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: installer.integrationDirectory, withDestinationURL: foreign)
            try mustFail { try installer.install() }
        }
    }
    private static func repair() throws {
        try fixture { _, _, installer in
            try installer.install()
            try FileManager.default.removeItem(at: installer.eventsDirectory)
            try expect(!installer.isInstalled && installer.needsRepair, "missing spool not repairable")
            try installer.install()
            var root = try json(installer.settingsURL)
            var hooks = root["hooks"] as! [String: Any]; hooks.removeValue(forKey: "Stop")
            root["hooks"] = hooks; root.removeValue(forKey: "statusLine")
            try write(root, to: installer.settingsURL)
            try expect(!installer.isInstalled && installer.needsRepair, "missing definitions not repairable")
            try installer.install()
            try expect(installer.isInstalled, "repair failed")
        }
    }
    private static func movedOrUpdated() throws {
        try fixture { home, source, installer in
            try write(["statusLine": originalLine], to: installer.settingsURL)
            try installer.install()
            let moved = source.deletingLastPathComponent().appendingPathComponent("Moved App/\(source.lastPathComponent)")
            try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: moved)
            let relocated = ClaudeHookInstaller(claudeHome: home, helperSource: moved)
            try expect(!relocated.isInstalled && relocated.needsRepair, "moved app not repairable")
            try relocated.install(); try expect(relocated.isInstalled, "moved app repair failed")
            let before = try Data(contentsOf: relocated.settingsURL)
            try Data("updated bundled helper".utf8).write(to: moved)
            try expect(!relocated.isInstalled && relocated.needsRepair, "updated app not repairable")
            try relocated.install()
            try expect(try Data(contentsOf: relocated.settingsURL) == before, "binary update rewrote settings")
            try relocated.remove()
            try expect(equal(try json(relocated.settingsURL)["statusLine"] as! [String: Any], originalLine), "repair lost original line")
        }
    }
    private static func deletedSettings() throws {
        for deleteFile in [true, false] {
            try fixture { _, _, installer in
                try write(["statusLine": originalLine], to: installer.settingsURL)
                try installer.install()
                if deleteFile { try FileManager.default.removeItem(at: installer.settingsURL) }
                else {
                    var root = try json(installer.settingsURL); root.removeValue(forKey: "statusLine")
                    try write(root, to: installer.settingsURL)
                }
                try installer.remove()
                if deleteFile { try expect(!FileManager.default.fileExists(atPath: installer.settingsURL.path), "deleted settings recreated") }
                else { try expect(try json(installer.settingsURL)["statusLine"] == nil, "deleted line recreated") }
            }
        }
    }
    private static func orphaned() throws {
        try fixture { _, _, installer in
            try installer.install()
            try FileManager.default.removeItem(at: manifestURL(installer))
            let before = try Data(contentsOf: installer.settingsURL)
            try mustFail { try installer.install() }
            try expect(try Data(contentsOf: installer.settingsURL) == before, "orphaned commands overwritten")
        }
        try fixture { _, _, installer in
            try write(["statusLine": ["type": "command", "command": "agentnotch-claude-hook --statusline"]], to: installer.settingsURL)
            try mustFail { try installer.install() }
        }
    }
    private static func preservation() throws {
        try fixture { _, _, installer in
            try write(["disableAllHooks": true, "statusLine": originalLine, "hooks": [:],
                       "env": ["EXAMPLE": "fixture"]], to: installer.settingsURL)
            try installer.install()
            try expect(try json(installer.settingsURL)["disableAllHooks"] as? Bool == true, "hook disabling changed")
            try installer.remove()
            let root = try json(installer.settingsURL)
            try expect((root["hooks"] as? [String: Any])?.isEmpty == true, "original hooks key changed")
            try expect(root["disableAllHooks"] as? Bool == true, "uninstall changed disabling")
            try expect(equal(root["statusLine"] as! [String: Any], originalLine), "line changed")
        }
    }
    private static func manifestConflict() throws {
        try fixture { _, _, installer in
            try installer.install()
            let settings = try Data(contentsOf: installer.settingsURL)
            var manifest = try json(manifestURL(installer))
            manifest["helperPath"] = "/usr/bin/false"
            try write(manifest, to: manifestURL(installer))
            try mustFail { try installer.install() }; try mustFail { try installer.remove() }
            try expect(try Data(contentsOf: installer.settingsURL) == settings, "unsafe manifest changed settings")
        }
    }
    private static func replacedStatusLine() throws {
        try fixture { _, _, installer in
            try write(["statusLine": originalLine], to: installer.settingsURL)
            try installer.install()
            let replacement: [String: Any] = ["type": "command", "command": "printf replacement", "padding": 7]
            var root = try json(installer.settingsURL)
            root["statusLine"] = replacement
            try write(root, to: installer.settingsURL)
            try mustFail { try installer.install() }
            try installer.remove()
            let result = try json(installer.settingsURL)
            try expect(equal(result["statusLine"] as! [String: Any], replacement), "replacement line overwritten")
            try expect(result["hooks"] == nil, "owned hooks remain")
            try expect(!FileManager.default.fileExists(atPath: manifestURL(installer).path), "manifest remains")
        }
    }
    private static func busy() throws {
        try fixture { _, _, installer in
            try installer.install()
            let lock = installer.integrationDirectory.appendingPathComponent(".installation-lock")
            try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
            let before = try Data(contentsOf: installer.settingsURL)
            try mustFail { try installer.remove() }
            try expect(try Data(contentsOf: installer.settingsURL) == before, "busy install changed settings")
        }
    }
    private static func quoting() throws {
        try fixture { _, _, installer in
            try installer.install()
            let root = try json(installer.settingsURL)
            let hooks = root["hooks"] as! [String: Any]
            let group = (hooks["PermissionRequest"] as! [[String: Any]])[0]
            let handler = (group["hooks"] as! [[String: Any]])[0]
            let command = handler["command"] as! String
            try expect(command.contains("'\\''") && command.contains(" --events-dir '"), "shell quote missing")
            try expect(handler["timeout"] as? Int == 3, "hook timeout not bounded")
        }
    }
}
