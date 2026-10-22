import CoreFoundation
import CryptoKit
import Darwin
import Foundation

// This executable is a notification-only hook. It must never answer an approval
// request or allow malformed input / IO failures to affect Claude's normal flow.
private struct Event: Encodable {
    let schemaVersion = 1
    let id: String
    let kind: String
    let timestamp: Double
    let sessionID: String
    let agentID: String?
    let project: String
    let toolName: String?
    let toolUseID: String?
    let toolFingerprint: String?
    let agentType: String?
    let notificationType: String?
    let fiveHourUsedPercent: Double?
    let fiveHourResetsAt: Double?
    let sevenDayUsedPercent: Double?
    let sevenDayResetsAt: Double?
    let model: String?
    let contextUsedPercent: Double?
}

private let supported = Set(["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
    "PostToolUse", "PostToolUseFailure", "Notification", "SubagentStart", "SubagentStop", "Stop", "StopFailure", "SessionEnd"])
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


private func number(_ value: Any?, percentage: Bool = false) -> Double? {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
    let number = value.doubleValue
    guard number.isFinite, percentage ? (0...100).contains(number) : (number > 0 && number < 253_402_300_800) else { return nil }
    return number
}

private func emit(_ data: Data, statusLine: Bool, eventsPath: String) {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let session = text(object["session_id"], limit: 128) else { return }
    let kind: String
    if statusLine { kind = "StatusLine" }
    else {
        guard let supplied = object["hook_event_name"] as? String, supported.contains(supplied) else { return }
        kind = supplied
    }
    let directory = URL(fileURLWithPath: eventsPath, isDirectory: true)
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
    let id = UUID().uuidString
    let cwd = (object["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
    let tool = text(object["tool_name"], limit: 128)
    let fingerprint: String?
    if ["PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure"].contains(kind),
       let input = object["tool_input"], JSONSerialization.isValidJSONObject(input),
       let bytes = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) {
        fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    } else { fingerprint = nil }
    let rates = statusLine ? object["rate_limits"] as? [String: Any] : nil
    let five = rates?["five_hour"] as? [String: Any]
    let seven = rates?["seven_day"] as? [String: Any]
    let model = statusLine ? object["model"] as? [String: Any] : nil
    let context = statusLine ? object["context_window"] as? [String: Any] : nil
    let event = Event(id: id, kind: kind, timestamp: Date().timeIntervalSince1970,
        sessionID: session, agentID: text(object["agent_id"], limit: 128), project: text(cwd) ?? "",
        toolName: statusLine ? nil : tool, toolUseID: statusLine ? nil : text(object["tool_use_id"], limit: 128),
        toolFingerprint: fingerprint, agentType: text(object["agent_type"], limit: 80),
        notificationType: kind == "Notification" ? text(object["notification_type"], limit: 80) : nil,
        fiveHourUsedPercent: number(five?["used_percentage"], percentage: true),
        fiveHourResetsAt: number(five?["resets_at"]),
        sevenDayUsedPercent: number(seven?["used_percentage"], percentage: true),
        sevenDayResetsAt: number(seven?["resets_at"]), model: text(model?["display_name"], limit: 80),
        contextUsedPercent: number(context?["used_percentage"], percentage: true))
    guard let encoded = try? JSONEncoder().encode(event) else { return }
    HookSpool.append(encoded, id: id, directoryFD: directoryFD, deadline: executionDeadline)
}


/// The optional existing status line is read only from the installer manifest,
/// never from stdin. Its stdout and exact input are preserved, with bounded IO
/// and a private process group so a hung shell cannot delay Claude indefinitely.
private func forwardStatusLine(_ data: Data, eventsPath: String) {
    let integration = URL(fileURLWithPath: eventsPath).deletingLastPathComponent()
    var info = stat()
    guard lstat(integration.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
          info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return }
    let directoryFD = open(integration.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directoryFD >= 0 else { return }
    defer { close(directoryFD) }
    var opened = stat()
    guard fstat(directoryFD, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev else { return }
    let manifestFD = openat(directoryFD, "installation.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard manifestFD >= 0 else { return }
    let manifest: [String: Any]?
    var manifestInfo = stat()
    if fstat(manifestFD, &manifestInfo) == 0, manifestInfo.st_mode & S_IFMT == S_IFREG,
       manifestInfo.st_uid == getuid(), manifestInfo.st_mode & 0o077 == 0,
       manifestInfo.st_size > 0, manifestInfo.st_size <= 262_144 {
        let handle = FileHandle(fileDescriptor: manifestFD, closeOnDealloc: false)
        manifest = (try? handle.readToEnd()).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    } else { manifest = nil }
    close(manifestFD)
    guard let manifest, manifest["schemaVersion"] as? Int == 1,
          let encodedOriginal = manifest["originalStatusLine"] as? String,
          let originalBytes = Data(base64Encoded: encodedOriginal),
          let original = (try? JSONSerialization.jsonObject(with: originalBytes)) as? [String: Any],
          original["type"] as? String == "command", let command = original["command"] as? String,
          !command.isEmpty, command.utf8.count <= 65_536,
          !command.contains("agentnotch-claude-hook"),
          !command.contains(CommandLine.arguments[0]) else { return }

    let temporary = ".statusline-\(UUID()).tmp"
    let inputFD = openat(directoryFD, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard inputFD >= 0 else { return }
    unlinkat(directoryFD, temporary, 0)
    defer { close(inputFD) }
    let wrote = data.withUnsafeBytes { bytes -> Bool in
        var offset = 0
        while offset < bytes.count {
            let count = write(inputFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            guard count > 0 else { return false }
            offset += count
        }
        return lseek(inputFD, 0, SEEK_SET) == 0
    }
    guard wrote else { return }
    var output = [Int32](repeating: -1, count: 2)
    guard pipe(&output) == 0 else { return }
    defer { close(output[0]); close(output[1]) }
    let nullFD = open("/dev/null", O_WRONLY)
    guard nullFD >= 0 else { return }
    defer { close(nullFD) }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { return }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else { return }
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attributes, 0)
    posix_spawn_file_actions_adddup2(&actions, inputFD, STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, nullFD, STDERR_FILENO)
    posix_spawn_file_actions_addclose(&actions, output[0])
    let arguments = ["/bin/sh", "-c", command].map { strdup($0) }
    defer { arguments.forEach { free($0) } }
    var argv = arguments + [nil]
    var processID: pid_t = 0
    let spawnResult = argv.withUnsafeMutableBufferPointer {
        posix_spawn(&processID, "/bin/sh", &actions, &attributes, $0.baseAddress!, environ)
    }
    guard spawnResult == 0 else { return }
    let deadline = ProcessInfo.processInfo.systemUptime + 2.0
    var exited = false
    var count = 0
    // Keep the parent's write end closed; EOF then works for an ordinary line.
    close(output[1]); output[1] = -1
    while ProcessInfo.processInfo.systemUptime < deadline, count < 1_048_576 {
        var descriptor = pollfd(fd: output[0], events: Int16(POLLIN), revents: 0)
        let remaining = Int32(max(1, min(50, (deadline - ProcessInfo.processInfo.systemUptime) * 1000)))
        if poll(&descriptor, 1, remaining) > 0 {
            var bytes = [UInt8](repeating: 0, count: min(16_384, 1_048_576 - count))
            let length = read(output[0], &bytes, bytes.count)
            if length <= 0 { break }
            var offset = 0
            while offset < length {
                let written = bytes.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress!.advanced(by: offset), length - offset) }
                if written <= 0 { break }
                offset += written
            }
            count += length
        }
        if waitpid(processID, nil, WNOHANG) == processID { exited = true }
    }
    // Include grandchildren: a timed-out shell must not leave a worker behind.
    kill(-processID, SIGKILL)
    if !exited { waitpid(processID, nil, 0) }
}

private func run() {
    let arguments = CommandLine.arguments
    guard [3, 4].contains(arguments.count), arguments[1] == "--events-dir", arguments[2].hasPrefix("/"),
          arguments.count == 3 || arguments[3] == "--statusline", let data = input() else { return }
    let statusLine = arguments.count == 4
    emit(data, statusLine: statusLine, eventsPath: arguments[2])
    if statusLine { forwardStatusLine(data, eventsPath: arguments[2]) }
}
@main
private enum ClaudeHookMain {
    static func main() {
        _ = executionDeadline
        run()
        exit(0)
    }
}
