#import "ios_mirror.h"

#import "device_ui.h"
#import "localization.h"

static NSString *const SCIOSSerialPrefix = @"ios-coredevice:";
static NSString *const SCIOSMirrorErrorDomain = @"io.github.laobie.anmir.ios";

@interface SCIOSDevice ()
@property(nonatomic, copy, readwrite) NSString *identifier;
@property(nonatomic, copy, readwrite) NSString *udid;
@property(nonatomic, copy, readwrite) NSString *name;
@property(nonatomic, copy, readwrite) NSString *system;
@end

@implementation SCIOSDevice
- (instancetype)initWithIdentifier:(NSString *)identifier udid:(NSString *)udid
                              name:(NSString *)name system:(NSString *)system {
    self = [super init];
    if (self) { _identifier = [identifier copy]; _udid = [udid copy]; _name = [name copy]; _system = [system copy]; }
    return self;
}
@end

static NSError *SCIOSError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:SCIOSMirrorErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey:message}];
}

NSString *
SCIOSDeviceSerial(SCIOSDevice *device) {
    return [SCIOSSerialPrefix stringByAppendingString:device.udid];
}

void
SCIOSDiscoverDevices(SCIOSDeviceDiscoveryCompletion completion) {
    if (!completion) { return; }
    NSString *output = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"anmir-coredevice-%@.json", NSUUID.UUID.UUIDString]];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = @[@"devicectl", @"list", @"devices", @"--timeout", @"5",
        @"--quiet", @"--json-output", output];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    task.terminationHandler = ^(NSTask *finished) {
        NSData *data = [NSData dataWithContentsOfFile:output];
        [NSFileManager.defaultManager removeItemAtPath:output error:nil];
        NSError *error = nil;
        NSDictionary *root = data.length
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        NSMutableArray<SCIOSDevice *> *result = [NSMutableArray array];
        if (!error && finished.terminationStatus == 0) {
            NSArray *devices = root[@"result"][@"devices"];
            for (NSDictionary *entry in devices) {
                NSDictionary *hardware = entry[@"hardwareProperties"];
                NSDictionary *properties = entry[@"deviceProperties"];
                NSDictionary *connection = entry[@"connectionProperties"];
                if (![hardware[@"platform"] isEqual:@"iOS"]
                        || ![hardware[@"reality"] isEqual:@"physical"]
                        || ![connection[@"transportType"] isEqual:@"wired"]
                        || ![connection[@"pairingState"] isEqual:@"paired"]) {
                    continue;
                }
                NSString *rawUDID = hardware[@"udid"];
                if (![rawUDID isKindOfClass:NSString.class] || !rawUDID.length) { continue; }
                SCIOSDevice *device = [[SCIOSDevice alloc] init];
                device.identifier = entry[@"identifier"] ?: @"";
                device.udid = [rawUDID stringByReplacingOccurrencesOfString:@"-" withString:@""];
                device.name = properties[@"name"] ?: hardware[@"marketingName"] ?: @"iPhone or iPad";
                NSString *version = properties[@"osVersionNumber"];
                NSString *platform = [hardware[@"deviceType"] isEqual:@"iPad"] ? @"iPadOS" : @"iOS";
                device.system = version.length
                    ? [NSString stringWithFormat:@"%@ %@", platform, version] : platform;
                [result addObject:device];
            }
        } else if (!error) {
            error = SCIOSError(finished.terminationStatus,
                SCLocalized(@"Could not list connected iPhone or iPad devices."));
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result, error); });
    };
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        [NSFileManager.defaultManager removeItemAtPath:output error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], launchError); });
    }
}
