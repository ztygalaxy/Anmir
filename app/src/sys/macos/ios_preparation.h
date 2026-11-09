#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Main-thread owned. Keep the device-manager check-in warm while its USB row
// is visible, without opening screen, media or input services.
@interface SCIOSConnectionPreparation : NSObject
@property(nonatomic, readonly, nullable) NSString *environmentValue;
- (instancetype)initWithIdentifier:(NSString *)identifier;
- (void)stop;
@end

// Only a recent, valid IPv6 tunnel address may cross into a mirror process.
NSDictionary *_Nullable SCIOSPreparedConnectionDetails(NSString *_Nullable value,
                                                       NSTimeInterval now);

NS_ASSUME_NONNULL_END
