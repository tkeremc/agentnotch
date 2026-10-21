import AppKit
import Combine
import Foundation

enum NowPlayingAvailability: Equatable {
    case connecting
    case available
    case unavailable
}

struct NowPlayingSnapshot {
    var title: String
    var artist: String
    var album: String
    var artwork: NSImage?
    var isPlaying: Bool
    var elapsedTime: TimeInterval
    var duration: TimeInterval
    var appName: String
    var bundleIdentifier: String
    var processIdentifier: Int
    var itemIdentifier: String
    var trackIdentifier: String
    var artworkIdentifier: String
    var canPrevious: Bool
    var canNext: Bool
    var timestamp: Date
    var playbackRate: Double

    var id: String {
        let fallback = trackIdentifier.isEmpty ? "\(title)|\(artist)|\(album)" : trackIdentifier
        let item = itemIdentifier.isEmpty ? fallback : itemIdentifier
        let source = processIdentifier > 0 ? "pid:\(processIdentifier)" : bundleIdentifier
        return "\(source)|\(item)"
    }

    init(title: String, artist: String = "", album: String = "", artwork: NSImage? = nil,
         isPlaying: Bool = false, elapsedTime: TimeInterval = 0, duration: TimeInterval = 0,
         appName: String = "", bundleIdentifier: String = "", canPrevious: Bool = true,
         canNext: Bool = true, timestamp: Date = Date(), playbackRate: Double = 1,
         trackIdentifier: String = "", artworkIdentifier: String = "", processIdentifier: Int = 0,
         itemIdentifier: String = "") {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.isPlaying = isPlaying
        self.elapsedTime = elapsedTime.isFinite ? max(0, elapsedTime) : 0
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = max(0, processIdentifier)
        self.itemIdentifier = itemIdentifier
        self.trackIdentifier = trackIdentifier
        self.artworkIdentifier = artworkIdentifier
        self.canPrevious = canPrevious
        self.canNext = canNext
        self.timestamp = timestamp
        self.playbackRate = playbackRate.isFinite ? max(0, playbackRate) : 1
    }

    func elapsed(at date: Date) -> TimeInterval {
        let advance = isPlaying ? max(0, date.timeIntervalSince(timestamp)) * playbackRate : 0
        let value = elapsedTime + advance
        return duration > 0 ? min(duration, value) : value
    }

    func progress(at date: Date) -> Double {
        duration > 0 ? min(1, max(0, elapsed(at: date) / duration)) : 0
    }
}

/// Decode each complete bridge message, preserving artwork only for the same
/// item. A player disappearing clears the old snapshot immediately.
struct NowPlayingDecoder {
    private(set) var snapshot: NowPlayingSnapshot?

    mutating func consume(_ data: Data, receivedAt: Date = Date()) throws -> Bool {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try consume(object, receivedAt: receivedAt)
    }

    mutating func consume(_ object: [String: Any], receivedAt: Date = Date()) throws -> Bool {
        guard let type = object["type"] as? String else { throw CocoaError(.coderReadCorrupt) }
        if type == "ready" { return false }
        guard type == "data", let payload = object["payload"] as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        let title = (payload["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { snapshot = nil; return true }
        let duration = (payload["duration"] as? NSNumber)?.doubleValue ?? 0
        let epoch = (payload["timestamp"] as? NSNumber)?.doubleValue
        let timestamp = epoch.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil } ?? receivedAt
        var next = NowPlayingSnapshot(
            title: title,
            artist: payload["artist"] as? String ?? "",
            album: payload["album"] as? String ?? "",
            isPlaying: (payload["playing"] as? NSNumber)?.boolValue ?? false,
            elapsedTime: (payload["elapsedTime"] as? NSNumber)?.doubleValue ?? 0,
            duration: duration,
            appName: payload["appName"] as? String ?? "",
            bundleIdentifier: payload["bundleIdentifier"] as? String ?? "",
            canPrevious: !((payload["prohibitsSkip"] as? NSNumber)?.boolValue ?? false),
            canNext: !((payload["prohibitsSkip"] as? NSNumber)?.boolValue ?? false),
            timestamp: timestamp,
            playbackRate: (payload["playbackRate"] as? NSNumber)?.doubleValue ?? 1,
            trackIdentifier: payload["trackIdentifier"] as? String ?? "",
            artworkIdentifier: payload["artworkIdentifier"] as? String ?? "",
            processIdentifier: (payload["processIdentifier"] as? NSNumber)?.intValue ?? 0,
            itemIdentifier: payload["itemIdentifier"] as? String ?? ""
        )
        if let encoded = payload["artworkData"] as? String, encoded.utf8.count <= 24 * 1024 * 1024,
           let artworkData = Data(base64Encoded: encoded) {
            next.artwork = NSImage(data: artworkData)
        }
        if next.artwork == nil, let previous = snapshot, next.id == previous.id {
            // Focus updates may omit artwork entirely. Absence does not
            // invalidate a known cover; an explicit replacement ID does.
            if next.artworkIdentifier.isEmpty { next.artworkIdentifier = previous.artworkIdentifier }
            if next.artworkIdentifier == previous.artworkIdentifier { next.artwork = previous.artwork }
        }
        snapshot = next
        return true
    }
}

/// One event stream for the application, owned by its panel controller. No
/// Automation, Accessibility, browser scripting or network access is required.
@MainActor
final class NowPlayingStore: ObservableObject {
    @Published private(set) var snapshot: NowPlayingSnapshot?
    @Published private(set) var availability: NowPlayingAvailability = .connecting
    @Published private(set) var isCommandPending = false

    var canControl: Bool { availability == .available && snapshot != nil }
    var canPrevious: Bool { canControl && snapshot?.canPrevious == true }
    var canNext: Bool { canControl && snapshot?.canNext == true }

    private let resourceDirectory: URL?
    private var streamProcess: Process?
    private var streamInput: Pipe?
    private var commandSequence: UInt = 0
    private var pendingCommandIDs = Set<UInt>()
    private var streamOutput: Pipe?
    private var streamErrors: Pipe?
    private var decoder = NowPlayingDecoder()
    private var buffer = Data()
    private var generation: UInt = 0

    init(bundle: Bundle = .main, resourceDirectory: URL? = nil) {
        self.resourceDirectory = resourceDirectory ?? bundle.resourceURL?.appendingPathComponent("Media", isDirectory: true)
    }

    func start() {
        guard streamProcess == nil else { return }
        generation &+= 1
        let currentGeneration = generation
        availability = .connecting
        guard let process = makeProcess(command: "stream") else {
            availability = .unavailable
            return
        }
        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()
        streamInput = input
        streamOutput = output
        streamErrors = errors
        streamProcess = process
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        // Drain diagnostics so an unsupported OS cannot fill stderr and stall.
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.receive(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                // Invalidate read tasks already queued by FileHandle before exit.
                self.generation &+= 1
                self.cleanUpStream()
                self.decoder = NowPlayingDecoder()
                self.snapshot = nil
                self.availability = .unavailable
            }
        }
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.generation == currentGeneration,
                      self.availability == .connecting else { return }
                self.streamProcess?.terminate()
            }
        }
        catch {
            cleanUpStream()
            availability = .unavailable
        }
    }

    func stop() {
        generation &+= 1
        streamProcess?.terminationHandler = nil
        if streamProcess?.isRunning == true { streamProcess?.terminate() }
        cleanUpStream()
        decoder = NowPlayingDecoder()
        snapshot = nil
        availability = .connecting
    }

    func togglePlayPause() { if canControl { send(2) } }
    func nextTrack() { if canNext { send(4) } }
    func previousTrack() { if canPrevious { send(5) } }

    private func send(_ command: Int) {
        guard let process = streamProcess, process.isRunning, let streamInput else { return }
        commandSequence &+= 1
        let commandID = commandSequence
        guard var message = try? JSONSerialization.data(withJSONObject: ["command": command, "id": commandID]) else { return }
        message.append(10)
        pendingCommandIDs.insert(commandID)
        isCommandPending = true
        do {
            // Reuse the live bridge so transport does not pay for Perl and
            // MediaRemote startup on every click. The bridge acknowledges IPC
            // separately from the subsequent player metadata refresh.
            try streamInput.fileHandleForWriting.write(contentsOf: message)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.pendingCommandIDs.remove(commandID) != nil else { return }
                self.isCommandPending = !self.pendingCommandIDs.isEmpty
                if process.isRunning { process.terminate() }
            }
        }
        catch {
            pendingCommandIDs.remove(commandID)
            isCommandPending = !pendingCommandIDs.isEmpty
            if process.isRunning { process.terminate() }
        }
    }

    private func makeProcess(command: String) -> Process? {
        guard let resourceDirectory else { return nil }
        let script = resourceDirectory.appendingPathComponent("now-playing-bridge.pl")
        let library = resourceDirectory.appendingPathComponent("NowPlayingBridge.dylib")
        guard FileManager.default.isReadableFile(atPath: script.path),
              FileManager.default.isReadableFile(atPath: library.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, library.path, command]
        // Do not inherit Perl library injection variables from a launching shell.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "en_US.UTF-8"]
        return process
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        guard buffer.count <= 32 * 1024 * 1024 else {
            streamProcess?.terminate()
            return
        }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if message["type"] as? String == "commandResult" {
                    if let commandID = (message["id"] as? NSNumber)?.uintValue,
                       pendingCommandIDs.remove(commandID) != nil {
                        isCommandPending = !pendingCommandIDs.isEmpty
                    }
                    continue
                }
                let changed = try decoder.consume(message)
                availability = .available
                if changed { snapshot = decoder.snapshot }
            } catch {
                // Ignore a single malformed message; never show stale text from it.
                continue
            }
        }
    }

    private func cleanUpStream() {
        try? streamInput?.fileHandleForWriting.close()
        streamInput = nil
        pendingCommandIDs.removeAll()
        isCommandPending = false
        streamOutput?.fileHandleForReading.readabilityHandler = nil
        streamErrors?.fileHandleForReading.readabilityHandler = nil
        streamOutput = nil
        streamErrors = nil
        streamProcess = nil
        buffer.removeAll(keepingCapacity: false)
    }

    deinit {
        streamOutput?.fileHandleForReading.readabilityHandler = nil
        streamErrors?.fileHandleForReading.readabilityHandler = nil
        if streamProcess?.isRunning == true { streamProcess?.terminate() }
        try? streamInput?.fileHandleForWriting.close()
    }
}
