// Read macOS Now Playing from the system Perl host. The application itself does
// not link against private frameworks. Keep this optional: Apple's private API
// can change, and absence of a player must remain a normal empty state.
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <signal.h>
#import <math.h>

static void *mediaLibrary;
static void (*readInfo)(dispatch_queue_t, void (^)(NSDictionary *));
static void (*readPID)(dispatch_queue_t, void (^)(int));
static void (*readPlaying)(dispatch_queue_t, void (^)(bool));
static void (*registerNotifications)(dispatch_queue_t);
static bool (*sendCommand)(int, NSDictionary *);
static BOOL reading;
static NSData *lastOutput;
static NSUInteger fetchGeneration;

// Players occasionally publish NaN/Infinity (for example for a live duration).
// Foundation raises an exception for those numbers instead of returning an error.
static id jsonMetadataValue(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class] && isfinite([value doubleValue])) return value;
    return nil;
}

static void emit(NSDictionary *object) {
    @autoreleasepool {
        if (![NSJSONSerialization isValidJSONObject:object]) return;
        NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
        if (!data || [data isEqualToData:lastOutput]) return;
        lastOutput = data;
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
        fflush(stdout);
    }
}

static void fetch(void) {
    if (reading) return;
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
            NSString *title = information[@"kMRMediaRemoteNowPlayingInfoTitle"];
            if (![title isKindOfClass:NSString.class] || !title.length) {
                emit(@{@"type": @"data", @"payload": @{}});
                return;
            }
            NSMutableDictionary *payload = [NSMutableDictionary dictionary];
            NSDictionary *keys = @{
                @"title": @"Title", @"artist": @"Artist", @"album": @"Album",
                @"duration": @"Duration", @"elapsedTime": @"ElapsedTime",
                @"playbackRate": @"PlaybackRate", @"prohibitsSkip": @"ProhibitsSkip"
            };
            for (NSString *key in keys) {
                id value = jsonMetadataValue(information[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:keys[key]]]);
                if (value) payload[key] = value;
            }
            NSDate *timestamp = information[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([timestamp isKindOfClass:NSDate.class] && isfinite(timestamp.timeIntervalSince1970))
                payload[@"timestamp"] = @(timestamp.timeIntervalSince1970);
            else payload[@"timestamp"] = @(NSDate.date.timeIntervalSince1970);
            NSData *artwork = information[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            if ([artwork isKindOfClass:NSData.class] && artwork.length <= 16 * 1024 * 1024)
                payload[@"artworkData"] = [artwork base64EncodedStringWithOptions:0];
            NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:processID];
            if (app.bundleIdentifier) payload[@"bundleIdentifier"] = app.bundleIdentifier;
            if (app.localizedName) payload[@"appName"] = app.localizedName;
            payload[@"playing"] = @(playing);
            emit(@{@"type": @"data", @"payload": payload});
        }
    });
    // Exit visibly on an inaccessible service instead of claiming that no
    // player exists forever. Never start overlapping requests after a timeout.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), queue, ^{
        if (generation == fetchGeneration && reading) {
            fprintf(stderr, "Now Playing service did not respond\n");
            exit(1);
        }
    });
}

__attribute__((visibility("default")))
void agentnotch_media_main(void) {
    @autoreleasepool {
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
            BOOL accepted = sendCommand(command.intValue, @{});
            // Allow the framework's asynchronous IPC to drain before exit.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{ exit(accepted ? 0 : 1); });
        } else if ([command isEqualToString:@"stream"]) {
            registerNotifications(dispatch_get_main_queue());
            NSArray *names = @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                               @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                               @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"];
            for (NSString *name in names) {
                [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { fetch(); }];
            }
            // Poll as a backstop for players that omit change notifications.
            [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
                if (getppid() == 1) exit(0);
                fetch();
            }];
            emit(@{@"type": @"ready"});
            fetch();
        } else {
            fprintf(stderr, "Unsupported media command\n"); exit(1);
        }
        CFRunLoopRun();
    }
}
