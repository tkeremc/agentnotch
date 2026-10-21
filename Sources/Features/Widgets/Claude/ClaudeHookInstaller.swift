import CryptoKit
import Darwin
import Foundation

/// Opt-in Claude Code integration. Only settings.json and our private directory
/// are changed; unrelated hooks and the complete original status line survive.
struct ClaudeHookInstaller {
    enum InstallationError: Error, LocalizedError {
        case missingHelper, unsafePath, malformedSettings, conflictingInstallation, installationBusy
        var errorDescription: String? {
            switch self {
            case .missingHelper: return "The bundled Claude hook helper is missing."
            case .unsafePath: return "The Claude integration path is not a regular private location."
            case .malformedSettings: return "The existing Claude settings could not be safely read."
            case .conflictingInstallation: return "The existing Claude integration has been changed."
            case .installationBusy: return "Another Claude integration change is in progress."
            }
        }
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let command: String
        let statusLineCommand: String
        let events: [String]
        let helperSHA256: String
        let helperPath: String
        let createdSettingsFile: Bool
        let hadHooksKey: Bool
        // JSON bytes preserve unknown statusLine fields and keep the command
        // out of the hook payload. Only this owner-validated manifest is read.
        let originalStatusLine: Data?
    }

    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                         "PostToolUse", "PostToolUseFailure", "Notification", "SubagentStart",
                         "SubagentStop", "Stop", "StopFailure", "SessionEnd"]
    let claudeHome: URL
    let settingsURL: URL
    let helperSource: URL?
    var integrationDirectory: URL { claudeHome.appendingPathComponent("agentnotch", isDirectory: true) }
    var eventsDirectory: URL { integrationDirectory.appendingPathComponent("events", isDirectory: true) }
    var executionURL: URL? { helperSource }
    private var manifestURL: URL { integrationDirectory.appendingPathComponent("installation.json") }

    init(claudeHome: URL, helperSource: URL? = nil, settingsURL: URL? = nil) {
        let home = claudeHome.standardizedFileURL
        self.claudeHome = home
        self.settingsURL = (settingsURL ?? home.appendingPathComponent("settings.json")).standardizedFileURL
        self.helperSource = (helperSource ?? Bundle.main.resourceURL?
            .appendingPathComponent("Claude/agentnotch-claude-hook"))?.standardizedFileURL
    }

    private func command(for helper: URL) -> String {
        "\(Self.quote(helper.path)) --events-dir \(Self.quote(eventsDirectory.path))"
    }
    private func group(for command: String) -> [String: Any] {
        ["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": 3]]]
    }
    private func originalStatusLine(_ manifest: Manifest) throws -> [String: Any]? {
        guard let bytes = manifest.originalStatusLine else { return nil }
        guard let value = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              value["type"] as? String == "command", let command = value["command"] as? String,
              !command.contains("agentnotch-claude-hook"), !command.contains(manifest.helperPath) else {
            throw InstallationError.conflictingInstallation
        }
        return value
    }
    private func statusLine(_ manifest: Manifest) throws -> [String: Any] {
        var value = try originalStatusLine(manifest) ?? [:]
        value["type"] = "command"
        value["command"] = manifest.statusLineCommand
        return value
    }

    var isInstalled: Bool {
        guard (try? validatePaths()) != nil,
              let manifest = try? readManifest(), let source = executionURL,
              manifest.helperPath == source.path,
              let bytes = try? executableData(), Self.hash(bytes) == manifest.helperSHA256,
              let root = try? readSettings(), let hooks = root["hooks"] as? [String: Any],
              (try? validateOwnership(manifest, root: root)) != nil,
              let expectedStatus = try? statusLine(manifest),
              let actualStatus = root["statusLine"] as? [String: Any], Self.equal(actualStatus, expectedStatus)
        else { return false }
        var info = stat()
        guard lstat(eventsDirectory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return false }
        let expected = group(for: manifest.command)
        return Self.events.allSatisfy {
            ((hooks[$0] as? [[String: Any]]) ?? []).filter { Self.equal($0, expected) }.count == 1
        }
    }

    var needsRepair: Bool {
        guard !isInstalled, (try? validatePaths()) != nil,
              let manifest = try? readManifest(), let root = try? readSettings(),
              (try? validateOwnership(manifest, root: root)) != nil else { return false }
        return true
    }

    func install() throws {
        try validatePaths()
        let bytes = try executableData()
        guard let source = executionURL else { throw InstallationError.missingHelper }
        let originalSettings = try existingData(settingsURL)
        let originalManifest = try existingData(manifestURL)
        var root = try readSettings()
        let previous = try readManifest()
        try validateOwnership(previous, root: root)
        if isInstalled { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        if let previous {
            let oldGroup = group(for: previous.command)
            for event in previous.events {
                if let groups = hooks[event] as? [[String: Any]] {
                    let remaining = groups.filter { !Self.equal($0, oldGroup) }
                    if remaining.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = remaining }
                }
            }
        }
        let newCommand = command(for: source)
        for event in Self.events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(group(for: newCommand)); hooks[event] = groups
        }
        let originalStatus: Data?
        if let previous { originalStatus = previous.originalStatusLine }
        else if let value = root["statusLine"] {
            originalStatus = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        } else { originalStatus = nil }
        let manifest = Manifest(schemaVersion: 1, command: newCommand,
            statusLineCommand: newCommand + " --statusline", events: Self.events,
            helperSHA256: Self.hash(bytes), helperPath: source.path,
            createdSettingsFile: previous?.createdSettingsFile ?? (originalSettings == nil),
            hadHooksKey: previous?.hadHooksKey ?? (root["hooks"] != nil), originalStatusLine: originalStatus)
        root["hooks"] = hooks
        root["statusLine"] = try statusLine(manifest)
        let newSettings = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        // A binary-only update must not rewrite settings unnecessarily.
        let settings = try readSettings()
        let settingsBytes = Self.equal(root, settings) ? originalSettings : newSettings
        try privateDirectory(integrationDirectory)
        try withLock {
            try validatePaths()
            guard try existingData(settingsURL) == originalSettings,
                  try existingData(manifestURL) == originalManifest else { throw InstallationError.conflictingInstallation }
            try validateOwnership(previous, root: try readSettings())
            try privateDirectory(eventsDirectory)
            try transaction([(manifestURL, try JSONEncoder().encode(manifest), 0o600),
                             (settingsURL, settingsBytes, nil)])
        }
    }

    func remove() throws {
        try validatePaths()
        guard let manifest = try readManifest() else { return }
        let originalSettings = try existingData(settingsURL)
        let originalManifest = try existingData(manifestURL)
        var root = try readSettings()
        try validateOwnership(manifest, root: root, allowReplacedStatusLine: true)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let owned = group(for: manifest.command)
        for event in manifest.events {
            if let groups = hooks[event] as? [[String: Any]] {
                let remaining = groups.filter { !Self.equal($0, owned) }
                if remaining.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = remaining }
            }
        }
        if hooks.isEmpty && !manifest.hadHooksKey { root.removeValue(forKey: "hooks") }
        else { root["hooks"] = hooks }
        // Deleted settings/statusLine are user intent; never resurrect either.
        if let current = root["statusLine"] as? [String: Any], Self.equal(current, try statusLine(manifest)) {
            if let original = try originalStatusLine(manifest) { root["statusLine"] = original }
            else { root.removeValue(forKey: "statusLine") }
        }
        let updated: Data? = originalSettings == nil || (manifest.createdSettingsFile && root.isEmpty)
            ? nil : try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try withLock {
            try validatePaths()
            guard try existingData(settingsURL) == originalSettings,
                  try existingData(manifestURL) == originalManifest else { throw InstallationError.conflictingInstallation }
            try validateOwnership(manifest, root: try readSettings(), allowReplacedStatusLine: true)
            try transaction([(settingsURL, updated, nil), (manifestURL, nil, nil)])
        }
    }

    private func readSettings() throws -> [String: Any] {
        guard let bytes = try existingData(settingsURL) else { return [:] }
        guard let root = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            throw InstallationError.malformedSettings
        }
        if let value = root["hooks"] {
            guard let hooks = value as? [String: Any], hooks.values.allSatisfy({ $0 is [[String: Any]] }) else {
                throw InstallationError.malformedSettings
            }
        }
        if let value = root["statusLine"] {
            guard let status = value as? [String: Any], status["type"] as? String == "command",
                  let command = status["command"] as? String, !command.isEmpty,
                  command.utf8.count <= 65_536 else { throw InstallationError.malformedSettings }
        }
        return root
    }

    private func readManifest() throws -> Manifest? {
        guard let bytes = try existingData(manifestURL) else { return nil }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes), manifest.schemaVersion == 1,
              manifest.events == Self.events, manifest.helperSHA256.count == 64,
              manifest.helperSHA256.allSatisfy(\.isHexDigit), manifest.helperPath.hasPrefix("/"),
              URL(fileURLWithPath: manifest.helperPath).standardizedFileURL.path == manifest.helperPath,
              !manifest.helperPath.hasPrefix(claudeHome.path + "/"),
              URL(fileURLWithPath: manifest.helperPath).lastPathComponent == executionURL?.lastPathComponent,
              manifest.command == command(for: URL(fileURLWithPath: manifest.helperPath)),
              manifest.statusLineCommand == manifest.command + " --statusline" else {
            throw InstallationError.conflictingInstallation
        }
        _ = try originalStatusLine(manifest)
        return manifest
    }

    private func validateOwnership(_ manifest: Manifest?, root: [String: Any], allowReplacedStatusLine: Bool = false) throws {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        let owned = manifest.map { group(for: $0.command) }
        let paths = [executionURL?.path, manifest?.helperPath].compactMap { $0 }
        func referencesUs(_ command: String) -> Bool {
            command.contains("agentnotch-claude-hook") || paths.contains { command.contains($0) || command.contains(Self.quote($0)) }
        }
        for (event, value) in hooks {
            for candidate in value as? [[String: Any]] ?? [] {
                let handlers = candidate["hooks"] as? [[String: Any]] ?? []
                if handlers.contains(where: { ($0["command"] as? String).map(referencesUs) ?? false }) {
                    guard let manifest, let owned, manifest.events.contains(event), Self.equal(candidate, owned) else {
                        throw InstallationError.conflictingInstallation
                    }
                }
            }
            if let owned, (value as? [[String: Any]] ?? []).filter({ Self.equal($0, owned) }).count > 1 {
                throw InstallationError.conflictingInstallation
            }
        }
        if let status = root["statusLine"] as? [String: Any] {
            if let manifest {
                if !Self.equal(status, try statusLine(manifest)) {
                    guard allowReplacedStatusLine, let command = status["command"] as? String,
                          !referencesUs(command) else { throw InstallationError.conflictingInstallation }
                }
            } else if let command = status["command"] as? String, referencesUs(command) {
                throw InstallationError.conflictingInstallation
            }
        }
    }

    private func executableData() throws -> Data {
        guard let source = executionURL, source.isFileURL, source.path.hasPrefix("/"),
              !source.path.hasPrefix(claudeHome.path + "/") else { throw InstallationError.missingHelper }
        var info = stat()
        guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & S_IXUSR != 0, let data = try? Data(contentsOf: source), !data.isEmpty else {
            throw InstallationError.missingHelper
        }
        return data
    }

    private func validatePaths() throws {
        guard claudeHome.isFileURL, settingsURL.isFileURL, claudeHome.path.hasPrefix("/"),
              settingsURL.lastPathComponent == "settings.json",
              settingsURL.deletingLastPathComponent().path == claudeHome.path else { throw InstallationError.unsafePath }
        for url in [claudeHome, integrationDirectory, eventsDirectory, settingsURL, manifestURL] {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                let directory = [claudeHome, integrationDirectory, eventsDirectory].contains(url)
                guard info.st_uid == getuid(), info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
                    throw InstallationError.unsafePath
                }
            } else if errno != ENOENT { throw InstallationError.unsafePath }
        }
    }
    private func existingData(_ url: URL) throws -> Data? {
        // O_NOFOLLOW also closes the final-component symlink race after validation.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw InstallationError.unsafePath
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size <= 8_388_608 else { throw InstallationError.unsafePath }
        return try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
    }
    private func privateDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private func withLock(_ body: () throws -> Void) throws {
        let lock = integrationDirectory.appendingPathComponent(".installation-lock")
        guard mkdir(lock.path, 0o700) == 0 else { throw InstallationError.installationBusy }
        defer { rmdir(lock.path) }
        try body()
    }
    private func transaction(_ changes: [(URL, Data?, Int?)]) throws {
        let before = try changes.map { url, _, _ in
            (url, try existingData(url), (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int)
        }
        do { for (url, bytes, mode) in changes { try replace(url, with: bytes, mode: mode) } }
        catch {
            for (url, bytes, mode) in before.reversed() { try? replace(url, with: bytes, mode: mode) }
            throw error
        }
    }
    private func replace(_ url: URL, with bytes: Data?, mode: Int?) throws {
        if let bytes {
            let oldMode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
            let staged = integrationDirectory.appendingPathComponent(".settings-\(UUID()).tmp")
            defer { try? FileManager.default.removeItem(at: staged) }
            try bytes.write(to: staged, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: mode ?? oldMode ?? 0o600], ofItemAtPath: staged.path)
            guard Darwin.rename(staged.path, url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private static func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func equal(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool { NSDictionary(dictionary: lhs).isEqual(to: rhs) }
}
