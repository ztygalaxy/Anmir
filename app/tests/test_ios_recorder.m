#import <AVFoundation/AVFoundation.h>
#import "sys/macos/ios_recorder.h"
#include <assert.h>

static void pump(double seconds) {
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static CVPixelBufferRef frame(BOOL blue) {
    CVPixelBufferRef buffer = NULL;
    assert(CVPixelBufferCreate(NULL, 64, 128, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}}, &buffer) == kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(buffer, 0);
    for (int y = 0; y < 128; y++) {
        uint8_t *row = CVPixelBufferGetBaseAddress(buffer) + y * CVPixelBufferGetBytesPerRow(buffer);
        for (int x = 0; x < 64; x++) {
            row[x * 4] = blue ? 255 : 0; row[x * 4 + 1] = 0;
            row[x * 4 + 2] = blue ? 0 : 255; row[x * 4 + 3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

int main(void) {
    @autoreleasepool {
        NSURL *URL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"anmir-recorder-test-%@.mp4", NSUUID.UUID.UUIDString]]];
        NSError *error = nil;
        assert(![[SCIOSRecorder alloc] initWithURL:URL size:CGSizeZero error:&error]);
        assert(error);
        SCIOSRecorder *recorder = [[SCIOSRecorder alloc] initWithURL:URL size:CGSizeMake(64, 128) error:&error];
        assert(recorder);
        CMTime base = CMClockGetTime(CMClockGetHostTimeClock());
        CVPixelBufferRef red = frame(NO), blue = frame(YES);
        [recorder appendPixelBuffer:red atHostTime:kCMTimeInvalid];
        // Two distinct colors verify actual encoding/decoding. Duplicate and
        // backwards timestamps must not corrupt the movie's presentation order.
        for (int index = 0; index < 12; index++) {
            CMTime time = CMTimeAdd(base, CMTimeMake(index, 10));
            [recorder appendPixelBuffer:index < 6 ? red : blue atHostTime:time];
            if (index == 8) { [recorder appendPixelBuffer:red atHostTime:base]; }
            pump(.025);
        }
        __block BOOL done = NO;
        [recorder finishAtHostTime:CMTimeAdd(base, CMTimeMake(2, 1)) completion:^(NSError *failure) {
            assert(NSThread.isMainThread); assert(!failure); done = YES;
        }];
        [recorder appendPixelBuffer:red atHostTime:CMTimeAdd(base, CMTimeMake(3, 1))];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        while (!done && deadline.timeIntervalSinceNow > 0) { pump(.02); }
        assert(done);
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:URL options:nil];
        NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        assert(tracks.count == 1 && [asset tracksWithMediaType:AVMediaTypeAudio].count == 0);
        assert(tracks.firstObject.naturalSize.width == 64 && tracks.firstObject.naturalSize.height == 128);
        assert(CMTimeGetSeconds(asset.duration) >= 1.99 && CMTimeGetSeconds(asset.duration) < 2.2);
        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tracks.firstObject
            outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
        [reader addOutput:output]; assert([reader startReading]);
        NSUInteger decoded = 0; BOOL sawRed = NO, sawBlue = NO;
        CMTime previous = kCMTimeInvalid;
        CMSampleBufferRef sample;
        while ((sample = [output copyNextSampleBuffer])) {
            CMTime time = CMSampleBufferGetPresentationTimeStamp(sample);
            assert(!CMTIME_IS_VALID(previous) || CMTimeCompare(time, previous) > 0);
            previous = time;
            CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
            CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
            uint8_t *pixel = CVPixelBufferGetBaseAddress(buffer);
            sawRed |= pixel[2] > 200 && pixel[0] < 30;
            sawBlue |= pixel[0] > 200 && pixel[2] < 30;
            CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
            CFRelease(sample); decoded++;
        }
        assert(reader.status == AVAssetReaderStatusCompleted && decoded >= 3 && sawRed && sawBlue);
        // The recorder must never silently overwrite an existing destination.
        assert(![[SCIOSRecorder alloc] initWithURL:URL size:CGSizeMake(64, 128) error:&error]);
        [NSFileManager.defaultManager removeItemAtURL:URL error:nil];
        recorder = [[SCIOSRecorder alloc] initWithURL:URL size:CGSizeMake(64, 128) error:&error];
        assert(recorder); done = NO;
        [recorder finishAtHostTime:CMClockGetTime(CMClockGetHostTimeClock()) completion:^(NSError *failure) {
            assert(failure); done = YES;
        }];
        deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        while (!done && deadline.timeIntervalSinceNow > 0) { pump(.02); }
        assert(done);
        CVPixelBufferRelease(red); CVPixelBufferRelease(blue);
        [NSFileManager.defaultManager removeItemAtURL:URL error:nil];
        puts("MP4 encode/decode, colors, timestamps, static tail, empty recording and overwrite protection passed.");
    }
    return 0;
}
