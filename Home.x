//
//  Volta - Home.x  (SpringBoard only)
//
//  Dock styling and animated wallpapers. Built as its own library so that the
//  video framework is loaded into SpringBoard alone, not into every app.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "VLTShared.h"
#import "VLTScene.h"

@interface UIView (VLTHomePrivate)
- (void)_setContinuousCornerRadius:(CGFloat)radius;
- (CGFloat)_continuousCornerRadius;
@end

#pragma mark - Settings

static BOOL     gOn;
static BOOL     gDockOn;
static CGFloat  gDockOpacity = 1;
static UIColor *gDockTint;
static CGFloat  gDockTintStrength;
static BOOL     gDockRadiusOn;
static CGFloat  gDockRadius;
static CGFloat  gDockBorderWidth;
static UIColor *gDockBorderColor;
static BOOL     gDockHideDivider;

static NSInteger gWallKind;
static NSInteger gWallWhere;      // 0 both, 1 home screen, 2 lock screen
static BOOL      gWallKeep;
static CGFloat   gWallSpeed = 1;
static CGFloat   gWallDim;
static NSString *gWallVideoPath;
static NSString *gWallTendiesPath;
static CGFloat   gWallVolume;      // 0 ... 0.40
static NSString *gWallAudioPath;
static NSInteger gWallFit;         // 0 auto, 1 fill, 2 fit, 3 stretch
static CGFloat   gWallZoom = 1;
static __weak VLTSceneView *gSoundScene;   // only one wallpaper view may make sound
static NSInteger gWallGen;

static inline CGFloat VLTClamp(CGFloat x, CGFloat lo, CGFloat hi) { return fmin(fmax(x, lo), hi); }
static inline BOOL VLTDockActive(void) { return gOn && gDockOn; }
static inline BOOL VLTWallActive(void) { return gOn && gWallKind != VLTSceneNone; }

static void VLTLoadHomePrefs(void) {
    NSDictionary *p = VLTCopyPrefs();
    gOn               = VLTBool(p, @"enabled", YES);

    gDockOn           = VLTBool(p, @"dockEnabled", YES);
    gDockOpacity      = VLTClamp(VLTNum(p, @"dockOpacity", 100) / 100.0, 0, 1);
    gDockTint         = VLTColorFromHex(p[@"dockTint"]);
    gDockTintStrength = VLTClamp(VLTNum(p, @"dockTintStrength", 40) / 100.0, 0, 1);
    gDockRadiusOn     = VLTBool(p, @"dockRadiusOn", NO);
    gDockRadius       = VLTClamp(VLTNum(p, @"dockRadius", 30), 0, 40);
    gDockBorderWidth  = VLTClamp(VLTNum(p, @"dockBorderWidth", 0), 0, 4);
    gDockBorderColor  = VLTColorFromHex(p[@"dockBorderColor"]);
    gDockHideDivider  = VLTBool(p, @"dockHideDivider", NO);

    gWallKind      = (NSInteger)VLTNum(p, @"wallKind", VLTSceneNone);
    gWallWhere     = (NSInteger)VLTNum(p, @"wallWhere", 0);
    gWallKeep      = VLTBool(p, @"wallKeep", NO);
    gWallSpeed     = VLTClamp(VLTNum(p, @"wallSpeed", 100) / 100.0, 0.5, 2);
    gWallDim       = VLTClamp(VLTNum(p, @"wallDim", 0) / 100.0, 0, 0.8);
    gWallVideoPath = VLTStr(p, @"wallVideoPath");
    gWallGen       = (NSInteger)VLTNum(p, @"wallGen", 0);
    gWallTendiesPath = VLTStr(p, @"wallTendiesPath");
    gWallAudioPath = VLTStr(p, @"wallAudioPath");
    gWallFit  = (NSInteger)VLTNum(p, @"wallFit", 0);
    gWallZoom = VLTClamp(VLTNum(p, @"wallZoom", 100) / 100.0, 0.5, 2);
    // The slider stops at 40; clamp again here so no stored value can exceed it.
    gWallVolume = VLTClamp(VLTNum(p, @"wallVolume", 0) / 100.0, 0, VLT_MAX_WALLPAPER_VOLUME);
    if (gWallKind == VLTSceneVideo && !gWallVideoPath.length) gWallKind = VLTSceneNone;
    if (gWallKind == VLTSceneTendies && !gWallTendiesPath.length) gWallKind = VLTSceneNone;
}

// KVC lookup that never throws; finds a property or a "_name" ivar.
static UIView *VLTHomeViewForKey(id object, NSString *key) {
    id value = nil;
    @try { value = [object valueForKey:key]; } @catch (__unused NSException *e) {}
    return [value isKindOfClass:[UIView class]] ? value : nil;
}

static void VLTHomeSetRadius(UIView *view, CGFloat radius) {
    if ([view respondsToSelector:@selector(_setContinuousCornerRadius:)]) {
        [view _setContinuousCornerRadius:radius];
    } else {
        view.layer.cornerRadius = radius;
        view.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

static NSHashTable *VLTWeakTable(void) { return [NSHashTable weakObjectsHashTable]; }

#pragma mark - Dock

static const void *kDockOverlay   = &kDockOverlay;
static const void *kDockTouched   = &kDockTouched;
static const void *kDockRealAlpha = &kDockRealAlpha;
static const void *kDockLastOpacity = &kDockLastOpacity;
static const void *kDividerMask   = &kDividerMask;
static BOOL gDockApplying;

static NSHashTable *VLTDocks(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = VLTWeakTable(); });
    return table;
}

static CGFloat VLTCurrentRadius(UIView *host, UIView *background) {
    @try {   // iPad floating dock knows its own radius
        id value = [host valueForKey:@"currentContinuousCornerRadius"];
        if ([value respondsToSelector:@selector(doubleValue)] && [value doubleValue] > 0) return [value doubleValue];
    } @catch (__unused NSException *e) {}
    if ([background respondsToSelector:@selector(_continuousCornerRadius)] && [background _continuousCornerRadius] > 0)
        return [background _continuousCornerRadius];
    return background.layer.cornerRadius;
}

// host: SBDockView (iPhone) or SBFloatingDockPlatterView (iPad).
// The frosted background is restyled; a clear overlay on top of it carries
// the tint and the border so both follow the dock's rounded shape.
static void VLTApplyDock(UIView *host) {
    if (![host isKindOfClass:[UIView class]]) return;
    [VLTDocks() addObject:host];
    BOOL active = VLTDockActive();
    BOOL touched = objc_getAssociatedObject(host, kDockTouched) != nil;
    if (!active && !touched) return;

    UIView *background = VLTHomeViewForKey(host, @"backgroundView");
    UIView *shadow = VLTHomeViewForKey(host, @"shadowView");
    UIView *overlay = objc_getAssociatedObject(host, kDockOverlay);
    BOOL isPhoneDock = [host respondsToSelector:NSSelectorFromString(@"setBackgroundAlpha:")];

    // Opacity. The iPhone dock fades its own background during transitions,
    // so there the value is multiplied in the setBackgroundAlpha: hook.
    CGFloat opacity = active ? gDockOpacity : 1;
    if (isPhoneDock) {
        // Replay the last real value through the hook, but only when our
        // multiplier changed, so layout never triggers itself.
        NSNumber *last = objc_getAssociatedObject(host, kDockLastOpacity);
        if (!last || fabs(last.doubleValue - opacity) > 0.001) {
            objc_setAssociatedObject(host, kDockLastOpacity, @(opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSNumber *real = objc_getAssociatedObject(host, kDockRealAlpha);
            gDockApplying = YES;
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(host, NSSelectorFromString(@"setBackgroundAlpha:"), real ? real.doubleValue : 1.0);
            gDockApplying = NO;
        }
    } else if (background) {
        background.alpha = opacity;
    }
    if (shadow) shadow.hidden = active && opacity < 0.05;

    // Corner radius.
    CGFloat radius = VLTCurrentRadius(host, background);
    if (active && gDockRadiusOn && background) {
        radius = MIN(gDockRadius, MIN(background.bounds.size.width, background.bounds.size.height) / 2);
        VLTHomeSetRadius(background, radius);
    } else if (!active && touched && background && radius > 0) {
        VLTHomeSetRadius(background, radius);
    }

    // Tint and border.
    BOOL wantsTint = active && gDockTint && gDockTintStrength > 0.001;
    BOOL wantsBorder = active && gDockBorderColor && gDockBorderWidth > 0.01;
    if ((wantsTint || wantsBorder) && background) {
        if (!overlay) {
            overlay = [[UIView alloc] initWithFrame:CGRectZero];
            overlay.userInteractionEnabled = NO;
            objc_setAssociatedObject(host, kDockOverlay, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        UIView *parent = background.superview ?: host;
        if (overlay.superview != parent) [parent insertSubview:overlay aboveSubview:background];
        overlay.frame = background.frame;
        overlay.backgroundColor = wantsTint ? [gDockTint colorWithAlphaComponent:gDockTintStrength * CGColorGetAlpha(gDockTint.CGColor)]
                                            : [UIColor clearColor];
        overlay.layer.borderWidth = wantsBorder ? gDockBorderWidth : 0;
        overlay.layer.borderColor = wantsBorder ? gDockBorderColor.CGColor : NULL;
        VLTHomeSetRadius(overlay, radius);
        overlay.clipsToBounds = YES;
    } else if (overlay) {
        [overlay removeFromSuperview];
        objc_setAssociatedObject(host, kDockOverlay, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    objc_setAssociatedObject(host, kDockTouched, active ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// iPad: the thin line between pinned apps and recent apps.
static void VLTApplyDivider(UIView *dock) {
    [VLTDocks() addObject:dock];
    UIView *divider = VLTHomeViewForKey(dock, @"dividerView");
    if (!divider) return;
    CALayer *ours = objc_getAssociatedObject(divider, kDividerMask);
    if (VLTDockActive() && gDockHideDivider) {
        if (!divider.layer.mask) {
            CALayer *mask = [CALayer layer];   // empty mask = nothing drawn
            divider.layer.mask = mask;
            objc_setAssociatedObject(divider, kDividerMask, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else if (ours) {
        if (divider.layer.mask == ours) divider.layer.mask = nil;
        objc_setAssociatedObject(divider, kDividerMask, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void VLTRefreshDocks(void) {
    Class floating = NSClassFromString(@"SBFloatingDockView");
    for (UIView *view in VLTDocks().allObjects) {
        if (floating && [view isKindOfClass:floating]) VLTApplyDivider(view);
        else VLTApplyDock(view);
        [view setNeedsLayout];
    }
}

%group Dock

// iPhone dock
%hook SBDockView

- (void)layoutSubviews {
    %orig;
    VLTApplyDock((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    VLTApplyDock((UIView *)self);
}

- (void)setBackgroundAlpha:(CGFloat)alpha {
    if (!gDockApplying) objc_setAssociatedObject(self, kDockRealAlpha, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (VLTDockActive()) alpha *= gDockOpacity;
    %orig(alpha);
}

%end

// iPad floating dock: the rounded platter behind the icons
%hook SBFloatingDockPlatterView

- (void)layoutSubviews {
    %orig;
    VLTApplyDock((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    VLTApplyDock((UIView *)self);
}

- (CGFloat)maximumContinuousCornerRadius {
    CGFloat radius = %orig;
    return (VLTDockActive() && gDockRadiusOn) ? MIN(radius, gDockRadius) : radius;
}

%end

%hook SBFloatingDockView

- (void)layoutSubviews {
    %orig;
    VLTApplyDivider((UIView *)self);
}

%end

%end // group Dock

#pragma mark - Animated wallpaper

static const void *kWallScene  = &kWallScene;
static const void *kWallNoRast = &kWallNoRast;
static BOOL gScreenOn = YES;
static BOOL gPlaying = YES;
static NSTimer *gVisibilityTimer;

static NSHashTable *VLTWallpaperViews(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = VLTWeakTable(); });
    return table;
}

static BOOL VLTDeviceLocked(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ notify_register_check("com.apple.springboard.lockstate", &token); });
    uint64_t state = 0;
    if (token >= 0) notify_get_state(token, &state);
    return state != 0;
}

// The wallpaper is only visible on the Lock Screen or when no app is open.
static BOOL VLTWallpaperVisible(void) {
    if (!gScreenOn) return NO;
    if (VLTDeviceLocked()) return YES;
    UIApplication *springBoard = [UIApplication sharedApplication];
    SEL frontmost = NSSelectorFromString(@"_accessibilityFrontMostApplication");
    if (![springBoard respondsToSelector:frontmost]) return YES;
    return ((id (*)(id, SEL))objc_msgSend)(springBoard, frontmost) == nil;
}

static void VLTUpdatePlayback(void) {
    gPlaying = VLTWallpaperVisible();
    // .tendies wallpapers animate between these states on their own.
    NSString *state = !gScreenOn ? @"Sleep" : (VLTDeviceLocked() ? @"Locked" : @"Unlock");
    for (UIView *wallpaper in VLTWallpaperViews().allObjects) {
        VLTSceneView *scene = objc_getAssociatedObject(wallpaper, kWallScene);
        [scene setWallpaperState:state];
        scene.paused = !gPlaying;
    }
}

// Checks twice a second, and only while a scene exists and the screen is on.
static void VLTUpdateVisibilityTimer(void) {
    BOOL anyScene = NO;
    for (UIView *wallpaper in VLTWallpaperViews().allObjects) {
        if (objc_getAssociatedObject(wallpaper, kWallScene)) { anyScene = YES; break; }
    }
    BOOL wanted = anyScene && gScreenOn;
    if (wanted && !gVisibilityTimer) {
        gVisibilityTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { VLTUpdatePlayback(); }];
        gVisibilityTimer.tolerance = 0.2;
    } else if (!wanted && gVisibilityTimer) {
        [gVisibilityTimer invalidate];
        gVisibilityTimer = nil;
    }
    VLTUpdatePlayback();
}

static void VLTSetRasterizationBlocked(UIView *wallpaper, BOOL blocked) {
    // A rasterized wallpaper is a frozen picture; ask SpringBoard not to do
    // that while a scene is showing.
    BOOL isBlocked = objc_getAssociatedObject(wallpaper, kWallNoRast) != nil;
    if (blocked == isBlocked) return;
    SEL sel = NSSelectorFromString(blocked ? @"_beginDisallowRasterizationBlock" : @"_endDisallowRasterizationBlock");
    if ([wallpaper respondsToSelector:sel]) ((void (*)(id, SEL))objc_msgSend)(wallpaper, sel);
    objc_setAssociatedObject(wallpaper, kWallNoRast, blocked ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// wallpaper: an SBFWallpaperView. variant 0 = Lock Screen, 1 = Home Screen.
static void VLTApplyWallpaper(UIView *wallpaper) {
    if (![wallpaper isKindOfClass:[UIView class]]) return;
    [VLTWallpaperViews() addObject:wallpaper];

    BOOL wanted = VLTWallActive();
    if (wanted && gWallWhere != 0) {
        NSInteger variant = -1;
        BOOL shared = NO;
        @try {
            variant = [[wallpaper valueForKey:@"variant"] integerValue];
            shared = [[wallpaper valueForKey:@"sharesContentsAcrossVariants"] boolValue];
        } @catch (__unused NSException *e) {}
        // One wallpaper used for both screens cannot be split.
        if (!shared && variant >= 0) wanted = (gWallWhere == 1) ? (variant == 1) : (variant == 0);
    }

    VLTSceneView *scene = objc_getAssociatedObject(wallpaper, kWallScene);
    if (!wanted) {
        if (scene) {
            [scene removeFromSuperview];
            objc_setAssociatedObject(wallpaper, kWallScene, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            VLTSetRasterizationBlocked(wallpaper, NO);
        }
        return;
    }
    if (!scene) {
        scene = [[VLTSceneView alloc] initWithFrame:wallpaper.bounds];
        scene.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        scene.paused = !gPlaying;
        objc_setAssociatedObject(wallpaper, kWallScene, scene, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        VLTSetRasterizationBlocked(wallpaper, YES);
    }
    if (scene.superview != wallpaper) [wallpaper addSubview:scene];
    else if (wallpaper.subviews.lastObject != scene) [wallpaper bringSubviewToFront:scene];
    scene.frame = wallpaper.bounds;
    [scene configureWithKind:gWallKind keepsWallpaper:gWallKeep speed:gWallSpeed dim:gWallDim
                   videoPath:(gWallKind == VLTSceneTendies ? gWallTendiesPath : gWallVideoPath) generation:gWallGen];
    // Home and Lock Screen can each have a wallpaper view; let just one be heard.
    VLTSceneView *soundScene = gSoundScene;
    if (!soundScene || !soundScene.window) gSoundScene = soundScene = scene;
    scene.fitMode = gWallFit;
    scene.zoom = gWallZoom;
    scene.audioPath = gWallAudioPath;
    scene.volume = (soundScene == scene) ? gWallVolume : 0;
}

static void VLTRefreshWallpapers(void) {
    for (UIView *wallpaper in VLTWallpaperViews().allObjects) VLTApplyWallpaper(wallpaper);
    VLTUpdateVisibilityTimer();
}

%group Wallpaper

%hook SBFWallpaperView

- (void)layoutSubviews {
    %orig;
    VLTApplyWallpaper((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    VLTApplyWallpaper((UIView *)self);
    VLTUpdateVisibilityTimer();
}

%end

%end // group Wallpaper

#pragma mark - Setup

static void VLTHomePrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VLTLoadHomePrefs();
        VLTRefreshDocks();
        VLTRefreshWallpapers();
    });
}

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        VLTLoadHomePrefs();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, VLTHomePrefsChanged,
                                        CFSTR(VLT_NOTIFY_PREFS), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // Screen on / off
        static int blankToken;
        notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &blankToken, dispatch_get_main_queue(), ^(int token) {
            uint64_t blanked = 0;
            notify_get_state(token, &blanked);
            gScreenOn = (blanked == 0);
            VLTUpdateVisibilityTimer();
        });

        // Lock / unlock: move a .tendies wallpaper to its new state right away
        // instead of waiting for the next timer tick.
        static int lockToken;
        notify_register_dispatch("com.apple.springboard.lockstate", &lockToken, dispatch_get_main_queue(), ^(int token) {
            VLTUpdatePlayback();
        });

        %init(Dock);
        %init(Wallpaper);
    }
}
