// Compile the shipping bridge in this translation unit so the regression
// exercises its actual serializer without requiring a live media daemon.
#import "../Native/NowPlayingBridge.m"

int main(void) {
    @autoreleasepool {
        if (jsonMetadataValue(@(NAN)) || jsonMetadataValue(@(INFINITY))
            || jsonMetadataValue(@(-INFINITY)) || jsonMetadataValue(NSNull.null)) return 1;
        if (![jsonMetadataValue(@42) isEqual:@42]
            || ![jsonMetadataValue(@"Track") isEqual:@"Track"]) return 1;
        // This exact input previously raised an Objective-C exception and killed
        // the long-running helper. It must be ignored without blocking valid data.
        emit(@{@"type": @"data", @"payload": @{@"duration": @(NAN)}});
        emit(@{@"type": @"data", @"payload": @{@"title": @"Valid track", @"duration": @42}});
        puts("PASS: native media serializer survives nonfinite player metadata");
        return 0;
    }
}
