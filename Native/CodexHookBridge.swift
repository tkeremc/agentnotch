import CryptoKit
import Darwin
import Foundation

// This executable is a notification-only hook. It must never answer an approval
// request or allow malformed input / IO failures to affect Codex's normal flow.
private struct Event: Encodable {
    let schemaVersion = 1
    let id: String
    let kind: String
    let timestamp: Double
    let sessionID: String
    let turnID: String?
    let agentID: String?
    let project: String
    let toolName: String?
    let toolUseID: String?
    let toolFingerprint: String?
    let permissionSummary: String?
}

private let supported = Set(["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
    "PostToolUse", "Stop", "Interrupt", "SubagentStart", "SubagentStop", "SessionEnd"])
private let executionDeadline = ProcessInfo.processInfo.systemUptime + 2.7

private func text(_ value: Any?, limit: Int = 160) -> String? {
    guard let string = value as? String else { return nil }
    let cleaned = String(string.prefix(4096)).components(separatedBy: .controlCharacters).joined(separator: " ")
        .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let result = String(cleaned.prefix(limit))
    return result.isEmpty ? nil : result
}

private func input() -> Data? {
    var data = Data()
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while ProcessInfo.processInfo.systemUptime < deadline {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let remaining = max(1, Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1000))
        guard poll(&descriptor, 1, remaining) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count == 0 { return data }
        guard count > 0, data.count + count <= 1_048_576 else { return nil }
        data.append(contentsOf: buffer.prefix(count))
    }
    return nil
}

private func prune(_ directoryFD: Int32) -> Bool {
    guard let stream = fdopendir(dup(directoryFD)) else { return false }
    defer { closedir(stream) }
    let oldest = Date().addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970
    var retained = [(String, Double)]()
    while let entry = readdir(stream) {
        guard ProcessInfo.processInfo.systemUptime < executionDeadline else { return false }
        let name = withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
        }
        guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil else { continue }
        var attributes = stat()
        guard fstatat(directoryFD, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0,
              attributes.st_mode & S_IFMT == S_IFREG, attributes.st_uid == getuid() else { continue }
        let modified = Double(attributes.st_mtimespec.tv_sec)
        if modified < oldest { unlinkat(directoryFD, name, 0); continue }
        // Bounded retained metadata even if an older build left a huge spool.
        if retained.count < 4096 { retained.append((name, modified)) }
        else { unlinkat(directoryFD, name, 0) }
    }
    if retained.count >= 4096,
       let oldestEntry = retained.min(by: { $0.1 < $1.1 }) {
        unlinkat(directoryFD, oldestEntry.0, 0)
    }
    return true
}

// Generic child hooks may carry only the tree's session_id. Recover the
// child's identity from the first metadata record when the supplied transcript
// is a regular owned JSONL file. This optional format hint never records paths
// or conversation content, and failure leaves the documented fields intact.
private func transcriptIdentity(_ object: [String: Any]) -> (String, String)? {
    guard let path = object["transcript_path"] as? String, path.hasPrefix("/"),
          path.hasSuffix(".jsonl") else { return nil }
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_uid == getuid() else { return nil }
    var buffer = [UInt8](repeating: 0, count: 65_536)
    let count = read(fd, &buffer, buffer.count)
    guard count > 0, let newline = buffer.prefix(count).firstIndex(of: 10),
          let record = (try? JSONSerialization.jsonObject(with: Data(buffer.prefix(newline)))) as? [String: Any],
          record["type"] as? String == "session_meta",
          let metadata = record["payload"] as? [String: Any],
          let id = text(metadata["id"], limit: 128) else { return nil }
    let source = metadata["source"] as? [String: Any]
    let subagent = source?["subagent"] as? [String: Any]
    let spawn = subagent?["thread_spawn"] as? [String: Any]
    guard let parent = text(metadata["parent_thread_id"] ?? spawn?["parent_thread_id"], limit: 128) else { return nil }
    return (parent, id)
}

private func emit() {
    guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--events-dir",
          CommandLine.arguments[2].hasPrefix("/"),
          let data = input(),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let kind = object["hook_event_name"] as? String, supported.contains(kind),
          let session = text(object["session_id"], limit: 128) else { return }
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        .standardizedFileURL
    // Never follow a substituted directory or write into a shared spool.
    var info = stat()
    guard lstat(directory.path, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
          info.st_mode & 0o077 == 0 else { return }
    let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directoryFD >= 0 else { return }
    defer { close(directoryFD) }
    var openedInfo = stat()
    guard fstat(directoryFD, &openedInfo) == 0, openedInfo.st_uid == getuid(),
          openedInfo.st_mode & 0o077 == 0,
          openedInfo.st_ino == info.st_ino, openedInfo.st_dev == info.st_dev else { return }
    let lockDeadline = min(executionDeadline, ProcessInfo.processInfo.systemUptime + 0.5)
    while flock(directoryFD, LOCK_EX | LOCK_NB) != 0 {
        guard ProcessInfo.processInfo.systemUptime < lockDeadline else { return }
        usleep(1_000)
    }
    defer { flock(directoryFD, LOCK_UN) }
    guard prune(directoryFD) else { return }
    let id = UUID().uuidString
    let cwd = (object["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
    let tool = text(object["tool_name"], limit: 128)
    // Descriptions are optional. Never fall back to command, prompt, tool args,
    // transcript paths, tool output or other potentially sensitive input.
    let description = (object["tool_input"] as? [String: Any])?["description"]
    let summary = kind == "PermissionRequest" ? text(description) : nil
    let fingerprint: String?
    if ["PreToolUse", "PermissionRequest"].contains(kind),
       let input = object["tool_input"], JSONSerialization.isValidJSONObject(input),
       let bytes = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) {
        fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    } else { fingerprint = nil }
    let identity = transcriptIdentity(object)
    let explicitAgent = text(object["agent_id"], limit: 128)
    let lifecycle = kind == "SubagentStart" || kind == "SubagentStop"
    let event = Event(id: id, kind: kind, timestamp: Date().timeIntervalSince1970,
        sessionID: lifecycle ? session : (identity?.0 ?? session),
        turnID: text(object["turn_id"], limit: 128),
        agentID: explicitAgent ?? (lifecycle ? nil : identity?.1), project: text(cwd) ?? "",
        toolName: tool, toolUseID: text(object["tool_use_id"], limit: 128),
        toolFingerprint: fingerprint, permissionSummary: summary)
    guard let encoded = try? JSONEncoder().encode(event) else { return }
    let temporary = ".\(id).tmp"
    let file = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard file >= 0 else { return }
    var succeeded = true
    encoded.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count <= 0 { succeeded = false; break }
            offset += count
        }
    }
    if close(file) != 0 { succeeded = false }
    if succeeded { succeeded = renameat(directoryFD, temporary, directoryFD, "\(id).json") == 0 }
    if !succeeded { unlinkat(directoryFD, temporary, 0) }
}

emit()
exit(0)
