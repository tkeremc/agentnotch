// Optional system Now Playing host. The app does not link private frameworks.
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <signal.h>
#import <math.h>
#import <fcntl.h>
#import <errno.h>

// Selectors are checked at runtime because MediaRemote is a private API.
@interface NSObject (AgentNotchMediaRequest)
+ (id)localNowPlayingPlayerPath;
- (id)initWithPlayerPath:(id)path;
- (void)requestNowPlayingItemArtworkWithCompletion:(void (^)(id, NSError *))completion;
- (NSData *)imageData;
@end

static void *mediaLibrary;
static void (*readInfo)(dispatch_queue_t, void (^)(NSDictionary *));
static void (*readPID)(dispatch_queue_t, void (^)(int));
static void (*readPlaying)(dispatch_queue_t, void (^)(bool));
static void (*registerNotifications)(dispatch_queue_t);
static bool (*sendCommand)(int, NSDictionary *);
static BOOL reading, fetchPending;
static NSData *lastOutput;
static NSUInteger fetchGeneration;
static dispatch_source_t commandSource;
static NSMutableData *commandBuffer;
static NSArray *currentItem;
static NSDictionary *currentMetadata;
static NSString *currentItemIdentifier;
static NSData *cachedArtwork;
static NSString *cachedArtworkIdentifier, *nativeArtworkIdentifier;
static NSArray *emittedArtworkItem;
static NSString *emittedArtworkIdentifier;
static NSUInteger artworkGeneration, artworkAttempts;
static BOOL artworkReading;
static NSTimeInterval artworkLastAttempt;
static NSNumber *fallbackTimestamp;
static NSArray *fallbackTimeline;

static void fetch(void);

// Players occasionally publish NaN/Infinity, e.g. for live durations.
static id jsonMetadataValue(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class] && isfinite([value doubleValue])) return value;
    return nil;
}

static void emit(NSDictionary *object) {
    @autoreleasepool {
        if (![NSJSONSerialization isValidJSONObject:object]) return;
        NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
        BOOL isData = [object[@"type"] isEqual:@"data"];
        if (!data || (isData && [data isEqualToData:lastOutput])) return;
        // ACKs must always be delivered, even if a caller repeats an ID.
        if (isData) lastOutput = data;
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
        fflush(stdout);
    }
}

static NSArray *itemIdentity(NSDictionary *payload) {
    return @[payload[@"processIdentifier"] ?: @0, payload[@"bundleIdentifier"] ?: @"",
             payload[@"trackIdentifier"] ?: @"",
             payload[@"title"] ?: @"", payload[@"artist"] ?: @"", payload[@"album"] ?: @""];
}

// A missing optional field is a partial update, not evidence of a new item.
// Explicitly different sources/track IDs take precedence over matching labels.
static BOOL hasMetadataValue(id value) {
    if ([value isKindOfClass:NSString.class]) return [value length] > 0;
    return [value isKindOfClass:NSNumber.class] && [value doubleValue] > 0;
}

static BOOL metadataContinuesItem(NSDictionary *previous, NSDictionary *next) {
    if (!previous || !hasMetadataValue(next[@"title"])) return NO;
    for (NSString *key in @[@"processIdentifier", @"bundleIdentifier", @"trackIdentifier"]) {
        id old = previous[key], value = next[key];
        if (hasMetadataValue(old) && hasMetadataValue(value) && ![old isEqual:value]) return NO;
    }
    BOOL matchingTrack = hasMetadataValue(previous[@"trackIdentifier"])
        && [previous[@"trackIdentifier"] isEqual:next[@"trackIdentifier"]];
    BOOL matchingSource = (hasMetadataValue(previous[@"processIdentifier"])
        && [previous[@"processIdentifier"] isEqual:next[@"processIdentifier"]])
        || (hasMetadataValue(previous[@"bundleIdentifier"])
        && [previous[@"bundleIdentifier"] isEqual:next[@"bundleIdentifier"]]);
    BOOL hadSource = hasMetadataValue(previous[@"processIdentifier"])
        || hasMetadataValue(previous[@"bundleIdentifier"]);
    if (hadSource && !matchingSource && !matchingTrack) return NO;
    if (matchingTrack) return YES;
    for (NSString *key in @[@"title", @"artist", @"album"]) {
        id old = previous[key], value = next[key];
        if (hasMetadataValue(old) && hasMetadataValue(value) && ![old isEqual:value]) return NO;
    }
    NSNumber *oldDuration = previous[@"duration"], *duration = next[@"duration"];
    if (oldDuration.doubleValue > 0 && duration.doubleValue > 0
        && fabs(oldDuration.doubleValue - duration.doubleValue) > 0.1) return NO;
    return YES;
}

static BOOL preserveItemMetadata(NSMutableDictionary *payload) {
    if (!metadataContinuesItem(currentMetadata, payload)) return NO;
    for (NSString *key in @[@"processIdentifier", @"bundleIdentifier", @"trackIdentifier",
                           @"artist", @"album", @"appName", @"duration"]) {
        if (!hasMetadataValue(payload[key]) && hasMetadataValue(currentMetadata[key]))
            payload[key] = currentMetadata[key];
    }
    return YES;
}

static NSString *artworkDigest(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *value = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [value appendFormat:@"%02x", digest[i]];
    return value;
}

static NSData *artworkBytes(id artwork) {
    if (![artwork isKindOfClass:NSData.class] && [artwork respondsToSelector:@selector(imageData)])
        artwork = [artwork imageData];
    return [artwork isKindOfClass:NSData.class] && [artwork length] > 0
        && [artwork length] <= 16 * 1024 * 1024 ? artwork : nil;
}

static NSMutableDictionary *metadataPayload(NSDictionary *information, int processID, BOOL playing) {
    NSString *title = information[@"kMRMediaRemoteNowPlayingInfoTitle"];
    // ContentItemIdentifier is a transient MediaRemote queue record. Zen can
    // replace it on pause/focus updates without changing the video. Only the
    // publisher's UniqueIdentifier is suitable as a stable track identity.
    id track = jsonMetadataValue(information[@"kMRMediaRemoteNowPlayingInfoUniqueIdentifier"]);
    NSString *trackIdentifier = track ? [track description] : nil;
    BOOL missingTitle = ![title isKindOfClass:NSString.class] || !title.length;
    // Focus changes can briefly leave only the active PID/playback state. Keep
    // the last confirmed item only while that exact process is still playing.
    BOOL confirmedSession = missingTitle && playing && processID > 0
        && [currentMetadata[@"processIdentifier"] intValue] == processID
        && (!hasMetadataValue(trackIdentifier)
            || [trackIdentifier isEqual:currentMetadata[@"trackIdentifier"]]);
    if (missingTitle && !confirmedSession) {
        fallbackTimeline = nil;
        fallbackTimestamp = nil;
        return [NSMutableDictionary dictionary];
    }
    NSMutableDictionary *payload = confirmedSession
        ? [currentMetadata mutableCopy] : [NSMutableDictionary dictionary];
    NSDictionary *keys = @{
        @"title": @"Title", @"artist": @"Artist", @"album": @"Album",
        @"duration": @"Duration", @"elapsedTime": @"ElapsedTime",
        @"playbackRate": @"PlaybackRate", @"prohibitsSkip": @"ProhibitsSkip"
    };
    for (NSString *key in keys) {
        id value = jsonMetadataValue(information[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:keys[key]]]);
        if (value && !(confirmedSession && [key isEqual:@"title"] && missingTitle)) payload[key] = value;
    }
    if (hasMetadataValue(trackIdentifier)) payload[@"trackIdentifier"] = trackIdentifier;
    if (processID > 0) payload[@"processIdentifier"] = @(processID);
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:processID];
    if (app.bundleIdentifier) payload[@"bundleIdentifier"] = app.bundleIdentifier;
    if (app.localizedName) payload[@"appName"] = app.localizedName;
    payload[@"playing"] = @(playing);
    preserveItemMetadata(payload);
    NSDate *timestamp = information[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if ([timestamp isKindOfClass:NSDate.class] && isfinite(timestamp.timeIntervalSince1970)) {
        payload[@"timestamp"] = @(timestamp.timeIntervalSince1970);
    } else if (confirmedSession && !information[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]
               && currentMetadata[@"timestamp"]) {
        payload[@"timestamp"] = currentMetadata[@"timestamp"];
    } else {
        // An unchanged timeline must not acquire a new timestamp on each poll.
        NSArray *timeline = @[itemIdentity(payload), payload[@"elapsedTime"] ?: @0,
                              payload[@"playbackRate"] ?: @1, @(playing)];
        if (![timeline isEqual:fallbackTimeline]) {
            fallbackTimeline = timeline;
            fallbackTimestamp = @(NSDate.date.timeIntervalSince1970);
        }
        payload[@"timestamp"] = fallbackTimestamp;
    }
    return payload;
}

static void updateArtwork(NSMutableDictionary *payload, NSDictionary *information) {
    BOOL sameItem = preserveItemMetadata(payload);
    NSArray *identity = payload[@"title"] ? itemIdentity(payload) : nil;
    if (!sameItem) {
        currentItemIdentifier = identity ? NSUUID.UUID.UUIDString : nil;
        cachedArtwork = nil;
        cachedArtworkIdentifier = nil;
        nativeArtworkIdentifier = nil;
        emittedArtworkItem = nil;
        emittedArtworkIdentifier = nil;
        artworkGeneration++;
        artworkReading = NO;
        artworkAttempts = 0;
    }
    if (currentItemIdentifier) payload[@"itemIdentifier"] = currentItemIdentifier;
    currentItem = identity;
    currentMetadata = identity ? [payload copy] : nil;
    if (!identity) return;
    id rawIdentifier = jsonMetadataValue(information[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"]);
    NSString *identifier = rawIdentifier ? [rawIdentifier description] : nil;
    if (identifier && ![identifier isEqual:nativeArtworkIdentifier]) {
        // Learning the native ID for an already cached cover is enrichment.
        // A transition between two known IDs is an actual artwork change.
        BOOL changed = nativeArtworkIdentifier != nil;
        nativeArtworkIdentifier = identifier;
        if (changed) {
            cachedArtwork = nil;
            cachedArtworkIdentifier = identifier;
            emittedArtworkItem = nil;
            emittedArtworkIdentifier = nil;
            artworkGeneration++;
            artworkReading = NO;
            artworkAttempts = 0;
        } else if (!cachedArtworkIdentifier) {
            cachedArtworkIdentifier = identifier;
        }
    }
    NSData *artwork = artworkBytes(information[@"kMRMediaRemoteNowPlayingInfoArtworkData"]);
    if (artwork && ![artwork isEqualToData:cachedArtwork]) {
        cachedArtwork = artwork;
        // Include the bytes' digest even if a player reuses its artwork ID.
        cachedArtworkIdentifier = artworkDigest(artwork);
    }
    if (cachedArtworkIdentifier) payload[@"artworkIdentifier"] = cachedArtworkIdentifier;
    if (cachedArtwork && (![identity isEqual:emittedArtworkItem]
                          || ![cachedArtworkIdentifier isEqual:emittedArtworkIdentifier])) {
        payload[@"artworkData"] = [cachedArtwork base64EncodedStringWithOptions:0];
        emittedArtworkItem = identity;
        emittedArtworkIdentifier = cachedArtworkIdentifier;
    }
}

// Some players publish an artwork identifier without embedding ArtworkData.
// Ask for that player's actual artwork separately; never block transport or
// metadata while it loads. A later fetch checks the item before using the bytes.
static void requestMissingArtwork(void) {
    if (!currentItem || cachedArtwork || artworkReading) return;
    if (artworkAttempts >= 3) {
        // A publisher can load its cover well after the initial track update.
        // Keep retrying slowly rather than permanently caching that absence.
        if (NSProcessInfo.processInfo.systemUptime - artworkLastAttempt < 10) return;
        artworkAttempts = 0;
    }
    Class requestClass = NSClassFromString(@"MRNowPlayingRequest");
    if (![requestClass respondsToSelector:@selector(localNowPlayingPlayerPath)]
        || ![requestClass instancesRespondToSelector:@selector(initWithPlayerPath:)]
        || ![requestClass instancesRespondToSelector:@selector(requestNowPlayingItemArtworkWithCompletion:)]) return;
    id path = [requestClass localNowPlayingPlayerPath];
    if (!path) return;
    id request = [[requestClass alloc] initWithPlayerPath:path];
    if (!request) return;
    artworkReading = YES;
    artworkAttempts++;
    artworkLastAttempt = NSProcessInfo.processInfo.systemUptime;
    NSUInteger generation = ++artworkGeneration;
    [request requestNowPlayingItemArtworkWithCompletion:^(id artwork, NSError *error) {
        // The private completion queue is unspecified. State stays on main.
        dispatch_async(dispatch_get_main_queue(), ^{
            (void)request;
            if (generation != artworkGeneration) return;
            artworkReading = NO;
            NSData *data = error ? nil : artworkBytes(artwork);
            if (data) {
                cachedArtwork = data;
                cachedArtworkIdentifier = artworkDigest(data);
            }
            // Re-read metadata before emitting artwork, so track changes cannot
            // attach an old asynchronous result to the new track.
            if (data) fetch();
            else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 3),
                                dispatch_get_main_queue(), ^{ fetch(); });
        });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (generation != artworkGeneration || !artworkReading) return;
        artworkReading = NO;
        artworkGeneration++;
        fetch();
    });
}

static void fetch(void) {
    // Retain one pending refresh instead of dropping changes during a read.
    if (reading) { fetchPending = YES; return; }
    reading = YES;
    NSUInteger generation = ++fetchGeneration;
    dispatch_queue_t queue = dispatch_get_main_queue();
    dispatch_group_t group = dispatch_group_create();
    __block NSDictionary *information;
    __block int processID = 0;
    __block BOOL playing = NO;
    dispatch_group_enter(group);
    readInfo(queue, ^(NSDictionary *value) { information = value; dispatch_group_leave(group); });
    dispatch_group_enter(group);
    readPID(queue, ^(int value) { processID = value; dispatch_group_leave(group); });
    dispatch_group_enter(group);
    readPlaying(queue, ^(bool value) { playing = value; dispatch_group_leave(group); });
    dispatch_group_notify(group, queue, ^{
        @autoreleasepool {
            if (generation != fetchGeneration) return;
            reading = NO;
            NSMutableDictionary *payload = metadataPayload(information, processID, playing);
            updateArtwork(payload, information);
            emit(@{@"type": @"data", @"payload": payload});
            requestMissingArtwork();
            if (fetchPending) {
                fetchPending = NO;
                dispatch_async(queue, ^{ fetch(); });
            }
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), queue, ^{
        if (generation == fetchGeneration && reading) {
            fprintf(stderr, "Now Playing service did not respond\n");
            exit(1);
        }
    });
}

static void consumeCommand(NSData *line) {
    id object = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class]) return;
    NSNumber *identifier = object[@"id"], *command = object[@"command"];
    if (![identifier isKindOfClass:NSNumber.class] || !isfinite(identifier.doubleValue)
        || identifier.doubleValue < 0 || floor(identifier.doubleValue) != identifier.doubleValue) return;
    BOOL valid = [command isKindOfClass:NSNumber.class]
        && (command.doubleValue == 2 || command.doubleValue == 4 || command.doubleValue == 5);
    BOOL accepted = valid && sendCommand && sendCommand(command.intValue, nil);
    emit(@{@"type": @"commandResult", @"id": identifier, @"accepted": @(accepted)});
    if (!accepted) return;
    fetch();
    // Players may apply the accepted command just after the first query.
    for (NSNumber *delay in @[@0.12, @0.4]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ fetch(); });
    }
}

static void listenForCommands(void) {
    int flags = fcntl(STDIN_FILENO, F_GETFL);
    if (flags < 0 || fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) < 0) return;
    commandBuffer = [NSMutableData data];
    commandSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(commandSource, ^{
        uint8_t bytes[4096];
        ssize_t count;
        while ((count = read(STDIN_FILENO, bytes, sizeof(bytes))) > 0) {
            [commandBuffer appendBytes:bytes length:(NSUInteger)count];
            if (commandBuffer.length > 8192) { fprintf(stderr, "Media command exceeds limit\n"); exit(1); }
            for (;;) {
                const uint8_t *newline = memchr(commandBuffer.bytes, '\n', commandBuffer.length);
                if (!newline) break;
                NSUInteger length = (NSUInteger)(newline - (const uint8_t *)commandBuffer.bytes);
                NSData *line = [commandBuffer subdataWithRange:NSMakeRange(0, length)];
                [commandBuffer replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
                if (length) consumeCommand(line);
            }
        }
        if (count == 0) {
            // The parent closed its command pipe; do not leave an orphan host.
            exit(0);
        }
        if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) exit(1);
    });
    dispatch_resume(commandSource);
}

__attribute__((visibility("default")))
void agentnotch_media_main(void) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        mediaLibrary = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!mediaLibrary) { fprintf(stderr, "MediaRemote is unavailable\n"); exit(1); }
        readInfo = dlsym(mediaLibrary, "MRMediaRemoteGetNowPlayingInfo");
        readPID = dlsym(mediaLibrary, "MRMediaRemoteGetNowPlayingApplicationPID");
        readPlaying = dlsym(mediaLibrary, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        registerNotifications = dlsym(mediaLibrary, "MRMediaRemoteRegisterForNowPlayingNotifications");
        sendCommand = dlsym(mediaLibrary, "MRMediaRemoteSendCommand");
        if (!readInfo || !readPID || !readPlaying || !registerNotifications || !sendCommand) {
            fprintf(stderr, "MediaRemote is incompatible\n"); exit(1);
        }
        NSString *command = NSProcessInfo.processInfo.environment[@"AGENTNOTCH_MEDIA_COMMAND"];
        if ([command isEqualToString:@"2"] || [command isEqualToString:@"4"] || [command isEqualToString:@"5"]) {
            BOOL accepted = sendCommand(command.intValue, nil);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{ exit(accepted ? 0 : 1); });
        } else if ([command isEqualToString:@"stream"]) {
            registerNotifications(dispatch_get_main_queue());
            NSArray *names = @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                               @"kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification",
                               @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                               @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"];
            for (NSString *name in names) {
                [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { fetch(); }];
            }
            [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
                if (getppid() == 1) exit(0);
                fetch();
            }];
            listenForCommands();
            emit(@{@"type": @"ready"});
            fetch();
        } else {
            fprintf(stderr, "Unsupported media command\n"); exit(1);
        }
        CFRunLoopRun();
    }
}
