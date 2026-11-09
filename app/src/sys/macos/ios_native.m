// Native CoreDevice media transport. Protocol/AVConference integration adapted
// from ipb (MIT), Copyright (c) 2026 Borealin and ipbtools contributors.
// See licenses/ipb-MIT.txt. All session lifecycle and Anmir integration are local.
#import "ios_native.h"
#import "ios_preparation.h"
#import "localization.h"
#include "ios_hid.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <xpc/xpc.h>
#include <dlfcn.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdatomic.h>

// These are runtime-checked private Objective-C interfaces. Loading is optional;
// Android and the device list work on hosts without the developer frameworks.
@interface NSObject (SCAVCPrivate)
- (instancetype)initWithMode:(long)mode options:(NSDictionary *)options error:(NSError **)error;
- (BOOL)createOffer;
- (NSData *)offer;
- (BOOL)setAnswer:(NSData *)answer withError:(NSError **)error;
- (id)generateMediaStreamConfigurationWithError:(NSError **)error;
- (id)generateMediaStreamInitOptionsWithError:(NSError **)error;
- (instancetype)initWithNetworkSockets:(id)sockets options:(id)options error:(NSError **)error;
- (BOOL)configure:(id)configuration error:(NSError **)error;
- (void)setDelegate:(id)delegate;
- (void)start;
- (void)stop;
- (long long)streamToken;
- (id)streamOutput;
- (void)setStreamOutput:(id)output;
- (instancetype)initWithStreamToken:(long long)token clientProcessID:(int)pid
    delegate:(id)delegate delegateQueue:(dispatch_queue_t)queue;
@end

@interface SCAVCVideoStream : NSObject
- (instancetype)initWithNetworkSockets:(id)sockets options:(id)options error:(NSError **)error;
- (BOOL)configure:(id)configuration error:(NSError **)error;
- (void)setDelegate:(id)delegate;
- (void)start;
- (void)stop;
@end

static struct {
    void *(*create)(int, dispatch_queue_t, uint64_t, uint64_t);
    void (*handler)(id, xpc_handler_t);
    void (*activate)(id);
    void (*cancel)(id);
    void (*send)(id, xpc_object_t);
    void (*reply)(id, xpc_object_t, dispatch_queue_t, xpc_handler_t);
    BOOL available;
} SCRemoteAPI;

static NSError *SCNativeError(NSString *message) {
    return [NSError errorWithDomain:@"io.github.laobie.anmir.ios.native" code:1
        userInfo:@{NSLocalizedDescriptionKey:SCLocalized(message)}];
}

static BOOL SCFindTunnelAddress(NSString *deviceIP, struct sockaddr_in6 *local) {
    struct in6_addr peer;
    if (!deviceIP || inet_pton(AF_INET6, deviceIP.UTF8String, &peer) != 1) { return NO; }
    *local = (struct sockaddr_in6){.sin6_len = sizeof(*local), .sin6_family = AF_INET6};
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces)) { return NO; }
    for (struct ifaddrs *it = interfaces; it; it = it->ifa_next) {
        if (!it->ifa_addr || it->ifa_addr->sa_family != AF_INET6 || strncmp(it->ifa_name, "utun", 4)) { continue; }
        struct sockaddr_in6 *address = (struct sockaddr_in6 *)it->ifa_addr;
        if (memcmp(&address->sin6_addr, &peer, 8) == 0) {
            local->sin6_addr = address->sin6_addr;
            local->sin6_scope_id = if_nametoindex(it->ifa_name); break;
        }
    }
    freeifaddrs(interfaces);
    return local->sin6_scope_id != 0;
}

@interface SCIOSNativeSession () {
    atomic_bool _stopped;
    int _rtp;
}
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *preparedConnection;
@property(nonatomic, strong) dispatch_queue_t setupQueue, mediaQueue, inputQueue, replyQueue;
@property(nonatomic, strong) xpc_connection_t host;
@property(nonatomic, strong) id remote, digitizer, button, imageOutput;
@property(nonatomic, strong) SCAVCVideoStream *video;
@property(nonatomic, strong) NSTimer *keepalive;
@property(nonatomic, strong) NSTask *warmTask;
@property(nonatomic, strong) NSUUID *sessionID;
@property(atomic, readwrite, getter=isInputReady) BOOL inputReady;
@property(nonatomic) BOOL backGestureActive;
@property(nonatomic) NSTimeInterval startupTime;
@property(nonatomic) BOOL loggedFirstFrame;
- (void)receiveSample:(CMSampleBufferRef)sample;
- (void)fail:(NSError *)error;
@end

// VCImageQueue has no public callback setter. Install a sink only on queues
// created while our own AVCVideoStream is starting. Never replace other clients'
// stream outputs. The delegate retains no session and is detached on stop.
static __weak SCIOSNativeSession *SCStartingSession;
static IMP SCOriginalImageQueueStart;
@interface SCNativeFrameSink : NSObject
@property(nonatomic, weak) SCIOSNativeSession *session;
@end
@implementation SCNativeFrameSink
- (void)didReceiveSampleBuffer:(CMSampleBufferRef)sample { [self.session receiveSample:sample]; }
- (void)streamOutput:(id)output didReceiveSampleBuffer:(CMSampleBufferRef)sample {
    (void)output; [self.session receiveSample:sample];
}
@end

static void SCImageQueueStart(id queue, SEL selector) {
    SCIOSNativeSession *session = SCStartingSession;
    if (session && ![queue streamOutput]) {
        SCNativeFrameSink *sink = [[SCNativeFrameSink alloc] init];
        sink.session = session;
        id output = [[NSClassFromString(@"VCStreamOutput") alloc]
            initWithStreamToken:[queue streamToken] clientProcessID:getpid()
            delegate:sink delegateQueue:session.mediaQueue];
        session.imageOutput = output;
        [queue setStreamOutput:output];
        // Some system versions keep the delegate weakly.
        objc_setAssociatedObject(output, @selector(receiveSample:), sink, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ((void (*)(id, SEL))SCOriginalImageQueueStart)(queue, selector);
}

static BOOL SCLoadNativeAPI(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *core = dlopen("/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice", RTLD_NOW | RTLD_GLOBAL);
        void *media = dlopen("/System/Library/PrivateFrameworks/AVConference.framework/AVConference", RTLD_NOW | RTLD_GLOBAL);
        if (!core || !media) { return; }
        void (*addBundle)(NSBundle *) = dlsym(core, "_coredevice_xpc_add_bundle");
        void (*initialize)(void) = dlsym(core, "_coredevice_xpc_init_services");
        SCRemoteAPI.create = dlsym(RTLD_DEFAULT, "xpc_remote_connection_create_with_connected_fd");
        SCRemoteAPI.handler = dlsym(RTLD_DEFAULT, "xpc_remote_connection_set_event_handler");
        SCRemoteAPI.activate = dlsym(RTLD_DEFAULT, "xpc_remote_connection_activate");
        SCRemoteAPI.cancel = dlsym(RTLD_DEFAULT, "xpc_remote_connection_cancel");
        SCRemoteAPI.send = dlsym(RTLD_DEFAULT, "xpc_remote_connection_send_message");
        SCRemoteAPI.reply = dlsym(RTLD_DEFAULT, "xpc_remote_connection_send_message_with_reply");
        Method start = class_getInstanceMethod(NSClassFromString(@"VCImageQueue"), @selector(start));
        if (!addBundle || !initialize || !SCRemoteAPI.create || !SCRemoteAPI.handler
                || !SCRemoteAPI.activate || !SCRemoteAPI.cancel || !SCRemoteAPI.send
                || !SCRemoteAPI.reply || !start || !NSClassFromString(@"VCStreamOutput")
                || !NSClassFromString(@"AVCMediaStreamNegotiator") || !NSClassFromString(@"AVCVideoStream")) { return; }
        addBundle([NSBundle bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreDevice.framework"]);
        initialize();
        SCOriginalImageQueueStart = method_setImplementation(start, (IMP)SCImageQueueStart);
        SCRemoteAPI.available = YES;
    });
    return SCRemoteAPI.available;
}

static xpc_object_t SCAction(NSString *action, NSString *identifier, xpc_object_t input) {
    xpc_object_t message = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(message, "CoreDevice.actionIdentifier", action.UTF8String);
    xpc_dictionary_set_string(message, "CoreDevice.deviceIdentifier", identifier.UTF8String);
    xpc_dictionary_set_string(message, "CoreDevice.invocationIdentifier", NSUUID.UUID.UUIDString.UTF8String);
    xpc_object_t version = xpc_dictionary_create_empty();
    // Read the installed host's version rather than claim a newer protocol.
    NSBundle *bundle = [NSBundle bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreDevice.framework"];
    NSString *number = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"518.33";
    xpc_object_t components = xpc_array_create_empty();
    for (NSString *part in [number componentsSeparatedByString:@"."]) {
        xpc_array_append_value(components, xpc_uint64_create(part.longLongValue));
    }
    xpc_dictionary_set_value(version, "components", components);
    xpc_dictionary_set_int64(version, "originalComponentsCount", xpc_array_get_count(components));
    xpc_dictionary_set_string(version, "stringValue", number.UTF8String);
    xpc_dictionary_set_value(message, "CoreDevice.coreDeviceVersion", version);
    xpc_dictionary_set_int64(message, "CoreDevice.CoreDeviceDDIProtocolVersion", 1);
    xpc_dictionary_set_value(message, "CoreDevice.input", input);
    return message;
}

static NSError *SCReplyError(xpc_object_t reply) {
    if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
        return SCNativeError(@"The iPhone connection closed or timed out.");
    }
    xpc_object_t error = xpc_dictionary_get_dictionary(reply, "CoreDevice.error");
    if (!error) { return nil; }
    xpc_object_t info = xpc_dictionary_get_dictionary(error, "userInfo");
    const char *description = info ? xpc_dictionary_get_string(info, "NSLocalizedDescription") : NULL;
    return SCNativeError(description ? [NSString stringWithUTF8String:description]
        : [NSString stringWithFormat:@"CoreDevice error %lld", xpc_dictionary_get_int64(error, "code")]);
}

@implementation SCIOSNativeSession
- (void)profile:(NSString *)stage {
    if (getenv("ANMIR_IOS_PROFILE")) {
        NSLog(@"IOS_STARTUP %@ %.3f", stage, NSProcessInfo.processInfo.systemUptime - self.startupTime);
    }
}
- (instancetype)initWithIdentifier:(NSString *)identifier {
    return [self initWithIdentifier:identifier
        preparedConnection:NSProcessInfo.processInfo.environment[@"ANMIR_IOS_PREPARED_TUNNEL"]];
}
- (instancetype)initWithIdentifier:(NSString *)identifier preparedConnection:(NSString *)preparedConnection {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _preparedConnection = [preparedConnection copy];
        _rtp = -1;
        atomic_init(&_stopped, false);
        _setupQueue = dispatch_queue_create("anmir.ios.setup", DISPATCH_QUEUE_SERIAL);
        _mediaQueue = dispatch_queue_create("anmir.ios.frames", DISPATCH_QUEUE_SERIAL);
        _inputQueue = dispatch_queue_create("anmir.ios.input", DISPATCH_QUEUE_SERIAL);
        _replyQueue = dispatch_queue_create("anmir.ios.replies", DISPATCH_QUEUE_SERIAL);
        _sessionID = NSUUID.UUID;
    }
    return self;
}

- (void)fail:(NSError *)error {
    if (atomic_load(&_stopped)) { return; }
    NSLog(@"Native iPhone mirroring: %@", error);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!atomic_load(&self->_stopped) && self.failed) { self.failed(error); }
        [self stop];
    });
}

// Completion always arrives on main. This native Apple utility currently owns
// the device-manager check-in/tunnel lease; it does not carry media or input.
- (void)warmTunnel:(void (^)(NSDictionary *, NSError *))completion {
    if (self.warmTask.running || atomic_load(&_stopped)) { return; }
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"anmir-native-%@.json", NSUUID.UUID.UUIDString]];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = @[@"devicectl", @"device", @"info", @"details", @"--device",
        self.identifier, @"--timeout", @"8", @"--quiet", @"--json-output", path];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    self.warmTask = task;
    __weak SCIOSNativeSession *weakSelf = self;
    task.terminationHandler = ^(NSTask *finished) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            SCIOSNativeSession *session = weakSelf;
            session.warmTask = nil;
            if (session && !atomic_load(&session->_stopped)) {
                completion(root[@"result"], finished.terminationStatus == 0 ? nil
                    : SCNativeError(@"Unlock the iPhone and check its USB connection and Developer Mode."));
            }
        });
    };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) { self.warmTask = nil; completion(nil, error); }
}

- (void)start {
    self.startupTime = NSProcessInfo.processInfo.systemUptime;
    if (!SCLoadNativeAPI()) { [self fail:SCNativeError(@"Install Xcode's device support to use native iPhone mirroring on this Mac.")]; return; }
    [self profile:@"frameworks"];
    __weak SCIOSNativeSession *weakSelf = self;
    NSDictionary *prepared = SCIOSPreparedConnectionDetails(
        self.preparedConnection, NSProcessInfo.processInfo.systemUptime);
    struct sockaddr_in6 address;
    if (prepared && !SCFindTunnelAddress(prepared[@"connectionProperties"][@"tunnelIPAddress"], &address)) { prepared = nil; }
    if (prepared) {
        [self profile:@"preparedTunnel"];
        dispatch_async(self.setupQueue, ^{ [self configure:prepared]; });
    }
    BOOL usingPrepared = prepared != nil;
    [self warmTunnel:^(NSDictionary *details, NSError *error) {
        SCIOSNativeSession *session = weakSelf;
        if (!session) { return; }
        if (error) { [session fail:error]; return; }
        [session profile:@"tunnel"];
        session.keepalive = [NSTimer scheduledTimerWithTimeInterval:4 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            [weakSelf warmTunnel:^(NSDictionary *ignored, NSError *failure) {
                (void)ignored;
                if (failure) { [weakSelf fail:failure]; }
            }];
        }];
        [NSRunLoop.mainRunLoop addTimer:session.keepalive forMode:NSRunLoopCommonModes];
        if (!usingPrepared) { dispatch_async(session.setupQueue, ^{ [session configure:details]; }); }
    }];
}

- (xpc_object_t)request:(xpc_object_t)request remote:(id)remote {
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block xpc_object_t reply = nil;
    xpc_handler_t handler = ^(xpc_object_t value) { reply = value; dispatch_semaphore_signal(ready); };
    if (remote) { SCRemoteAPI.reply(remote, request, self.replyQueue, handler); }
    else { xpc_connection_send_message_with_reply(self.host, request, self.replyQueue, handler); }
    if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC))) { return nil; }
    return reply;
}

- (id)openFeature:(NSString *)feature error:(NSError **)error {
    if (atomic_load(&_stopped)) { *error = SCNativeError(@"The iPhone connection closed or timed out."); return nil; }
    xpc_object_t input = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(input, "featureIdentifier", feature.UTF8String);
    xpc_object_t reply = [self request:SCAction(@"com.apple.coredevice.action.createservicesocket", self.identifier, input) remote:nil];
    *error = SCReplyError(reply);
    if (*error) { return nil; }
    xpc_object_t output = xpc_dictionary_get_dictionary(reply, "CoreDevice.output");
    int fd = output ? xpc_dictionary_dup_fd(output, "fileDescriptor") : -1;
    if (fd < 0) { *error = SCNativeError(@"The iPhone's screen service is unavailable. iOS 27 developer services are required."); return nil; }
    uint64_t flags = xpc_dictionary_get_uint64(output, "remoteXPCVersionFlags");
    void *pointer = SCRemoteAPI.create(fd, self.replyQueue, flags, 0);
    if (!pointer) { close(fd); *error = SCNativeError(@"Could not open the iPhone service."); return nil; }
    id remote = CFBridgingRelease(pointer);
    __weak SCIOSNativeSession *weakSelf = self;
    SCRemoteAPI.handler(remote, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) { [weakSelf fail:SCNativeError(@"The iPhone USB connection ended.")]; }
    });
    SCRemoteAPI.activate(remote);
    return remote;
}

- (void)configure:(NSDictionary *)details {
    if (atomic_load(&_stopped)) { return; }
    NSError *error = nil;
    NSString *deviceIP = details[@"connectionProperties"][@"tunnelIPAddress"];
    struct sockaddr_in6 local;
    if (!SCFindTunnelAddress(deviceIP, &local)) { [self fail:SCNativeError(@"The iPhone USB tunnel is not ready. Try again.")]; return; }
    self.host = xpc_connection_create("com.apple.CoreDevice.CoreDeviceService", self.replyQueue);
    xpc_connection_set_event_handler(self.host, ^(xpc_object_t event) { (void)event; });
    xpc_connection_resume(self.host);
    self.remote = [self openFeature:@"com.apple.coredevice.feature.startmediastream" error:&error];
    if (!self.remote) { [self fail:error]; return; }
    [self profile:@"mediaService"];
    _rtp = socket(AF_INET6, SOCK_DGRAM, 0);
    int reuse = 1, receiveBytes = 4 * 1024 * 1024;
    setsockopt(_rtp, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    setsockopt(_rtp, SOL_SOCKET, SO_RCVBUF, &receiveBytes, sizeof(receiveBytes));
    if (_rtp < 0 || bind(_rtp, (struct sockaddr *)&local, sizeof(local))) {
        [self fail:SCNativeError(@"Could not open the iPhone video receiver.")]; return;
    }
    socklen_t length = sizeof(local);
    if (getsockname(_rtp, (struct sockaddr *)&local, &length)) { [self fail:SCNativeError(@"Could not bind the video receiver.")]; return; }
    char localIP[INET6_ADDRSTRLEN]; inet_ntop(AF_INET6, &local.sin6_addr, localIP, sizeof(localIP));
    id negotiator = [[NSClassFromString(@"AVCMediaStreamNegotiator") alloc] initWithMode:5 options:@{} error:&error];
    if (!negotiator || ![negotiator createOffer]) { [self fail:error ?: SCNativeError(@"Could not negotiate iPhone video.")]; return; }
    NSData *offer = [negotiator offer];
    [self profile:@"offer"];
    xpc_object_t input = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(input, "receiverIP", localIP);
    xpc_dictionary_set_uint64(input, "receiverPort", ntohs(local.sin6_port));
    xpc_dictionary_set_string(input, "senderIP", deviceIP.UTF8String);
    xpc_dictionary_set_uint64(input, "senderPort", 51000);
    xpc_dictionary_set_uint64(input, "timeout", 30);
    xpc_dictionary_set_string(input, "type", "video");
    xpc_dictionary_set_string(input, "direction", "output");
    xpc_dictionary_set_data(input, "negotiatorOffer", offer.bytes, offer.length);
    xpc_dictionary_set_uint64(input, "clientSupportedFeatures", 972);
    xpc_object_t options = xpc_dictionary_create_empty(), uuid = xpc_dictionary_create_empty();
    uuid_t bytes; [self.sessionID getUUIDBytes:bytes];
    xpc_dictionary_set_uuid(uuid, "uuid", bytes);
    xpc_dictionary_set_value(options, "avcMediaStreamOptionClientSessionID", uuid);
    xpc_dictionary_set_value(input, "options", options);
    xpc_object_t reply = [self request:SCAction(@"com.apple.coredevice.action.mediastreamstart", self.identifier, input) remote:self.remote];
    error = SCReplyError(reply);
    if (error) { [self fail:error]; return; }
    xpc_object_t output = xpc_dictionary_get_dictionary(reply, "CoreDevice.output");
    size_t size = 0;
    const void *answer = output ? xpc_dictionary_get_data(output, "negotiatorAnswer", &size) : NULL;
    if (!answer && output) { answer = xpc_dictionary_get_data(output, "answer", &size); }
    if (!answer || ![negotiator setAnswer:[NSData dataWithBytes:answer length:size] withError:&error]) {
        [self fail:error ?: SCNativeError(@"The iPhone refused video negotiation.")]; return;
    }
    id configuration = [negotiator generateMediaStreamConfigurationWithError:&error];
    NSDictionary *generated = [negotiator generateMediaStreamInitOptionsWithError:&error];
    if (!configuration || !generated) { [self fail:error ?: SCNativeError(@"Could not configure the video decoder.")]; return; }
    [self profile:@"negotiated"];
    struct timeval timeout = {8, 0};
    setsockopt(_rtp, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    uint8_t peek[4]; struct sockaddr_in6 sender; socklen_t senderLength = sizeof(sender);
    if (recvfrom(_rtp, peek, sizeof(peek), MSG_PEEK, (struct sockaddr *)&sender, &senderLength) <= 0
            || connect(_rtp, (struct sockaddr *)&sender, senderLength)) {
        [self fail:SCNativeError(@"No video received from the iPhone. Unlock it and try again.")]; return;
    }
    [self profile:@"firstPacket"];
    NSMutableDictionary *decodeOptions = generated.mutableCopy;
    decodeOptions[@"avcMediaStreamOptionRunInProcess"] = @YES;
    decodeOptions[@"avcMediaStreamOptionClientName"] = @"CoreDeviceScreenSharing";
    decodeOptions[@"avcMediaStreamOptionClientSessionID"] = self.sessionID;
    xpc_object_t sockets = xpc_dictionary_create_empty();
    xpc_dictionary_set_fd(sockets, "avcKeySharedSocket", _rtp);
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (atomic_load(&self->_stopped)) { return; }
        SCStartingSession = self;
        NSError *configureError = nil;
        self.video = [[NSClassFromString(@"AVCVideoStream") alloc]
            initWithNetworkSockets:sockets options:decodeOptions error:&configureError];
        [self profile:@"decoderCreated"];
        [self.video setDelegate:self];
        if (!self.video || ![self.video configure:configuration error:&configureError]) {
            [self fail:configureError ?: SCNativeError(@"Could not start the native video decoder.")];
        } else { [self profile:@"decoderConfigured"]; [self.video start]; }
        SCStartingSession = nil;
    });
    [self profile:@"decoderStarted"];
    if (atomic_load(&_stopped)) { return; }
    id digitizer = [self openFeature:@"com.apple.coredevice.feature.remote.universalhidservice" error:&error];
    id button = [self openFeature:@"com.apple.coredevice.feature.remote.hid.button" error:&error];
    dispatch_sync(self.inputQueue, ^{ self.digitizer = digitizer; self.button = button; });
    if (!digitizer || !button) { [self fail:error]; return; }
    self.inputReady = YES;
    [self profile:@"controlsReady"];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!atomic_load(&self->_stopped) && self.controlsReady) { self.controlsReady(); }
    });
}

- (void)receiveSample:(CMSampleBufferRef)sample {
    if (!atomic_load(&_stopped) && sample && CMSampleBufferGetImageBuffer(sample) && self.frame) {
        if (!self.loggedFirstFrame) {
            self.loggedFirstFrame = YES; [self profile:@"firstFrame"];
            double click = [NSProcessInfo.processInfo.environment[@"ANMIR_IOS_CLICK_UPTIME"] doubleValue];
            if (getenv("ANMIR_IOS_PROFILE") && click > 0) {
                NSLog(@"IOS_STARTUP clickToFirstFrame %.3f", NSProcessInfo.processInfo.systemUptime - click);
            }
        }
        self.frame(sample);
    }
}
- (void)stream:(id)stream didStart:(BOOL)started error:(NSError *)error {
    (void)stream; if (!started) { [self fail:error ?: SCNativeError(@"The native iPhone video stream could not start.")]; }
}
- (void)streamDidStop:(id)stream { (void)stream; [self fail:SCNativeError(@"The iPhone video stream stopped.")]; }
- (void)streamDidServerDie:(id)stream { (void)stream; [self fail:SCNativeError(@"The video decoder stopped.")]; }
- (void)vcMediaStreamDidStop:(id)stream { (void)stream; [self streamDidStop:stream]; }

- (void)sendTouchAtX:(double)x y:(double)y phase:(NSUInteger)phase {
    // Runs on inputQueue, including every step of a synthetic gesture.
    uint8_t report[58];
    if (atomic_load(&_stopped) || !self.digitizer
            || !sc_ios_hid_touch(report, x, y, (unsigned)phase)) { return; }
    xpc_object_t parameters = xpc_dictionary_create_empty();
    xpc_dictionary_set_data(parameters, "_0", report, sizeof(report));
    xpc_dictionary_set_uint64(parameters, "_1", 0x101);
    xpc_object_t payload = xpc_dictionary_create_empty(), message = xpc_dictionary_create_empty();
    xpc_dictionary_set_value(payload, "send", parameters);
    xpc_dictionary_set_string(message, "messageType", "Request");
    xpc_dictionary_set_string(message, "featureIdentifier", "com.apple.coredevice.feature.remote.universalhidservice");
    xpc_dictionary_set_value(message, "payload", payload);
    SCRemoteAPI.send(self.digitizer, message);
}
- (void)touchAtX:(double)x y:(double)y phase:(NSUInteger)phase {
    dispatch_async(self.inputQueue, ^{
        if (!self.backGestureActive) { [self sendTouchAtX:x y:y phase:phase]; }
    });
}
- (void)pressButtonOnPage:(uint64_t)page usage:(uint64_t)usage {
    dispatch_async(self.inputQueue, ^{
        if (atomic_load(&self->_stopped) || !self.button || self.backGestureActive) { return; }
        for (NSUInteger state = 1; state <= 2; state++) {
            xpc_object_t payload = xpc_dictionary_create_empty(), message = xpc_dictionary_create_empty();
            xpc_dictionary_set_uint64(payload, "usagePage", page);
            xpc_dictionary_set_uint64(payload, "usageCode", usage);
            xpc_dictionary_set_uint64(payload, "state", state);
            xpc_dictionary_set_string(message, "messageType", "IndigoButtonEvent");
            xpc_dictionary_set_string(message, "featureIdentifier", "com.apple.coredevice.feature.remote.hid.button");
            xpc_dictionary_set_value(message, "payload", payload);
            if (state == 1) { SCRemoteAPI.send(self.button, message); }
            else { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), self.inputQueue, ^{
                if (!atomic_load(&self->_stopped) && self.button) { SCRemoteAPI.send(self.button, message); }
            }); }
        }
    });
}
- (void)home { [self pressButtonOnPage:0x0c usage:0x40]; }
- (void)showAppSwitcher {
    // AppleVendorKeyboard App Switcher; opens it directly without a swipe.
    [self pressButtonOnPage:0xff01 usage:0x10];
}
- (void)back {
    // iOS has no Android-style global Back key. Reproduce the left-edge
    // navigation gesture; apps decide whether their current page supports it.
    dispatch_async(self.inputQueue, ^{
        if (atomic_load(&self->_stopped) || !self.digitizer || self.backGestureActive) { return; }
        self.backGestureActive = YES;
        [self sendTouchAtX:0 y:.5 phase:0];
        for (NSUInteger step = 1; step <= 18; step++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, step * 16 * NSEC_PER_MSEC), self.inputQueue, ^{
                [self sendTouchAtX:.7 * step / 18 y:.5 phase:1];
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 310 * NSEC_PER_MSEC), self.inputQueue, ^{
            [self sendTouchAtX:.7 y:.5 phase:2];
            self.backGestureActive = NO;
        });
    });
}
- (void)stop {
    if (atomic_exchange(&_stopped, true)) { return; }
    self.inputReady = NO;
    [self.keepalive invalidate]; self.keepalive = nil;
    [self.warmTask terminate]; self.warmTask = nil;
    dispatch_async(self.setupQueue, ^{
        // Serialize with setup so a close during negotiation cannot install a
        // fresh input connection after cleanup has already run.
        dispatch_sync(self.inputQueue, ^{
            if (self.digitizer) {
                // Best-effort release when the window closes during a drag.
                // Keep the service alive until its barrier is acknowledged, or
                // for 300ms if the cable has already gone away.
                id remote = self.digitizer;
                xpc_object_t parameter = xpc_dictionary_create_empty();
                xpc_dictionary_set_uint64(parameter, "_0", 0x101);
                xpc_object_t payload = xpc_dictionary_create_empty(), reset = xpc_dictionary_create_empty();
                xpc_dictionary_set_value(payload, "resetGestureState", parameter);
                xpc_dictionary_set_string(reset, "messageType", "Request");
                xpc_dictionary_set_string(reset, "featureIdentifier", "com.apple.coredevice.feature.remote.universalhidservice");
                xpc_dictionary_set_value(reset, "payload", payload);
                SCRemoteAPI.send(remote, reset);
                xpc_object_t barrier = xpc_dictionary_create_empty();
                xpc_dictionary_set_bool(barrier, "isBarrier", true);
                SCRemoteAPI.reply(remote, barrier, self.replyQueue, ^(xpc_object_t reply) {
                    (void)reply; SCRemoteAPI.cancel(remote);
                });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), self.replyQueue, ^{
                    SCRemoteAPI.cancel(remote);
                });
            }
            if (self.button) { SCRemoteAPI.cancel(self.button); }
            self.digitizer = nil; self.button = nil;
        });
        if (self.remote) { SCRemoteAPI.cancel(self.remote); self.remote = nil; }
        if (self.host) { xpc_connection_cancel(self.host); self.host = nil; }
        if (self->_rtp >= 0) { close(self->_rtp); self->_rtp = -1; }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.video setDelegate:nil]; [self.video stop];
            self.video = nil; self.imageOutput = nil;
        });
    });
}
@end
