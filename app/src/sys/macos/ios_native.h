#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

// A session owns its control connections, UDP socket and in-process decoder.
// Frame callbacks run on a serial media queue; they must return promptly.
@interface SCIOSNativeSession : NSObject
@property(nonatomic, copy, nullable) void (^frame)(CMSampleBufferRef sample);
@property(nonatomic, copy, nullable) void (^failed)(NSError *error);
@property(nonatomic, copy, nullable) void (^controlsReady)(void);
@property(atomic, readonly, getter=isInputReady) BOOL inputReady;
- (instancetype)initWithIdentifier:(NSString *)identifier;
- (instancetype)initWithIdentifier:(NSString *)identifier
                preparedConnection:(nullable NSString *)preparedConnection;
- (void)start;
- (void)stop;
- (void)touchAtX:(double)x y:(double)y phase:(NSUInteger)phase;
- (void)home;
- (void)showAppSwitcher;
- (void)back;
@end

NS_ASSUME_NONNULL_END
