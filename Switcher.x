// Volta - App Switcher look: rounder cards, a border, and hiding the app name
// and icon above each card. SpringBoard only.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import "VLTShared.h"
#import "VLTLook.h"

static BOOL gSwitcherOn;
static BOOL gRadiusOn, gHideHeader;
static CGFloat gRadius, gBorderWidth;
static UIColor *gBorder;

static void VLTLoadSwitcherPrefs(void) {
    NSDictionary *p = VLTCopyPrefs();
    gSwitcherOn = VLTBool(p, @"enabled", YES) && VLTBool(p, @"swOn", NO);
    gRadiusOn = VLTBool(p, @"swRadiusOn", NO);
    gRadius = fmin(fmax(VLTNum(p, @"swRadius", 40), 0), 160);
    gBorder = VLTColorFromHex(p[@"swBorder"]);
    gBorderWidth = fmin(fmax(VLTNum(p, @"swBorderWidth", 0), 0), 16);
    gHideHeader = gSwitcherOn && VLTBool(p, @"swHideHeader", NO);
}

static NSHashTable *VLTSwitcherTable(int which) {
    static NSHashTable *tables[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ for (int i = 0; i < 2; i++) tables[i] = [NSHashTable weakObjectsHashTable]; });
    return tables[which];
}

// Same layout as UIKit's UIRectCornerRadii: four corner sizes.
typedef struct { CGFloat a, b, c, d; } VLTCornerRadii;

@interface SBAppSwitcherPageView : UIView
- (void)setCornerRadii:(VLTCornerRadii)radii;
@end

static const void *kPageRadii = &kPageRadii;     // the radii the system last asked for
static const void *kPageBorder = &kPageBorder;
static const void *kHeaderMask = &kHeaderMask;
static BOOL gReplayingRadii;

// A page view shows an app both as a card in the switcher and full screen.
// The system gives it rounded corners only while it is a card, so that is how
// a card is told apart: nothing here touches an app that fills the screen.
static BOOL VLTIsCard(VLTCornerRadii radii) {
    return radii.a > 0.5 || radii.b > 0.5 || radii.c > 0.5 || radii.d > 0.5;
}

static void VLTApplyBorder(UIView *page) {
    CALayer *border = objc_getAssociatedObject(page, kPageBorder);
    NSValue *stored = objc_getAssociatedObject(page, kPageRadii);
    VLTCornerRadii real = {0};
    if (stored) [stored getValue:&real size:sizeof(real)];
    BOOL wanted = gSwitcherOn && gBorder && gBorderWidth > 0.01 && VLTIsCard(real);
    if (!wanted) {
        if (border) {
            [border removeFromSuperlayer];
            objc_setAssociatedObject(page, kPageBorder, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (!border) {
        border = [CALayer layer];
        border.zPosition = 1000;
        objc_setAssociatedObject(page, kPageBorder, border, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat radius = gRadiusOn ? gRadius : MAX(MAX(real.a, real.b), MAX(real.c, real.d));
    radius = MIN(radius, MIN(page.bounds.size.width, page.bounds.size.height) / 2);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (border.superlayer != page.layer) [page.layer addSublayer:border];
    border.frame = page.bounds;
    border.borderColor = gBorder.CGColor;
    border.borderWidth = gBorderWidth;
    border.cornerRadius = radius;
    border.cornerCurve = kCACornerCurveContinuous;
    [CATransaction commit];
}

%group SwitcherLook

%hook SBAppSwitcherPageView

- (void)setCornerRadii:(VLTCornerRadii)radii {
    if (!gReplayingRadii) objc_setAssociatedObject(self, kPageRadii, [NSValue valueWithBytes:&radii objCType:@encode(VLTCornerRadii)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL card = VLTIsCard(radii);
    if (gSwitcherOn && gRadiusOn && card) radii = (VLTCornerRadii){gRadius, gRadius, gRadius, gRadius};
    %orig(radii);
    VLTApplyBorder((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) [VLTSwitcherTable(0) addObject:self];
}

- (void)layoutSubviews {
    %orig;
    if (objc_getAssociatedObject(self, kPageBorder)) VLTApplyBorder((UIView *)self);   // keep the border the size of the card
}

%end

%hook SBFluidSwitcherItemContainerHeaderView

- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window) return;
    [VLTSwitcherTable(1) addObject:self];
    VLTSetMasked((UIView *)self, gHideHeader, kHeaderMask);
}

%end

%end // group SwitcherLook

// Pushes the system's own radii back through the hook so new settings apply.
static void VLTRefreshCards(void) {
    for (SBAppSwitcherPageView *page in VLTSwitcherTable(0).allObjects) {
        NSValue *stored = objc_getAssociatedObject(page, kPageRadii);
        if (!stored || ![page respondsToSelector:@selector(setCornerRadii:)]) continue;
        VLTCornerRadii real = {0};
        [stored getValue:&real size:sizeof(real)];
        gReplayingRadii = YES;
        [page setCornerRadii:real];
        gReplayingRadii = NO;
    }
}

static void VLTSwitcherPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VLTLoadSwitcherPrefs();
        VLTRefreshCards();
        for (UIView *header in VLTSwitcherTable(1).allObjects) VLTSetMasked(header, gHideHeader, kHeaderMask);
    });
}

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        VLTLoadSwitcherPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, VLTSwitcherPrefsChanged,
                                        CFSTR(VLT_NOTIFY_PREFS), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        %init(SwitcherLook);
    }
}
