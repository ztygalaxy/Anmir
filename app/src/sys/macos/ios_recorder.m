#import "ios_recorder.h"
#import "localization.h"
#import <AVFoundation/AVFoundation.h>
#include <math.h>

@interface SCIOSRecorder () {
    CVPixelBufferRef _lastFrame;
    CMTime _start, _lastTime;
    NSUInteger _pending;
    BOOL _finishing;
}
@property(nonatomic, strong) AVAssetWriter *writer;
@property(nonatomic, strong) AVAssetWriterInput *input;
@property(nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, readwrite) NSURL *URL;
@property(nonatomic) CGSize size;
@property(nonatomic, strong) NSError *failure;
@end

static NSError *SCRecordingError(NSString *message) {
    return [NSError errorWithDomain:@"io.github.laobie.anmir.ios.recording" code:1
                          userInfo:@{NSLocalizedDescriptionKey:SCLocalized(message)}];
}

@implementation SCIOSRecorder
- (instancetype)initWithURL:(NSURL *)URL size:(CGSize)size error:(NSError **)error {
    self = [super init];
    if (!self) { return nil; }
    if (!isfinite(size.width) || !isfinite(size.height) || size.width < 2 || size.height < 2) {
        if (error) { *error = SCRecordingError(@"Invalid screen size."); }
        return nil;
    }
    _URL = URL; _size = size;
    _queue = dispatch_queue_create("anmir.ios.recording", DISPATCH_QUEUE_SERIAL);
    _writer = [[AVAssetWriter alloc] initWithURL:URL fileType:AVFileTypeMPEG4 error:error];
    if (!_writer) { return nil; }
    NSDictionary *settings = @{
        AVVideoCodecKey:AVVideoCodecTypeH264,
        AVVideoWidthKey:@((NSInteger)size.width), AVVideoHeightKey:@((NSInteger)size.height),
        AVVideoCompressionPropertiesKey:@{
            AVVideoAverageBitRateKey:@(MAX(2000000, MIN(20000000, size.width * size.height * 4))),
            AVVideoMaxKeyFrameIntervalKey:@60,
        },
    };
    _input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    _input.expectsMediaDataInRealTime = YES;
    _adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_input
        sourcePixelBufferAttributes:nil];
    if (![_writer canAddInput:_input]) {
        if (error) { *error = SCRecordingError(@"Could not configure the video encoder."); }
        return nil;
    }
    [_writer addInput:_input];
    if (![_writer startWriting]) { if (error) { *error = _writer.error; } return nil; }
    [_writer startSessionAtSourceTime:kCMTimeZero];
    _start = CMClockGetTime(CMClockGetHostTimeClock());
    _lastTime = kCMTimeInvalid;
    return self;
}
- (void)dealloc { if (_lastFrame) { CVPixelBufferRelease(_lastFrame); } }
- (void)appendPixelBuffer:(CVPixelBufferRef)buffer atHostTime:(CMTime)time {
    if (!buffer || !CMTIME_IS_NUMERIC(time)) { return; }
    @synchronized (self) {
        if (_finishing || _pending >= 3) { return; }
        _pending++;
        CVPixelBufferRetain(buffer);
        dispatch_async(self.queue, ^{
        @autoreleasepool {
            CMTime elapsed = CMTimeSubtract(time, self->_start);
            BOOL sizeMatches = CVPixelBufferGetWidth(buffer) == self.size.width
                            && CVPixelBufferGetHeight(buffer) == self.size.height;
            if (sizeMatches && self.writer.status == AVAssetWriterStatusWriting
                    && self.input.readyForMoreMediaData && CMTimeCompare(elapsed, kCMTimeZero) >= 0
                    && (!CMTIME_IS_VALID(self->_lastTime) || CMTimeCompare(elapsed, self->_lastTime) > 0)) {
                if ([self.adaptor appendPixelBuffer:buffer withPresentationTime:elapsed]) {
                    if (self->_lastFrame) { CVPixelBufferRelease(self->_lastFrame); }
                    self->_lastFrame = CVPixelBufferRetain(buffer); self->_lastTime = elapsed;
                } else { self.failure = self.writer.error ?: SCRecordingError(@"Could not encode the screen recording."); }
            }
            CVPixelBufferRelease(buffer);
            @synchronized (self) { self->_pending--; }
        }
        });
    }
}
- (void)finishAtHostTime:(CMTime)time completion:(void (^)(NSError *))completion {
    @synchronized (self) {
        if (_finishing) { return; }
        _finishing = YES;
        // Submit under the same lock as append so accepted frames cannot be
        // queued behind finish when the media and main threads race.
        dispatch_async(self.queue, ^{
        CMTime end = CMTimeSubtract(time, self->_start);
        if (self->_lastFrame && self.writer.status == AVAssetWriterStatusWriting && !self.failure) {
            // Extend an unchanged screen to the stop time instead of truncating
            // the movie at the last frame the phone happened to send.
            end = CMTimeMaximum(end, CMTimeAdd(self->_lastTime, CMTimeMake(1, 60)));
            if (self.input.readyForMoreMediaData) {
                if (![self.adaptor appendPixelBuffer:self->_lastFrame withPresentationTime:end]) {
                    self.failure = self.writer.error ?: SCRecordingError(@"Could not finish the screen recording.");
                }
            }
            [self.writer endSessionAtSourceTime:end];
        } else if (!self.failure) {
            self.failure = self.writer.error ?: SCRecordingError(@"No video frames were recorded.");
        }
        [self.input markAsFinished];
        if (self.failure) {
            [self.writer cancelWriting];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(self.failure); });
            return;
        }
        [self.writer finishWritingWithCompletionHandler:^{
            NSError *error = self.writer.status == AVAssetWriterStatusCompleted ? nil
                : self.writer.error ?: SCRecordingError(@"Could not finish the screen recording.");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        }];
        });
    }
}
@end
