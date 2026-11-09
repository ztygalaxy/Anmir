#import "ios_preparation.h"
#include <arpa/inet.h>
#include <math.h>

NSDictionary *SCIOSPreparedConnectionDetails(NSString *value, NSTimeInterval now) {
    if (!value.length) { return nil; }
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:NSDictionary.class]) { return nil; }
    id address = root[@"address"], time = root[@"uptime"];
    if (![address isKindOfClass:NSString.class] || ![time isKindOfClass:NSNumber.class]) { return nil; }
    double age = now - [time doubleValue];
    struct in6_addr parsed;
    if (!isfinite(age) || age < 0 || age > 6 || inet_pton(AF_INET6, [address UTF8String], &parsed) != 1) { return nil; }
    return @{@"connectionProperties":@{@"tunnelIPAddress":address}};
}

@interface SCIOSConnectionPreparation ()
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *payload;
@property(nonatomic, strong) NSTask *task;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) BOOL stopped;
@end

@implementation SCIOSConnectionPreparation
- (instancetype)initWithIdentifier:(NSString *)identifier {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        __weak SCIOSConnectionPreparation *weakSelf = self;
        _timer = [NSTimer timerWithTimeInterval:4 repeats:YES block:^(NSTimer *timer) {
            (void)timer; [weakSelf refresh];
        }];
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
        [self refresh];
    }
    return self;
}
- (NSString *)environmentValue {
    return SCIOSPreparedConnectionDetails(self.payload, NSProcessInfo.processInfo.systemUptime) ? self.payload : nil;
}
- (void)refresh {
    if (self.stopped || self.task.running) { return; }
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"anmir-ios-prepare-%@.json", NSUUID.UUID.UUIDString]];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = @[@"devicectl", @"device", @"info", @"details", @"--device",
        self.identifier, @"--timeout", @"8", @"--quiet", @"--json-output", path];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    self.task = task;
    __weak SCIOSConnectionPreparation *weakSelf = self;
    task.terminationHandler = ^(NSTask *finished) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        id address = [root isKindOfClass:NSDictionary.class]
            ? root[@"result"][@"connectionProperties"][@"tunnelIPAddress"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            SCIOSConnectionPreparation *preparation = weakSelf;
            if (!preparation || preparation.stopped || preparation.task != finished) { return; }
            preparation.task = nil; preparation.payload = nil;
            if (finished.terminationStatus == 0 && [address isKindOfClass:NSString.class]) {
                NSData *payload = [NSJSONSerialization dataWithJSONObject:
                    @{@"address":address, @"uptime":@(NSProcessInfo.processInfo.systemUptime)} options:0 error:nil];
                preparation.payload = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
            }
        });
    };
    if (![task launchAndReturnError:nil]) { self.task = nil; self.payload = nil; }
}
- (void)stop {
    self.stopped = YES; self.payload = nil;
    [self.timer invalidate]; self.timer = nil;
    if (self.task.running) { [self.task terminate]; }
    self.task = nil;
}
- (void)dealloc { [_timer invalidate]; if (_task.running) { [_task terminate]; } }
@end
