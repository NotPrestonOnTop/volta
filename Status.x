// Volta - status bar text, hidden status bar items, and the fake notch /
// Dynamic Island / home bar. Loaded into SpringBoard and every app, because
// each app draws its own status bar.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <substrate.h>
#import "VLTShared.h"

@interface _UIStatusBarStringView : UILabel
@end

@interface _UIStatusBarDisplayItem : NSObject
- (void)setEnabled:(BOOL)enabled;
- (id)identifier;
@end

@interface _UIStatusBarTimeItem : NSObject
+ (id)dateDisplayIdentifier;
- (_UIStatusBarStringView *)timeView;
- (_UIStatusBarStringView *)shortTimeView;
- (_UIStatusBarStringView *)pillTimeView;
- (_UIStatusBarStringView *)dateView;
@end

@interface _UIStatusBarCellularItem : NSObject
- (_UIStatusBarStringView *)serviceNameView;
@end

#pragma mark - Settings

enum { VLTTextTime = 1, VLTTextDate, VLTTextCarrier };
enum {
    VLTHideWifi = 1 << 0, VLTHideCell = 1 << 1, VLTHideLocation = 1 << 2, VLTHideFocus = 1 << 3, VLTHideRotation = 1 << 4,
    VLTHideAlarm = 1 << 5, VLTHideAirplane = 1 << 6, VLTHideVPN = 1 << 7, VLTHideBluetooth = 1 << 8,
};

static BOOL gIsSpringBoard;
static BOOL gOn;
static NSString *gClockFormat;      // nil = the system's clock
static NSInteger gDateMode;         // 0 system, 1 hidden, 2 own text
static NSString *gDateText, *gCarrier;
static uint32_t gHide;
static NSInteger gCutout;           // 0 none, 1 notch, 2 Dynamic Island
static CGFloat gCutWidth = 160, gCutHeight = 30, gCutTop = 6;
static BOOL gCutCharge = YES, gCutLens = YES, gHomeBar;
static BOOL gReplaying;

static void VLTLoadStatus(void) {
    NSDictionary *s = nil;
    if (gIsSpringBoard) {
        s = VLTStatusDict(VLTCopyPrefs());
    } else {
        s = [NSDictionary dictionaryWithContentsOfFile:VLT_STATUS_PATH];
        if (![s isKindOfClass:[NSDictionary class]]) s = @{};
    }
    gOn = VLTBool(s, @"enabled", YES);
    gClockFormat = gOn ? VLTClockFormat(s) : nil;
    gDateMode = gOn ? (NSInteger)VLTNum(s, @"sbDateMode", 0) : 0;
    NSString *date = VLTStr(s, @"sbDateText"), *carrier = VLTStr(s, @"sbCarrier");
    gDateText = date.length > 40 ? [date substringToIndex:40] : date;
    gCarrier = (gOn && carrier.length) ? (carrier.length > 30 ? [carrier substringToIndex:30] : carrier) : nil;
    if (gDateMode == 2 && gDateText.length == 0) gDateMode = 0;

    gHide = 0;
    if (gOn) {
        NSArray *keys = @[@"sbHideWifi", @"sbHideCell", @"sbHideLocation", @"sbHideFocus", @"sbHideRotation",
                          @"sbHideAlarm", @"sbHideAirplane", @"sbHideVPN", @"sbHideBluetooth"];
        for (NSUInteger i = 0; i < keys.count; i++) if (VLTBool(s, keys[i], NO)) gHide |= (1u << i);
    }

    gCutout = gOn ? (NSInteger)VLTNum(s, @"fakeCutout", 0) : 0;
    if (gCutout < 0 || gCutout > 2) gCutout = 0;
    gCutWidth  = fmin(fmax(VLTNum(s, @"fakeWidth", 160), 60), 320);
    gCutHeight = fmin(fmax(VLTNum(s, @"fakeHeight", 30), 14), 60);
    gCutTop    = fmin(fmax(VLTNum(s, @"fakeTop", 6), 0), 30);
    gCutCharge = VLTBool(s, @"fakeCharge", YES);
    gCutLens   = VLTBool(s, @"fakeLens", YES);
    gHomeBar   = gOn && VLTBool(s, @"fakeHomeBar", NO);
}

#pragma mark - Clock, date and carrier text

static const void *kTextKind = &kTextKind;
static const void *kTextReal = &kTextReal;

static NSHashTable *VLTTextViews(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static void VLTTag(id view, int kind) {
    if (![view isKindOfClass:[UIView class]] || objc_getAssociatedObject(view, kTextKind)) return;
    objc_setAssociatedObject(view, kTextKind, @(kind), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [VLTTextViews() addObject:view];
}

static NSString *VLTClockString(void) {
    static NSDateFormatter *formatter;
    static NSString *formatterFormat;
    if (!gClockFormat) return nil;
    if (!formatter) {
        formatter = [[NSDateFormatter alloc] init];
        formatter.timeZone = [NSTimeZone localTimeZone];   // follows the device if the zone changes
    }
    if (![formatterFormat isEqualToString:gClockFormat]) {
        formatterFormat = [gClockFormat copy];
        @try { formatter.dateFormat = formatterFormat; } @catch (__unused NSException *e) { return nil; }
    }
    NSString *text = [formatter stringFromDate:[NSDate date]];
    return text.length ? text : nil;
}

static NSString *VLTStatusText(int kind, NSString *real) {
    if (real.length == 0) return real;   // the system is hiding this item
    switch (kind) {
        case VLTTextTime:    return VLTClockString() ?: real;
        case VLTTextDate:    return gDateMode == 2 ? gDateText : real;
        case VLTTextCarrier: return gCarrier ?: real;
        default:             return real;
    }
}

// Pushes the real text back through the hook so it picks up new settings
// (and, for a clock with seconds, the new time).
static void VLTReplayText(int onlyKind) {
    gReplaying = YES;
    for (_UIStatusBarStringView *view in VLTTextViews().allObjects) {
        NSNumber *kind = objc_getAssociatedObject(view, kTextKind);
        NSString *real = objc_getAssociatedObject(view, kTextReal);
        if (!real || (onlyKind && kind.intValue != onlyKind) || !view.window) continue;
        [view setText:real];
    }
    gReplaying = NO;
}

// A clock that shows seconds needs a tick; any other format is refreshed by
// the system once a minute.
static NSTimer *gSecondsTimer;

static void VLTSyncSecondsTimer(void) {
    BOOL needed = gClockFormat && [gClockFormat rangeOfString:@"s"].location != NSNotFound;
    if (needed && !gSecondsTimer) {
        NSDate *nextSecond = [NSDate dateWithTimeIntervalSinceReferenceDate:floor([NSDate timeIntervalSinceReferenceDate]) + 1.02];
        gSecondsTimer = [[NSTimer alloc] initWithFireDate:nextSecond interval:1 repeats:YES block:^(NSTimer *timer) {
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground && !gIsSpringBoard) return;
            // Nothing to draw while the screen is off.
            static int blankToken = -1;
            if (blankToken == -1 && notify_register_check("com.apple.springboard.hasBlankedScreen", &blankToken) != NOTIFY_STATUS_OK) blankToken = -2;
            uint64_t blanked = 0;
            if (blankToken >= 0 && notify_get_state(blankToken, &blanked) == NOTIFY_STATUS_OK && blanked) return;
            VLTReplayText(VLTTextTime);
        }];
        gSecondsTimer.tolerance = 0.05;
        [[NSRunLoop mainRunLoop] addTimer:gSecondsTimer forMode:NSRunLoopCommonModes];
    } else if (!needed && gSecondsTimer) {
        [gSecondsTimer invalidate];
        gSecondsTimer = nil;
    }
}

#pragma mark - Hidden items

// Each status bar item decides whether it is shown in applyUpdate:toDisplayItem:.
// Hidden ones are switched off right after, so the bar closes the gap itself.
static void VLTHookItem(NSString *className, uint32_t bit) {
    Class cls = NSClassFromString(className);
    SEL sel = @selector(applyUpdate:toDisplayItem:);
    if (!cls || !class_getInstanceMethod(cls, sel)) return;
    IMP *original = (IMP *)calloc(1, sizeof(IMP));   // lives as long as the hook
    if (!original) return;
    IMP replacement = imp_implementationWithBlock(^id(id item, id update, id displayItem) {
        IMP real = *original ?: class_getMethodImplementation(class_getSuperclass(cls), sel);
        id result = real ? ((id (*)(id, SEL, id, id))real)(item, sel, update, displayItem) : nil;
        if ((gHide & bit) && [displayItem respondsToSelector:@selector(setEnabled:)]) [(_UIStatusBarDisplayItem *)displayItem setEnabled:NO];
        return result;
    });
    MSHookMessageEx(cls, sel, replacement, original);
}

#pragma mark - Fake notch, Dynamic Island and home bar

@interface VLTCutoutView : UIView
- (void)announce:(NSString *)text;
@end

@implementation VLTCutoutView {
    CAShapeLayer *_shape;
    CALayer *_lens;
    UILabel *_label;
    CALayer *_homeBar;
    BOOL _expanded;
    NSUInteger _announceGen;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        _shape = [CAShapeLayer layer];
        _shape.fillColor = [UIColor blackColor].CGColor;
        [self.layer addSublayer:_shape];
        _lens = [CALayer layer];
        _lens.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.16 alpha:1].CGColor;
        _lens.borderColor = [UIColor colorWithWhite:0.16 alpha:1].CGColor;
        _lens.borderWidth = 1;
        [self.layer addSublayer:_lens];
        _label = [[UILabel alloc] initWithFrame:CGRectZero];
        _label.textColor = [UIColor colorWithRed:0.30 green:0.85 blue:0.39 alpha:1];
        _label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.alpha = 0;
        [self addSubview:_label];
        _homeBar = [CALayer layer];
        _homeBar.backgroundColor = [UIColor colorWithWhite:1 alpha:0.92].CGColor;
        _homeBar.shadowColor = [UIColor blackColor].CGColor;
        _homeBar.shadowOpacity = 0.45;
        _homeBar.shadowRadius = 2;
        _homeBar.shadowOffset = CGSizeZero;
        [self.layer addSublayer:_homeBar];
    }
    return self;
}

// iPhone-style notch: flat against the top edge, small flares where it meets
// the edge, round bottom corners.
static UIBezierPath *VLTNotchPath(CGRect rect) {
    CGFloat x = rect.origin.x, y = rect.origin.y, w = rect.size.width, h = rect.size.height;
    CGFloat ear = MIN(6, h / 3), corner = MIN(h * 0.62, w / 4);
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(x - ear, y)];
    [path addQuadCurveToPoint:CGPointMake(x, y + ear) controlPoint:CGPointMake(x, y)];
    [path addLineToPoint:CGPointMake(x, y + h - corner)];
    [path addQuadCurveToPoint:CGPointMake(x + corner, y + h) controlPoint:CGPointMake(x, y + h)];
    [path addLineToPoint:CGPointMake(x + w - corner, y + h)];
    [path addQuadCurveToPoint:CGPointMake(x + w, y + h - corner) controlPoint:CGPointMake(x + w, y + h)];
    [path addLineToPoint:CGPointMake(x + w, y + ear)];
    [path addQuadCurveToPoint:CGPointMake(x + w + ear, y) controlPoint:CGPointMake(x + w, y)];
    [path closePath];
    return path;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGSize size = self.bounds.size;
    BOOL island = gCutout == 2, notch = gCutout == 1;
    CGFloat width = gCutWidth + ((_expanded && island) ? 96 : 0), height = gCutHeight;
    // Centre on the screen, not on this window: in Split View each app only has part of the screen,
    // and each draws the part of the cutout that falls inside it.
    CGFloat centerX = size.width / 2, bottom = size.height;
    UIScreen *screen = self.window.screen;
    if (screen) {
        CGRect whole = screen.bounds;
        CGPoint top = [self convertPoint:CGPointMake(CGRectGetMidX(whole), 0) fromCoordinateSpace:screen.coordinateSpace];
        CGPoint foot = [self convertPoint:CGPointMake(CGRectGetMidX(whole), CGRectGetMaxY(whole)) fromCoordinateSpace:screen.coordinateSpace];
        if (isfinite(top.x) && fabs(top.x) < 5000 && fabs(top.y) < 1) centerX = top.x;
        if (isfinite(foot.y) && fabs(foot.y - size.height) < 1) bottom = foot.y;
    }
    CGRect cut = CGRectMake(centerX - width / 2, island ? gCutTop : 0, width, height);

    _shape.frame = self.bounds;
    _shape.hidden = !(island || notch);
    if (island) _shape.path = [UIBezierPath bezierPathWithRoundedRect:cut cornerRadius:height / 2].CGPath;
    else if (notch) _shape.path = VLTNotchPath(cut).CGPath;

    CGFloat lens = MIN(11, height * 0.38);
    _lens.hidden = _shape.hidden || !gCutLens;
    _lens.cornerRadius = lens / 2;
    _lens.frame = CGRectMake(CGRectGetMaxX(cut) - height / 2 - lens / 2 - (island ? 2 : width * 0.16),
                             CGRectGetMidY(cut) - lens / 2, lens, lens);

    _label.frame = CGRectInset(cut, height / 2, 0);

    CGFloat barWidth = MIN(size.width * 0.34, 300);
    _homeBar.hidden = !gHomeBar;
    _homeBar.cornerRadius = 2.5;
    _homeBar.frame = CGRectMake(centerX - barWidth / 2, bottom - 13, barWidth, 5);
    [CATransaction commit];
}

// The island stretches for a moment to show a message (charging).
- (void)announce:(NSString *)text {
    if (gCutout != 2 || !gCutCharge || UIAccessibilityIsReduceMotionEnabled()) return;
    NSUInteger generation = ++_announceGen;
    _label.text = text;
    _expanded = YES;
    CABasicAnimation *morph = [CABasicAnimation animationWithKeyPath:@"path"];
    morph.fromValue = (__bridge id)_shape.path;
    morph.duration = 0.35;
    morph.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self layoutSubviews];
    [_shape addAnimation:morph forKey:@"vltMorph"];
    [UIView animateWithDuration:0.25 delay:0.15 options:0 animations:^{ self->_label.alpha = 1; } completion:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_announceGen != generation) return;
        strongSelf->_expanded = NO;
        CABasicAnimation *back = [CABasicAnimation animationWithKeyPath:@"path"];
        back.fromValue = (__bridge id)strongSelf->_shape.path;
        back.duration = 0.35;
        back.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        strongSelf->_label.alpha = 0;
        [strongSelf layoutSubviews];
        [strongSelf->_shape addAnimation:back forKey:@"vltMorph"];
    });
}

@end

static const void *kCutoutKey = &kCutoutKey;

static NSHashTable *VLTBars(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static NSHashTable *VLTCutouts(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

// The cutout lives in the window that holds the status bar: a view that takes
// no touches, kept in front. Nothing is added when every fake is off.
static void VLTApplyCutout(UIView *statusBar) {
    UIWindow *window = statusBar.window;
    if (!window) return;
    VLTCutoutView *cutout = objc_getAssociatedObject(window, kCutoutKey);
    BOOL wanted = (gCutout != 0 || gHomeBar) && window.bounds.size.height > 200 && window.bounds.size.width > 200;
    if (!wanted) {
        if (cutout) {
            [cutout removeFromSuperview];
            objc_setAssociatedObject(window, kCutoutKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (!cutout) {
        cutout = [[VLTCutoutView alloc] initWithFrame:window.bounds];
        objc_setAssociatedObject(window, kCutoutKey, cutout, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [VLTCutouts() addObject:cutout];
    }
    if (cutout.superview != window) [window addSubview:cutout];
    else if (window.subviews.lastObject != cutout) [window bringSubviewToFront:cutout];
    if (!CGRectEqualToRect(cutout.frame, window.bounds)) cutout.frame = window.bounds;
    [cutout setNeedsLayout];
}

// Called by the battery hooks (Tweak.x) when the device starts charging.
void VLTIslandAnnounce(NSString *text) {
    for (VLTCutoutView *cutout in VLTCutouts().allObjects) {
        if (cutout.window) [cutout announce:text];
    }
}

#pragma mark - Hooks

%group StatusLook

%hook _UIStatusBarTimeItem

- (id)applyUpdate:(id)update toDisplayItem:(id)displayItem {
    // Tag the labels first: the original call is what sets their text.
    if ([self respondsToSelector:@selector(timeView)]) VLTTag([self timeView], VLTTextTime);
    if ([self respondsToSelector:@selector(shortTimeView)]) VLTTag([self shortTimeView], VLTTextTime);
    if ([self respondsToSelector:@selector(pillTimeView)]) VLTTag([self pillTimeView], VLTTextTime);
    if ([self respondsToSelector:@selector(dateView)]) VLTTag([self dateView], VLTTextDate);
    id result = %orig;
    if (gDateMode == 1 && [displayItem respondsToSelector:@selector(identifier)] && [displayItem respondsToSelector:@selector(setEnabled:)] &&
        [[self class] respondsToSelector:@selector(dateDisplayIdentifier)]) {
        id dateIdentifier = [[self class] dateDisplayIdentifier];
        if (dateIdentifier && [[(_UIStatusBarDisplayItem *)displayItem identifier] isEqual:dateIdentifier])
            [(_UIStatusBarDisplayItem *)displayItem setEnabled:NO];
    }
    return result;
}

%end

%hook _UIStatusBarCellularItem

- (id)applyUpdate:(id)update toDisplayItem:(id)displayItem {
    if ([self respondsToSelector:@selector(serviceNameView)]) VLTTag([self serviceNameView], VLTTextCarrier);
    return %orig;
}

%end

%hook _UIStatusBarStringView

- (void)setText:(NSString *)text {
    NSNumber *kind = objc_getAssociatedObject(self, kTextKind);
    if (!kind) {
        %orig;
        return;
    }
    if (!gReplaying) objc_setAssociatedObject(self, kTextReal, text, OBJC_ASSOCIATION_COPY_NONATOMIC);
    %orig(VLTStatusText(kind.intValue, text));
}

%end

%hook _UIStatusBar

- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window) return;
    [VLTBars() addObject:self];
    VLTApplyCutout((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    if (gCutout != 0 || gHomeBar) VLTApplyCutout((UIView *)self);
}

%end

%end // group StatusLook

static void VLTStatusRefresh(void) {
    VLTLoadStatus();
    VLTSyncSecondsTimer();
    VLTReplayText(0);
    for (UIView *bar in VLTBars().allObjects) {
        VLTApplyCutout(bar);
        [bar setNeedsLayout];
    }
    // Cutouts whose status bar has since moved to another window.
    BOOL wanted = gCutout != 0 || gHomeBar;
    for (UIView *cutout in VLTCutouts().allObjects) {
        if (wanted) {
            [cutout setNeedsLayout];
            continue;
        }
        UIView *window = cutout.superview;
        [cutout removeFromSuperview];
        if (window) objc_setAssociatedObject(window, kCutoutKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void VLTStatusChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ VLTStatusRefresh(); });
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

        VLTLoadStatus();
        // SpringBoard reads the preferences itself; apps wait for SpringBoard to
        // write the shared file, which it does before posting "apply".
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, VLTStatusChanged,
                                        gIsSpringBoard ? CFSTR(VLT_NOTIFY_PREFS) : CFSTR(VLT_NOTIFY_APPLY), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        %init(StatusLook);
        NSDictionary *items = @{
            @"_UIStatusBarWifiItem": @(VLTHideWifi),
            @"_UIStatusBarCellularItem": @(VLTHideCell),
            @"_UIStatusBarCellularCondensedItem": @(VLTHideCell),
            @"_UIStatusBarCellularExpandedItem": @(VLTHideCell),
            @"_UIStatusBarSecondaryCellularCondensedItem": @(VLTHideCell),
            @"_UIStatusBarSecondaryCellularExpandedItem": @(VLTHideCell),
            @"_UIStatusBarIndicatorLocationItem": @(VLTHideLocation),
            @"_UIStatusBarIndicatorQuietModeItem": @(VLTHideFocus),
            @"_UIStatusBarIndicatorRotationLockItem": @(VLTHideRotation),
            @"_UIStatusBarIndicatorAlarmItem": @(VLTHideAlarm),
            @"_UIStatusBarIndicatorAirplaneModeItem": @(VLTHideAirplane),
            @"_UIStatusBarIndicatorVPNItem": @(VLTHideVPN),
            @"_UIStatusBarBluetoothItem": @(VLTHideBluetooth),
        };
        [items enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSNumber *bit, BOOL *stop) {
            VLTHookItem(name, bit.unsignedIntValue);
        }];

        dispatch_async(dispatch_get_main_queue(), ^{ VLTSyncSecondsTimer(); });
    }
}
