// Isolated sandbox entitlement probe; never reads or changes a real Claude home.
import AppKit
import Darwin
import Foundation

let desktop = CommandLine.arguments.count == 1
let root = URL(fileURLWithPath: desktop ? Bundle.main.object(forInfoDictionaryKey: "ProbeFixture") as! String : CommandLine.arguments[1], isDirectory: true)
let own = root.appendingPathComponent("agentnotch", isDirectory: true)
let hooks = root.appendingPathComponent("settings.json")
var failures = 0
var results: [String] = []
func check(_ name: String, _ block: () throws -> Void) {
    do { try block(); print("PASS \(name)"); results.append("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error)"); results.append("FAIL \(name): \(error)") }
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: message, code: Int(errno)) }
}
check("stat-parent") {
    var info = stat()
    try require(lstat(root.path, &info) == 0, "lstat")
}
check("mkdir-owned-directory") {
    try FileManager.default.createDirectory(at: own, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
}
check("read-sessions") {
    _ = try Data(contentsOf: root.appendingPathComponent("sessions/fixture.jsonl"))
}
for phase in ["absent", "present"] {
    check("atomic-rename-hooks-\(phase)") {
        let staging = own.appendingPathComponent(UUID().uuidString)
        try Data(phase.utf8).write(to: staging, options: .atomic)
        let status = staging.path.withCString { source in hooks.path.withCString { rename(source, $0) } }
        try require(status == 0, "rename")
        try require(try Data(contentsOf: hooks) == Data(phase.utf8), "contents")
    }
}
check("remove-hooks") { try FileManager.default.removeItem(at: hooks) }
let installer = ClaudeHookInstaller(claudeHome: root,
    helperSource: desktop ? Bundle.main.resourceURL!.appendingPathComponent("Claude/agentnotch-claude-hook") : URL(fileURLWithPath: CommandLine.arguments[2]))
check("production-install-absent-hooks") {
    try installer.install()
    try require(installer.isInstalled, "installation-not-detected")
}
check("production-install-idempotent") {
    let before = try Data(contentsOf: hooks)
    try installer.install()
    try require(try Data(contentsOf: hooks) == before, "idempotent-bytes-changed")
}
check("production-remove-created-hooks") {
    try installer.remove()
    try require(!FileManager.default.fileExists(atPath: hooks.path), "created-hooks-remain")
    try require(!installer.isInstalled, "removed-installation-detected")
}
let original: [String: Any] = ["keep": "foreign-metadata", "statusLine": ["type": "command", "command": "cat >/dev/null; echo prior-status-line", "padding": 2], "hooks": ["Stop": [
    ["matcher": "*", "hooks": [["type": "command", "command": "foreign-command"]]]
]]]
check("production-install-existing-hooks") {
    try JSONSerialization.data(withJSONObject: original).write(to: hooks)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: hooks.path)
    try installer.install()
    try require(installer.isInstalled, "existing-installation-not-detected")
    let permissions = try FileManager.default.attributesOfItem(atPath: hooks.path)[.posixPermissions] as? Int
    try require(permissions == 0o640, "existing-permissions-changed")
}
check("production-remove-preserves-foreign-hooks") {
    try installer.remove()
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as? [String: Any]
    try require(root.map { NSDictionary(dictionary: $0).isEqual(to: original) } == true,
                "foreign-hooks-changed")
    let permissions = try FileManager.default.attributesOfItem(atPath: hooks.path)[.posixPermissions] as? Int
    try require(permissions == 0o640, "removal-permissions-changed")
}
for filename in ["auth.json", "ungranted.json"] {
    check("deny-write-\(filename)") {
        do {
            try Data("forbidden".utf8).write(to: root.appendingPathComponent(filename))
            throw NSError(domain: "unexpected-write-grant", code: 1)
        } catch let error as NSError where error.domain != "unexpected-write-grant" {
            // A denied read/write is the expected result.
        }
    }
}
check("deny-read-auth") {
    do {
        _ = try Data(contentsOf: root.appendingPathComponent("auth.json"))
        throw NSError(domain: "unexpected-read-grant", code: 1)
    } catch let error as NSError where error.domain != "unexpected-read-grant" {}
}
check("leave-owned-fixture-for-shell-delivery") { try installer.install() }
if desktop {
    try? results.joined(separator: "\n").write(to: own.appendingPathComponent("probe-results.txt"), atomically: true, encoding: .utf8)
    _ = NSApplication.shared
    let text = NSTextField(wrappingLabelWithString: results.joined(separator: "\n"))
    text.frame = NSRect(x: 20, y: 20, width: 700, height: 470)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 510), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Claude sandbox probe · \(failures) failures"
    window.contentView?.addSubview(text)
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.run()
}
exit(failures == 0 ? 0 : 1)
