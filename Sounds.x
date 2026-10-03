// Volta - system sounds: a sound when the device locks, unlocks, is plugged
// in or unplugged, and a tick for each volume step. The sounds are made in
// code (VLTSynth.h) and played as system sounds, so they follow the mute
// switch and mix with whatever an app is playing. SpringBoard only.
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import "VLTShared.h"
#import "VLTSynth.h"

static BOOL gSoundsOn;
static NSInteger gPack;
static int gLoudStep = 7;                 // 1 ... 10
static BOOL gEventOn[VLTSoundCount];

static void VLTLoadSoundPrefs(void) {
    NSDictionary *p = VLTCopyPrefs();
    gSoundsOn = VLTBool(p, @"enabled", YES) && VLTBool(p, @"sndOn", NO);
    gPack = (NSInteger)VLTNum(p, @"sndPack", 0);
    if (gPack < 0 || gPack >= VLTPackCount) gPack = 0;
    gLoudStep = (int)lround(fmin(fmax(VLTNum(p, @"sndLoudness", 70), 10), 100) / 10.0);
    NSArray *keys = @[@"sndLock", @"sndUnlock", @"sndPlug", @"sndUnplug", @"sndTick"];
    for (int i = 0; i < VLTSoundCount; i++) gEventOn[i] = VLTBool(p, keys[i], i != VLTSoundTick);   // the tick is opt-in
}

// Each sound is written to a small file once per pack and loudness, then kept.
static void VLTPlaySound(int event, BOOL evenIfOff) {
    if (event < 0 || event >= VLTSoundCount) return;
    if (!evenIfOff && (!gSoundsOn || !gEventOn[event])) return;
    static NSMutableDictionary<NSString *, NSNumber *> *sounds;
    if (!sounds) sounds = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%ld-%d-%d", (long)gPack, event, gLoudStep];
    NSNumber *known = sounds[key];
    if (!known) {
        SystemSoundID sound = 0;
        size_t length = 0;
        uint8_t *bytes = vlt_synth_wav((int)gPack, event, gLoudStep / 10.0, &length);
        if (bytes) {
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"volta-sound-%@.wav", key]];
            if ([[NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES] writeToFile:path atomically:YES])
                AudioServicesCreateSystemSoundID((__bridge CFURLRef)[NSURL fileURLWithPath:path], &sound);
        }
        known = @(sound);   // 0 is remembered too, so a failure is not retried on every event
        sounds[key] = known;
    }
    if (known.unsignedIntValue) AudioServicesPlaySystemSound(known.unsignedIntValue);
}

%group Sounds

%hook SBVolumeControl

// Called for each press of a volume button (see Popups.x, which draws the indicator).
- (void)_presentVolumeHUDWithVolume:(float)volume {
    %orig;
    if (!gSoundsOn || !gEventOn[VLTSoundTick]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        static CFTimeInterval last;
        CFTimeInterval now = CACurrentMediaTime();
        if (now - last < 0.08) return;   // holding the button down
        last = now;
        VLTPlaySound(VLTSoundTick, NO);
    });
}

%end

%end // group Sounds

static void VLTSoundPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ VLTLoadSoundPrefs(); });
}

// The Preview button in Settings: every sound of the chosen pack, one after another.
static void VLTSoundPreview(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VLTLoadSoundPrefs();
        for (int event = 0; event < VLTSoundCount; event++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(event * 0.85 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ VLTPlaySound(event, YES); });
        }
    });
}

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        VLTLoadSoundPrefs();
        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(darwin, NULL, VLTSoundPrefsChanged, CFSTR(VLT_NOTIFY_PREFS), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(darwin, NULL, VLTSoundPreview, CFSTR(VLT_DOMAIN "/previewSounds"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        %init(Sounds);

        // Locked <-> unlocked. The first reading only sets the starting point.
        static int lockToken;
        static int64_t wasLocked = -1;
        notify_register_dispatch("com.apple.springboard.lockstate", &lockToken, dispatch_get_main_queue(), ^(int token) {
            uint64_t locked = 0;
            notify_get_state(token, &locked);
            if (wasLocked >= 0 && (int64_t)(locked != 0) != wasLocked) VLTPlaySound(locked ? VLTSoundLock : VLTSoundUnlock, NO);
            wasLocked = locked != 0;
        });
        uint64_t lockedNow = 0;
        if (notify_get_state(lockToken, &lockedNow) == NOTIFY_STATUS_OK) wasLocked = lockedNow != 0;

        // Plugged in / unplugged.
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIDevice currentDevice].batteryMonitoringEnabled = YES;
            __block UIDeviceBatteryState last = [UIDevice currentDevice].batteryState;
            [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceBatteryStateDidChangeNotification object:nil queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                UIDeviceBatteryState state = [UIDevice currentDevice].batteryState;
                BOOL was = last == UIDeviceBatteryStateCharging || last == UIDeviceBatteryStateFull;
                BOOL is = state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull;
                if (last != UIDeviceBatteryStateUnknown && state != UIDeviceBatteryStateUnknown && is != was) VLTPlaySound(is ? VLTSoundPlug : VLTSoundUnplug, NO);
                last = state;
            }];
        });
    }
}
