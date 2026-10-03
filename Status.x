// Volta - status bar text, hidden status bar items and the fake cellular
// signal. Loaded into SpringBoard and every app, because each app draws its
// own status bar. (The fake notch and Dynamic Island are in Popups.x.)
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

@interface _UIStatusBar : UIView
- (UIColor *)foregroundColor;
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
static BOOL gSigOn;
static NSInteger gSigBars = 4;      // 0 ... 4
static NSString *gSigType, *gSigCarrier;
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

    gSigOn = gOn && VLTBool(s, @"sigOn", NO);
    gSigBars = (NSInteger)fmin(fmax(VLTNum(s, @"sigBars", 4), 0), 4);
    NSArray *types = @[@"5G", @"5G+", @"5G UW", @"5G UC", @"LTE", @"4G", @"3G", @"E", @""];
    NSInteger type = (NSInteger)VLTNum(s, @"sigType", 0);
    gSigType = types[(type >= 0 && type < (NSInteger)types.count) ? type : 0];
    NSString *sigCarrier = VLTStr(s, @"sigCarrier");
    gSigCarrier = sigCarrier.length > 20 ? [sigCarrier substringToIndex:20] : sigCarrier;
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

#pragma mark - Status bars on screen

static NSHashTable *VLTBars(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

#pragma mark - Fake cellular signal

// Signal bars and "5G" for devices with no cellular at all. Drawn as a small
// view of its own, placed just left of the real items on the right-hand side.
@interface VLTSignalView : UIView
@property (nonatomic, strong) UIColor *ink;
- (CGSize)wantedSize;
@end

@implementation VLTSignalView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
        _ink = [UIColor whiteColor];
    }
    return self;
}

- (NSDictionary *)textAttributes {
    return @{NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: self.ink ?: [UIColor whiteColor]};
}

- (CGSize)wantedSize {
    CGFloat width = 17;   // four bars
    if (gSigCarrier.length) width += ceil([gSigCarrier sizeWithAttributes:[self textAttributes]].width) + 5;
    if (gSigType.length) width += ceil([gSigType sizeWithAttributes:[self textAttributes]].width) + 4;
    return CGSizeMake(width, 14);
}

- (void)setInk:(UIColor *)ink {
    if ([_ink isEqual:ink]) return;
    _ink = ink;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    NSDictionary *attributes = [self textAttributes];
    UIColor *ink = self.ink ?: [UIColor whiteColor];
    CGFloat x = 0, height = self.bounds.size.height;
    if (gSigCarrier.length) {
        CGSize size = [gSigCarrier sizeWithAttributes:attributes];
        [gSigCarrier drawAtPoint:CGPointMake(x, (height - size.height) / 2) withAttributes:attributes];
        x += ceil(size.width) + 5;
    }
    for (int i = 0; i < 4; i++) {
        CGFloat barHeight = 4 + i * 2.2;
        [(i < gSigBars ? ink : [ink colorWithAlphaComponent:0.3 * CGColorGetAlpha(ink.CGColor)]) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x + i * 4.5, height - 2 - barHeight, 3, barHeight) cornerRadius:1] fill];
    }
    x += 17 + 4;
    if (gSigType.length) {
        CGSize size = [gSigType sizeWithAttributes:attributes];
        [gSigType drawAtPoint:CGPointMake(x, (height - size.height) / 2) withAttributes:attributes];
    }
}

@end

static const void *kSignalKey = &kSignalKey;

// Whether a class is one of the things a status bar shows (a label, the Wi-Fi
// fan, the battery...). Asked for every view on every layout, so the answer is
// remembered per class.
static BOOL VLTIsItemClass(Class cls, NSString *unused) {
    static NSMapTable *verdicts;
    if (!verdicts) verdicts = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                                    valueOptions:NSPointerFunctionsStrongMemory];
    NSNumber *known = [verdicts objectForKey:cls];
    if (known) return known.boolValue;
    NSString *name = NSStringFromClass(cls);
    BOOL item = [name containsString:@"StringView"] || [name containsString:@"SignalView"] || [name containsString:@"BatteryView"] ||
                [name containsString:@"ImageView"] || [name containsString:@"ActivityView"];
    [verdicts setObject:@(item) forKey:cls];
    return item;
}

// Finds the real items drawn on the right half of the bar (Wi-Fi, battery,
// percentage...) so the fake signal can sit to their left.
static void VLTCollectItems(UIView *view, UIView *bar, UIView *skip, int depth, CGFloat *minX, CGFloat *midY, UIColor **ink) {
    if (depth > 8 || view == skip || view.hidden || view.alpha < 0.02) return;
    NSString *name = nil;
    BOOL item = VLTIsItemClass([view class], name);
    if (item && view != bar) {
        CGRect frame = [view convertRect:view.bounds toView:bar];
        if (frame.size.width > 1 && frame.size.height > 1 && CGRectGetMidX(frame) > bar.bounds.size.width * 0.55) {
            if (frame.origin.x < *minX) {
                *minX = frame.origin.x;
                *midY = CGRectGetMidY(frame);
            }
            if (!*ink && [view isKindOfClass:[UILabel class]] && [(UILabel *)view textColor]) *ink = [(UILabel *)view textColor];
        }
        return;
    }
    for (UIView *subview in view.subviews) VLTCollectItems(subview, bar, skip, depth + 1, minX, midY, ink);
}

static void VLTApplySignal(UIView *bar) {
    VLTSignalView *signal = objc_getAssociatedObject(bar, kSignalKey);
    BOOL wanted = gSigOn && bar.window && bar.bounds.size.width > 300;
    if (!wanted) {
        if (signal) {
            [signal removeFromSuperview];
            objc_setAssociatedObject(bar, kSignalKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (!signal) {
        signal = [[VLTSignalView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(bar, kSignalKey, signal, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (signal.superview != bar) [bar addSubview:signal];

    // The bar lays its items out after itself; ask for that now so their places are current.
    for (UIView *subview in bar.subviews) if (subview != signal) [subview layoutIfNeeded];
    CGFloat minX = CGFLOAT_MAX, midY = bar.bounds.size.height / 2;
    UIColor *ink = nil;
    VLTCollectItems(bar, bar, signal, 0, &minX, &midY, &ink);
    // Nothing on the right (the left half of Split View, say): no signal there either.
    signal.hidden = minX == CGFLOAT_MAX || !isfinite(minX) || !isfinite(midY);
    if (signal.hidden) return;
    if (!ink) {   // no label on that side: borrow the clock's color
        for (_UIStatusBarStringView *view in VLTTextViews().allObjects) {
            if ([view isDescendantOfView:bar] && view.textColor) { ink = view.textColor; break; }
        }
    }
    if (!ink && [bar respondsToSelector:@selector(foregroundColor)]) ink = [(_UIStatusBar *)bar foregroundColor];
    signal.ink = [ink isKindOfClass:[UIColor class]] ? ink : (bar.tintColor ?: [UIColor whiteColor]);
    CGSize size = [signal wantedSize];
    CGRect frame = CGRectMake(floor(minX - 7 - size.width), round(midY - size.height / 2), size.width, size.height);
    if (!CGRectEqualToRect(signal.frame, frame)) {
        signal.frame = frame;
        [signal setNeedsDisplay];
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
}

// Items come and go without the bar itself laying out; follow them.
- (void)_updateWithAggregatedData:(id)data {
    %orig;
    if (gSigOn) [(UIView *)self setNeedsLayout];
}

- (void)layoutSubviews {
    %orig;
    if (gSigOn || objc_getAssociatedObject(self, kSignalKey)) VLTApplySignal((UIView *)self);
}

%end

%end // group StatusLook

static void VLTStatusRefresh(void) {
    VLTLoadStatus();
    VLTSyncSecondsTimer();
    VLTReplayText(0);
    for (UIView *bar in VLTBars().allObjects) {
        VLTApplySignal(bar);
        [(UIView *)objc_getAssociatedObject(bar, kSignalKey) setNeedsDisplay];
        [bar setNeedsLayout];
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
