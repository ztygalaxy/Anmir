#include "toolbar.h"
#include "device_picker.h"
#include <string.h>
#import "ios_mirror.h"
#import "ios_native.h"
#import "ios_recorder.h"
#import "mirror_window.h"
#import "device_ui.h"
#import "localization.h"
#import "settings.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface SCIOSVideoView : NSView
@property(nonatomic, strong) AVSampleBufferDisplayLayer *display;
@property(nonatomic) CGSize videoSize;
@property(nonatomic, copy) void (^touch)(double, double, NSUInteger);
@property(nonatomic) BOOL touching;
@end
@implementation SCIOSVideoView
- (instancetype)init {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        self.wantsLayer = YES; self.layer.backgroundColor = NSColor.blackColor.CGColor;
        _display = [AVSampleBufferDisplayLayer layer];
        _display.videoGravity = AVLayerVideoGravityResizeAspect;
        [self.layer addSublayer:_display];
    }
    return self;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)layout { [super layout]; self.display.frame = self.bounds; }
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    if (self.window) { SCMirrorWindowRefreshAppearance(self.window); }
}
- (void)sendTouch:(NSEvent *)event phase:(NSUInteger)phase {
    if (!self.touch || self.videoSize.width <= 0 || self.videoSize.height <= 0) { return; }
    NSRect area = AVMakeRectWithAspectRatioInsideRect(self.videoSize, self.bounds);
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    if (phase == 0 && !NSPointInRect(location, area)) { return; }
    if (phase == 0) { self.touching = YES; [self.window makeFirstResponder:self]; }
    if (!self.touching) { return; }
    double x = MIN(1, MAX(0, (location.x - area.origin.x) / area.size.width));
    double y = MIN(1, MAX(0, 1 - (location.y - area.origin.y) / area.size.height));
    self.touch(x, y, phase);
    if (phase == 2) { self.touching = NO; }
}
- (void)mouseDown:(NSEvent *)event { [self sendTouch:event phase:0]; }
- (void)mouseDragged:(NSEvent *)event { [self sendTouch:event phase:1]; }
- (void)mouseUp:(NSEvent *)event { [self sendTouch:event phase:2]; }
@end

// Native hosting only: all pixels and hit rectangles come from toolbar.c.
@class SCIOSActionSurface;
@interface SCIOSActionButton : NSButton
@property(nonatomic, weak) SCIOSActionSurface *surface;
@property(nonatomic, strong) NSTrackingArea *tracking;
@end

@interface SCIOSActionSurface : NSView {
    struct sc_toolbar _toolbar;
}
@property(nonatomic, copy) NSArray<SCIOSActionButton *> *buttons;
@property(nonatomic, strong) NSImage *rendered;
@property(nonatomic) BOOL recording;
- (void)invalidateRendering;
- (void)setHoveredAction:(enum sc_toolbar_action)action;
- (void)setPressedAction:(enum sc_toolbar_action)action;
- (void)showScreenshotSuccess;
@end

@implementation SCIOSActionButton
- (void)drawRect:(NSRect)dirty { (void)dirty; } // The shared renderer draws the button.
- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    [self.surface invalidateRendering];
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.tracking) { [self removeTrackingArea:self.tracking]; }
    self.tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
            NSTrackingInVisibleRect | NSTrackingEnabledDuringMouseDrag
        owner:self userInfo:nil];
    [self addTrackingArea:self.tracking];
}
- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    if (self.enabled) { [self.surface setHoveredAction:(enum sc_toolbar_action)self.tag]; }
}
- (void)mouseExited:(NSEvent *)event {
    (void)event; [self.surface setHoveredAction:SC_TOOLBAR_ACTION_NONE];
}
- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) { return; }
    [self.surface setPressedAction:(enum sc_toolbar_action)self.tag];
    [self.surface displayIfNeeded];
    [super mouseDown:event];
    [self.surface setPressedAction:SC_TOOLBAR_ACTION_NONE];
}
@end

@implementation SCIOSActionSurface
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) { sc_toolbar_init(&_toolbar, true, true); }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)setRecording:(BOOL)recording {
    _recording = recording; [self invalidateRendering];
}
- (void)invalidateRendering {
    self.rendered = nil; self.needsDisplay = YES;
}
- (void)setHoveredAction:(enum sc_toolbar_action)action {
    if (_toolbar.hovered == action) { return; }
    _toolbar.hovered = action; [self invalidateRendering];
}
- (void)setPressedAction:(enum sc_toolbar_action)action {
    if (_toolbar.pressed == action) { return; }
    _toolbar.pressed = action; [self invalidateRendering];
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance]; [self invalidateRendering];
}
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties]; [self invalidateRendering];
}
- (void)showScreenshotSuccess {
    sc_toolbar_show_screenshot_success(&_toolbar);
    [self invalidateRendering];
    __weak SCIOSActionSurface *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{ [weakSelf invalidateRendering]; });
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    if (!self.rendered) {
        struct sc_toolbar_view_state state = {
            .light_theme = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:
                @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameAqua],
            .navigation_enabled = true,
            .screenshot_enabled = true,
            .record_enabled = true,
            .recording = self.recording,
            .reduce_motion = true,
        };
        for (SCIOSActionButton *button in self.buttons) {
            if (!button.enabled) { state.disabled_actions |= UINT32_C(1) << button.tag; }
        }
        CGFloat density = self.window.backingScaleFactor ?: 1;
        SDL_Surface *pixels = sc_toolbar_render_snapshot(&_toolbar, &state, density);
        if (!pixels) { return; }
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:pixels->w pixelsHigh:pixels->h
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            // SDL has already blended into transparent RGBA, so the result is
            // premultiplied. Preserve that when AppKit composites the edges.
            colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:0
            bytesPerRow:pixels->pitch bitsPerPixel:32];
        if (bitmap) {
            memcpy(bitmap.bitmapData, pixels->pixels, (size_t)pixels->pitch * pixels->h);
            self.rendered = [[NSImage alloc] initWithSize:self.bounds.size];
            [self.rendered addRepresentation:bitmap];
        }
        SDL_DestroySurface(pixels);
    }
    [self.rendered drawInRect:self.bounds fromRect:NSZeroRect
        operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES
        hints:@{NSImageHintInterpolation:@(NSImageInterpolationHigh)}];
}
@end

@interface SCIOSMirrorController () <NSWindowDelegate> {
    CMSampleBufferRef _latest;
    CVPixelBufferRef _screenshot;
    BOOL _presentationPending;
}
@property(nonatomic, strong) SCIOSDevice *device;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) SCIOSVideoView *videoView;
@property(nonatomic, strong) SCIOSNativeSession *session;
@property(nonatomic, strong) NSView *loadingView;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSProgressIndicator *spinner;
@property(nonatomic, strong) NSPanel *actions;
@property(nonatomic, strong) NSArray<NSButton *> *buttons;
@property(nonatomic, strong) NSTimer *firstFrameTimer;
@property(nonatomic) BOOL ready, closing;
@property(nonatomic, readwrite, getter=isStarting) BOOL starting;
@property(nonatomic) CFAbsoluteTime startedAt;
@property(nonatomic, strong) SCIOSRecorder *recorder;
@property(nonatomic, strong) NSPanel *recordingTimerPanel;
@property(nonatomic, strong) NSTimer *recordingTimer;
@property(nonatomic) CFAbsoluteTime recordingStartedAt;
@property(nonatomic) BOOL savingRecording;
@end

@implementation SCIOSMirrorController
- (instancetype)initWithDevice:(SCIOSDevice *)device {
    self = [super init]; if (self) { _device = device; } return self;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_latest) { CFRelease(_latest); }
    if (_screenshot) { CVPixelBufferRelease(_screenshot); }
}
- (BOOL)isRunning { return self.ready && (self.window.visible || self.window.miniaturized); }
- (BOOL)hasPendingRecording { return self.recorder != nil || self.savingRecording; }

- (void)createWindow {
    if (self.window) { return; }
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 390, 760)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = self.device.name;
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    self.window.minSize = NSMakeSize(260, 420);
    self.window.backgroundColor = NSColor.blackColor;
    SCMirrorWindowConfigure(self.window);
    SCMirrorWindowSetTitle(self.window, self.device.name, self.device.system);
    self.videoView = [[SCIOSVideoView alloc] init];
    self.videoView.translatesAutoresizingMaskIntoConstraints = NO;
    __weak SCIOSMirrorController *weakSelf = self;
    self.videoView.touch = ^(double x, double y, NSUInteger phase) {
        [weakSelf.session touchAtX:x y:y phase:phase];
    };
    self.spinner = [[NSProgressIndicator alloc] init];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel = SCDeviceLabel(SCLocalized(@"Preparing iPhone mirroring…"), 12, NSFontWeightRegular, YES);
    self.statusLabel.alignment = NSTextAlignmentCenter;
    self.statusLabel.maximumNumberOfLines = 5;
    self.statusLabel.preferredMaxLayoutWidth = 300;
    self.loadingView = SCDeviceStack(@[self.spinner, self.statusLabel], YES, 14);
    [(NSStackView *)self.loadingView setAlignment:NSLayoutAttributeCenterX];
    NSView *content = self.window.contentView;
    [content addSubview:self.videoView]; [content addSubview:self.loadingView];
    [NSLayoutConstraint activateConstraints:@[
        [self.videoView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.videoView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.videoView.topAnchor constraintEqualToAnchor:content.topAnchor],
        [self.videoView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [self.loadingView.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [self.loadingView.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [self.statusLabel.widthAnchor constraintLessThanOrEqualToAnchor:content.widthAnchor constant:-40],
    ]];
    [self.window center];
    [self createActions];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged:)
        name:SCSettingsChangedNotification object:nil];
}

- (void)createActions {
    self.actions = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, SC_TOOLBAR_WINDOW_WIDTH, SC_TOOLBAR_WINDOW_HEIGHT)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    self.actions.opaque = NO; self.actions.backgroundColor = NSColor.clearColor;
    // toolbar.c includes the same shadow pixels used by Android.
    self.actions.hasShadow = NO; self.actions.hidesOnDeactivate = NO;
    self.actions.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.actions.contentView = [[SCIOSActionSurface alloc] initWithFrame:self.actions.contentView.bounds];
    NSArray *labels = @[@"Home", @"Back (swipe right in supported apps)", @"Recent apps", @"Screenshot", @"Record screen (no audio)"];
    NSMutableArray *buttons = [NSMutableArray array];
    struct sc_toolbar layout;
    sc_toolbar_init(&layout, true, true);
    for (enum sc_toolbar_action action = SC_TOOLBAR_ACTION_HOME;
            action < SC_TOOLBAR_ACTION_COUNT; action++) {
        SCIOSActionButton *button = [[SCIOSActionButton alloc] initWithFrame:NSZeroRect];
        button.target = self; button.action = @selector(action:);
        button.surface = (SCIOSActionSurface *)self.actions.contentView;
        button.tag = action; button.bordered = NO; button.focusRingType = NSFocusRingTypeNone;
        SCBind(button, @"toolTip", labels[action - SC_TOOLBAR_ACTION_HOME]);
        SCBind(button, @"accessibilityLabel", labels[action - SC_TOOLBAR_ACTION_HOME]);
        SDL_FRect rectangle = layout.buttons[action];
        button.frame = NSMakeRect(rectangle.x, rectangle.y, rectangle.w, rectangle.h);
        button.enabled = NO;
        [self.actions.contentView addSubview:button]; [buttons addObject:button];
    }
    self.buttons = buttons;
    [(SCIOSActionSurface *)self.actions.contentView setButtons:buttons];
}
- (void)positionActions {
    NSRect content = [self.window convertRectToScreen:
        [self.window.contentView convertRect:self.window.contentView.bounds toView:nil]];
    NSRect screen = self.window.screen.visibleFrame;
    CGFloat right = NSMaxX(content) + SC_TOOLBAR_GAP;
    CGFloat left = NSMinX(content) - SC_TOOLBAR_GAP - SC_TOOLBAR_PANEL_WIDTH;
    CGFloat accessory = SC_TOOLBAR_ACCESSORY_GAP + SC_TOOLBAR_ACCESSORY_MAX_WIDTH;
    BOOL rightFits = right + SC_TOOLBAR_PANEL_WIDTH + accessory <= NSMaxX(screen);
    BOOL leftFits = left - accessory >= NSMinX(screen);
    CGFloat x = !rightFits && (leftFits || NSMinX(content) - NSMinX(screen) > NSMaxX(screen) - NSMaxX(content))
        ? left : right;
    CGFloat y = NSMaxY(content) - SC_TOOLBAR_TOP_OFFSET - SC_TOOLBAR_PANEL_HEIGHT;
    x = MAX(NSMinX(screen), MIN(x, NSMaxX(screen) - SC_TOOLBAR_PANEL_WIDTH));
    y = MAX(NSMinY(screen), MIN(y, NSMaxY(screen) - SC_TOOLBAR_PANEL_HEIGHT));
    [self.actions setFrameOrigin:NSMakePoint(x - SC_TOOLBAR_SHADOW_MARGIN, y - SC_TOOLBAR_SHADOW_MARGIN)];
    [self updateRecordingTimer];
}
- (void)settingsChanged:(NSNotification *)notification {
    (void)notification;
    if (self.ready && self.window.visible && !self.window.miniaturized
            && !(self.window.styleMask & NSWindowStyleMaskFullScreen)
            && sc_settings_toolbar_visible()) {
        [self positionActions]; [self.actions orderFront:nil];
    } else { [self.actions orderOut:nil]; }
    [(SCIOSActionSurface *)self.actions.contentView invalidateRendering];
    [self updateRecordingTimer];
}
- (void)windowDidMove:(NSNotification *)notification { (void)notification; [self positionActions]; }
- (void)windowDidResize:(NSNotification *)notification { (void)notification; [self positionActions]; }
- (void)windowDidMiniaturize:(NSNotification *)notification {
    (void)notification; [self.actions orderOut:nil];
    [self updateRecordingTimer];
}
- (void)windowDidDeminiaturize:(NSNotification *)notification { [self settingsChanged:notification]; }
- (void)windowWillEnterFullScreen:(NSNotification *)notification {
    (void)notification; [self.actions orderOut:nil];
    [self updateRecordingTimer];
}
- (void)windowDidExitFullScreen:(NSNotification *)notification { [self settingsChanged:notification]; }

- (void)show {
    [self createWindow];
    if (self.window.miniaturized) { [self.window deminiaturize:nil]; }
    [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    if (!self.starting && !self.ready) { [self start]; }
}
- (void)start {
    self.closing = NO; self.starting = YES;
    self.startedAt = CFAbsoluteTimeGetCurrent();
    self.loadingView.hidden = NO;
    self.statusLabel.stringValue = SCLocalized(@"Preparing iPhone mirroring…");
    [self.spinner startAnimation:nil];
    SCIOSNativeSession *session = [[SCIOSNativeSession alloc] initWithIdentifier:self.device.identifier];
    self.session = session;
    __weak SCIOSMirrorController *weakSelf = self;
    session.frame = ^(CMSampleBufferRef sample) { [weakSelf receiveSample:sample]; };
    session.failed = ^(NSError *error) { [weakSelf showError:error.localizedDescription]; };
    session.controlsReady = ^{ [weakSelf refreshActionAvailability]; };
    [session start];
    self.firstFrameTimer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        SCIOSMirrorController *controller = weakSelf;
        if (controller && !controller.ready) {
            [controller.session stop];
            [controller showError:SCLocalized(@"No video received from the iPhone. Unlock it and try again.")];
        }
    }];
}
- (void)receiveSample:(CMSampleBufferRef)sample {
    @synchronized (self) {
        if (self.closing) { return; }
        [self.recorder appendPixelBuffer:CMSampleBufferGetImageBuffer(sample)
            atHostTime:CMClockGetTime(CMClockGetHostTimeClock())];
        if (_latest) { CFRelease(_latest); }
        _latest = (CMSampleBufferRef)CFRetain(sample);
        if (_screenshot) { CVPixelBufferRelease(_screenshot); }
        _screenshot = CVPixelBufferRetain(CMSampleBufferGetImageBuffer(sample));
        if (_presentationPending) { return; }
        _presentationPending = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self presentLatest]; });
}
- (void)presentLatest {
    CMSampleBufferRef sample = NULL;
    @synchronized (self) { sample = _latest; _latest = NULL; _presentationPending = NO; }
    if (!sample) { return; }
    if (self.closing) { CFRelease(sample); return; }
    CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
    CGSize size = CGSizeMake(CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image));
    self.videoView.videoSize = size;
    if (!self.ready) {
        self.ready = YES; self.starting = NO;
        [self.firstFrameTimer invalidate]; self.firstFrameTimer = nil;
        [self.spinner stopAnimation:nil]; self.loadingView.hidden = YES;
        CGFloat height = MIN(760, self.window.screen.visibleFrame.size.height - 100);
        [self.window setContentSize:NSMakeSize(round(height * size.width / size.height), height)];
        self.window.contentAspectRatio = NSMakeSize(size.width, size.height);
        [self refreshActionAvailability];
        [self positionActions];
        [self.window addChildWindow:self.actions ordered:NSWindowAbove];
        if (!sc_settings_toolbar_visible()) { [self.actions orderOut:nil]; }
        NSLog(@"Native iPhone first frame: %.3f s (%gx%g)", CFAbsoluteTimeGetCurrent() - self.startedAt, size.width, size.height);
        SCDevicePickerNativeMirrorShown(self.window, SCIOSDeviceSerial(self.device));
    }
    AVSampleBufferDisplayLayer *display = self.videoView.display;
    if (display.status == AVQueuedSampleBufferRenderingStatusFailed) { [display flush]; }
    if (display.readyForMoreMediaData) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
        if (CFArrayGetCount(attachments)) {
            CFMutableDictionaryRef attachment = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        }
        [display enqueueSampleBuffer:sample];
    }
    CFRelease(sample);
}
- (void)action:(NSButton *)button {
    if (button.tag == SC_TOOLBAR_ACTION_HOME) { [self.session home]; }
    else if (button.tag == SC_TOOLBAR_ACTION_BACK) { [self.session back]; }
    else if (button.tag == SC_TOOLBAR_ACTION_RECENTS) { [self.session showAppSwitcher]; }
    else if (button.tag == SC_TOOLBAR_ACTION_RECORD) { [self toggleRecording]; }
    else if (button.tag == SC_TOOLBAR_ACTION_SCREENSHOT) {
        CVPixelBufferRef buffer;
        @synchronized (self) { buffer = _screenshot ? CVPixelBufferRetain(_screenshot) : NULL; }
        if (!buffer) { return; }
        CIImage *image = [CIImage imageWithCVPixelBuffer:buffer];
        CGImageRef cgImage = [[CIContext contextWithOptions:nil] createCGImage:image fromRect:image.extent];
        CVPixelBufferRelease(buffer);
        if (cgImage) {
            NSImage *screenshot = [[NSImage alloc] initWithCGImage:cgImage size:NSZeroSize];
            CGImageRelease(cgImage);
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard writeObjects:@[screenshot]];
            [(SCIOSActionSurface *)self.actions.contentView showScreenshotSuccess];
        }
    }
}
- (void)refreshActionAvailability {
    for (NSButton *button in self.buttons) {
        BOOL navigation = button.tag == SC_TOOLBAR_ACTION_HOME || button.tag == SC_TOOLBAR_ACTION_BACK
                       || button.tag == SC_TOOLBAR_ACTION_RECENTS;
        button.enabled = self.ready && !self.closing && (!navigation || self.session.isInputReady)
            && (button.tag != SC_TOOLBAR_ACTION_RECORD || !self.savingRecording);
    }
}
- (void)updateRecordingTimer {
    if (!self.recordingTimerPanel) { return; }
    BOOL outwardLeft = NSMidX(self.actions.frame) < NSMidX(self.window.frame);
    struct sc_toolbar layout; sc_toolbar_init(&layout, true, true);
    SCMirrorUpdateRecordingTimer(self.recordingTimerPanel, self.actions,
        sc_toolbar_action_center_y(&layout, SC_TOOLBAR_ACTION_RECORD), outwardLeft,
        (uint64_t)MAX(0, CFAbsoluteTimeGetCurrent() - self.recordingStartedAt));
    if (self.actions.visible && !self.closing) { [self.recordingTimerPanel orderFront:nil]; }
    else { [self.recordingTimerPanel orderOut:nil]; }
}
- (void)recordingError:(NSError *)error {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = SCLocalized(@"Recording failed");
    alert.informativeText = error.localizedDescription ?: SCLocalized(@"Recording failed");
    [alert addButtonWithTitle:SCLocalized(@"OK")];
    if (self.window.visible) { [alert beginSheetModalForWindow:self.window completionHandler:nil]; }
    else { [alert runModal]; }
}
- (void)toggleRecording {
    if (self.recorder) { [self finishRecording]; return; }
    if (!self.ready || self.closing || self.savingRecording) { return; }
    CVPixelBufferRef buffer;
    @synchronized (self) { buffer = _screenshot ? CVPixelBufferRetain(_screenshot) : NULL; }
    if (!buffer) { return; }
    NSURL *URL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Anmir-iPhone-%@.mp4", NSUUID.UUID.UUIDString]]];
    NSError *error = nil;
    SCIOSRecorder *recorder = [[SCIOSRecorder alloc] initWithURL:URL
        size:CGSizeMake(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)) error:&error];
    @synchronized (self) { self.recorder = recorder; }
    if (!recorder) { CVPixelBufferRelease(buffer); [self recordingError:error]; return; }
    [recorder appendPixelBuffer:buffer atHostTime:CMClockGetTime(CMClockGetHostTimeClock())];
    CVPixelBufferRelease(buffer);
    [(SCIOSActionSurface *)self.actions.contentView setRecording:YES];
    SCBind(self.buttons[4], @"toolTip", @"Stop recording");
    SCBind(self.buttons[4], @"accessibilityLabel", @"Stop recording");
    self.recordingStartedAt = CFAbsoluteTimeGetCurrent();
    self.recordingTimerPanel = SCMirrorCreateRecordingTimer();
    [self.window addChildWindow:self.recordingTimerPanel ordered:NSWindowAbove];
    __weak SCIOSMirrorController *weakSelf = self;
    self.recordingTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        (void)timer; [weakSelf updateRecordingTimer];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.recordingTimer forMode:NSRunLoopCommonModes];
    [self updateRecordingTimer];
}
- (void)finishRecording {
    SCIOSRecorder *recorder;
    @synchronized (self) { recorder = self.recorder; self.recorder = nil; }
    if (!recorder) { return; }
    self.savingRecording = YES;
    [self.recordingTimer invalidate]; self.recordingTimer = nil;
    [self.window removeChildWindow:self.recordingTimerPanel];
    [self.recordingTimerPanel orderOut:nil]; self.recordingTimerPanel = nil;
    [(SCIOSActionSurface *)self.actions.contentView setRecording:NO];
    SCBind(self.buttons[4], @"toolTip", @"Record screen (no audio)");
    SCBind(self.buttons[4], @"accessibilityLabel", @"Record screen (no audio)");
    [self refreshActionAvailability];
    // Retain the controller through finalization/save even if its mirror closes.
    [recorder finishAtHostTime:CMClockGetTime(CMClockGetHostTimeClock()) completion:^(NSError *error) {
        if (error) {
            self.savingRecording = NO; [self refreshActionAvailability]; [self recordingError:error];
        } else { [self saveRecordingAtURL:recorder.URL]; }
    }];
}
- (void)saveRecordingAtURL:(NSURL *)source {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypeMPEG4Movie]; panel.canCreateDirectories = YES;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    panel.nameFieldStringValue = [NSString stringWithFormat:@"Anmir-iPhone-%@.mp4", [formatter stringFromDate:NSDate.date]];
    NSString *directory = [NSUserDefaults.standardUserDefaults stringForKey:@"SCIOSRecordingDirectory"];
    if (directory) { panel.directoryURL = [NSURL fileURLWithPath:directory isDirectory:YES]; }
    void (^completed)(NSModalResponse) = ^(NSModalResponse response) {
        if (response != NSModalResponseOK) { [self retryRecordingSave:source error:nil]; return; }
        NSURL *destination = panel.URL;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSFileManager *files = NSFileManager.defaultManager;
            NSURL *staging = [[destination URLByDeletingLastPathComponent] URLByAppendingPathComponent:
                [NSString stringWithFormat:@".Anmir-%@.mp4", NSUUID.UUID.UUIDString]];
            NSError *error = nil;
            BOOL saved = [files copyItemAtURL:source toURL:staging error:&error];
            if (saved) {
                if ([files fileExistsAtPath:destination.path]) {
                    saved = [files replaceItemAtURL:destination withItemAtURL:staging
                        backupItemName:nil options:0 resultingItemURL:nil error:&error];
                } else { saved = [files moveItemAtURL:staging toURL:destination error:&error]; }
            }
            [files removeItemAtURL:staging error:nil];
            if (saved) { [files removeItemAtURL:source error:nil]; }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!saved) { [self retryRecordingSave:source error:error]; return; }
                [NSUserDefaults.standardUserDefaults setObject:destination.URLByDeletingLastPathComponent.path
                    forKey:@"SCIOSRecordingDirectory"];
                self.savingRecording = NO; [self refreshActionAvailability];
                [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[destination]];
            });
        });
    };
    if (self.window.visible) { [panel beginSheetModalForWindow:self.window completionHandler:completed]; }
    else { [panel beginWithCompletionHandler:completed]; }
}
- (void)retryRecordingSave:(NSURL *)source error:(NSError *)error {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = SCLocalized(@"Discard recording?");
    alert.informativeText = SCLocalized(error
        ? @"Saving failed. Return to choose another location, or discard the temporary recording."
        : @"The recording has not been saved. Return to the save dialog, or discard it permanently.");
    [alert addButtonWithTitle:SCLocalized(@"Return")];
    [alert addButtonWithTitle:SCLocalized(@"Discard")];
    void (^completed)(NSModalResponse) = ^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) { [self saveRecordingAtURL:source]; }
        else {
            [NSFileManager.defaultManager removeItemAtURL:source error:nil];
            self.savingRecording = NO; [self refreshActionAvailability];
        }
    };
    if (self.window.visible) { [alert beginSheetModalForWindow:self.window completionHandler:completed]; }
    else { completed([alert runModal]); }
}
- (void)showError:(NSString *)message {
    if (self.closing) { return; }
    self.starting = NO; self.ready = NO;
    [self finishRecording];
    self.session.frame = nil;
    [self.session stop]; self.session = nil;
    @synchronized (self) { if (_latest) { CFRelease(_latest); _latest = NULL; } }
    [self.videoView.display flushAndRemoveImage];
    [self.firstFrameTimer invalidate]; self.firstFrameTimer = nil;
    [self.spinner stopAnimation:nil]; self.loadingView.hidden = NO;
    self.statusLabel.stringValue = message;
    for (NSButton *button in self.buttons) { button.enabled = NO; }
}
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    @synchronized (self) { self.closing = YES; }
    [self finishRecording];
    [self.firstFrameTimer invalidate]; self.firstFrameTimer = nil;
    [self.session stop]; self.session = nil;
    [self.videoView.display flushAndRemoveImage];
    [self.window removeChildWindow:self.actions]; [self.actions orderOut:nil];
    void (^closed)(void) = self.closed; self.closed = nil; if (closed) { closed(); }
}
- (void)close { [self.window close]; }
@end
