// Volta - notification banners and the notification list: tint, corner
// radius, border, and an option to drop the blur. SpringBoard only.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import "VLTShared.h"
#import "VLTLook.h"

@interface NCNotificationShortLookView : UIView
- (UIView *)backgroundMaterialView;
@end

static BOOL gNotifOn;
static UIColor *gTint, *gBorder;
static CGFloat gTintStrength, gBorderWidth, gRadius;
static BOOL gRadiusOn, gHideBlur;

static void VLTLoadNotifPrefs(void) {
    NSDictionary *p = VLTCopyPrefs();
    gNotifOn = VLTBool(p, @"enabled", YES) && VLTBool(p, @"notifOn", NO);
    gTint = VLTColorFromHex(p[@"notifTint"]);
    gTintStrength = fmin(fmax(VLTNum(p, @"notifTintStrength", 50) / 100.0, 0), 1);
    gBorder = VLTColorFromHex(p[@"notifBorder"]);
    gBorderWidth = fmin(fmax(VLTNum(p, @"notifBorderWidth", 0), 0), 6);
    gRadiusOn = VLTBool(p, @"notifRadiusOn", NO);
    gRadius = fmin(fmax(VLTNum(p, @"notifRadius", 20), 0), 40);
    gHideBlur = VLTBool(p, @"notifHideBlur", NO);
}

static NSHashTable *VLTPlatters(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static const void *kNotifOverlay = &kNotifOverlay;
static const void *kNotifRealRadius = &kNotifRealRadius;
static const void *kNotifBlurMask = &kNotifBlurMask;

// host: the notification's platter. Its frosted background is restyled, and a
// clear overlay just above it carries the tint and the border.
static void VLTApplyNotif(UIView *host) {
    UIView *background = [host respondsToSelector:@selector(backgroundMaterialView)] ? [(NCNotificationShortLookView *)host backgroundMaterialView] : nil;
    if (![background isKindOfClass:[UIView class]]) {
        id value = VLTLookValue(host, @"backgroundView");
        background = [value isKindOfClass:[UIView class]] ? value : nil;
    }
    if (!background) return;
    NSNumber *realRadius = objc_getAssociatedObject(host, kNotifRealRadius);
    UIView *overlay = objc_getAssociatedObject(host, kNotifOverlay);
    if (!gNotifOn && !realRadius && !overlay && !objc_getAssociatedObject(background, kNotifBlurMask)) return;   // never touched

    // Corner radius (the real one is remembered so it can be put back).
    CGFloat radius = VLTLookRadius(background);
    if (gNotifOn && gRadiusOn) {
        if (!realRadius) objc_setAssociatedObject(host, kNotifRealRadius, @(radius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGFloat wanted = MIN(gRadius, MIN(background.bounds.size.width, background.bounds.size.height) / 2);
        if (fabs(radius - wanted) > 0.01) VLTLookSetRadius(background, wanted);
        radius = wanted;
    } else if (realRadius) {
        if (fabs(radius - realRadius.doubleValue) > 0.01) VLTLookSetRadius(background, realRadius.doubleValue);
        radius = realRadius.doubleValue;
        objc_setAssociatedObject(host, kNotifRealRadius, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    VLTSetMasked(background, gNotifOn && gHideBlur, kNotifBlurMask);

    BOOL wantsTint = gNotifOn && gTint && gTintStrength > 0.001;
    BOOL wantsBorder = gNotifOn && gBorder && gBorderWidth > 0.01;
    if (wantsTint || wantsBorder) {
        if (!overlay) {
            overlay = [[UIView alloc] initWithFrame:CGRectZero];
            overlay.userInteractionEnabled = NO;
            overlay.clipsToBounds = YES;
            objc_setAssociatedObject(host, kNotifOverlay, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        UIView *parent = background.superview ?: host;
        if (overlay.superview != parent) [parent insertSubview:overlay aboveSubview:background];
        if (!CGRectEqualToRect(overlay.frame, background.frame)) overlay.frame = background.frame;
        overlay.backgroundColor = wantsTint ? [gTint colorWithAlphaComponent:gTintStrength * CGColorGetAlpha(gTint.CGColor)] : [UIColor clearColor];
        overlay.layer.borderWidth = wantsBorder ? gBorderWidth : 0;
        overlay.layer.borderColor = wantsBorder ? gBorder.CGColor : NULL;
        if (fabs(VLTLookRadius(overlay) - radius) > 0.01) VLTLookSetRadius(overlay, radius);
    } else if (overlay) {
        [overlay removeFromSuperview];
        objc_setAssociatedObject(host, kNotifOverlay, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%group NotifLook

%hook NCNotificationShortLookView

- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window) return;
    [VLTPlatters() addObject:self];
    VLTApplyNotif((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    VLTApplyNotif((UIView *)self);
}

%end

%end // group NotifLook

static void VLTNotifPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VLTLoadNotifPrefs();
        for (UIView *platter in VLTPlatters().allObjects) VLTApplyNotif(platter);
    });
}

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        VLTLoadNotifPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, VLTNotifPrefsChanged,
                                        CFSTR(VLT_NOTIFY_PREFS), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        %init(NotifLook);
    }
}
