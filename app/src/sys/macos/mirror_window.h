#import <AppKit/AppKit.h>

// Common titlebar configuration for both SDL/Android and AppKit/iOS windows.
void SCMirrorWindowConfigure(NSWindow *window);
void SCMirrorWindowSetTitle(NSWindow *window, NSString *primary, NSString *secondary);
void SCMirrorWindowRefreshAppearance(NSWindow *window);

// Same recording timer bubble for the SDL and native mirror hosts.
NSPanel *SCMirrorCreateRecordingTimer(void);
void SCMirrorUpdateRecordingTimer(NSPanel *panel, NSWindow *toolbar,
                                 float anchorY, BOOL outwardLeft,
                                 uint64_t elapsedSeconds);
