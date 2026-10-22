import AppKit
import Combine
import Darwin
import Foundation

enum CodexConnection: Equatable {
    case notInstalled, repairRequired, waitingForEvents, receiving, unavailable
}

enum CodexIndicator: Equatable {
    case none, working, approval, failed, connectionIssue

    var symbol: String {
        switch self {
        case .none, .working: return "circle.dotted.circle"
        case .approval: return "exclamationmark.bubble.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .connectionIssue: return "link.badge.plus"
        }
    }
    var title: L10nKey {
        switch self {
        case .none, .working: return .codexWorking
        case .approval: return .codexPermissionRequested
        case .failed: return .codexFailed
        case .connectionIssue: return .codexRepairHint
        }
    }

    static func resolve(agents: [CodexAgentSnapshot], approvals: [CodexApprovalSnapshot],
                        connection: CodexConnection, now: Date = .now) -> Self {
        if !approvals.isEmpty { return .approval }
        if agents.contains(where: { ($0.status == .failed || $0.hasIssue)
            && now.timeIntervalSince($0.updatedAt) < 300 }) { return .failed }
        if agents.contains(where: { $0.status == .working }) { return .working }
        if connection == .repairRequired || connection == .unavailable { return .connectionIssue }
        return .none
    }
}

struct CodexCompactAgent: Identifiable, Equatable {
    enum Role: Equatable {
        case main, subagent

        var title: L10nKey { self == .main ? .agentMain : .codexSubagent }
    }

    let id: String
    let name: String
    let indicator: CodexIndicator
    var iconName = "GPTMark"
    // Provider-level connection/error alerts have no agent role.
    var role: Role? = nil

    static func make(agents: [CodexAgentSnapshot], approvals: [CodexApprovalSnapshot],
                     connection: CodexConnection, now: Date = .now) -> [Self] {
        let active = agents.filter { $0.status == .working || $0.status == .approvalRequested }
            .sorted {
                if $0.isSubagent != $1.isSubagent { return !$0.isSubagent }
                return $0.id < $1.id
            }
        if !active.isEmpty {
            return active.map { agent in
                let status: CodexIndicator
                if agent.status == .approvalRequested || approvals.contains(where: { $0.targetID == agent.id }) {
                    status = .approval
                } else { status = agent.hasIssue ? .failed : .working }
                let label = agent.conversationTitle != nil || agent.name != nil
                    ? "\(agent.displayTitle) · \(agent.displaySubtitle)" : agent.project
                return Self(id: agent.id, name: label, indicator: status,
                            role: agent.isSubagent ? .subagent : .main)
            }
        }
        let status = CodexIndicator.resolve(agents: agents, approvals: approvals, connection: connection, now: now)
        return status == .none ? [] : [Self(id: "codex-status", name: "Codex", indicator: status)]
    }
}

enum CodexLocations {
    /// HOME/NSHomeDirectory point at the app container in an App Sandbox process.
    static var defaultHome: URL {
        let realHome = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }
            .map { String(cString: $0) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: realHome, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
    }

    static func configuredHome(environment: [String: String] = ProcessInfo.processInfo.environment,
                               standardHome: URL = defaultHome) -> URL {
        guard let path = environment["CODEX_HOME"], path.hasPrefix("/") else { return standardHome }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// Inspect known Codex locations only; never crawl the user's home or read
    /// credentials. An explicitly configured home must not fall back to another
    /// installation when it is missing or inaccessible.
    static func discover(home: URL) -> URL? {
        var info = stat()
        guard lstat(home.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { return nil }
        return home.standardizedFileURL
    }
}

struct CodexMonitorSnapshot {
    let usage: CodexUsageReadResult
    let agents: [CodexAgentSnapshot]
    let approvals: [CodexApprovalSnapshot]
    let lastHookAt: Date?
    let connection: CodexConnection
}

/// Confined to the store's serial utility queue. Only the installer writes to
/// Codex, and it is never called by this monitor or by an automatic refresh.
final class CodexMonitor {
    let home: URL
    private let usage: CodexUsageReader
    private let helperSource: URL?
    private let eventData: (URL) throws -> Data?
    private var activity = CodexActivityState()
    private var seenFiles: Set<String> = []
    private var lastHookAt: Date?
    private var lastPollAt: Date?
    private var usageResult = CodexUsageReadResult(snapshot: nil, availability: .noData,
                                                  scannedFiles: 0, readErrors: [])

    private var installed = false
    private var needsRepair = false
    private var didValidate = false
    private var eventAccessFailed = false
    private var retryEventsAt: Date?
    private(set) var eventScanCount = 0
    private(set) var validationCount = 0
    var usageScanCount: Int { usage.fullScanCount }
    var usageFileReadCount: Int { usage.fileReadCount }

    var observationRoots: [URL] {
        let installer = CodexHookInstaller(codexHome: home, helperSource: helperSource)
        return [home.appendingPathComponent("sessions"),
                home.appendingPathComponent("agentnotch/events"),
                home.appendingPathComponent("agentnotch/installation.json"),
                home.appendingPathComponent("hooks.json")] + [home.appendingPathComponent("session_index.jsonl")]
            + [installer.executionURL].compactMap { $0 }
    }

    var observationPaths: [URL] { observationRoots + usage.observationPaths }

    init(home: URL, helperSource: URL? = nil,
         eventData: @escaping (URL) throws -> Data? = CodexMonitor.readEventData) {
        self.home = home
        self.helperSource = helperSource
        self.eventData = eventData
        usage = CodexUsageReader(sessionsDirectory: home.appendingPathComponent("sessions"))
    }

    func poll(now: Date = .now, changes: MonitorChanges = .all) -> CodexMonitorSnapshot {
        var changes = changes
        if lastPollAt == nil || now < lastPollAt! { changes = .all }
        lastPollAt = now
        let sessions = home.appendingPathComponent("sessions")
        if changes.reconcile { usageResult = usage.refresh(now: now) }
        else if changes.affects(sessions) {
            usageResult = usage.refresh(now: now, changedPaths: changes.paths.filter {
                MonitorChanges(paths: [$0]).affects(sessions)
            })
        } else { usageResult = usage.advance(now: now) }
        let directory = home.appendingPathComponent("agentnotch/events", isDirectory: true)
        if changes.affects(directory) || retryEventsAt.map({ $0 <= now }) == true {
            eventScanCount += 1
            eventAccessFailed = false
            retryEventsAt = nil
            if FileManager.default.fileExists(atPath: directory.path) {
                do {
                    let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
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
                    var incoming: [CodexHookEvent] = []
                    for url in eligible where !seenFiles.contains(url.lastPathComponent) {
                        do {
                            guard let data = try eventData(url) else {
                                seenFiles.insert(url.lastPathComponent)
                                continue
                            }
                            if let event = try? JSONDecoder().decode(CodexHookEvent.self, from: data),
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
                    }) { activity.consume(event) }
                } catch { eventAccessFailed = true }
            }
            if eventAccessFailed { retryEventsAt = now.addingTimeInterval(5) }
        }
        let installer = CodexHookInstaller(codexHome: home, helperSource: helperSource)
        let configuration = home.appendingPathComponent("hooks.json")
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
        let projection = CodexActivityProjection(observed: usage.activitySnapshots(now: now,
                refreshTitles: changes.affects(home.appendingPathComponent("session_index.jsonl"))),
            hooked: installed && !eventAccessFailed ? activity.agents(at: now) : [],
            approvals: installed && !eventAccessFailed ? activity.pendingApprovals(at: now) : [])
        return CodexMonitorSnapshot(usage: usageResult, agents: projection.agents,
            approvals: projection.approvals, lastHookAt: lastHookAt, connection: connection)
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
final class CodexStore: ObservableObject {
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
    private let queue = DispatchQueue(label: "com.agentnotch.codex", qos: .utility)
    private var monitor: CodexMonitor?
    var hasCachedMonitor: Bool { monitor != nil }
    private lazy var cacheRetention = MonitorCacheRetention { [weak self] in
        guard let self, self.driver == nil else { return }
        self.discardCachedMonitor()
    }
    private var driver: LocalMonitorDriver?
    private var generation = 0
    private var accessURL: URL?
    private var home: URL
    private static let bookmarkKey = "codex.integration.folder"

    init(codexHome: URL? = nil, helperSource: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.helperSource = helperSource
        var resolvedHome = codexHome ?? CodexLocations.configuredHome()
        if codexHome == nil, let bookmark = defaults.data(forKey: Self.bookmarkKey) {
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
        let monitor = monitor ?? CodexMonitor(home: home, helperSource: helperSource)
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

    /// Settings can inspect/remove an existing connection even when the Codex
    /// widget has not been added. This does not start background monitoring.
    func refreshConnection() {
        guard !isChangingConnection else { return }
        let installer = CodexHookInstaller(codexHome: home, helperSource: helperSource)
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
    /// Codex still owns its separate hook trust UI.
    func connect(localization: AppLocalization) {
        connect { _ in
            let alert = NSAlert()
            alert.messageText = localization.text(.codexConnectQuestion)
            alert.informativeText = localization.text(.codexConnectPermission)
            alert.addButton(withTitle: localization.text(.codexEnable))
            alert.addButton(withTitle: localization.text(.codexCancel))
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
            let selected = CodexLocations.discover(home: candidate)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let selected else {
                    self.isChangingConnection = false
                    self.connectionFailure = .codexNotFound
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
        let installer = CodexHookInstaller(codexHome: selected, helperSource: helperSource)
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
                    self.connectionFailure = .codexConnectionFailed
                }
            }
        }
    }

    func disconnect() {
        guard !isChangingConnection else { return }
        isChangingConnection = true
        connectionFailure = nil
        let installer = CodexHookInstaller(codexHome: home, helperSource: helperSource)
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
                    self.home = CodexLocations.configuredHome()
                    self.agents = []
                    self.connection = .notInstalled
                    self.lastHookAt = nil
                    if wasRunning { self.start() }
                } else { self.connectionFailure = .codexConnectionFailed }
            }
        }
    }

    private func apply(_ result: CodexMonitorSnapshot) {
        if usage != result.usage.snapshot { usage = result.usage.snapshot }
        if usageAvailability != result.usage.availability { usageAvailability = result.usage.availability }
        if agents != result.agents { agents = result.agents }
        if approvals != result.approvals { approvals = result.approvals }
        if lastHookAt != result.lastHookAt { lastHookAt = result.lastHookAt }
        if connection != result.connection { connection = result.connection }
        let nextIndicator = CodexIndicator.resolve(agents: result.agents, approvals: result.approvals,
                                           connection: result.connection)
        let nextCompactAgents = CodexCompactAgent.make(agents: result.agents, approvals: result.approvals,
                                              connection: result.connection)
        if indicator != nextIndicator { indicator = nextIndicator }
        if compactAgents != nextCompactAgents { compactAgents = nextCompactAgents }
    }
}
