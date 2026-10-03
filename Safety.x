// Volta - Safety: keeps iOS's software-update services switched off, so an
// update cannot install itself and take the jailbreak with it. (Crash Guard,
// the other half of the Safety page, is in VLTShared.h.) SpringBoard only.
//
// The switching is done by the small root tool that Voltweaks also uses
// (voltweakshelper/main.c): "ota-block", "ota-allow", "ota-status".
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <notify.h>
#import <sys/wait.h>
#import "VLTShared.h"

extern char **environ;

static dispatch_queue_t VLTSafetyQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.notpreston.volta.safety", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

// Exit code of the helper, or -1 if it could not be started. Never on the main thread.
static int VLTRunHelper(const char *command) {
    const char *tool = "/var/jb/usr/libexec/voltweaks-helper";
    if (access(tool, X_OK) != 0) return -1;
    char *const arguments[] = {(char *)tool, (char *)command, NULL};
    pid_t pid = 0;
    if (posix_spawn(&pid, tool, NULL, NULL, arguments, environ) != 0) return -1;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static int VLTStateFromStatus(int statusCode) {
    switch (statusCode) {
        case 0:  return VLTOtaBlocked;
        case 1:  return VLTOtaAllowed;
        case 3:  return VLTOtaNoRoot;
        case 6:  return VLTOtaNoTool;
        default: return VLTOtaFailed;
    }
}

// Brings the device in line with the "Block iOS Updates" switch and records
// what was found, for the Safety page.
static void VLTSyncUpdates(BOOL atLaunch) {
    id setting = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("safeBlockOTA"), CFSTR(VLT_DOMAIN)));
    BOOL wanted = [setting isKindOfClass:[NSNumber class]] && [setting boolValue];
    NSNumber *lastWanted = VLTGuardGet(@"otaWanted");
    BOOL changed = ![lastWanted isKindOfClass:[NSNumber class]] || lastWanted.boolValue != wanted;
    // Nothing to do if the switch has never been touched, or nothing changed since
    // it was last applied (at launch a blocked device is still checked once).
    if (!changed && !(atLaunch && wanted)) return;
    if (changed && !wanted && ![lastWanted isKindOfClass:[NSNumber class]]) return;

    dispatch_async(VLTSafetyQueue(), ^{
        int state = VLTStateFromStatus(VLTRunHelper("ota-status"));
        BOOL inLine = (wanted && state == VLTOtaBlocked) || (!wanted && state == VLTOtaAllowed);
        if (!inLine && state != VLTOtaNoRoot && state != VLTOtaNoTool) {
            int code = VLTRunHelper(wanted ? "ota-block" : "ota-allow");
            state = code == 0 ? VLTStateFromStatus(VLTRunHelper("ota-status")) : VLTStateFromStatus(code == 3 || code == 6 ? code : 5);
            if ((wanted && state == VLTOtaAllowed) || (!wanted && state == VLTOtaBlocked)) state = VLTOtaFailed;   // it said done, but nothing changed
        }
        VLTGuardSet(@"otaWanted", @(wanted));
        VLTGuardSet(@"otaState", @(state));
        VLTGuardSet(@"otaChecked", [NSDate date]);
        notify_post(VLT_NOTIFY_SAFETY);
    });
}

static void VLTSafetyPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ VLTSyncUpdates(NO); });
}

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, VLTSafetyPrefsChanged,
                                        CFSTR(VLT_NOTIFY_PREFS), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        // Once things have settled after launch.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ VLTSyncUpdates(YES); });
    }
}
