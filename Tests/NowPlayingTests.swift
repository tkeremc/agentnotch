import AppKit
import Foundation
@testable import AgentNotch

@MainActor
struct NowPlayingTests {
    static let cases: [(String, @MainActor () throws -> Void)] = [
        ("media timeline follows playing, paused and unknown duration", timeline),
        ("media messages clear ended sessions and reject malformed input", lifecycle),
        ("media artwork stays with its track", artworkIdentity),
        ("media artwork survives focus updates with omitted cover and app metadata", artworkFocus),
        ("media skip restrictions and invalid times are sanitized", restrictions),
        ("missing media bridge disables transport without starting a player", missingBridge),
        ("media bridge routes transport and can restart after cleanup", bridgeIPC),
        ("exited media bridge cannot resurrect a queued snapshot", exitedBridge),
        ("compact media hides ten seconds after pause despite metadata refreshes", compactPause),
        ("resuming or clearing media cancels the pending compact hide", compactResume)
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
        _ = try decoder.consume(data(["title": "First", "trackIdentifier": "item-1",
                                      "artworkIdentifier": "cover-1", "artworkData": png]))
        _ = try decoder.consume(data(["title": "Corrected title", "trackIdentifier": "item-1",
                                      "artworkIdentifier": "cover-1"]))
        try expect(decoder.snapshot?.artwork != nil, "metadata corrections must preserve the same item's artwork")
        _ = try decoder.consume(data(["title": "Corrected title", "trackIdentifier": "item-1",
                                      "artworkIdentifier": "cover-2"]))
        try expect(decoder.snapshot?.artwork == nil, "changed artwork identity must invalidate old cover")
        _ = try decoder.consume(data(["title": "Corrected title", "trackIdentifier": "item-1",
                                      "artworkIdentifier": "cover-2", "artworkData": png]))
        try expect(decoder.snapshot?.artwork != nil, "delayed artwork must appear when received")
        _ = try decoder.consume(data(["title": "Corrected title", "trackIdentifier": "item-2",
                                      "artworkIdentifier": "cover-2"]))
        try expect(decoder.snapshot?.artwork == nil, "same title and cover ID in a different item must not reuse artwork")
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

    private static func artworkFocus() throws {
        var decoder = NowPlayingDecoder()
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="
        _ = try decoder.consume(data(["title": "Video", "trackIdentifier": "video-1",
                                      "processIdentifier": 42, "bundleIdentifier": "com.example.browser",
                                      "artworkIdentifier": "cover-1", "artworkData": png]))
        let artwork = decoder.snapshot?.artwork
        try expect(artwork != nil, "initial cover must decode")
        _ = try decoder.consume(data(["title": "Video", "trackIdentifier": "video-1",
                                      "processIdentifier": 42, "playing": true]))
        try expect(decoder.snapshot?.artwork === artwork,
                   "focus update must retain the decoded image when bundle and artwork fields are omitted")
        try expect(decoder.snapshot?.artworkIdentifier == "cover-1", "known cover identity must survive omission")
        _ = try decoder.consume(data(["title": "Video", "trackIdentifier": "video-1",
                                      "processIdentifier": 42, "artworkIdentifier": "cover-2"]))
        try expect(decoder.snapshot?.artwork == nil, "explicit replacement cover must invalidate cached bytes")
        _ = try decoder.consume(data(["title": "Video", "trackIdentifier": "video-1",
                                      "processIdentifier": 42, "artworkIdentifier": "cover-2", "artworkData": png]))
        _ = try decoder.consume(data(["title": "Video", "trackIdentifier": "video-1",
                                      "processIdentifier": 43]))
        try expect(decoder.snapshot?.artwork == nil, "a different process must never inherit the previous cover")
        _ = try decoder.consume(data(["title": "Browser video", "processIdentifier": 42,
                                      "itemIdentifier": "confirmed-item-1", "artworkData": png]))
        _ = try decoder.consume(data(["title": "Browser video", "processIdentifier": 42,
                                      "itemIdentifier": "confirmed-item-1"]))
        try expect(decoder.snapshot?.artwork != nil, "confirmed item must preserve its cover across updates")
        _ = try decoder.consume(data(["title": "Browser video", "processIdentifier": 42,
                                      "itemIdentifier": "confirmed-item-2"]))
        try expect(decoder.snapshot?.artwork == nil, "new confirmed item must clear a same-title video's old cover")
    }

    private static func bridgeIPC() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentNotchMedia-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("now-playing-bridge.pl")
        try #"""
        use strict;
        use JSON::PP;
        $| = 1;
        die "transport must reuse stream" unless $ARGV[1] eq 'stream';
        print "{\"type\":\"ready\"}\n";
        print "{\"type\":\"data\",\"payload\":{\"title\":\"Integration fixture\",\"playing\":false}}\n";
        my $playing = JSON::PP::false;
        while (my $line = <STDIN>) {
            my $message = decode_json($line);
            open my $log, '>>', __FILE__ . '.commands' or die $!;
            print $log "$message->{command}\n";
            close $log;
            # A stale acknowledgment must not clear outstanding commands.
            print encode_json({type => 'commandResult', id => 0, accepted => JSON::PP::true}) . "\n";
            select undef, undef, undef, 0.04;
            print encode_json({type => 'commandResult', id => $message->{id}, accepted => JSON::PP::true}) . "\n";
            $playing = !$playing if $message->{command} == 2;
            print encode_json({type => 'data', payload => {title => 'Integration fixture', playing => $playing ? JSON::PP::true : JSON::PP::false}}) . "\n";
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
        for action in [store.togglePlayPause, store.nextTrack, store.previousTrack] {
            action()
            try expect(store.isCommandPending, "command acknowledgment should still be tracked")
            try expect(store.canControl && store.canPrevious && store.canNext,
                       "transport must stay enabled while commands await acknowledgment")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.015))
        try expect(store.isCommandPending, "unrelated command acknowledgment must be ignored")
        try waitUntil { !store.isCommandPending }
        try waitUntil { store.snapshot?.isPlaying == true }
        let commandLog = try String(contentsOf: commands, encoding: .utf8)
        try expect(commandLog == "2\n4\n5\n", "rapid transport commands must all arrive in order")
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

    private static func compactPause() throws {
        let visibility = CompactMediaVisibility()
        visibility.update(isPlaying: true)
        visibility.update(isPlaying: false)
        let start = Date()
        while Date().timeIntervalSince(start) < 9.5 {
            try expect(visibility.isVisible, "paused media must remain visible for the full grace period")
            visibility.update(isPlaying: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let deadline = start.addingTimeInterval(11.5)
        while visibility.isVisible && Date() < deadline {
            visibility.update(isPlaying: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try expect(!visibility.isVisible, "metadata polling must not postpone the ten-second hide")
        try expect(Date().timeIntervalSince(start) >= 9.95, "default grace period is ten seconds")
        visibility.update(isPlaying: false)
        try expect(!visibility.isVisible, "later paused metadata must not redisplay the compact artwork")
        visibility.update(isPlaying: true)
        try expect(visibility.isVisible, "resuming immediately redisplays compact media")
    }

    private static func compactResume() throws {
        let visibility = CompactMediaVisibility(pauseDelay: .milliseconds(80))
        visibility.update(isPlaying: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        visibility.update(isPlaying: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try expect(visibility.isVisible, "old pause timeout must not hide resumed playback")
        visibility.update(isPlaying: false)
        visibility.update(isPlaying: nil)
        try expect(!visibility.isVisible, "removing media or hiding the panel clears the compact state")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        visibility.update(isPlaying: false)
        try expect(visibility.isVisible, "a new paused session gets its own grace period")
        visibility.update(isPlaying: nil)
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
