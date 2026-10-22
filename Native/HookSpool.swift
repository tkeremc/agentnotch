import Darwin
import Foundation

/// Shared by both standalone helpers. Directory flock serializes publication
/// and this small checkpoint across processes, including while the app is off.
enum HookSpool {
    private static let maximumEvents = 4096
    private static let retainedAfterCleanup = 3072
    private static let cleanupInterval: TimeInterval = 60
    private static let checkpointName = ".spool-state-v1"

    private struct Checkpoint: Codable {
        let version: Int
        let cleanedAt: TimeInterval
        let count: Int
        let directoryStamp: String
    }

    static func append(_ data: Data, id: String, directoryFD: Int32, deadline: TimeInterval) {
        let lockDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.5)
        while flock(directoryFD, LOCK_EX | LOCK_NB) != 0 {
            guard ProcessInfo.processInfo.systemUptime < lockDeadline else { return }
            usleep(1_000)
        }
        defer { flock(directoryFD, LOCK_UN) }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return }

        let checkpointFD = openCheckpoint(directoryFD)
        defer { if checkpointFD >= 0 { close(checkpointFD) } }
        let now = Date().timeIntervalSince1970
        let saved = readCheckpoint(checkpointFD)
        let count: Int
        let cleanedAt: TimeInterval
        if let saved, saved.version == 1, (0..<maximumEvents).contains(saved.count),
           saved.cleanedAt.isFinite, now >= saved.cleanedAt,
           now - saved.cleanedAt < cleanupInterval,
           saved.directoryStamp == directoryStamp(directoryFD) {
            count = saved.count
            cleanedAt = saved.cleanedAt
        } else {
            // Missing/corrupt state, outside writers, rollback, expiry or a full
            // queue require reconciliation. Unsafe state files are never used
            // or overwritten; the conservative scan still permits delivery.
            guard let remaining = prune(directoryFD, now: now, deadline: deadline) else { return }
            count = remaining
            cleanedAt = now
        }

        let temporary = ".\(id).tmp"
        let file = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { return }
        var succeeded = writeAll(data, to: file)
        if close(file) != 0 { succeeded = false }
        if succeeded { succeeded = renameat(directoryFD, temporary, directoryFD, "\(id).json") == 0 }
        guard succeeded else { unlinkat(directoryFD, temporary, 0); return }

        // Overwriting an existing regular checkpoint does not change the
        // directory stamp. A crash/partial write makes the next helper rescan.
        if checkpointFD >= 0, let stamp = directoryStamp(directoryFD),
           let bytes = try? JSONEncoder().encode(Checkpoint(version: 1, cleanedAt: cleanedAt,
               count: count + 1, directoryStamp: stamp)),
           lseek(checkpointFD, 0, SEEK_SET) == 0, ftruncate(checkpointFD, 0) == 0 {
            _ = writeAll(bytes, to: checkpointFD)
        }
    }

    private static func openCheckpoint(_ directoryFD: Int32) -> Int32 {
        let file = openat(directoryFD, checkpointName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard file >= 0 else { return -1 }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_nlink == 1, info.st_size <= 1024 else { close(file); return -1 }
        return file
    }

    private static func readCheckpoint(_ file: Int32) -> Checkpoint? {
        guard file >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        guard let bytes = try? handle.read(upToCount: 1024) else { return nil }
        return try? JSONDecoder().decode(Checkpoint.self, from: bytes)
    }

    private static func directoryStamp(_ directoryFD: Int32) -> String? {
        var info = stat()
        guard fstat(directoryFD, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    private static func writeAll(_ data: Data, to file: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private static func prune(_ directoryFD: Int32, now: TimeInterval, deadline: TimeInterval) -> Int? {
        let copy = dup(directoryFD)
        guard copy >= 0 else { return nil }
        guard let stream = fdopendir(copy) else { close(copy); return nil }
        defer { closedir(stream) }
        let oldest = now - 7 * 24 * 3600
        var retained: [(name: String, seconds: Int, nanoseconds: Int)] = []
        func remove(_ name: String) -> Bool {
            unlinkat(directoryFD, name, 0) == 0 || errno == ENOENT
        }
        func trim(to limit: Int) -> Bool {
            retained.sort {
                if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
                if $0.nanoseconds != $1.nanoseconds { return $0.nanoseconds > $1.nanoseconds }
                return $0.name > $1.name
            }
            for entry in retained.dropFirst(limit) {
                guard ProcessInfo.processInfo.systemUptime < deadline, remove(entry.name) else { return false }
            }
            if retained.count > limit { retained.removeSubrange(limit...) }
            return true
        }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { return nil }
                break
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil else { continue }
            var info = stat()
            guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { continue }
            if Double(info.st_mtimespec.tv_sec) < oldest {
                guard remove(name) else { return nil }
            } else {
                retained.append((name, info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec))
                // Bound temporary metadata even for a spool left by an older
                // build. Retain the newest events, regardless of readdir order.
                if retained.count == maximumEvents * 2, !trim(to: maximumEvents) { return nil }
            }
        }
        // Free headroom at capacity so a busy full queue does not regress to a
        // full scan per event. Publication still never exceeds 4096 events.
        if retained.count >= maximumEvents, !trim(to: retainedAfterCleanup) { return nil }
        return retained.count
    }
}
