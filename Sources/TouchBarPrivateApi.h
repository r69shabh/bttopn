#ifndef TouchBarPrivateApi_h
#define TouchBarPrivateApi_h

#import <AppKit/AppKit.h>

// DFRFoundation private functions
extern void DFRElementSetControlStripPresenceForIdentifier(
    NSTouchBarItemIdentifier _Nonnull identifier, BOOL presence);
extern void DFRSystemModalShowsCloseBoxWhenFrontMost(BOOL show);

// Private methods on NSTouchBar for system-modal presentation
@interface NSTouchBar (PrivateMethods)
+ (void)presentSystemModalTouchBar:(NSTouchBar * _Nonnull)touchBar
                          placement:(long long)placement
            systemTrayItemIdentifier:(NSTouchBarItemIdentifier _Nullable)identifier;
+ (void)dismissSystemModalTouchBar:(NSTouchBar * _Nonnull)touchBar;
+ (void)minimizeSystemModalTouchBar:(NSTouchBar * _Nonnull)touchBar;
@end

// Private methods on NSTouchBarItem for system tray
@interface NSTouchBarItem (PrivateMethods)
+ (void)addSystemTrayItem:(NSTouchBarItem * _Nonnull)item;
+ (void)removeSystemTrayItem:(NSTouchBarItem * _Nonnull)item;
@end

#endif
