import CryptoKit
import Darwin
import Foundation

/// Explicit opt-in installation only. Does not touch Codex config.toml, auth,
/// trust decisions, or approval policy. Atomic hooks.json replacements are
/// staged inside our own directory, so sandbox access can be restricted to
/// that directory and the exact hooks file instead of the whole Codex home.
struct CodexHookInstaller {
    enum InstallationError: Error, LocalizedError {
        case missingHelper, unsafePath, malformedHooks, conflictingInstallation, installationBusy

        var errorDescription: String? {
            switch self {
            case .missingHelper: return "The bundled Codex hook helper is missing."
            case .unsafePath: return "The Codex integration path is not a regular private location."
            case .malformedHooks: return "The existing Codex hooks file could not be safely read."
            case .conflictingInstallation: return "The existing Codex integration has been changed."
            case .installationBusy: return "Another Codex integration change is in progress."
            }
        }
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let command: String
        let events: [String]
        let helperSHA256: String
        let createdHooksFile: Bool
        let helperPath: String?
        // Allows cleanup of a verified v1 executable without ever rewriting it.
        let legacyHelperSHA256: String?
    }

    private static let legacyEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse",
                                       "Stop", "Interrupt", "SubagentStart", "SubagentStop", "SessionEnd"]
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                         "Stop", "Interrupt", "SubagentStart", "SubagentStop", "SessionEnd"]
    let codexHome: URL
    let hooksURL: URL
    let helperSource: URL?
    var integrationDirectory: URL { codexHome.appendingPathComponent("agentnotch", isDirectory: true) }
    var eventsDirectory: URL { integrationDirectory.appendingPathComponent("events", isDirectory: true) }
    /// Historical v1 location, used only for ownership checks and cleanup.
    var helperURL: URL { integrationDirectory.appendingPathComponent("bin/agentnotch-codex-hook") }
    /// Execute the signed resource in the app bundle. Sandbox-created copies
    /// acquire quarantine and cannot be launched by Codex.
    var executionURL: URL? { helperSource }
    private var manifestURL: URL { integrationDirectory.appendingPathComponent("installation.json") }
    private func command(for helper: URL) -> String {
        "\(Self.quote(helper.path)) --events-dir \(Self.quote(eventsDirectory.path))"
    }
    private func group(for command: String) -> [String: Any] {
        ["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": 3]]]
    }

    init(codexHome: URL, helperSource: URL? = nil, hooksURL: URL? = nil) {
        let normalizedHome = codexHome.standardizedFileURL
        self.codexHome = normalizedHome
        self.hooksURL = (hooksURL ?? normalizedHome.appendingPathComponent("hooks.json")).standardizedFileURL
        self.helperSource = (helperSource ?? Bundle.main.resourceURL?
            .appendingPathComponent("Codex/agentnotch-codex-hook"))?.standardizedFileURL
    }

    var isInstalled: Bool {
        guard (try? validatePaths()) != nil,
              let manifest = try? readManifest(), manifest.schemaVersion == 2,
              let source = executionURL, manifest.helperPath == source.path,
              manifest.events == Self.events, manifest.command == command(for: source),
              let helper = try? executableData(), Self.hash(helper) == manifest.helperSHA256,
              let root = try? readHooks(), let hooks = root["hooks"] as? [String: Any],
              (try? validateOwnership(manifest, hooks: hooks)) != nil else { return false }
        var info = stat()
        guard lstat(eventsDirectory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { return false }
        let expected = group(for: manifest.command)
        return Self.events.allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? []).filter { Self.equal($0, expected) }.count == 1
        }
    }

    /// An owned installation can be migrated/repaired explicitly, including
    /// after an app move or resource update. Modified definitions are conflicts.
    var needsRepair: Bool {
        guard !isInstalled, (try? validatePaths()) != nil,
              let manifest = try? readManifest(), let root = try? readHooks(),
              (try? validateOwnership(manifest, hooks: root["hooks"] as? [String: Any] ?? [:])) != nil else { return false }
        return true
    }

    func install() throws {
        try validatePaths()
        let helper = try executableData()
        guard let source = executionURL else { throw InstallationError.missingHelper }
        let newCommand = command(for: source)
        let newGroup = group(for: newCommand)
        let originalHooks = try existingData(hooksURL)
        let originalManifest = try existingData(manifestURL)
        var root = try readHooks()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let manifest = try readManifest()
        try validateOwnership(manifest, hooks: hooks)
        let definitionsCurrent = manifest?.schemaVersion == 2 && manifest?.command == newCommand
            && Self.events.allSatisfy { event in
                ((hooks[event] as? [[String: Any]]) ?? []).filter { Self.equal($0, newGroup) }.count == 1
            }
        if let manifest {
            let previousGroup = group(for: manifest.command)
            for event in manifest.events {
                if let groups = hooks[event] as? [[String: Any]] {
                    let remaining = groups.filter { !Self.equal($0, previousGroup) }
                    if remaining.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = remaining }
                }
            }
        }
        for event in Self.events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(newGroup)
            hooks[event] = groups
        }
        root["hooks"] = hooks
        let newHooks: Data
        if definitionsCurrent, let originalHooks { newHooks = originalHooks }
        else { newHooks = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) }
        let legacyHash = manifest?.schemaVersion == 1 ? manifest?.helperSHA256 : manifest?.legacyHelperSHA256
        let newManifest = Manifest(schemaVersion: 2, command: newCommand, events: Self.events,
            helperSHA256: Self.hash(helper), createdHooksFile: manifest?.createdHooksFile ?? (originalHooks == nil),
            helperPath: source.path, legacyHelperSHA256: legacyHash)
        // Keep trust-definition bytes unchanged on an idempotent install.
        if isInstalled { return }
        try privateDirectory(integrationDirectory)
        try withLock {
            guard try existingData(hooksURL) == originalHooks,
                  try existingData(manifestURL) == originalManifest else { throw InstallationError.conflictingInstallation }
            try validateOwnership(manifest, hooks: try readHooks()["hooks"] as? [String: Any] ?? [:])
            try privateDirectory(eventsDirectory)
            try transaction([
                (manifestURL, try JSONEncoder().encode(newManifest), 0o600),
                (hooksURL, newHooks, nil)
            ])
            // Legacy cleanup cannot require recreating quarantined executable
            // bytes during transaction rollback. The v2 manifest retains its
            // verified hash if cleanup needs to be retried on removal.
            if legacyHash != nil { try? FileManager.default.removeItem(at: helperURL) }
        }
    }

    func remove() throws {
        try validatePaths()
        guard let manifest = try readManifest() else { return }
        let originalHooks = try existingData(hooksURL)
        let originalManifest = try existingData(manifestURL)
        var root = try readHooks()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        try validateOwnership(manifest, hooks: hooks)
        let ownedGroup = group(for: manifest.command)
        for event in manifest.events {
            if let groups = hooks[event] as? [[String: Any]] {
                let remaining = groups.filter { !Self.equal($0, ownedGroup) }
                if remaining.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = remaining }
            }
        }
        root["hooks"] = hooks
        let newHooks: Data? = originalHooks == nil || (manifest.createdHooksFile && root.count == 1 && hooks.isEmpty)
            ? nil : try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try withLock {
            guard try existingData(hooksURL) == originalHooks,
                  try existingData(manifestURL) == originalManifest else { throw InstallationError.conflictingInstallation }
            try validateOwnership(manifest, hooks: try readHooks()["hooks"] as? [String: Any] ?? [:])
            // Delete only a validated historical copy; never modify the bundle.
            if try existingData(helperURL) != nil { try FileManager.default.removeItem(at: helperURL) }
            try transaction([(hooksURL, newHooks, nil), (manifestURL, nil, nil)])
        }
        // Keep event history and directories; they may contain user files.
    }

    private func executableData() throws -> Data {
        guard let source = executionURL, source.isFileURL, source.path.hasPrefix("/"),
              !source.path.hasPrefix(codexHome.path + "/") else { throw InstallationError.missingHelper }
        var info = stat()
        guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & S_IXUSR != 0,
              let data = try? Data(contentsOf: source), !data.isEmpty else { throw InstallationError.missingHelper }
        return data
    }

    private func readHooks() throws -> [String: Any] {
        guard let data = try existingData(hooksURL) else { return [:] }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstallationError.malformedHooks
        }
        if let value = root["hooks"] {
            guard let hooks = value as? [String: Any], hooks.values.allSatisfy({ $0 is [[String: Any]] }) else {
                throw InstallationError.malformedHooks
            }
        }
        return root
    }

    private func readManifest() throws -> Manifest? {
        guard let data = try existingData(manifestURL) else { return nil }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              [1, 2].contains(manifest.schemaVersion), manifest.helperSHA256.count == 64,
              manifest.helperSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw InstallationError.conflictingInstallation
        }
        if manifest.schemaVersion == 1 {
            guard manifest.events == Self.legacyEvents, manifest.helperPath == nil,
                  manifest.command == command(for: helperURL) else { throw InstallationError.conflictingInstallation }
        } else {
            guard let path = manifest.helperPath, path.hasPrefix("/"),
                  URL(fileURLWithPath: path).standardizedFileURL.path == path,
                  !path.hasPrefix(codexHome.path + "/"),
                  URL(fileURLWithPath: path).lastPathComponent == executionURL?.lastPathComponent,
                  manifest.events == Self.events,
                  manifest.command == command(for: URL(fileURLWithPath: path)),
                  manifest.legacyHelperSHA256.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) ?? true else {
                throw InstallationError.conflictingInstallation
            }
        }
        return manifest
    }

    private func validateOwnership(_ manifest: Manifest?, hooks: [String: Any]) throws {
        if let helper = try existingData(helperURL) {
            let expected = manifest?.schemaVersion == 1 ? manifest?.helperSHA256 : manifest?.legacyHelperSHA256
            guard let expected, Self.hash(helper) == expected else { throw InstallationError.conflictingInstallation }
        }
        let ownedGroup = manifest.map { group(for: $0.command) }
        let referencedPaths = [helperURL.path, executionURL?.path, manifest?.helperPath].compactMap { $0 }
        for (event, value) in hooks {
            let groups = value as? [[String: Any]] ?? []
            if let ownedGroup, groups.filter({ Self.equal($0, ownedGroup) }).count > 1 {
                throw InstallationError.conflictingInstallation
            }
            for candidate in groups {
                let handlers = candidate["hooks"] as? [[String: Any]] ?? []
                let referencesUs = handlers.contains {
                    guard let command = $0["command"] as? String else { return false }
                    return command == manifest?.command || referencedPaths.contains {
                        command.contains($0) || command.contains(Self.quote($0))
                    }
                }
                if referencesUs {
                    guard let manifest, let ownedGroup, manifest.events.contains(event),
                          Self.equal(candidate, ownedGroup) else { throw InstallationError.conflictingInstallation }
                }
            }
        }
    }

    private func validatePaths() throws {
        guard codexHome.path.hasPrefix("/"),
              hooksURL.deletingLastPathComponent().standardizedFileURL.path == codexHome.path else {
            throw InstallationError.unsafePath
        }
        // Existing target components must not redirect writes through symlinks.
        for url in [codexHome, integrationDirectory, eventsDirectory, helperURL.deletingLastPathComponent(),
                    hooksURL, helperURL, manifestURL] {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                let type = info.st_mode & S_IFMT
                let isDirectory = [codexHome, integrationDirectory, eventsDirectory,
                                   helperURL.deletingLastPathComponent()].contains(url)
                guard info.st_uid == getuid(), type == (isDirectory ? S_IFDIR : S_IFREG) else {
                    throw InstallationError.unsafePath
                }
            } else if errno != ENOENT { throw InstallationError.unsafePath }
        }
    }

    private func privateDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func withLock(_ body: () throws -> Void) throws {
        let lock = integrationDirectory.appendingPathComponent(".installation-lock")
        guard mkdir(lock.path, 0o700) == 0 else { throw InstallationError.installationBusy }
        defer { rmdir(lock.path) }
        try body()
    }

    private func existingData(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Restores the previous bytes and modes if a later filesystem step fails.
    private func transaction(_ changes: [(URL, Data?, Int?)]) throws {
        let before = try changes.map { url, _, _ in
            (url, try existingData(url), try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        }
        do {
            for (url, data, mode) in changes {
                try replace(url, with: data, mode: mode)
            }
        } catch {
            for (url, data, mode) in before.reversed() { try? replace(url, with: data, mode: mode ?? nil) }
            throw error
        }
    }

    private func replace(_ url: URL, with data: Data?, mode: Int?) throws {
        if let data {
            let oldMode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
            let permissions = mode ?? oldMode ?? 0o600
            if url == hooksURL {
                let staged = integrationDirectory.appendingPathComponent(".hooks-\(UUID()).tmp")
                defer { try? FileManager.default.removeItem(at: staged) }
                try data.write(to: staged, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: staged.path)
                guard Darwin.rename(staged.path, url.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            } else {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func equal(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }
}
