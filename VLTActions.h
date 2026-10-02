//
//  VLTActions.h
//  What a custom Control Center button can do. Shared by the tweak (which
//  performs the action) and the Settings pane (which lets you pick one).
//
//  A button is stored as a dictionary:
//    @"t" title   @"s" SF Symbol name   @"a" action number   @"v" target (bundle id, URL or shortcut name)
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, VLTAction) {
    VLTActionOpenApp     = 1,   // v = bundle identifier
    VLTActionOpenURL     = 2,   // v = URL
    VLTActionShortcut    = 3,   // v = shortcut name
    VLTActionRespring    = 4,
    VLTActionLock        = 5,
    VLTActionDarkMode    = 6,   // toggle
    VLTActionLowPower    = 7,   // toggle
    VLTActionVoltaPrefs  = 8,
    VLTActionRotation    = 9,   // toggle orientation lock
};

#define VLT_MAX_BUTTONS 8

static inline NSArray<NSNumber *> *VLTAllActions(void) {
    return @[@(VLTActionOpenApp), @(VLTActionOpenURL), @(VLTActionShortcut), @(VLTActionDarkMode), @(VLTActionLowPower),
             @(VLTActionRotation), @(VLTActionLock), @(VLTActionRespring), @(VLTActionVoltaPrefs)];
}

static inline NSString *VLTActionName(NSInteger action) {
    switch (action) {
        case VLTActionOpenApp:    return @"Open App";
        case VLTActionOpenURL:    return @"Open Link";
        case VLTActionShortcut:   return @"Run Shortcut";
        case VLTActionRespring:   return @"Respring";
        case VLTActionLock:       return @"Lock Device";
        case VLTActionDarkMode:   return @"Toggle Dark Mode";
        case VLTActionLowPower:   return @"Toggle Low Power Mode";
        case VLTActionVoltaPrefs: return @"Open Volta Settings";
        case VLTActionRotation:   return @"Toggle Orientation Lock";
        default:                  return @"Nothing";
    }
}

static inline NSString *VLTActionDefaultSymbol(NSInteger action) {
    switch (action) {
        case VLTActionOpenApp:    return @"app.fill";
        case VLTActionOpenURL:    return @"link";
        case VLTActionShortcut:   return @"bolt.fill";
        case VLTActionRespring:   return @"arrow.clockwise";
        case VLTActionLock:       return @"lock.fill";
        case VLTActionDarkMode:   return @"moon.fill";
        case VLTActionLowPower:   return @"battery.25";
        case VLTActionVoltaPrefs: return @"slider.horizontal.3";
        case VLTActionRotation:   return @"lock.rotation";
        default:                  return @"circle";
    }
}

// Does this action need something typed or picked in the "target" field?
static inline BOOL VLTActionNeedsTarget(NSInteger action) {
    return action == VLTActionOpenApp || action == VLTActionOpenURL || action == VLTActionShortcut;
}
