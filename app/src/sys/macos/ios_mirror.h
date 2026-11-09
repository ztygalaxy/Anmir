#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCIOSDevice : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *udid;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *system;
- (instancetype)initWithIdentifier:(NSString *)identifier udid:(NSString *)udid
                              name:(NSString *)name system:(NSString *)system;
@end

typedef void (^SCIOSDeviceDiscoveryCompletion)(NSArray<SCIOSDevice *> *devices,
                                                NSError * _Nullable error);

// CoreDevice is the supported screen-stream path on current iOS versions.
// Discovery is asynchronous because devicectl may need to wake a paired phone.
void SCIOSDiscoverDevices(SCIOSDeviceDiscoveryCompletion completion);
NSString *SCIOSDeviceSerial(SCIOSDevice *device);

@interface SCIOSMirrorController : NSObject
@property(nonatomic, copy, nullable) void (^closed)(void);
@property(nonatomic, readonly, getter=isRunning) BOOL running;
@property(nonatomic, readonly, getter=isStarting) BOOL starting;
@property(nonatomic, readonly) BOOL hasPendingRecording;
- (instancetype)initWithDevice:(SCIOSDevice *)device;
- (void)show;
- (void)close;
@end

NS_ASSUME_NONNULL_END
