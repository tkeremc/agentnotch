import CoreServices
import Darwin
import Foundation

/// File notifications are hints. A bounded recovery scan handles dropped events,
/// unavailable streams, sleep/wake and changes made while monitoring was stopped.
struct MonitorChanges {
    var reconcile = false
    var paths: Set<String> = []

    static let all = Self(reconcile: true)

    func affects(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        return reconcile || paths.contains { path in
            path == target || path.hasPrefix(target + "/") || target.hasPrefix(path + "/")
        }
    }
}

/// All mutable state (including the FSEvents callback) lives on one utility queue.
/// The one-second tick projects expiry from memory. Only paths without an
/// available native watch need a metadata check; content is never polled.
final class LocalMonitorDriver {
    private let queue: DispatchQueue
    private let home: URL
    private let observed: [URL]
    private let recursiveDirectories: [URL]
    private let receive: (MonitorChanges) -> Void
    private let watchPaths: () -> [URL]
    private let recoveryInterval: TimeInterval
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var flush: DispatchWorkItem?
    private var pending = MonitorChanges()
    private var running = false
    private var lastRecovery: TimeInterval = 0
    private var aliases: [(original: String, canonical: String)] = []
    private var vnodeSources: [String: DispatchSourceFileSystemObject] = [:]
    private var fallback: [String: FileStamp] = [:]
    private var previousPaths: Set<String> = []
    private var watchesDirty = true

    private struct FileStamp: Equatable {
        let identity: String
        init(_ path: String) {
            var info = stat()
            if lstat(path, &info) == 0 {
                identity = "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
            } else { identity = "error:\(errno)" }
        }
    }

    init(home: URL, observed: [URL], queue: DispatchQueue,
         recoveryInterval: TimeInterval = 60, recursiveDirectories: [URL] = [],
         watchPaths: (() -> [URL])? = nil,
         receive: @escaping (MonitorChanges) -> Void) {
        self.home = home
        self.observed = observed
        self.recursiveDirectories = recursiveDirectories
        self.queue = queue
        self.recoveryInterval = recoveryInterval
        self.watchPaths = watchPaths ?? { observed }
        self.receive = receive
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            startStream()
            lastRecovery = ProcessInfo.processInfo.systemUptime
            // Arm entry-point directories before the initial read to close the
            // startup race, then add discovered session files/directories.
            updateNativeWatches()
            pending = .all
            deliver()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            timer?.cancel()
            timer = nil
            flush?.cancel()
            flush = nil
            pending = MonitorChanges()
            stopStream()
            vnodeSources.values.forEach { $0.cancel() }
            vnodeSources = [:]
            fallback = [:]
            previousPaths = []
            watchesDirty = true
        }
    }

    private func tick() {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Only paths without an available vnode watch need metadata fallback.
        // No enumeration, content reads or hashes happen here.
        for (path, stamp) in fallback {
            let current = FileStamp(path)
            if current != stamp {
                pending.paths.insert(path)
                fallback.removeValue(forKey: path)
                watchesDirty = true
            }
        }
        if now - lastRecovery >= recoveryInterval {
            lastRecovery = now
            pending = .all
            // Re-arm roots after atomic replacement, deletion or an unavailable home.
            stopStream()
            startStream()
            fallback = [:]
            watchesDirty = true
        }
        deliver()
    }

    private func deliver() {
        flush?.cancel()
        flush = nil
        let changes = pending
        pending = MonitorChanges()
        receive(changes)
        updateNativeWatches()
    }

    private func updateNativeWatches() {
        let urls = [home] + watchPaths()
        var unique: Set<String> = []
        let paths = urls.map { $0.standardizedFileURL.path }.filter { unique.insert($0).inserted }
        guard watchesDirty || unique != previousPaths else { return }
        watchesDirty = false
        previousPaths = unique
        for path in Array(vnodeSources.keys) where !unique.contains(path) {
            vnodeSources.removeValue(forKey: path)?.cancel()
        }
        fallback = fallback.filter { unique.contains($0.key) }
        for path in paths where vnodeSources[path] == nil && fallback[path] == nil {
            // Bound descriptor usage even with very large session histories.
            guard vnodeSources.count < 128 else { fallback[path] = FileStamp(path); continue }
            let fd = Darwin.open(path, O_EVTONLY | O_NOFOLLOW)
            guard fd >= 0 else { fallback[path] = FileStamp(path); continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke, .link], queue: queue)
            source.setCancelHandler { Darwin.close(fd) }
            source.setEventHandler { [weak self] in
                guard let self, self.running else { return }
                self.pending.paths.insert(path)
                if let flags = self.vnodeSources[path]?.data,
                   !flags.intersection([.rename, .delete, .revoke]).isEmpty {
                    self.vnodeSources.removeValue(forKey: path)?.cancel()
                    self.watchesDirty = true
                }
                self.scheduleDelivery()
            }
            vnodeSources[path] = source
            source.resume()
            // A writer may have changed a newly discovered file between the
            // reader's snapshot and arming this watch. Recheck once after arming.
            pending.paths.insert(path)
        }
        scheduleDelivery()
    }

    private func startStream() {
        // Recursive streams cover only the explicitly allowed data directories.
        // Individual configuration/helper files use native watches; observing
        // their whole parent would include unrelated account/auth metadata.
        let roots = Set(recursiveDirectories.compactMap { url -> String? in
            var info = stat()
            let path = url.standardizedFileURL.path
            return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR ? path : nil
        })
        guard !roots.isEmpty else { return }
        aliases = roots.map { ($0, URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }
            .sorted { $0.canonical.count > $1.canonical.count }
        let canonicalRoots = Set(aliases.map(\.canonical)).sorted()
        let minimalRoots = canonicalRoots.filter { path in
            !canonicalRoots.contains { $0 != path && path.hasPrefix($0 + "/") }
        }
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(Unmanaged<LocalMonitorDriver>.fromOpaque(info).retain().toOpaque())
            }, release: { info in
                if let info { Unmanaged<LocalMonitorDriver>.fromOpaque(info).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let owner = Unmanaged<LocalMonitorDriver>.fromOpaque(info).takeUnretainedValue()
            let values = unsafeBitCast(paths, to: NSArray.self) as! [String]
            owner.changed(values, flags: flags, count: count)
        }, &context, minimalRoots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, flags) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        if FSEventStreamStart(created) { stream = created }
        else { FSEventStreamInvalidate(created); FSEventStreamRelease(created) }
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func changed(_ paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        guard running else { return }
        let recoveryFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
        for index in 0..<count {
            if flags[index] & recoveryFlags != 0 { pending = .all; break }
            let canonical = paths[index]
            var path = canonical
            if let alias = aliases.first(where: {
                canonical == $0.canonical || canonical.hasPrefix($0.canonical + "/")
            }) {
                path = alias.original + canonical.dropFirst(alias.canonical.count)
            }
            let change = MonitorChanges(paths: [path])
            if observed.contains(where: { change.affects($0) }) { pending.paths.insert(path) }
        }
        scheduleDelivery()
    }

    private func scheduleDelivery() {
        guard pending.reconcile || !pending.paths.isEmpty, flush == nil else { return }
        // Schedule once from the first event, so a busy writer cannot starve IO.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.deliver()
        }
        flush = work
        queue.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
}
