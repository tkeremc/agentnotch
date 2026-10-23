import AppKit
import Combine
import Darwin
import Foundation

enum ClaudeLocations {
    /// HOME/NSHomeDirectory point at the app container in an App Sandbox process.
    static var defaultHome: URL {
        let realHome = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }
            .map { String(cString: $0) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: realHome, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
    }

    static func configuredHome(environment: [String: String] = ProcessInfo.processInfo.environment,
                               standardHome: URL = defaultHome) -> URL {
        guard let path = environment["CLAUDE_CONFIG_DIR"], path.hasPrefix("/") else { return standardHome }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// Inspect known Claude locations only; never crawl the user's home or read
    /// credentials. An explicitly configured home must not fall back to another
    /// installation when it is missing or inaccessible.
    static func discover(home: URL) -> URL? {
        var info = stat()
        guard lstat(home.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { return nil }
        return home.standardizedFileURL
    }
}


struct ClaudeMonitorSnapshot {
    let usage: CodexUsageReadResult
    let agents: [CodexAgentSnapshot]
    let approvals: [CodexApprovalSnapshot]
    let lastHookAt: Date?
    let connection: CodexConnection
}

/// Confined to the store's serial utility queue. Only the installer writes to
/// Claude, and it is never called by this monitor or by an automatic refresh.
final class ClaudeMonitor {
    let home: URL
    private var usage = ClaudeUsageState()
    private let helperSource: URL?
    private let eventData: (URL) throws -> Data?
    private var activity = ClaudeActivityState()
    private let runtime: ClaudeRuntimeReader
    private var seenFiles: Set<String> = []
    private var lastHookAt: Date?
    private var lastPollAt: Date?

    private var installed = false
    private var needsRepair = false
    private var didValidate = false
    private var eventAccessFailed = false
    private var retryEventsAt: Date?
    private(set) var eventScanCount = 0
    private(set) var validationCount = 0
    var runtimeScanCount: Int { runtime.fileScanCount }

    var observationRoots: [URL] {
        let installer = ClaudeHookInstaller(claudeHome: home, helperSource: helperSource)
        return [home.appendingPathComponent("sessions"),
                home.appendingPathComponent("agentnotch/events"),
                home.appendingPathComponent("agentnotch/installation.json"),
                home.appendingPathComponent("settings.json")]
            + [installer.executionURL].compactMap { $0 }
    }

    var observationPaths: [URL] { observationRoots + runtime.observationPaths }

    init(home: URL, helperSource: URL? = nil,
         eventData: @escaping (URL) throws -> Data? = ClaudeMonitor.readEventData) {
        self.home = home
        self.helperSource = helperSource
        self.eventData = eventData
        runtime = ClaudeRuntimeReader(home: home)
    }

    func poll(now: Date = .now, changes: MonitorChanges = .all) -> ClaudeMonitorSnapshot {
        var changes = changes
        if lastPollAt == nil || now < lastPollAt! { changes = .all }
        if let previous = lastPollAt, now < previous {
            // A corrected wall clock must not preserve a future watermark.
            activity = ClaudeActivityState()
            usage = ClaudeUsageState()
            seenFiles.removeAll()
            lastHookAt = nil
        }
        lastPollAt = now
        let directory = home.appendingPathComponent("agentnotch/events", isDirectory: true)
        if changes.affects(directory) || retryEventsAt.map({ $0 <= now }) == true {
            eventScanCount += 1
            eventAccessFailed = false
            retryEventsAt = nil
            if FileManager.default.fileExists(atPath: directory.path) {
                do {
                    guard Self.safeDirectory(home),
                          Self.safeDirectory(home.appendingPathComponent("agentnotch")),
                          Self.safeDirectory(directory) else { throw CocoaError(.fileReadNoPermission) }
                    let urls = try FileManager.default.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                                      .contentModificationDateKey], options: [.skipsHiddenFiles])
                        .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
                        .sorted {
                            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                            return lhs == rhs ? $0.lastPathComponent < $1.lastPathComponent : lhs > rhs
                        }
                    let eligible = Array(urls.prefix(4096))
                    seenFiles.formIntersection(Set(eligible.map(\.lastPathComponent)))
                    var incoming: [ClaudeHookEvent] = []
                    for url in eligible where !seenFiles.contains(url.lastPathComponent) {
                        do {
                            guard let data = try eventData(url) else {
                                seenFiles.insert(url.lastPathComponent)
                                continue
                            }
                            if let event = try? JSONDecoder().decode(ClaudeHookEvent.self, from: data),
                               event.schemaVersion == 1, UUID(uuidString: event.id) != nil {
                                // A clock-skewed event must not move a reducer watermark
                                // ahead of real activity. Retry it when time catches up.
                                if event.timestamp > now {
                                    retryEventsAt = min(retryEventsAt ?? event.timestamp, event.timestamp)
                                    continue
                                }
                                guard event.timestamp >= now.addingTimeInterval(-7 * 86400) else {
                                    seenFiles.insert(url.lastPathComponent)
                                    continue
                                }
                                incoming.append(event)
                                lastHookAt = max(lastHookAt ?? .distantPast, event.timestamp)
                            }
                            seenFiles.insert(url.lastPathComponent)
                        } catch {
                            // The helper prunes old files while we scan. A listed
                            // event disappearing is normal, not a lost connection.
                            let error = error as NSError
                            let missing = (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
                                || (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoSuchFile.rawValue)
                            if !missing { eventAccessFailed = true }
                            // Retry actual read failures next poll. Other events
                            // must still reach the reducer during this poll.
                        }
                    }
                    for event in incoming.sorted(by: {
                        $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
                    }) {
                        activity.consume(event)
                        usage.consume(event, now: now)
                    }
                } catch { eventAccessFailed = true }
            }
            if eventAccessFailed { retryEventsAt = now.addingTimeInterval(5) }
        }
        let installer = ClaudeHookInstaller(claudeHome: home, helperSource: helperSource)
        let configuration = home.appendingPathComponent("settings.json")
        if !didValidate || changes.affects(configuration)
            || changes.affects(home.appendingPathComponent("agentnotch/installation.json"))
            || installer.executionURL.map({ changes.affects($0) }) == true {
            validationCount += 1
            installed = installer.isInstalled
            needsRepair = installer.needsRepair(installed: installed)
            didValidate = true
        }
        let connection: CodexConnection
        if eventAccessFailed { connection = .unavailable }
        else if needsRepair { connection = .repairRequired }
        else if !installed { connection = .notInstalled }
        else if let lastHookAt, now.timeIntervalSince(lastHookAt) < 300 { connection = .receiving }
        else { connection = .waitingForEvents }
        let currentUsage = installed && !eventAccessFailed ? usage.current(at: now) : nil
        let usageResult = CodexUsageReadResult(snapshot: currentUsage,
            availability: eventAccessFailed ? .permissionDenied : (currentUsage == nil ? .noData : .available),
            scannedFiles: seenFiles.count, readErrors: [])
        let runtimeAgents = runtime.poll(now: now, refreshFiles: changes.affects(home.appendingPathComponent("sessions")))
        let projection = ClaudeActivityProjection(
            runtime: runtimeAgents,
            hooked: installed && !eventAccessFailed ? activity.agents(at: now) : [],
            approvals: installed && !eventAccessFailed ? activity.pendingApprovals(at: now) : [],
            unavailableSessions: runtime.unavailableSessionIDs)
        return ClaudeMonitorSnapshot(usage: usageResult,
            agents: projection.agents,
            approvals: projection.approvals,
            lastHookAt: lastHookAt, connection: connection)
    }

    static func safeDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }

    static func readEventData(_ url: URL) throws -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return nil }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fstat(descriptor, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size > 0, info.st_size <= 8192 else { return nil }
        let data = try handle.read(upToCount: 8193) ?? Data()
        return data.count <= 8192 ? data : nil
    }
}


@MainActor
final class ClaudeStore: ObservableObject {
    @Published private(set) var usage: CodexUsageSnapshot?
    @Published private(set) var usageAvailability: CodexUsageAvailability = .noData
    @Published private(set) var agents: [CodexAgentSnapshot] = []
    @Published private(set) var approvals: [CodexApprovalSnapshot] = []
    @Published private(set) var connection: CodexConnection = .notInstalled
    @Published private(set) var lastHookAt: Date?
    @Published private(set) var indicator: CodexIndicator = .none
    @Published private(set) var compactAgents: [CodexCompactAgent] = []
    @Published private(set) var isChangingConnection = false
    @Published private(set) var connectionFailure: L10nKey?

    private let defaults: UserDefaults
    private let helperSource: URL?
    private let queue = DispatchQueue(label: "com.agentnotch.claude", qos: .utility)
    private var monitor: ClaudeMonitor?
    var hasCachedMonitor: Bool { monitor != nil }
    private lazy var cacheRetention = MonitorCacheRetention { [weak self] in
        guard let self, self.driver == nil else { return }
        self.discardCachedMonitor()
    }
    private var driver: LocalMonitorDriver?
    private var generation = 0
    private var accessURL: URL?
    private var home: URL
    private static let bookmarkKey = "claude.integration.folder"

    init(claudeHome: URL? = nil, helperSource: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.helperSource = helperSource
        var resolvedHome = claudeHome ?? ClaudeLocations.configuredHome()
        if claudeHome == nil, let bookmark = defaults.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                resolvedHome = url
                accessURL = url
                if stale, let renewed = try? url.bookmarkData(options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil, relativeTo: nil) {
                    defaults.set(renewed, forKey: Self.bookmarkKey)
                }
            }
        }
        home = resolvedHome
    }

    deinit {
        driver?.stop()
        accessURL?.stopAccessingSecurityScopedResource()
    }

    func start() {
        cacheRetention.cancel()
        guard driver == nil else { return }
        generation += 1
        let token = generation
        let monitor = monitor ?? ClaudeMonitor(home: home, helperSource: helperSource)
        self.monitor = monitor
        let source = LocalMonitorDriver(home: home, observed: monitor.observationRoots, queue: queue,
            recursiveDirectories: [home.appendingPathComponent("sessions"), home.appendingPathComponent("agentnotch/events")],
            watchPaths: { monitor.observationPaths }) { [weak self] changes in
            let result = monitor.poll(changes: changes)
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.driver != nil else { return }
                self.apply(result)
            }
        }
        driver = source
        source.start()
    }

    func stop(releaseCaches: Bool = true) {
        generation += 1
        driver?.stop()
        driver = nil
        approvals = []
        indicator = .none
        compactAgents = []
        if releaseCaches {
            cacheRetention.cancel()
            discardCachedMonitor()
        } else if monitor != nil {
            cacheRetention.schedule()
        }
    }

    private func discardCachedMonitor() {
        monitor = nil
        agents = []
        usage = nil
        usageAvailability = .noData
        lastHookAt = nil
        if connection == .receiving { connection = .waitingForEvents }
    }

    func retry() {
        let wasRunning = driver != nil
        stop()
        // The next start rebuilds unreadable/replaced event state.
        if wasRunning { start() }
    }

    /// Settings can inspect/remove an existing connection even when the Claude
    /// widget has not been added. This does not start background monitoring.
    func refreshConnection() {
        guard !isChangingConnection else { return }
        let installer = ClaudeHookInstaller(claudeHome: home, helperSource: helperSource)
        let token = generation
        queue.async { [weak self] in
            let installed = installer.isInstalled
            let needsRepair = installer.needsRepair(installed: installed)
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, !self.isChangingConnection else { return }
                if needsRepair { self.connection = .repairRequired }
                else if !installed { self.connection = .notInstalled }
                else if self.connection != .receiving { self.connection = .waitingForEvents }
            }
        }
    }

    /// Discovery is automatic; only the installation decision is interactive.
    /// Claude still owns its separate hook trust UI.
    func connect(localization: AppLocalization) {
        connect { _ in
            let alert = NSAlert()
            alert.messageText = localization.text(.claudeConnectQuestion)
            alert.informativeText = localization.text(.claudeConnectPermission)
            alert.addButton(withTitle: localization.text(.claudeEnable))
            alert.addButton(withTitle: localization.text(.claudeCancel))
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    /// Shared by the UI and isolated integration tests. No writes occur during
    /// discovery, on refresh, or when the confirmation is cancelled.
    func connect(confirm: @escaping @MainActor (URL) -> Bool) {
        guard !isChangingConnection else { return }
        isChangingConnection = true
        connectionFailure = nil
        let candidate = home
        queue.async { [weak self] in
            let selected = ClaudeLocations.discover(home: candidate)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let selected else {
                    self.isChangingConnection = false
                    self.connectionFailure = .claudeNotFound
                    return
                }
                guard confirm(selected) else {
                    self.isChangingConnection = false
                    return
                }
                self.installConnection(at: selected)
            }
        }
    }

    private func installConnection(at selected: URL) {
        let installer = ClaudeHookInstaller(claudeHome: selected, helperSource: helperSource)
        // Retain a legacy saved grant, when present, until the worker finishes.
        let heldScope = selected.startAccessingSecurityScopedResource()
        queue.async { [weak self] in
            defer { if heldScope { selected.stopAccessingSecurityScopedResource() } }
            let succeeded: Bool
            do { try installer.install(); succeeded = true } catch { succeeded = false }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isChangingConnection = false
                if succeeded {
                    let wasRunning = self.driver != nil
                    self.stop()
                    self.home = selected
                    self.connection = .waitingForEvents
                    if wasRunning { self.start() }
                } else {
                    self.connectionFailure = .claudeConnectionFailed
                }
            }
        }
    }

    func disconnect() {
        guard !isChangingConnection else { return }
        isChangingConnection = true
        connectionFailure = nil
        let installer = ClaudeHookInstaller(claudeHome: home, helperSource: helperSource)
        let removalScope = accessURL
        let heldScope = removalScope?.startAccessingSecurityScopedResource() == true
        queue.async { [weak self] in
            defer { if heldScope { removalScope?.stopAccessingSecurityScopedResource() } }
            let succeeded: Bool
            do { try installer.remove(); succeeded = true } catch { succeeded = false }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isChangingConnection = false
                if succeeded {
                    let wasRunning = self.driver != nil
                    self.stop()
                    self.defaults.removeObject(forKey: Self.bookmarkKey)
                    self.accessURL?.stopAccessingSecurityScopedResource()
                    self.accessURL = nil
                    self.home = ClaudeLocations.configuredHome()
                    self.agents = []
                    self.connection = .notInstalled
                    self.lastHookAt = nil
                    if wasRunning { self.start() }
                } else { self.connectionFailure = .claudeConnectionFailed }
            }
        }
    }

    private func apply(_ result: ClaudeMonitorSnapshot) {
        if usage != result.usage.snapshot { usage = result.usage.snapshot }
        if usageAvailability != result.usage.availability { usageAvailability = result.usage.availability }
        if agents != result.agents { agents = result.agents }
        if approvals != result.approvals { approvals = result.approvals }
        if lastHookAt != result.lastHookAt { lastHookAt = result.lastHookAt }
        if connection != result.connection { connection = result.connection }
        let nextIndicator = CodexIndicator.resolve(agents: result.agents, approvals: result.approvals,
                                                 connection: result.connection)
        let nextCompactAgents = CodexCompactAgent.make(agents: result.agents, approvals: result.approvals,
                                              connection: result.connection).map {
            CodexCompactAgent(id: $0.id == "codex-status" ? "claude-status" : $0.id,
                              name: $0.name == "Codex" ? "Claude" : $0.name,
                              indicator: $0.indicator, iconName: "ClaudeMark", role: $0.role)
        }
        if indicator != nextIndicator { indicator = nextIndicator }
        if compactAgents != nextCompactAgents { compactAgents = nextCompactAgents }
    }
}

/// Optional private Claude runtime registry. It contains lifecycle metadata,
/// never conversation bodies. Unknown versions or unverifiable PIDs are ignored.
final class ClaudeRuntimeReader {
    private let home: URL
    private let processMatches: (Int32, String) -> Bool
    private var records: [(pid: Int32, start: String, snapshot: CodexAgentSnapshot)] = []
    private var verifiedSessions: Set<String> = []
    private var lostSince: [String: Date] = [:]
    private var lastProjectionAt: Date?
    private(set) var unavailableSessionIDs: Set<String> = []
    private(set) var fileScanCount = 0
    private(set) var observationPaths: [URL] = []
    init(home: URL, processMatches: @escaping (Int32, String) -> Bool = ClaudeRuntimeReader.processMatches) {
        self.home = home
        self.processMatches = processMatches
    }
    func poll(now: Date, refreshFiles: Bool = true) -> [CodexAgentSnapshot] {
        if refreshFiles {
            fileScanCount += 1
            records = []
            observationPaths = []
            let directory = home.appendingPathComponent("sessions", isDirectory: true)
            var info = stat()
            guard ClaudeMonitor.safeDirectory(home), lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(),
                  let urls = try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return project(now: now) }
            observationPaths = urls.filter { $0.pathExtension == "json" }
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(512) {
                guard url.pathExtension == "json", let filePID = Int32(url.deletingPathExtension().lastPathComponent),
                      filePID > 0, let data = try? ClaudeMonitor.readEventData(url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pid = Self.number(object["pid"]), pid == Double(filePID),
                      object["pidDomain"] as? String == "darwin",
                      let start = object["procStart"] as? String,
                      let session = object["sessionId"] as? String, !session.isEmpty, session.utf8.count <= 512,
                      let milliseconds = Self.number(object["statusUpdatedAt"]),
                      milliseconds > 0 else { continue }
                let at = Date(timeIntervalSince1970: milliseconds / 1000)
                // This registry updates on transitions, not a heartbeat. A verified
                // identical live process keeps a durable busy/waiting state valid.
                guard let raw = object["status"] as? String else { continue }
                let status: CodexAgentStatus
                switch raw {
                case "busy", "shell": status = .working
                case "idle": status = .idle
                case "waiting":
                    // Only a documented permission wait is a permission indicator.
                    status = object["waitingFor"] as? String == "permission prompt" ? .approvalRequested : .unknown
                default: continue
                }
                let project = ((object["cwd"] as? String ?? "") as NSString).lastPathComponent
                let name = (object["name"] as? String).flatMap { raw -> String? in
                    let cleaned = raw.components(separatedBy: .controlCharacters).joined(separator: " ")
                        .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    return cleaned.isEmpty ? nil : String(cleaned.prefix(256))
                }
                let snapshot = CodexAgentSnapshot(id: session, project: project, name: nil,
                    status: status, updatedAt: at, conversationTitle: name)
                records.append((filePID, start, snapshot))
            }
        }
        return project(now: now)
    }

    private func project(now: Date) -> [CodexAgentSnapshot] {
        if let previous = lastProjectionAt, now < previous {
            verifiedSessions = []
            lostSince = [:]
        }
        lastProjectionAt = now
        // A cached registry is not proof of liveness. Recheck the process identity
        // even on memory-only ticks so exited/reused PIDs cannot remain busy.
        var result: [String: CodexAgentSnapshot] = [:]
        for record in records where record.snapshot.updatedAt <= now && processMatches(record.pid, record.start) {
            let snapshot = record.snapshot
            if result[snapshot.id].map({ snapshot.updatedAt >= $0.updatedAt }) ?? true {
                result[snapshot.id] = snapshot
            }
        }
        let live = Set(result.keys)
        for id in verifiedSessions.subtracting(live) { lostSince[id] = now }
        for id in live { lostSince.removeValue(forKey: id) }
        verifiedSessions = live
        // Losing a previously verified process must not fall back to its old
        // running hooks. Keep this fence for the hook freshness window only;
        // a replacement verified process immediately clears it. This is loss
        // of evidence, not proof that the task completed.
        lostSince = lostSince.filter { now.timeIntervalSince($0.value) <= 300 }
        if lostSince.count > 512 {
            lostSince = Dictionary(uniqueKeysWithValues: lostSince.sorted { $0.value > $1.value }
                .prefix(512).map { ($0.key, $0.value) })
        }
        unavailableSessionIDs = Set(lostSince.keys)
        return result.values.sorted { $0.id < $1.id }
    }
    private static let processDateFormatter: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return format
    }()
    static func processMatches(_ pid: Int32, _ expected: String) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid(), info.pbi_pid == UInt32(pid) else { return false }
        // Claude normalizes ps lstart to UTC; the field itself has no zone.
        let actual = processDateFormatter.string(from: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec)))
        func normalized(_ value: String) -> String { value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        return normalized(actual) == normalized(expected)
    }
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c",
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}

struct ClaudeActivityProjection {
    let agents: [CodexAgentSnapshot]
    let approvals: [CodexApprovalSnapshot]
    init(runtime: [CodexAgentSnapshot], hooked: [CodexAgentSnapshot], approvals: [CodexApprovalSnapshot],
         unavailableSessions: Set<String> = []) {
        let live = Dictionary(runtime.map { ($0.id, $0) }, uniquingKeysWith: { $0.updatedAt >= $1.updatedAt ? $0 : $1 })
        var merged = Dictionary(hooked.filter {
            !unavailableSessions.contains($0.parentID ?? $0.id)
        }.map { ($0.id, $0) }, uniquingKeysWith: { $0.updatedAt >= $1.updatedAt ? $0 : $1 })
        for snapshot in runtime {
            if let hook = merged[snapshot.id], hook.updatedAt > snapshot.updatedAt
                || (snapshot.status == .unknown && (hook.status == .approvalRequested || hook.status == .awaitingInput)) {
                var value = hook
                value.conversationTitle = snapshot.conversationTitle
                merged[snapshot.id] = value
            } else {
                var value = snapshot
                // A runtime busy transition has no tool outcome. It cannot
                // clear a proven tool failure within the continuing work.
                if snapshot.status == .working, let hook = merged[snapshot.id], hook.isActive(at: snapshot.updatedAt) {
                    value.hasIssue = hook.hasIssue
                }
                merged[snapshot.id] = value
            }
        }
        CodexAgentSnapshot.closeEndedSessions(in: &merged)
        self.approvals = approvals.filter { approval in
            guard !unavailableSessions.contains(approval.sessionID) else { return false }
            guard merged[approval.targetID]?.sessionEndedAt == nil,
                  merged[approval.sessionID]?.sessionEndedAt == nil else { return false }
            guard let snapshot = live[approval.targetID] else { return true }
            return snapshot.updatedAt < approval.requestedAt || snapshot.status == .approvalRequested || snapshot.status == .unknown
        }
        self.agents = merged.values.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }
}
