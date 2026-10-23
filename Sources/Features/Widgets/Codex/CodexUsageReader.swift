import Darwin
import Foundation

struct CodexUsageWindow: Equatable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

struct CodexUsageSnapshot: Equatable {
    let primary: CodexUsageWindow?
    let secondary: CodexUsageWindow?
    let observedAt: Date
    let planType: String?
    let limitID: String?
    /// Opaque to this reader's lifetime. Never an account ID or email address.
    let identityKey: String?
}

enum CodexUsageAvailability: Equatable {
    case available, notFound, permissionDenied, noData, ambiguousAccounts
}

struct CodexUsageReadError: Equatable {
    enum Kind: Equatable { case notFound, permissionDenied, io }
    /// Opaque identifier, deliberately excludes paths and conversation contents.
    let fileKey: String?
    let kind: Kind
}

struct CodexUsageReadResult: Equatable {
    let snapshot: CodexUsageSnapshot?
    let availability: CodexUsageAvailability
    let scannedFiles: Int
    let readErrors: [CodexUsageReadError]
}

/// A synchronous, incremental, read-only reader. Confine each instance to one
/// background queue. It opens only regular JSONL files below the explicit root;
/// it reads optional chat names from the sibling session index. It never
/// discovers credentials, configuration, or a custom CODEX_HOME.
final class CodexUsageReader {
    private struct FileState {
        let key: String
        var resourceID: String
        var offset: UInt64 = 0
        var modifiedAt: Date?
        var pending = Data()
        var droppingLongLine = false
        var ordinal = 0
        var hasMetadata = false
        var accountIdentity: String?
        var inheritedThrough = -1
        var unsupportedChild = false
        var buckets: [String: CodexUsageSnapshot] = [:]
        var deferredBuckets: [String: [CodexUsageSnapshot]] = [:]
        var prefix = Data()
        var activity: CodexSessionActivity?
        var deferredActivity: [(Date, [String: Any])] = []
        var malformedActivity = false
    }

    private let root: URL
    private let titles: CodexThreadTitleIndex
    private let files = FileManager.default
    private var states: [String: FileState] = [:]
    private var fileKeys: [String: String] = [:]
    private var identityKeys: [String: String] = [:]
    private var lastKnown: CodexUsageSnapshot?
    private var lastKnownGroup: String?
    private var lastRefreshTime: Date?
    private var cachedErrors: [CodexUsageReadError] = []
    private var cachedCount = 0
    private var rootUnavailable: CodexUsageAvailability?
    private(set) var fullScanCount = 0
    private(set) var fileReadCount = 0
    private var directories: Set<String> = []
    var observationPaths: [URL] {
        (directories.sorted() + states.keys.sorted()).map { URL(fileURLWithPath: $0) }
    }

    func activitySnapshots(now: Date, refreshTitles: Bool = true) -> [CodexAgentSnapshot] {
        let names = refreshTitles ? titles.read() : titles.cachedNames
        let agents = states.values.compactMap { state -> CodexAgentSnapshot? in
            guard !state.unsupportedChild, !state.malformedActivity else { return nil }
            return state.activity?.snapshot(at: now)
        }
        let parents = Dictionary(agents.compactMap { agent in
            agent.parentID.map { (agent.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        return agents.map { agent in
            var value = agent
            var id: String? = agent.id
            var visited: Set<String> = []
            while let current = id, visited.count < 32, visited.insert(current).inserted {
                if let title = names[current] { value.conversationTitle = title; break }
                id = parents[current]
            }
            return value
        }
    }
    private let standardDate = ISO8601DateFormatter()
    private let fractionalDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let chunkBytes = 64 * 1024
    private static let maximumLineBytes = 1024 * 1024

    // Internal diagnostics used by the deferred regression suite. Byte count
    // measures live partial input, not Foundation's allocator capacity or RSS.
    var retainedStateCounts: (files: Int, fileKeys: Int, identities: Int, pendingBytes: Int) {
        (states.count, fileKeys.count, identityKeys.count, states.values.reduce(0) { $0 + $1.pending.count })
    }

    init(sessionsDirectory: URL) {
        root = sessionsDirectory.standardizedFileURL
        titles = CodexThreadTitleIndex(url: root.deletingLastPathComponent().appendingPathComponent("session_index.jsonl"))
    }

    /// nil performs recovery discovery; explicit paths read only changed JSONL files.
    func refresh(now: Date = .now, changedPaths: Set<String>? = nil) -> CodexUsageReadResult {
        var changedPaths = changedPaths
        // A wall-clock correction must not leave an observation from the future
        // selected. Reparse on rollback; ordinary forward refreshes remain incremental.
        if let previous = lastRefreshTime, now < previous {
            states.removeAll()
            lastKnown = nil
            lastKnownGroup = nil
            changedPaths = nil
        }
        // Discovery errors need a complete retry before they can be cleared.
        if !cachedErrors.isEmpty { changedPaths = nil }
        lastRefreshTime = now
        var errors: [CodexUsageReadError] = []
        var candidates: [URL] = []
        var discoveryFailed = false
        do {
            // URL resource values can be cached across calls; construct a fresh
            // URL so a deleted or replaced root is actually revalidated.
            let currentRoot = URL(fileURLWithPath: root.path, isDirectory: true)
            let values = try currentRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                rootUnavailable = .notFound
                return result(.notFound, count: 0, errors: [])
            }
            rootUnavailable = nil
            if let paths = changedPaths, paths.allSatisfy({ $0.hasPrefix(root.path + "/") && $0.hasSuffix(".jsonl") }) {
                for path in paths {
                    let url = URL(fileURLWithPath: path)
                    var info = stat()
                    let status = lstat(path, &info)
                    if (status != 0 && errno == ENOENT) || (status == 0 && info.st_mode & S_IFMT != S_IFREG) {
                        states.removeValue(forKey: path)
                        fileKeys.removeValue(forKey: path)
                        continue
                    }
                    // File-level notifications must not bypass discovery's refusal
                    // to traverse symlinked directories, including replaced parents.
                    var parent = url.deletingLastPathComponent()
                    var safe = true
                    while parent.path.hasPrefix(root.path + "/") {
                        if lstat(parent.path, &info) != 0 || info.st_mode & S_IFMT != S_IFDIR { safe = false; break }
                        parent.deleteLastPathComponent()
                    }
                    if safe { candidates.append(url) }
                    else {
                        changedPaths = nil
                        candidates = []
                        directories = []
                        fullScanCount += 1
                        discover(root, candidates: &candidates, errors: &errors)
                        break
                    }
                }
            } else {
                changedPaths = nil
                fullScanCount += 1
                directories = []
                discover(root, candidates: &candidates, errors: &errors)
            }
        } catch {
            errors.append(readError(error, key: nil))
            discoveryFailed = true
            rootUnavailable = errors.last?.kind == .permissionDenied ? .permissionDenied : .notFound
        }
        var seen: Set<String> = []
        var scanned = 0
        for url in candidates.sorted(by: { $0.path < $1.path }) {
            let path = url.path
            seen.insert(path)
            if fileKeys[path] == nil { fileKeys[path] = UUID().uuidString }
            do {
                try read(url, now: now)
                scanned += 1
            } catch {
                errors.append(readError(error, key: fileKeys[path]))
            }
        }
        // A failed subtree discovery must not make previously observed accounts
        // disappear, allowing a different account to be silently selected.
        if changedPaths == nil && !discoveryFailed && errors.isEmpty {
            states = states.filter { seen.contains($0.key) }
            fileKeys = fileKeys.filter { seen.contains($0.key) }
        }
        cachedErrors = errors
        cachedCount = changedPaths == nil ? scanned : states.count
        let value = project(now: now)
        pruneIdentityKeys()
        return value
    }

    /// Expiry and clock-skewed observations advance without enumerating/opening files.
    func advance(now: Date) -> CodexUsageReadResult {
        if let previous = lastRefreshTime, now < previous { return refresh(now: now) }
        lastRefreshTime = now
        return project(now: now)
    }

    private func project(now: Date) -> CodexUsageReadResult {
        let errors = cachedErrors
        let scanned = cachedCount
        if let rootUnavailable { return result(rootUnavailable, count: scanned, errors: errors) }
        for path in Array(states.keys) {
            guard var state = states[path] else { continue }
            for (bucket, pending) in state.deferredBuckets {
                if let ready = pending.filter({ $0.observedAt <= now }).max(by: { $0.observedAt < $1.observedAt }),
                   state.buckets[bucket].map({ ready.observedAt >= $0.observedAt }) ?? true {
                    state.buckets[bucket] = ready
                }
                state.deferredBuckets[bucket] = pending.filter { $0.observedAt > now }
            }
            let ready = state.deferredActivity.filter { $0.0 <= now }.sorted { $0.0 < $1.0 }
            for (at, payload) in ready { consumeActivity(payload, at: at, state: &state) }
            state.deferredActivity.removeAll { $0.0 <= now }
            states[path] = state
        }
        let grouped = Dictionary(grouping: states.values.filter { $0.accountIdentity != nil || !$0.buckets.isEmpty }) {
            $0.accountIdentity ?? "unattributed:\($0.key)"
        }
        if grouped.count > 1 {
            return CodexUsageReadResult(snapshot: nil, availability: .ambiguousAccounts,
                                       scannedFiles: scanned, readErrors: errors)
        }
        if let (groupKey, group) = grouped.first {
            if let previous = lastKnownGroup, previous != groupKey {
                lastKnown = nil
                lastKnownGroup = nil
            }
            let snapshots = group.flatMap { $0.buckets.values }
            // Never substitute a newer model-specific bucket for the main Codex
            // quota, and never splice windows from separate observations.
            let codex = snapshots.filter { $0.limitID == "codex" }
            if let latest = (codex.isEmpty ? snapshots : codex).max(by: { $0.observedAt < $1.observedAt }) {
                lastKnown = latest
                lastKnownGroup = groupKey
                let status: CodexUsageAvailability
                if errors.contains(where: { $0.kind == .permissionDenied }) { status = .permissionDenied }
                else if scanned == 0 && errors.contains(where: { $0.kind == .notFound }) { status = .notFound }
                else { status = .available }
                return result(status, count: scanned, errors: errors)
            }
        }
        let status: CodexUsageAvailability
        if errors.contains(where: { $0.kind == .permissionDenied }) { status = .permissionDenied }
        else if scanned == 0 && errors.contains(where: { $0.kind == .notFound }) { status = .notFound }
        else { status = .noData }
        return result(status, count: scanned, errors: errors)
    }

    private func result(_ status: CodexUsageAvailability, count: Int,
                        errors: [CodexUsageReadError]) -> CodexUsageReadResult {
        CodexUsageReadResult(snapshot: lastKnown, availability: status,
                            scannedFiles: count, readErrors: errors)
    }

    private func discover(_ directory: URL, candidates: inout [URL],
                          errors: inout [CodexUsageReadError]) {
        directories.insert(directory.path)
        do {
            let entries = try files.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            for entry in entries {
                do {
                    let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true { continue }
                    if values.isDirectory == true { discover(entry, candidates: &candidates, errors: &errors) }
                    else if values.isRegularFile == true && entry.pathExtension == "jsonl" { candidates.append(entry) }
                } catch {
                    if fileKeys[entry.path] == nil { fileKeys[entry.path] = UUID().uuidString }
                    errors.append(readError(error, key: fileKeys[entry.path]))
                }
            }
        } catch { errors.append(readError(error, key: nil)) }
    }

    private func read(_ url: URL, now: Date) throws {
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return }
        let resourceID = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = attributes[.modificationDate] as? Date
        fileReadCount += 1
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: min(128, Int(min(size, 128)))) ?? Data()
        let fileKey = fileKeys[url.path] ?? UUID().uuidString
        var state = states[url.path] ?? FileState(key: fileKey, resourceID: resourceID)
        let prefixChanged = !state.prefix.isEmpty && !prefix.starts(with: state.prefix)
        if state.resourceID != resourceID || size < state.offset || prefixChanged
            || (state.offset == size && state.modifiedAt != modifiedAt) {
            state = FileState(key: fileKey, resourceID: resourceID)
        }
        state.prefix = prefix
        state.modifiedAt = modifiedAt
        try handle.seek(toOffset: state.offset)
        // Capture the size at open so continuous writers cannot keep this read
        // alive forever. Every refresh only consumes the remaining finite tail.
        do {
            while state.offset < size {
                let amount = min(Self.chunkBytes, Int(min(UInt64(Self.chunkBytes), size - state.offset)))
                guard let chunk = try handle.read(upToCount: amount), !chunk.isEmpty else { break }
                state.offset += UInt64(chunk.count)
                consumeChunk(chunk, state: &state, now: now)
            }
            // An EOF with a complete line needs no per-file scratch capacity.
            // Keep real partial input, including a line split across refreshes.
            if state.pending.isEmpty { state.pending = Data() }
            states[url.path] = state
        } catch {
            // Completed observations remain usable even when a subsequent read
            // fails. Pending partial lines and offsets remain consistent.
            if state.pending.isEmpty { state.pending = Data() }
            states[url.path] = state
            throw error
        }
    }

    private func consumeChunk(_ chunk: Data, state: inout FileState, now: Date) {
        chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var start = 0
            while start < bytes.count {
                let newline = memchr(base.advanced(by: start), 10, bytes.count - start)
                let end = newline.map { base.distance(to: UnsafeRawPointer($0)) } ?? bytes.count
                let length = end - start
                if !state.droppingLongLine {
                    if length > Self.maximumLineBytes - state.pending.count {
                        state.pending = Data()
                        state.droppingLongLine = true
                        state.malformedActivity = true
                    } else if state.pending.isEmpty, newline != nil {
                        // The common case needs no growing scratch buffer.
                        consume(Data(bytes: base.advanced(by: start), count: length), state: &state, now: now)
                    } else {
                        state.pending.append(base.advanced(by: start).assumingMemoryBound(to: UInt8.self), count: length)
                        if newline != nil { consume(state.pending, state: &state, now: now) }
                    }
                }
                guard newline != nil else { break }
                // Reuse small scratch capacity inside this read only; release
                // large completed/oversized lines instead of pinning 1 MiB.
                if state.pending.count > Self.chunkBytes { state.pending = Data() }
                else { state.pending.removeAll(keepingCapacity: true) }
                state.droppingLongLine = false
                state.ordinal += 1
                start = end + 1
            }
        }
    }

    private func pruneIdentityKeys() {
        var live = Set(states.values.compactMap(\.accountIdentity))
        // Preserve the opaque identity of the explicitly retained last quota
        // even if its source log was deleted. Other removed accounts can go.
        if let group = lastKnownGroup, identityKeys[group] != nil { live.insert(group) }
        identityKeys = identityKeys.filter { live.contains($0.key) }
    }

    private func consume(_ line: Data, state: inout FileState, now: Date) {
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = record["payload"] as? [String: Any] else {
            if !line.isEmpty { state.malformedActivity = true }
            return
        }
        if record["type"] as? String == "session_meta" {
            guard !state.hasMetadata else { return }
            state.hasMetadata = true
            if let account = boundedString(payload["creator_account_id"]),
               let user = boundedString(payload["creator_user_id"]) {
                // Length prefixes prevent ambiguous concatenation. The string
                // remains private; snapshots expose a random opaque key only.
                state.accountIdentity = "\(account.utf8.count):\(account)\(user.utf8.count):\(user)"
            }
            let source = payload["source"] as? [String: Any]
            let child = payload["parent_thread_id"] != nil || source?["subagent"] != nil
            if let id = boundedString(payload["id"]) {
                let spawn = (source?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
                let parent = boundedString(payload["parent_thread_id"]) ?? boundedString(spawn?["parent_thread_id"])
                let cwd = boundedString(payload["cwd"]) ?? ""
                let nickname = boundedString(payload["agent_nickname"]) ?? boundedString(spawn?["agent_nickname"])
                let path = boundedString(payload["agent_path"]) ?? boundedString(spawn?["agent_path"])
                state.activity = CodexSessionActivity(id: id,
                    project: (cwd as NSString).lastPathComponent,
                    name: child ? (nickname ?? path.map { ($0 as NSString).lastPathComponent } ?? String(id.prefix(8))) : nil,
                    parentID: parent)
            }
            if child {
                if let ordinal = integer(payload["subagent_history_start_ordinal"]), ordinal >= 0 {
                    state.inheritedThrough = ordinal
                } else { state.unsupportedChild = true }
            }
            return
        }
        guard state.hasMetadata, !state.unsupportedChild, state.ordinal > state.inheritedThrough,
              let recordType = record["type"] as? String,
              let metadata = activityMetadata(payload, recordType: recordType),
              let timestamp = record["timestamp"] as? String,
              let at = fractionalDate.date(from: timestamp) ?? standardDate.date(from: timestamp) else { return }
        if at <= now { consumeActivity(metadata, at: at, state: &state) }
        else if state.deferredActivity.count < 32 {
            state.deferredActivity.append((at, metadata))
        }
        guard recordType == "event_msg", payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any] else { return }
        let primary = window(limits["primary"])
        let secondary = window(limits["secondary"])
        guard primary != nil || secondary != nil else { return }
        let limitID = boundedString(limits["limit_id"])
        let bucket = limitID ?? "unlabelled"
        // Unknown model buckets cannot cause unbounded per-file state growth.
        let knownBuckets = Set(state.buckets.keys).union(state.deferredBuckets.keys)
        guard knownBuckets.contains(bucket) || knownBuckets.count < 32 || bucket == "codex" else { return }
        guard state.buckets[bucket].map({ at >= $0.observedAt }) ?? true else { return }
        let key: String?
        if let identity = state.accountIdentity {
            if identityKeys[identity] == nil { identityKeys[identity] = UUID().uuidString }
            key = identityKeys[identity]
        } else { key = nil }
        let observation = CodexUsageSnapshot(primary: primary, secondary: secondary,
            observedAt: at, planType: boundedString(limits["plan_type"]), limitID: limitID, identityKey: key)
        if at > now {
            // Keep a bounded queue of future observations, rather than letting a
            // skewed timestamp permanently suppress valid current evidence. They
            // become eligible without requiring another write to the source file.
            var pending = state.deferredBuckets[bucket] ?? []
            pending.removeAll { $0.observedAt == at }
            pending.append(observation)
            pending.sort { $0.observedAt < $1.observedAt }
            state.deferredBuckets[bucket] = Array(pending.prefix(32))
        } else {
            state.buckets[bucket] = observation
        }
    }

    /// Reduce records before retaining anything, including future-dated events.
    /// Tool arguments, answers, error messages and output never enter the cache.
    private func activityMetadata(_ payload: [String: Any], recordType: String) -> [String: Any]? {
        guard let kind = payload["type"] as? String else { return nil }
        if recordType == "response_item" {
            let requesting = ["function_call", "custom_tool_call"].contains(kind)
                && CodexAgentSnapshot.isQuestionTool(payload["name"] as? String)
            guard requesting || ["function_call_output", "custom_tool_call_output"].contains(kind),
                  let id = boundedString(payload["call_id"]) else { return nil }
            return ["type": requesting ? "input_requested" : "input_resolved", "call_id": id]
        }
        guard recordType == "event_msg" else { return nil }
        var metadata: [String: Any] = ["type": kind]
        metadata["turn_id"] = boundedString(payload["turn_id"])
        switch kind {
        case "task_started", "task_complete", "turn_aborted", "token_count":
            if let error = payload["error"], !(error is NSNull) { metadata["error"] = true }
        case "request_user_input":
            guard let id = boundedString(payload["call_id"]) else { return nil }
            metadata["type"] = "input_requested"
            metadata["call_id"] = id
        case "error":
            let info = payload["codex_error_info"]
            metadata["codex_error_info"] = boundedString(info) ?? (info as? [String: Any])?.keys.first
        case "item_started", "item_completed":
            if let item = payload["item"] as? [String: Any] {
                var reduced: [String: Any] = [:]
                reduced["type"] = boundedString(item["type"])
                reduced["status"] = boundedString(item["status"])
                reduced["exit_code"] = integer(item["exit_code"] ?? item["exitCode"])
                reduced["is_error"] = (item["is_error"] ?? item["isError"]
                    ?? (item["result"] as? [String: Any])?["isError"]) as? Bool
                metadata["item"] = reduced
            }
        default: return nil
        }
        return metadata
    }

    private func consumeActivity(_ payload: [String: Any], at: Date, state: inout FileState) {
        if state.activity?.consume(payload, at: at) == true,
           payload["type"] as? String == "task_started" {
            state.malformedActivity = false
        }
    }

    private func window(_ raw: Any?) -> CodexUsageWindow? {
        guard let value = raw as? [String: Any], let used = number(value["used_percent"]),
              (0...100).contains(used) else { return nil }
        let duration = integer(value["window_minutes"]).flatMap { $0 > 0 ? $0 : nil }
        let reset = number(value["resets_at"]).flatMap { $0 > 0 && $0 < 253_402_300_800 ? Date(timeIntervalSince1970: $0) : nil }
        return CodexUsageWindow(usedPercent: used, windowMinutes: duration, resetsAt: reset)
    }

    private func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, String(cString: value.objCType) != "c" else { return nil }
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }

    private func integer(_ value: Any?) -> Int? {
        guard let value = number(value), value.rounded(.towardZero) == value,
              value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }

    private func boundedString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 512 else { return nil }
        return value
    }

    private func readError(_ error: Error, key: String?) -> CodexUsageReadError {
        let value = error as NSError
        let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError
        let posix = value.domain == NSPOSIXErrorDomain ? value.code
            : (underlying?.domain == NSPOSIXErrorDomain ? underlying?.code : nil)
        let kind: CodexUsageReadError.Kind
        if posix == 1 || posix == 13 || (value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoPermissionError) {
            kind = .permissionDenied
        } else if posix == 2 || (value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoSuchFileError) {
            kind = .notFound
        } else { kind = .io }
        return CodexUsageReadError(fileKey: key, kind: kind)
    }
}


/// Optional user-facing names only. Never opens the state DB or conversation bodies.
/// The index is an internal format, so missing/malformed entries simply retain
/// the existing project/agent fallback. A renamed chat is picked up on refresh.
private final class CodexThreadTitleIndex {
    private let url: URL
    private var signature: String?
    private var names: [String: String] = [:]
    var cachedNames: [String: String] { names }

    init(url: URL) { self.url = url }

    func read() -> [String: String] {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                signature = nil; names = [:]; return [:]
            }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let stamp = "\(attributes[.systemFileNumber] ?? ""):\(size):\(modified)"
            if stamp == signature { return names }
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { return [:] }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            // The newest entries are at the end. Bound both IO and retained names.
            let limit: UInt64 = 1024 * 1024
            let offset = size > limit ? size - limit : 0
            try handle.seek(toOffset: offset)
            let bytes = try handle.read(upToCount: Int(min(size, limit))) ?? Data()
            var lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
            if offset > 0 && !lines.isEmpty { lines.removeFirst() }
            // Do not parse a partially appended final line.
            if bytes.last != 10 && !lines.isEmpty { lines.removeLast() }
            var result: [String: String] = [:]
            for line in lines.suffix(4096) where line.count <= 16_384 {
                guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 512,
                      let title = row["thread_name"] as? String else { continue }
                let cleaned = title.components(separatedBy: .controlCharacters).joined(separator: " ")
                    .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                guard !cleaned.isEmpty else { continue }
                result[id] = String(cleaned.prefix(256))
            }
            signature = stamp
            names = result
            return result
        } catch {
            // A removed or inaccessible index cannot keep a stale chat name forever.
            signature = nil; names = [:]; return [:]
        }
    }
}
