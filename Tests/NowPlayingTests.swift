import AppKit
import Foundation
@testable import AgentNotch

@MainActor
struct NowPlayingTests {
    static let cases: [(String, @MainActor () throws -> Void)] = [
        ("media timeline follows playing, paused and unknown duration", timeline),
        ("media messages clear ended sessions and reject malformed input", lifecycle),
        ("media artwork stays with its track", artworkIdentity),
        ("media skip restrictions and invalid times are sanitized", restrictions),
        ("missing media bridge disables transport without starting a player", missingBridge),
        ("media bridge routes transport and can restart after cleanup", bridgeIPC),
        ("exited media bridge cannot resurrect a queued snapshot", exitedBridge)
    ]

    private struct Failure: Error { let message: String }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    private static func data(_ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "data", "payload": payload])
    }

    private static func timeline() throws {
        let timestamp = Date(timeIntervalSince1970: 1000)
        var snapshot = NowPlayingSnapshot(title: "Video", isPlaying: true, elapsedTime: 10,
                                          duration: 60, timestamp: timestamp, playbackRate: 1.5)
        try expect(snapshot.elapsed(at: timestamp.addingTimeInterval(10)) == 25, "playback speed")
        try expect(snapshot.progress(at: timestamp.addingTimeInterval(100)) == 1, "progress clamps to duration")
        try expect(snapshot.elapsed(at: timestamp.addingTimeInterval(-5)) == 10, "future timestamp must not rewind")
        snapshot.isPlaying = false
        try expect(snapshot.elapsed(at: timestamp.addingTimeInterval(10)) == 10, "pause must freeze timeline")
        snapshot.duration = 0
        try expect(snapshot.progress(at: timestamp) == 0, "live media must have no invented duration")
    }

    private static func lifecycle() throws {
        var decoder = NowPlayingDecoder()
        let ready = try JSONSerialization.data(withJSONObject: ["type": "ready"])
        let readyChanged = try decoder.consume(ready)
        try expect(!readyChanged, "ready is not a song")
        _ = try decoder.consume(data(["title": "  Track  ", "artist": "Artist", "playing": true]))
        try expect(decoder.snapshot?.title == "Track", "title trimming")
        do {
            _ = try decoder.consume(Data("{broken".utf8))
            throw Failure(message: "invalid JSON accepted")
        } catch is Failure { throw Failure(message: "invalid JSON accepted") }
        catch { }
        try expect(decoder.snapshot?.title == "Track", "bad packet should not erase a valid song")
        _ = try decoder.consume(data([:]))
        try expect(decoder.snapshot == nil, "ended session should disappear")
        _ = try decoder.consume(data(["title": "  "]))
        try expect(decoder.snapshot == nil, "blank title must not become an active player")
    }

    private static func artworkIdentity() throws {
        var decoder = NowPlayingDecoder()
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="
        _ = try decoder.consume(data(["title": "First", "artist": "Artist", "artworkData": png]))
        try expect(decoder.snapshot?.artwork != nil, "artwork should decode")
        _ = try decoder.consume(data(["title": "First", "artist": "Artist", "playing": false]))
        try expect(decoder.snapshot?.artwork != nil, "a pause update must not flash artwork")
        _ = try decoder.consume(data(["title": "Second", "artist": "Artist"]))
        try expect(decoder.snapshot?.artwork == nil, "new track must not show previous art")
    }

    private static func restrictions() throws {
        var decoder = NowPlayingDecoder()
        _ = try decoder.consume(data(["title": "Live", "duration": -5, "elapsedTime": -10,
                                      "prohibitsSkip": true, "playing": true, "timestamp": 1000]))
        guard let snapshot = decoder.snapshot else { throw Failure(message: "snapshot missing") }
        try expect(!snapshot.canNext && !snapshot.canPrevious, "skip prohibition ignored")
        try expect(snapshot.duration == 0 && snapshot.elapsedTime == 0, "negative timeline values")
        let invalid = NowPlayingSnapshot(title: "Bad", elapsedTime: .infinity, duration: .nan, playbackRate: .nan)
        try expect(invalid.duration == 0 && invalid.elapsedTime == 0, "nonfinite timeline values")
    }

    private static func bridgeIPC() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentNotchMedia-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("now-playing-bridge.pl")
        try #"""
        use strict;
        $| = 1;
        if ($ARGV[1] eq 'stream') {
            print "{\"type\":\"ready\"}\n";
            print "{\"type\":\"data\",\"payload\":{\"title\":\"Integration fixture\",\"playing\":false}}\n";
            select undef, undef, undef, 15;
        } else {
            open my $log, '>>', __FILE__ . '.commands' or die $!;
            print $log "$ARGV[1]\n";
            close $log;
        }
        """#.write(to: script, atomically: true, encoding: .utf8)
        try Data().write(to: directory.appendingPathComponent("NowPlayingBridge.dylib"))
        let store = NowPlayingStore(resourceDirectory: directory)
        defer { store.stop() }
        func waitUntil(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            try expect(condition(), "bridge IPC timed out")
        }
        store.start()
        try waitUntil { store.canControl }
        try expect(store.snapshot?.title == "Integration fixture", "real process stream reaches the store")
        let commands = URL(fileURLWithPath: script.path + ".commands")
        for (index, action) in [store.togglePlayPause, store.nextTrack, store.previousTrack].enumerated() {
            action()
            try expect(store.isCommandPending, "transport blocks duplicate commands during IPC")
            try waitUntil { !store.isCommandPending }
            let lines = try String(contentsOf: commands).split(separator: "\n").map(String.init)
            try expect(lines.count == index + 1, "each button launches exactly one command")
        }
        let commandLog = try String(contentsOf: commands)
        try expect(commandLog == "2\n4\n5\n", "play/pause and skip command IDs")
        store.stop()
        try expect(store.snapshot == nil && !store.canControl, "stopping clears transport")
        store.start()
        try waitUntil { store.canControl }
    }

    private static func exitedBridge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentNotchMediaExit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try #"""
        $| = 1;
        print "{\"type\":\"data\",\"payload\":{\"title\":\"Ended session\"}}\n" for 1..32;
        """#.write(to: directory.appendingPathComponent("now-playing-bridge.pl"), atomically: true, encoding: .utf8)
        try Data().write(to: directory.appendingPathComponent("NowPlayingBridge.dylib"))
        let store = NowPlayingStore(resourceDirectory: directory)
        defer { store.stop() }
        for _ in 0..<5 {
            store.start()
            let deadline = Date().addingTimeInterval(3)
            while store.availability != .unavailable && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            // Drain any reads queued just before the termination notification.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            try expect(store.availability == .unavailable && store.snapshot == nil && !store.canControl,
                       "exited stream must not restore stale metadata")
        }
    }

    private static func missingBridge() throws {
        let store = NowPlayingStore(resourceDirectory: URL(fileURLWithPath: "/nonexistent-agentnotch-test-media"))
        store.start()
        try expect(store.availability == .unavailable, "missing bridge must report unavailable")
        try expect(!store.canControl && !store.canPrevious && !store.canNext, "empty controls should disable")
        store.togglePlayPause()
        store.nextTrack()
        store.previousTrack()
        try expect(!store.isCommandPending && store.snapshot == nil, "empty transport must not launch anything")
        store.stop()
    }
}
