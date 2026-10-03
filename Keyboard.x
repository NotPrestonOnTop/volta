// Volta - keyboard look: always dark or always light, and a color wash over
// the keyboard's background. Loaded into SpringBoard and every app, because
// each app draws its own keyboard.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import "VLTShared.h"

static BOOL gIsSpringBoard;
static NSInteger gMode;         // 0 system, 1 always dark, 2 always light
static UIColor *gTint;
static CGFloat gStrength;
static BOOL gRainbow;

static void VLTLoadKeyboard(void) {
    NSDictionary *s = gIsSpringBoard ? VLTStatusDict(VLTCopyPrefs()) : [NSDictionary dictionaryWithContentsOfFile:VLT_STATUS_PATH];
    if (![s isKindOfClass:[NSDictionary class]]) s = @{};
    BOOL on = VLTBool(s, @"enabled", YES) && VLTBool(s, @"kbOn", NO);
    gMode = on ? (NSInteger)VLTNum(s, @"kbMode", 0) : 0;
    if (gMode < 0 || gMode > 2) gMode = 0;
    gTint = on ? VLTColorFromHex(s[@"kbTint"]) : nil;
    gStrength = fmin(fmax(VLTNum(s, @"kbTintStrength", 40) / 100.0, 0), 1);
    gRainbow = on && VLTBool(s, @"kbRainbow", NO);
}

static NSHashTable *VLTBackdrops(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static const void *kWash = &kWash;

// backdrop: the blurred panel behind the keys (a UIVisualEffectView). The
// wash goes in its content view, which is where such views accept subviews.
static void VLTApplyWash(UIVisualEffectView *backdrop) {
    if (![backdrop isKindOfClass:[UIVisualEffectView class]]) return;
    UIView *wash = objc_getAssociatedObject(backdrop, kWash);
    BOOL wanted = (gRainbow || gTint) && gStrength > 0.005;
    if (!wanted) {
        if (wash) {
            [wash removeFromSuperview];
            objc_setAssociatedObject(backdrop, kWash, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (!wash) {
        wash = [[UIView alloc] initWithFrame:backdrop.contentView.bounds];
        wash.userInteractionEnabled = NO;
        wash.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(backdrop, kWash, wash, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (wash.superview != backdrop.contentView) [backdrop.contentView addSubview:wash];
    wash.frame = backdrop.contentView.bounds;

    BOOL moving = gRainbow && !UIAccessibilityIsReduceMotionEnabled();
    if (moving) {
        if (![wash.layer animationForKey:@"vltRainbow"]) {
            NSMutableArray *colors = [NSMutableArray array];
            for (int i = 0; i <= 6; i++) [colors addObject:(id)[UIColor colorWithHue:(i % 6) / 6.0 saturation:0.8 brightness:1 alpha:gStrength].CGColor];
            CAKeyframeAnimation *cycle = [CAKeyframeAnimation animationWithKeyPath:@"backgroundColor"];
            cycle.values = colors;
            cycle.duration = 9;
            cycle.repeatCount = HUGE_VALF;
            cycle.removedOnCompletion = NO;
            [wash.layer addAnimation:cycle forKey:@"vltRainbow"];
        }
    } else {
        [wash.layer removeAnimationForKey:@"vltRainbow"];
    }
    UIColor *still = gTint ?: [UIColor colorWithHue:0.72 saturation:0.8 brightness:1 alpha:1];
    wash.backgroundColor = [still colorWithAlphaComponent:gStrength * CGColorGetAlpha(still.CGColor)];
}

%group KeyboardLook

%hook UIKBRenderConfig

- (BOOL)lightKeyboard {
    if (gMode == 1) return NO;
    if (gMode == 2) return YES;
    return %orig;
}

// Some of the keyboard reads the stored value directly, so set that too.
- (void)setLightKeyboard:(BOOL)light {
    if (gMode == 1) light = NO;
    else if (gMode == 2) light = YES;
    %orig(light);
}

%end

%hook UIKBBackdropView

- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window) return;
    [VLTBackdrops() addObject:self];
    VLTApplyWash((UIVisualEffectView *)self);   // also restarts the color cycle, which stops while off screen
}

%end

%end // group KeyboardLook

static void VLTKeyboardChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VLTLoadKeyboard();
        for (UIVisualEffectView *backdrop in VLTBackdrops().allObjects) {
            [((UIView *)objc_getAssociatedObject(backdrop, kWash)).layer removeAnimationForKey:@"vltRainbow"];   // pick up a new strength
            VLTApplyWash(backdrop);
        }
    });
}

%ctor {
    @autoreleasepool {
        NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
        NSString *executable = [NSBundle mainBundle].executablePath ?: @"";
        gIsSpringBoard = [bundleID isEqualToString:@"com.apple.springboard"];
        if (!gIsSpringBoard) {   // same rule as the battery hooks: real apps only
            if (!bundleID) return;
            if (![executable containsString:@"/Application"]) return;
            if ([executable containsString:@".appex/"]) return;
        }
        VLTLoadKeyboard();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, VLTKeyboardChanged,
                                        gIsSpringBoard ? CFSTR(VLT_NOTIFY_PREFS) : CFSTR(VLT_NOTIFY_APPLY), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        %init(KeyboardLook);
        // The color cycle is dropped while an app is in the background; start it again.
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            if (!gRainbow) return;
            for (UIVisualEffectView *backdrop in VLTBackdrops().allObjects) VLTApplyWash(backdrop);
        }];
    }
}
