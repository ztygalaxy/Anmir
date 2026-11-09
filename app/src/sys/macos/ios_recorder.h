#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

// Silent H.264 screen recording. A bounded serial queue keeps disk/encoder
// backpressure off the display callback. Times use the host monotonic clock.
@interface SCIOSRecorder : NSObject
@property(nonatomic, readonly) NSURL *URL;
- (nullable instancetype)initWithURL:(NSURL *)URL size:(CGSize)size
                              error:(NSError **)error;
- (void)appendPixelBuffer:(CVPixelBufferRef)buffer atHostTime:(CMTime)time;
// Completion is always on main. Accepted frames finish before the MP4 closes.
- (void)finishAtHostTime:(CMTime)time completion:(void (^)(NSError *_Nullable))completion;
@end

NS_ASSUME_NONNULL_END
