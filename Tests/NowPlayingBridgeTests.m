// Compile the shipping bridge here; tests never connect to a media daemon.
#import "../Native/NowPlayingBridge.m"

@interface ArtworkFixture : NSObject
@property NSData *imageData;
@end
@implementation ArtworkFixture
@end

static NSUInteger commandCalls;
static int receivedCommand;
static bool rejectCommand(int command, NSDictionary *options) {
    commandCalls++;
    receivedCommand = command;
    if (options) abort();
    return false;
}

static int require(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); return 1; }
    return 0;
}

int main(void) {
    @autoreleasepool {
        int failures = 0;
        failures += require(!jsonMetadataValue(@(NAN)) && !jsonMetadataValue(@(INFINITY))
            && !jsonMetadataValue(@(-INFINITY)) && !jsonMetadataValue(NSNull.null), @"nonfinite metadata rejected");
        failures += require([jsonMetadataValue(@42) isEqual:@42]
            && [jsonMetadataValue(@"Track") isEqual:@"Track"], @"valid metadata preserved");
        emit(@{@"type": @"data", @"payload": @{@"duration": @(NAN)}});
        emit(@{@"type": @"data", @"payload": @{@"title": @"Valid track", @"duration": @42}});

        NSDictionary *info = @{@"kMRMediaRemoteNowPlayingInfoTitle": @"Track",
                                @"kMRMediaRemoteNowPlayingInfoUniqueIdentifier": @"item-1",
                                @"kMRMediaRemoteNowPlayingInfoElapsedTime": @12};
        NSMutableDictionary *first = metadataPayload(info, 0, YES);
        NSMutableDictionary *same = metadataPayload(info, 0, YES);
        failures += require([first[@"timestamp"] isEqual:same[@"timestamp"]]
            && [first[@"trackIdentifier"] isEqual:@"item-1"], @"stable fallback timeline and item ID");
        failures += require(metadataPayload(@{}, 0, NO).count == 0, @"empty session clears payload");

        NSData *one = [@"artwork one" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *two = [@"artwork two" dataUsingEncoding:NSUTF8StringEncoding];
        ArtworkFixture *object = [ArtworkFixture new]; object.imageData = one;
        failures += require([artworkBytes(object) isEqual:one] && !artworkBytes(NSNull.null)
            && !artworkBytes(NSData.data), @"separate artwork object exposes valid image bytes");
        NSDictionary *withArt = @{@"kMRMediaRemoteNowPlayingInfoArtworkData": one,
                                  @"kMRMediaRemoteNowPlayingInfoArtworkIdentifier": @"old-cover"};
        updateArtwork(first, withArt);
        NSString *firstIdentifier = first[@"artworkIdentifier"];
        failures += require(first[@"artworkData"] != nil && firstIdentifier.length == 64,
                            @"first artwork emitted with content identity");
        updateArtwork(same, withArt);
        failures += require(same[@"artworkData"] == nil && [same[@"artworkIdentifier"] isEqual:firstIdentifier],
                            @"unchanged artwork avoids repeated base64 transfer");
        NSMutableDictionary *temporarilyAbsent = metadataPayload(info, 0, YES);
        updateArtwork(temporarilyAbsent, @{});
        failures += require([temporarilyAbsent[@"artworkIdentifier"] isEqual:firstIdentifier]
            && temporarilyAbsent[@"artworkData"] == nil, @"temporary artwork omission preserves identity");
        NSMutableDictionary *replacement = metadataPayload(info, 0, YES);
        updateArtwork(replacement, @{@"kMRMediaRemoteNowPlayingInfoArtworkData": two});
        failures += require(replacement[@"artworkData"] != nil
            && ![replacement[@"artworkIdentifier"] isEqual:firstIdentifier], @"replaced artwork delivered for the same track");
        NSMutableDictionary *newNativeIdentifier = metadataPayload(info, 0, YES);
        updateArtwork(newNativeIdentifier, @{@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier": @"new-cover"});
        failures += require(!cachedArtwork && [newNativeIdentifier[@"artworkIdentifier"] isEqual:@"new-cover"],
                            @"new native artwork ID clears old bytes before replacement loads");
        NSMutableDictionary *nextTrack = metadataPayload(@{@"kMRMediaRemoteNowPlayingInfoTitle": @"Track",
            @"kMRMediaRemoteNowPlayingInfoUniqueIdentifier": @"item-2"}, 0, YES);
        updateArtwork(nextTrack, @{});
        failures += require(!nextTrack[@"artworkData"] && !nextTrack[@"artworkIdentifier"] && !cachedArtwork,
                            @"different item with identical title clears artwork");

        NSUInteger previousGeneration = artworkGeneration;
        NSMutableDictionary *empty = [NSMutableDictionary dictionary];
        updateArtwork(empty, @{});
        failures += require(!currentItem && !emittedArtworkItem && artworkGeneration > previousGeneration,
                            @"disappearing session invalidates pending artwork and delivery state");

        // Focus loss often removes just the optional source/track/album fields.
        NSMutableDictionary *focused = [@{@"title": @"Video", @"artist": @"Artist", @"album": @"Album",
            @"bundleIdentifier": @"player.one", @"processIdentifier": @101, @"trackIdentifier": @"focus-item"} mutableCopy];
        updateArtwork(focused, @{@"kMRMediaRemoteNowPlayingInfoArtworkData": one});
        NSString *focusArtwork = focused[@"artworkIdentifier"];
        NSMutableDictionary *partial = [@{@"title": @"Video", @"processIdentifier": @101} mutableCopy];
        updateArtwork(partial, @{});
        failures += require([cachedArtwork isEqual:one] && [partial[@"trackIdentifier"] isEqual:@"focus-item"]
            && [partial[@"bundleIdentifier"] isEqual:@"player.one"] && [partial[@"album"] isEqual:@"Album"]
            && [partial[@"artworkIdentifier"] isEqual:focusArtwork], @"focus metadata omissions preserve the confirmed item and artwork");
        NSMutableDictionary *lateArtworkID = [partial mutableCopy];
        [lateArtworkID removeObjectForKey:@"artworkData"];
        updateArtwork(lateArtworkID, @{@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier": @"late-native-id"});
        failures += require([cachedArtwork isEqual:one] && [lateArtworkID[@"artworkIdentifier"] isEqual:focusArtwork],
                            @"first native artwork identifier enriches the existing cover");
        NSMutableDictionary *correction = [@{@"title": @"Video corrected", @"artist": @"Artist corrected", @"album": @"Album corrected",
            @"processIdentifier": @101, @"trackIdentifier": @"focus-item"} mutableCopy];
        updateArtwork(correction, @{});
        failures += require([cachedArtwork isEqual:one] && [correction[@"artworkIdentifier"] isEqual:focusArtwork],
                            @"stable source and track ID permit metadata corrections");
        NSMutableDictionary *missingPID = [@{@"title": @"Video corrected", @"trackIdentifier": @"focus-item"} mutableCopy];
        updateArtwork(missingPID, @{});
        failures += require([missingPID[@"processIdentifier"] isEqual:@101] && [cachedArtwork isEqual:one],
                            @"matching strong item ID preserves temporarily missing PID");
        NSMutableDictionary *playingWithoutMetadata = metadataPayload(@{}, 101, YES);
        updateArtwork(playingWithoutMetadata, @{});
        failures += require([playingWithoutMetadata[@"title"] isEqual:@"Video corrected"] && [cachedArtwork isEqual:one],
                            @"same confirmed process continuing playback survives missing metadata");
        NSMutableDictionary *emptyTitle = metadataPayload(@{@"kMRMediaRemoteNowPlayingInfoTitle": @""}, 101, YES);
        updateArtwork(emptyTitle, @{});
        failures += require([emptyTitle[@"title"] isEqual:@"Video corrected"] && [cachedArtwork isEqual:one],
                            @"empty title during focus transition preserves confirmed playback");
        failures += require(metadataPayload(@{}, 101, NO).count == 0 && metadataPayload(@{}, 202, YES).count == 0
            && metadataPayload(@{@"kMRMediaRemoteNowPlayingInfoUniqueIdentifier": @"different-item"}, 101, YES).count == 0,
                            @"paused empty session, different process and different item cannot revive old metadata");
        NSMutableDictionary *differentSource = [@{@"title": @"Video corrected", @"trackIdentifier": @"focus-item",
            @"processIdentifier": @202, @"bundleIdentifier": @"player.two"} mutableCopy];
        updateArtwork(differentSource, @{});
        failures += require(!cachedArtwork && !differentSource[@"artworkIdentifier"],
                            @"different source cannot borrow artwork despite identical track metadata");
        updateArtwork(focused, @{@"kMRMediaRemoteNowPlayingInfoArtworkData": one});
        NSMutableDictionary *unknownSource = [@{@"title": @"Video", @"artist": @"Artist", @"album": @"Album"} mutableCopy];
        updateArtwork(unknownSource, @{});
        failures += require(!cachedArtwork && !unknownSource[@"processIdentifier"],
                            @"unconfirmed source and item do not inherit a prior player cache");
        NSMutableDictionary *unidentifiedItem = [@{@"title": @"Video", @"processIdentifier": @101} mutableCopy];
        updateArtwork(unidentifiedItem, @{@"kMRMediaRemoteNowPlayingInfoArtworkData": one});
        failures += require(metadataPayload(@{@"kMRMediaRemoteNowPlayingInfoUniqueIdentifier": @"unconfirmed-new-item"},
                                           101, YES).count == 0,
                            @"a new item ID without a title cannot borrow an unidentified item's metadata");

        NSMutableDictionary *browserInfo = [@{@"kMRMediaRemoteNowPlayingInfoTitle": @"Browser video",
            @"kMRMediaRemoteNowPlayingInfoArtist": @"Channel", @"kMRMediaRemoteNowPlayingInfoDuration": @180,
            @"kMRMediaRemoteNowPlayingInfoContentItemIdentifier": @"queue-before-focus"} mutableCopy];
        NSMutableDictionary *browserFirst = metadataPayload(browserInfo, 303, YES);
        updateArtwork(browserFirst, @{@"kMRMediaRemoteNowPlayingInfoArtworkData": one});
        browserInfo[@"kMRMediaRemoteNowPlayingInfoContentItemIdentifier"] = @"queue-after-focus";
        NSMutableDictionary *browserFocus = metadataPayload(browserInfo, 303, YES);
        updateArtwork(browserFocus, @{});
        failures += require([cachedArtwork isEqual:one] && !browserFocus[@"trackIdentifier"]
            && [browserFirst[@"itemIdentifier"] isEqual:browserFocus[@"itemIdentifier"]],
                            @"transient browser queue ID changes do not erase a video's cached artwork");
        browserInfo[@"kMRMediaRemoteNowPlayingInfoDuration"] = @240;
        NSMutableDictionary *differentVideo = metadataPayload(browserInfo, 303, YES);
        updateArtwork(differentVideo, @{});
        failures += require(!cachedArtwork && ![differentVideo[@"itemIdentifier"] isEqual:browserFirst[@"itemIdentifier"]],
                            @"different video duration must not inherit an identically titled cover");

        sendCommand = rejectCommand;
        for (NSString *line in @[@"{\"id\":1,\"command\":2}", @"{\"id\":2,\"command\":4}",
                                 @"{\"id\":3,\"command\":5}"]) {
            consumeCommand([line dataUsingEncoding:NSUTF8StringEncoding]);
        }
        failures += require(commandCalls == 3 && receivedCommand == 5, @"supported commands use existing host");
        for (NSString *line in @[@"{\"id\":4,\"command\":99}", @"{\"id\":5,\"command\":2.5}",
                                 @"{\"id\":6,\"command\":\"2\"}", @"[]", @"garbage"]) {
            consumeCommand([line dataUsingEncoding:NSUTF8StringEncoding]);
        }
        failures += require(commandCalls == 3, @"malformed and unsupported commands cannot reach transport");
        reading = YES; fetchPending = NO;
        fetch();
        failures += require(fetchPending, @"notifications received during a fetch are coalesced");
        puts(failures ? "FAIL: native media regressions" : "PASS: native media serializer, artwork lifecycle, transport and refresh regressions");
        return failures ? 1 : 0;
    }
}
