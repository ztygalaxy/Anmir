// Opt-in physical-device probe. Never registered as an automatic test.
// clang -fobjc-arc probe_ios_native.m ../src/sys/macos/ios_native.m \
//   ../src/sys/macos/ios_recorder.m \
//   ../src/sys/macos/ios_preparation.m \
//   ../src/sys/macos/localization.m -framework AppKit -framework CoreMedia \
//   -framework CoreVideo -framework CoreImage -framework AVFoundation -o /tmp/anmir-native-probe
// Usage: probe <CoreDevice UUID> [--tap x y | --switcher-record | --back | --startup | --prepared-startup]
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import "../src/sys/macos/ios_native.h"
#import "../src/sys/macos/ios_recorder.h"
#import "../src/sys/macos/ios_preparation.h"
#include <stdatomic.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2 && argc != 3 && argc != 5) { return 2; }
        [NSApplication sharedApplication];
        BOOL tap = argc == 5 && !strcmp(argv[2], "--tap");
        BOOL switcher = argc == 3 && !strcmp(argv[2], "--switcher-record");
        BOOL back = argc == 3 && !strcmp(argv[2], "--back");
        BOOL preparedStartup = argc == 3 && !strcmp(argv[2], "--prepared-startup");
        BOOL startup = preparedStartup || (argc == 3 && !strcmp(argv[2], "--startup"));
        if (argc == 3 && !switcher && !back && !startup) { return 2; }
        double x = tap ? strtod(argv[3], NULL) : 0, y = tap ? strtod(argv[4], NULL) : 0;
        __block BOOL done = NO, received = NO, failed = NO;
        __block NSUInteger frames = 0;
        __block CFAbsoluteTime first = 0;
        __block SCIOSRecorder *recorder;
        NSString *identifier = [NSString stringWithUTF8String:argv[1]];
        SCIOSConnectionPreparation *preparation;
        if (preparedStartup) {
            preparation = [[SCIOSConnectionPreparation alloc] initWithIdentifier:identifier];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
            while (!preparation.environmentValue && deadline.timeIntervalSinceNow > 0) {
                [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
            }
            if (!preparation.environmentValue) { NSLog(@"PREPARATION_FAILED"); [preparation stop]; return 1; }
        }
        CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
        SCIOSNativeSession *session = [[SCIOSNativeSession alloc]
            initWithIdentifier:identifier preparedConnection:preparation.environmentValue];
        session.failed = ^(NSError *error) { NSLog(@"Probe failed: %@", error); failed = YES; done = YES; };
        __weak SCIOSNativeSession *weakSession = session;
        session.frame = ^(CMSampleBufferRef sample) {
            CFRetain(sample);
            dispatch_async(dispatch_get_main_queue(), ^{
                frames++;
                if (!received) {
                    received = YES; first = CFAbsoluteTimeGetCurrent();
                    NSLog(@"FIRST_FRAME %.3fs", first - started);
                    if (switcher || back) {
                        CIImage *image = [CIImage imageWithCVPixelBuffer:CMSampleBufferGetImageBuffer(sample)];
                        CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
                        NSData *png = [[CIContext contextWithOptions:nil] PNGRepresentationOfImage:image
                            format:kCIFormatRGBA8 colorSpace:color options:@{}];
                        CGColorSpaceRelease(color);
                        [png writeToFile:@"/tmp/anmir-native-probe-before.png" atomically:YES];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                            if (switcher) { [weakSession showAppSwitcher]; }
                            else { [weakSession back]; }
                        });
                    }
                    if (switcher) {
                        NSURL *URL = [NSURL fileURLWithPath:@"/tmp/anmir-native-probe-recording.mp4"];
                        [NSFileManager.defaultManager removeItemAtURL:URL error:nil];
                        CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(sample);
                        NSError *error = nil;
                        recorder = [[SCIOSRecorder alloc] initWithURL:URL
                            size:CGSizeMake(CVPixelBufferGetWidth(pixel), CVPixelBufferGetHeight(pixel)) error:&error];
                        if (!recorder) { NSLog(@"RECORDING_FAILED %@", error); failed = YES; }
                    }
                    if (tap) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                            [weakSession touchAtX:x y:y phase:0];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                                [weakSession touchAtX:x y:y phase:2];
                            });
                        });
                    }
                }
                [recorder appendPixelBuffer:CMSampleBufferGetImageBuffer(sample)
                    atHostTime:CMClockGetTime(CMClockGetHostTimeClock())];
                if (startup && frames >= 3) { done = YES; }
                // Save the observed result locally so the effect, not merely
                // acceptance of an HID packet, can be checked by the developer.
                if (!startup && CFAbsoluteTimeGetCurrent() - first > 12 && !done) {
                    CIImage *image = [CIImage imageWithCVPixelBuffer:CMSampleBufferGetImageBuffer(sample)];
                    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
                    NSData *png = [[CIContext contextWithOptions:nil] PNGRepresentationOfImage:image
                        format:kCIFormatRGBA8 colorSpace:color options:@{}];
                    CGColorSpaceRelease(color);
                    [png writeToFile:@"/tmp/anmir-native-probe-result.png" atomically:YES];
                    NSLog(@"FRAMES %lu, elapsed %.3fs", (unsigned long)frames, CFAbsoluteTimeGetCurrent() - first);
                    done = YES;
                }
                CFRelease(sample);
            });
        };
        [session start];
        while (!done && CFAbsoluteTimeGetCurrent() - started < 35) {
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        }
        __block BOOL recordingFinished = !recorder;
        [recorder finishAtHostTime:CMClockGetTime(CMClockGetHostTimeClock()) completion:^(NSError *error) {
            if (error) { NSLog(@"RECORDING_FAILED %@", error); failed = YES; }
            else { NSLog(@"RECORDING_COMPLETE %@", recorder.URL.path); }
            recordingFinished = YES;
        }];
        CFAbsoluteTime finishDeadline = CFAbsoluteTimeGetCurrent() + 10;
        while (!recordingFinished && CFAbsoluteTimeGetCurrent() < finishDeadline) {
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        }
        if (!recordingFinished) { failed = YES; }
        session.frame = nil;
        [session stop];
        [preparation stop];
        CFAbsoluteTime stop = CFAbsoluteTimeGetCurrent();
        while (CFAbsoluteTimeGetCurrent() - stop < 2) {
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        }
        return failed || !received || !done ? 1 : 0;
    }
}
