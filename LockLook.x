// Volta - Lock Screen look: the clock's typeface, color, size and position,
// a message under it, and hiding the smaller bits. SpringBoard only.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import "VLTShared.h"
#import "VLTLook.h"

@interface _UILegibilitySettings : NSObject
- (id)initWithStyle:(NSInteger)style primaryColor:(UIColor *)primary secondaryColor:(UIColor *)secondary shadowColor:(UIColor *)shadow;
- (NSInteger)style;
- (UIColor *)shadowColor;
@end

@interface SBFLockScreenDateView : UIView
+ (UIFont *)timeFont;
- (void)setLegibilitySettings:(_UILegibilitySettings *)settings;
- (void)setSubtitleHidden:(BOOL)hidden;
- (id)_timeLabel;
@end

#pragma mark - Settings

static BOOL gLookOn;
static NSInteger gFont;             // 0 system, 1 rounded, 2 serif, 3 mono, 4 heavy, 5 ultra light
static UIColor *gClockColor;
static CGFloat gClockScale = 1, gClockX, gClockY;
static BOOL gHideDate;
static NSString *gMessage;
static BOOL gHideHint, gHideDots, gHideQuick, gHideLockIcon;

static void VLTLoadLookPrefs(void) {
    NSDictionary *p = VLTCopyPrefs();
    gLookOn = VLTBool(p, @"enabled", YES) && VLTBool(p, @"lockLookOn", NO);
    gFont = gLookOn ? (NSInteger)VLTNum(p, @"lockClockFont", 0) : 0;
    if (gFont < 0 || gFont > 5) gFont = 0;
    gClockColor = gLookOn ? VLTColorFromHex(p[@"lockClockColor"]) : nil;
    gClockScale = gLookOn ? fmin(fmax(VLTNum(p, @"lockClockScale", 100) / 100.0, 0.5), 2.0) : 1;
    gClockX = gLookOn ? fmin(fmax(VLTNum(p, @"lockClockX", 0), -400), 400) : 0;
    gClockY = gLookOn ? fmin(fmax(VLTNum(p, @"lockClockY", 0), -200), 600) : 0;
    gHideDate = gLookOn && VLTBool(p, @"lockHideDate", NO);
    NSString *message = [VLTStr(p, @"lockMessage") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    gMessage = (gLookOn && message.length) ? (message.length > 120 ? [message substringToIndex:120] : message) : nil;
    gHideHint = gLookOn && VLTBool(p, @"lockHideHint", NO);
    gHideDots = gLookOn && VLTBool(p, @"lockHideDots", NO);
    gHideQuick = gLookOn && VLTBool(p, @"lockHideQuick", NO);
    gHideLockIcon = gLookOn && VLTBool(p, @"lockHideLockIcon", NO);
}

static NSHashTable *VLTLookTable(int which) {
    static NSHashTable *tables[5];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ for (int i = 0; i < 5; i++) tables[i] = [NSHashTable weakObjectsHashTable]; });
    return tables[which];
}
#define VLTDateViews() VLTLookTable(0)

#pragma mark - Clock

static UIFont *VLTClockFont(UIFont *system) {
    if (![system isKindOfClass:[UIFont class]] || gFont == 0) return system;
    CGFloat size = system.pointSize;
    UIFont *font = nil;
    UIFontDescriptorSystemDesign design = nil;
    switch (gFont) {
        case 1: design = UIFontDescriptorSystemDesignRounded; break;
        case 2: design = UIFontDescriptorSystemDesignSerif; break;
        case 3: design = UIFontDescriptorSystemDesignMonospaced; break;
        case 4: font = [UIFont systemFontOfSize:size weight:UIFontWeightHeavy]; break;
        case 5: font = [UIFont systemFontOfSize:size weight:UIFontWeightUltraLight]; break;
        default: break;
    }
    if (design) {
        UIFont *base = [UIFont systemFontOfSize:size weight:UIFontWeightMedium];
        UIFontDescriptor *descriptor = [base.fontDescriptor fontDescriptorWithDesign:design];
        if (descriptor) font = [UIFont fontWithDescriptor:descriptor size:size];
    }
    return font ?: system;
}

static const void *kRealSettings = &kRealSettings;
static const void *kRealSubtitleHidden = &kRealSubtitleHidden;
static const void *kMessageLabel = &kMessageLabel;
static const void *kLookTouched = &kLookTouched;
static BOOL gLookReplaying;

static id VLTClockSettings(_UILegibilitySettings *real) {
    if (!gClockColor) return real;
    Class cls = NSClassFromString(@"_UILegibilitySettings");
    if (!cls || ![cls instancesRespondToSelector:@selector(initWithStyle:primaryColor:secondaryColor:shadowColor:)]) return real;
    NSInteger style = [real respondsToSelector:@selector(style)] ? [real style] : 1;
    UIColor *shadow = [real respondsToSelector:@selector(shadowColor)] ? [real shadowColor] : nil;
    return [[cls alloc] initWithStyle:style primaryColor:gClockColor
                       secondaryColor:[gClockColor colorWithAlphaComponent:0.7 * CGColorGetAlpha(gClockColor.CGColor)]
                          shadowColor:shadow ?: [UIColor colorWithWhite:0 alpha:0.3]];
}

static void VLTApplyClock(SBFLockScreenDateView *view) {
    CALayer *layer = view.layer;
    VLTPinOffset(layer, @"vltClockScale", @"transform.scale", gLookOn, gClockScale - 1);
    VLTPinOffset(layer, @"vltClockX", @"transform.translation.x", gLookOn, gClockX);
    VLTPinOffset(layer, @"vltClockY", @"transform.translation.y", gLookOn, gClockY);

    // Typeface. The label keeps whatever font it was given, so set it when it differs.
    // Compared with the last font we set (not the label's own getter), so layout can never chase itself.
    UIFont *lastSet = objc_getAssociatedObject(view, kLookTouched);
    if ((gFont != 0 || lastSet) && [view respondsToSelector:@selector(_timeLabel)] && [[view class] respondsToSelector:@selector(timeFont)]) {
        id label = [view _timeLabel];
        UIFont *wanted = [[view class] timeFont];   // goes through the hook below
        if ([label respondsToSelector:@selector(setFont:)] && [wanted isKindOfClass:[UIFont class]] && ![lastSet isEqual:wanted]) {
            [label setFont:wanted];
            objc_setAssociatedObject(view, kLookTouched, wanted, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [view setNeedsLayout];
        }
    }

    // The message, centred under the clock and date.
    UILabel *message = objc_getAssociatedObject(view, kMessageLabel);
    if (gMessage) {
        if (!message) {
            message = [[UILabel alloc] initWithFrame:CGRectZero];
            message.userInteractionEnabled = NO;
            message.textAlignment = NSTextAlignmentCenter;
            message.numberOfLines = 2;
            message.adjustsFontSizeToFitWidth = YES;
            message.minimumScaleFactor = 0.6;
            message.layer.shadowColor = [UIColor blackColor].CGColor;
            message.layer.shadowOpacity = 0.35;
            message.layer.shadowRadius = 3;
            message.layer.shadowOffset = CGSizeZero;
            objc_setAssociatedObject(view, kMessageLabel, message, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (message.superview != view) [view addSubview:message];
        UIFont *font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
        if (gFont == 1 || gFont == 2 || gFont == 3) {
            UIFontDescriptorSystemDesign design = gFont == 1 ? UIFontDescriptorSystemDesignRounded
                                                : (gFont == 2 ? UIFontDescriptorSystemDesignSerif : UIFontDescriptorSystemDesignMonospaced);
            UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorWithDesign:design];
            if (descriptor) font = [UIFont fontWithDescriptor:descriptor size:20];
        }
        if (![message.text isEqualToString:gMessage]) message.text = gMessage;
        if (![message.font isEqual:font]) message.font = font;
        UIColor *color = gClockColor ?: [UIColor whiteColor];
        if (![message.textColor isEqual:color]) message.textColor = color;
        CGFloat width = MAX(view.bounds.size.width, 280);
        CGRect frame = CGRectMake((view.bounds.size.width - width) / 2, view.bounds.size.height + 8, width, 54);
        if (!CGRectEqualToRect(message.frame, frame)) message.frame = frame;
    } else if (message) {
        [message removeFromSuperview];
        objc_setAssociatedObject(view, kMessageLabel, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Pushes the real values back through the hooks so they pick up new settings.
static void VLTRefreshClocks(void) {
    for (SBFLockScreenDateView *view in VLTDateViews().allObjects) {
        gLookReplaying = YES;
        _UILegibilitySettings *settings = objc_getAssociatedObject(view, kRealSettings);
        if (settings && [view respondsToSelector:@selector(setLegibilitySettings:)]) [view setLegibilitySettings:settings];
        NSNumber *hidden = objc_getAssociatedObject(view, kRealSubtitleHidden);
        if ([view respondsToSelector:@selector(setSubtitleHidden:)]) [view setSubtitleHidden:hidden.boolValue];
        gLookReplaying = NO;
        VLTApplyClock(view);
        [view setNeedsLayout];
    }
}

#pragma mark - Small bits

static const void *kBitMask = &kBitMask;

static BOOL VLTBitHidden(int which) {
    switch (which) {
        case 1: return gHideHint;
        case 2: return gHideDots;
        case 3: return gHideQuick;
        case 4: return gHideLockIcon;
        default: return NO;
    }
}

static void VLTTrackBit(UIView *view, int which) {
    if (!view.window) return;
    [VLTLookTable(which) addObject:view];
    VLTSetMasked(view, VLTBitHidden(which), kBitMask);
}

static void VLTRefreshBits(void) {
    for (int which = 1; which <= 4; which++) {
        for (UIView *view in VLTLookTable(which).allObjects) VLTSetMasked(view, VLTBitHidden(which), kBitMask);
    }
}

#pragma mark - Hooks

%group LockLook

%hook SBFLockScreenDateView

+ (id)timeFont {
    UIFont *font = %orig;
    return VLTClockFont(font);
}

- (void)setLegibilitySettings:(id)settings {
    if (!gLookReplaying) objc_setAssociatedObject(self, kRealSettings, settings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(settings ? VLTClockSettings(settings) : settings);
}

- (void)setSubtitleHidden:(BOOL)hidden {
    if (!gLookReplaying) objc_setAssociatedObject(self, kRealSubtitleHidden, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(gHideDate ? YES : hidden);
}

- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window) return;
    [VLTDateViews() addObject:self];
    if (gHideDate && [self respondsToSelector:@selector(setSubtitleHidden:)]) {
        gLookReplaying = YES;
        NSNumber *hidden = objc_getAssociatedObject(self, kRealSubtitleHidden);
        [self setSubtitleHidden:hidden.boolValue];
        gLookReplaying = NO;
    }
    VLTApplyClock(self);
}

- (void)layoutSubviews {
    %orig;
    VLTApplyClock(self);
}

%end

%hook SBUICallToActionLabel
- (void)didMoveToWindow {
    %orig;
    VLTTrackBit((UIView *)self, 1);
}
%end

%hook CSPageControl
- (void)didMoveToWindow {
    %orig;
    VLTTrackBit((UIView *)self, 2);
}
%end

%hook CSQuickActionsView
- (void)didMoveToWindow {
    %orig;
    VLTTrackBit((UIView *)self, 3);
}
%end

%hook SBUIProudLockIconView
- (void)didMoveToWindow {
    %orig;
    VLTTrackBit((UIView *)self, 4);
}
%end

%end // group LockLook

static void VLTLookPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VLTLoadLookPrefs();
        VLTRefreshClocks();
        VLTRefreshBits();
    });
}

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        VLTLoadLookPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, VLTLookPrefsChanged,
                                        CFSTR(VLT_NOTIFY_PREFS), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        %init(LockLook);
    }
}
