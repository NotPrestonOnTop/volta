//
//  Volta - Tweak.x
//
//  Part 1 (every app + SpringBoard): restyles the status bar battery.
//  Part 2 (SpringBoard only):        restyles Control Center.
//
//  All private classes are touched defensively (respondsToSelector / KVC in
//  @try), so a class that changed between iOS versions makes one feature a
//  no-op instead of crashing.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "VLTShared.h"

#pragma mark - Private interfaces

@interface _UIBatteryView : UIView
@property (nonatomic) CGFloat chargePercent;       // 0.0 - 1.0
@property (nonatomic) NSInteger chargingState;     // 1 = charging
@property (nonatomic) BOOL saverModeActive;
@property (nonatomic) BOOL showsPercentage;        // number inside the icon (iOS 16+)
@property (nonatomic, copy) UIColor *bodyColor;
@property (nonatomic, copy) UIColor *pinColor;
@property (nonatomic, copy) UIColor *boltColor;   // not present on every iOS version
- (UIColor *)_batteryFillColor;
- (BOOL)isLowBattery;
@end

// Image-based battery used by parts of the status bar on iOS 15 and later.
@interface _UIStaticBatteryView : _UIBatteryView
@end

@interface _UIStatusBarStringView : UILabel
@end

@interface _UIStatusBarBatteryItem : NSObject
@property (nonatomic, retain) _UIStatusBarStringView *percentView;
@end

@interface UIView (VLTPrivate)
- (void)_setContinuousCornerRadius:(CGFloat)radius;
- (CGFloat)_continuousCornerRadius;
- (void)_setCornerRadius:(CGFloat)radius;
@end

#pragma mark - State

static VLTState gState;          // battery settings (all processes)
static BOOL gIsSpringBoard;
static BOOL gRefreshing;         // YES while we replay real values through our own hooks
static BOOL gNestedSetter;       // YES while a subclass hook is calling down to the base class
static UIImage *gCustomImage;    // the user's picture, unscaled
static BOOL gCustomLoaded;
static uint8_t gCustomLoadedGen;

static inline BOOL VLTActive(void)            { return (gState.flags1 & VLTOn) != 0; }
static inline BOOL VLTFlag1(uint8_t f)        { return VLTActive() && (gState.flags1 & f); }
static inline BOOL VLTCustomColor(uint8_t f)  { return VLTFlag1(VLTColors) && (gState.flags2 & f); }

static inline void VLTCallVoid(id obj, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if ([obj respondsToSelector:sel]) ((void (*)(id, SEL))objc_msgSend)(obj, sel);
}

// Associated-object keys
static const void *kRealPercent   = &kRealPercent;
static const void *kRealCharging  = &kRealCharging;
static const void *kRealSaver     = &kRealSaver;
static const void *kRealShowsPct  = &kRealShowsPct;
static const void *kRealBody      = &kRealBody;
static const void *kRealPin       = &kRealPin;
static const void *kRealBolt      = &kRealBolt;
static const void *kHideMask      = &kHideMask;
static const void *kImageApplied  = &kImageApplied;
static const void *kPinMask       = &kPinMask;
static const void *kIsPercentView = &kIsPercentView;
static const void *kRealText      = &kRealText;
static const void *kRealTextColor = &kRealTextColor;

static NSHashTable *VLTBatteryViews(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static NSHashTable *VLTPercentViews(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

#pragma mark - Status bar fun

// The clock, the percentage and the battery in every app's status bar. The
// animations are additive, so the system keeps laying the items out as usual.
static NSHashTable *VLTStatusViews(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static void VLTStatusLoop(CALayer *layer, NSString *key, NSString *keyPath, BOOL on, CGFloat from, CGFloat to, CFTimeInterval duration, BOOL reverses) {
    if (!on) {
        [layer removeAnimationForKey:key];
        return;
    }
    if ([layer animationForKey:key]) return;
    CABasicAnimation *loop = [CABasicAnimation animationWithKeyPath:keyPath];
    loop.fromValue = @(from);
    loop.toValue = @(to);
    loop.additive = YES;
    loop.duration = duration;
    loop.autoreverses = reverses;
    loop.repeatCount = HUGE_VALF;
    loop.removedOnCompletion = NO;
    loop.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [layer addAnimation:loop forKey:key];
}

static void VLTApplyStatusFun(UIView *view) {
    if (!view.window) return;
    uint8_t flags = VLTActive() ? gState.reserved[0] : 0;
    BOOL moving = !UIAccessibilityIsReduceMotionEnabled();
    CALayer *layer = view.layer;
    VLTStatusLoop(layer, @"vltStatusWiggle", @"transform.rotation.z", moving && (flags & VLTStatusWiggle), -0.16, 0.16, 0.45, YES);
    VLTStatusLoop(layer, @"vltStatusBounce", @"transform.translation.y", moving && (flags & VLTStatusBounce), -2.0, 2.0, 0.35, YES);
    VLTStatusLoop(layer, @"vltStatusPulse", @"transform.scale", moving && (flags & VLTStatusPulse), -0.12, 0.18, 0.6, YES);
    VLTStatusLoop(layer, @"vltStatusFlip", @"transform.rotation.z", (flags & VLTStatusFlip) != 0, M_PI, M_PI, 1000, NO);
}

static void VLTRefreshStatusFun(void) {
    for (UIView *view in VLTStatusViews().allObjects) VLTApplyStatusFun(view);
}

#pragma mark - Battery helpers

static NSCache *VLTImageCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 60; });
    return cache;
}

static NSArray<UIImage *> *gUserFrames;   // the user's animation frames, unscaled
static BOOL gFramesLoaded;
static uint8_t gFramesLoadedGen;

static UIImage *VLTCustomSource(void) {
    // SpringBoard gets the picture straight from preferences (see VLTSyncCustomImage).
    if (!gIsSpringBoard && (!gCustomLoaded || gCustomLoadedGen != gState.imageGen)) {
        NSData *data = [NSData dataWithContentsOfFile:VLT_IMAGE_PATH];
        gCustomImage = data ? [UIImage imageWithData:data] : nil;
        gCustomLoaded = YES;
        gCustomLoadedGen = gState.imageGen;
    }
    return gCustomImage;
}

static NSArray<UIImage *> *VLTUserFrames(void) {
    // Same arrangement: SpringBoard has them from preferences, apps read the shared files.
    if (!gIsSpringBoard && (!gFramesLoaded || gFramesLoadedGen != gState.imageGen)) {
        NSMutableArray *frames = [NSMutableArray array];
        for (NSUInteger i = 0; i < gState.animFrames && i < VLT_MAX_FRAMES; i++) {
            NSData *data = [NSData dataWithContentsOfFile:VLTFramePath(i)];
            UIImage *image = data ? [UIImage imageWithData:data] : nil;
            if (image) [frames addObject:image];
        }
        gUserFrames = frames;
        gFramesLoaded = YES;
        gFramesLoadedGen = gState.imageGen;
    }
    return gUserFrames;
}

// The picture that replaces the battery icon, as one frame (a still) or
// several (an animation), or nil to keep the normal icon. `key` identifies
// the result, so callers can tell when it changed.
static NSArray<UIImage *> *VLTBatteryFrames(double fraction, NSString **key, double *fps) {
    if (!VLTActive() || gState.imageKind == VLT_IMAGE_NONE) return nil;

    BOOL animated = gState.imageKind == VLT_IMAGE_ANIMATED;
    int effect = animated ? VLTEffectNone : gState.animEffect;
    if (fps) *fps = animated ? MAX(gState.animFps, 1) : VLT_EFFECT_FPS;

    CGFloat height = VLT_IMAGE_HEIGHT * gState.scale / 100.0;
    NSString *baseKey = [NSString stringWithFormat:@"%d-%d-%d-%d", gState.imageKind, gState.imageGen, gState.scale, effect];
    NSArray<UIImage *> *base = [VLTImageCache() objectForKey:baseKey];
    if (!base) {
        if (animated) {
            base = VLTFittedFrames(VLTUserFrames(), height, 0);
        } else {
            UIImage *still = (gState.imageKind == VLT_IMAGE_CUSTOM) ? VLTFittedImage(VLTCustomSource(), height, 0)
                                                                    : VLTThemeImage(gState.imageKind, height, 0);
            if (still) base = VLTEffectFrames(still, effect) ?: @[still];
        }
        if (!base.count) return nil;   // e.g. this app could not read the picture files
        [VLTImageCache() setObject:base forKey:baseKey];
    }
    if (!(gState.flags2 & VLTImageFill)) {
        if (key) *key = baseKey;
        return base;
    }

    int step = (int)lround(fmin(fmax(fraction, 0), 1) * 50);   // 2 % steps
    NSString *levelKey = [baseKey stringByAppendingFormat:@"-%d", step];
    NSArray<UIImage *> *frames = [VLTImageCache() objectForKey:levelKey];
    if (!frames) {
        NSMutableArray *filled = [NSMutableArray arrayWithCapacity:base.count];
        for (UIImage *frame in base) {
            UIImage *level = VLTLevelImage(frame, step / 50.0);
            if (level) [filled addObject:level];
        }
        frames = filled;
        if (frames.count) [VLTImageCache() setObject:frames forKey:levelKey];
    }
    if (key) *key = levelKey;
    return frames;
}

static const void *kAnimKey = &kAnimKey;
static NSString * const kVLTFrameAnimation = @"voltaFrames";

// Size, visibility and picture. layer.contents, sublayerTransform and mask are
// all left alone by the status bar's own layout and animations, so they
// survive transitions.
static void VLTApplyGeometry(_UIBatteryView *view) {
    NSString *framesKey = nil;
    double fps = VLT_EFFECT_FPS;
    NSArray<UIImage *> *frames = VLTBatteryFrames(view.chargePercent, &framesKey, &fps);
    UIImage *image = frames.firstObject;
    if (image) {
        // Draw the picture as the view's own contents (it may overflow the
        // small battery frame) and shrink the real battery layers to nothing.
        id contents = (__bridge id)image.CGImage;
        if (view.layer.contents != contents) {
            view.layer.contentsGravity = kCAGravityCenter;
            view.layer.contentsScale = image.scale;
            view.layer.contents = contents;
        }
        view.layer.sublayerTransform = CATransform3DMakeScale(0.0001, 0.0001, 1);
        objc_setAssociatedObject(view, kImageApplied, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // More than one frame: flip through them by animating the contents.
        // Core Animation drops animations when a view leaves the screen, so
        // this also re-adds a missing one.
        BOOL animate = frames.count > 1 && fps > 0 && !UIAccessibilityIsReduceMotionEnabled();
        NSString *current = objc_getAssociatedObject(view, kAnimKey);
        if (animate) {
            if (![current isEqualToString:framesKey] || ![view.layer animationForKey:kVLTFrameAnimation]) {
                NSMutableArray *images = [NSMutableArray arrayWithCapacity:frames.count];
                for (UIImage *frame in frames) [images addObject:(__bridge id)frame.CGImage];
                CAKeyframeAnimation *flip = [CAKeyframeAnimation animationWithKeyPath:@"contents"];
                flip.values = images;
                flip.calculationMode = kCAAnimationDiscrete;
                flip.duration = frames.count / fps;
                flip.repeatCount = HUGE_VALF;
                flip.removedOnCompletion = NO;
                [view.layer addAnimation:flip forKey:kVLTFrameAnimation];
                objc_setAssociatedObject(view, kAnimKey, framesKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
            }
        } else if (current) {
            [view.layer removeAnimationForKey:kVLTFrameAnimation];
            objc_setAssociatedObject(view, kAnimKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
    } else {
        if (objc_getAssociatedObject(view, kAnimKey)) {
            [view.layer removeAnimationForKey:kVLTFrameAnimation];
            objc_setAssociatedObject(view, kAnimKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        if (objc_getAssociatedObject(view, kImageApplied)) {
            view.layer.contents = nil;
            objc_setAssociatedObject(view, kImageApplied, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CGFloat scale = VLTActive() ? gState.scale / 100.0 : 1.0;
        view.layer.sublayerTransform = (fabs(scale - 1.0) < 0.01) ? CATransform3DIdentity
                                                                 : CATransform3DMakeScale(scale, scale, 1);
        // iOS versions without a boltColor property: color the bolt layer directly.
        if (VLTCustomColor(VLTHasBolt) && ![view respondsToSelector:@selector(setBoltColor:)]) {
            @try {
                id bolt = [view valueForKey:@"boltLayer"];
                if ([bolt isKindOfClass:[CAShapeLayer class]])
                    [(CAShapeLayer *)bolt setFillColor:VLTColorFromRGBA(gState.bolt).CGColor];
            } @catch (__unused NSException *e) {}
        }
    }

    // The tip. Changing pinColor is not enough on iOS 15 (the status bar never
    // asks for it again), so work on the tip's own layer.
    CALayer *pin = nil;
    for (NSString *key in @[@"pinLayer", @"pinShapeLayer"]) {
        @try {
            id layer = [view valueForKey:key];
            if ([layer isKindOfClass:[CALayer class]]) { pin = layer; break; }
        } @catch (__unused NSException *e) {}
    }
    if (pin) {
        CALayer *pinMask = objc_getAssociatedObject(view, kPinMask);
        if (VLTFlag1(VLTHidePin)) {
            if (!pin.mask) {
                CALayer *mask = [CALayer layer];
                pin.mask = mask;
                objc_setAssociatedObject(view, kPinMask, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } else {
            if (pinMask) {
                if (pin.mask == pinMask) pin.mask = nil;
                objc_setAssociatedObject(view, kPinMask, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (VLTCustomColor(VLTHasPin) && [pin isKindOfClass:[CAShapeLayer class]])
                [(CAShapeLayer *)pin setFillColor:VLTColorFromRGBA(gState.pin).CGColor];
        }
    }

    CALayer *ours = objc_getAssociatedObject(view, kHideMask);
    if (VLTFlag1(VLTHideIcon)) {
        if (!view.layer.mask) {
            CALayer *mask = [CALayer layer];   // empty mask = nothing drawn
            view.layer.mask = mask;
            objc_setAssociatedObject(view, kHideMask, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else if (ours) {
        if (view.layer.mask == ours) view.layer.mask = nil;
        objc_setAssociatedObject(view, kHideMask, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static NSString *VLTDisplayText(NSString *real) {
    if (!VLTActive() || real.length == 0) return real;
    if (gState.flags1 & VLTHidePercent) return @"";

    NSString *label = VLTStateLabel(&gState);
    if (label.length) return label;

    BOOL hideSymbol = (gState.flags1 & VLTHideSymbol) != 0;
    NSInteger value;
    if (gState.flags1 & VLTFake) {
        value = gState.fakePercent;
    } else if (hideSymbol) {
        NSScanner *scanner = [NSScanner scannerWithString:real];
        [scanner scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:NULL];
        if (![scanner scanInteger:&value]) return real;
    } else {
        return real;
    }
    return [NSString stringWithFormat:(hideSymbol ? @"%ld" : @"%ld%%"), (long)value];
}

// Pushes the real values back through the hooked setters so they pick up the
// current settings. Called whenever settings change.
static void VLTRefreshBattery(void) {
    gRefreshing = YES;
    for (_UIBatteryView *view in VLTBatteryViews().allObjects) {
        NSNumber *n;
        UIColor *c;
        if ((n = objc_getAssociatedObject(view, kRealPercent)))  [view setChargePercent:n.doubleValue];
        if ((n = objc_getAssociatedObject(view, kRealCharging))) [view setChargingState:n.integerValue];
        if ((n = objc_getAssociatedObject(view, kRealSaver)))    [view setSaverModeActive:n.boolValue];
        if ((n = objc_getAssociatedObject(view, kRealShowsPct)) && [view respondsToSelector:@selector(setShowsPercentage:)])
            [view setShowsPercentage:n.boolValue];
        if ((c = objc_getAssociatedObject(view, kRealBody))) [view setBodyColor:c];
        if ((c = objc_getAssociatedObject(view, kRealPin)))  [view setPinColor:c];
        if ((c = objc_getAssociatedObject(view, kRealBolt)) && [view respondsToSelector:@selector(setBoltColor:)])
            [view setBoltColor:c];

        for (NSString *sel in @[@"_updateFillColor", @"_updateBatteryFillColor", @"_updateBodyColors", @"_updateBolt", @"_updatePercentage"])
            VLTCallVoid(view, sel);
        VLTApplyGeometry(view);
        [view setNeedsLayout];
    }
    for (_UIStatusBarStringView *view in VLTPercentViews().allObjects) {
        NSString *text = objc_getAssociatedObject(view, kRealText);
        UIColor *color = objc_getAssociatedObject(view, kRealTextColor);
        if (text) [view setText:text];
        if (color) [view setTextColor:color];
    }
    gRefreshing = NO;
    VLTRefreshStatusFun();
}

#pragma mark - Battery hooks

%group Battery

%hook _UIBatteryView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [VLTBatteryViews() addObject:self];
        [VLTStatusViews() addObject:self];
        VLTApplyGeometry(self);
        VLTApplyStatusFun(self);
    }
}

- (void)layoutSubviews {
    %orig;
    VLTApplyGeometry(self);
}

- (void)setChargePercent:(CGFloat)percent {
    if (!gRefreshing) objc_setAssociatedObject(self, kRealPercent, @(percent), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (VLTFlag1(VLTFake)) percent = gState.fakePercent / 100.0;
    %orig(percent);
    if (VLTActive() && gState.imageKind != VLT_IMAGE_NONE) VLTApplyGeometry(self);   // picture may track the level
}

- (void)setChargingState:(NSInteger)state {
    if (!gRefreshing) {
        objc_setAssociatedObject(self, kRealCharging, @(state), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (VLTActive()) {
        if (gState.chargeMode == 1) state = 1;
        else if (gState.chargeMode == 2) state = 0;
    }
    %orig(state);
}

- (void)setSaverModeActive:(BOOL)active {
    if (!gRefreshing) objc_setAssociatedObject(self, kRealSaver, @(active), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (VLTActive()) {
        if (gState.saverMode == 1) active = YES;
        else if (gState.saverMode == 2) active = NO;
    }
    %orig(active);
}

- (void)setShowsPercentage:(BOOL)shows {
    if (gNestedSetter) {   // already handled by the _UIStaticBatteryView hook below
        %orig;
        return;
    }
    if (!gRefreshing) objc_setAssociatedObject(self, kRealShowsPct, @(shows), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (VLTActive()) {
        if (gState.inIconMode == 1) shows = YES;
        else if (gState.inIconMode == 2) shows = NO;
    }
    %orig(shows);
}

- (void)setBodyColor:(UIColor *)color {
    if (!gRefreshing && color) objc_setAssociatedObject(self, kRealBody, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (VLTCustomColor(VLTHasBody)) color = VLTColorFromRGBA(gState.body);
    %orig(color);
}

- (void)setPinColor:(UIColor *)color {
    if (!gRefreshing && color) objc_setAssociatedObject(self, kRealPin, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (VLTFlag1(VLTHidePin)) color = [UIColor clearColor];
    else if (VLTCustomColor(VLTHasPin)) color = VLTColorFromRGBA(gState.pin);
    %orig(color);
}

- (void)setBoltColor:(UIColor *)color {
    if (!gRefreshing && color) objc_setAssociatedObject(self, kRealBolt, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (VLTCustomColor(VLTHasBolt)) color = VLTColorFromRGBA(gState.bolt);
    %orig(color);
}

// The colour of the charge level bar.
- (UIColor *)_batteryFillColor {
    UIColor *original = %orig;
    if (!VLTFlag1(VLTColors)) return original;

    // Optionally leave green (charging), yellow (Low Power) and red (low) alone.
    if (gState.flags2 & VLTKeepStatus) {
        BOOL low = [self respondsToSelector:@selector(isLowBattery)] ? [self isLowBattery] : self.chargePercent <= 0.20;
        BOOL special = self.saverModeActive || self.chargingState == 1 || low;
        if (special) return original;
    }
    if (gState.flags1 & VLTLevelColor) return VLTLevelColorFor(self.chargePercent);
    if (gState.flags2 & VLTHasFill) return VLTColorFromRGBA(gState.fill);
    return original;
}

// Custom text for the number drawn inside the icon.
- (void)_updatePercentage {
    %orig;
    if (!VLTActive()) return;
    NSString *label = VLTStateLabel(&gState);
    if (!label.length) return;
    @try {
        id view = [self valueForKey:@"percentageLabel"];
        if ([view isKindOfClass:[UILabel class]]) [(UILabel *)view setText:label];
    } @catch (__unused NSException *e) {}
}

%end

// This subclass has its own setShowsPercentage:, so the forced value has to
// go in here; the base-class hook above then just passes it through.
%hook _UIStaticBatteryView

- (void)setShowsPercentage:(BOOL)shows {
    if (!gRefreshing) objc_setAssociatedObject(self, kRealShowsPct, @(shows), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (VLTActive()) {
        if (gState.inIconMode == 1) shows = YES;
        else if (gState.inIconMode == 2) shows = NO;
    }
    BOOL wasNested = gNestedSetter;
    gNestedSetter = YES;
    %orig(shows);
    gNestedSetter = wasNested;
}

%end

// The "85%" text shown next to the icon (older layouts and the Control Center
// status bar) is a generic string view, so we tag the battery's one first.
%hook _UIStatusBarBatteryItem

- (id)applyUpdate:(id)update toDisplayItem:(id)item {
    if ([self respondsToSelector:@selector(percentView)]) {
        _UIStatusBarStringView *view = self.percentView;
        if (view && !objc_getAssociatedObject(view, kIsPercentView)) {
            objc_setAssociatedObject(view, kIsPercentView, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [VLTPercentViews() addObject:view];
        }
    }
    return %orig;
}

%end

%hook _UIStatusBarStringView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [VLTStatusViews() addObject:self];
        VLTApplyStatusFun(self);
    }
}

- (void)setText:(NSString *)text {
    if (!objc_getAssociatedObject(self, kIsPercentView)) {
        %orig;
        return;
    }
    if (!gRefreshing) objc_setAssociatedObject(self, kRealText, text, OBJC_ASSOCIATION_COPY_NONATOMIC);
    %orig(VLTDisplayText(text));
}

- (void)setTextColor:(UIColor *)color {
    if (!objc_getAssociatedObject(self, kIsPercentView)) {
        %orig;
        return;
    }
    if (!gRefreshing && color) objc_setAssociatedObject(self, kRealTextColor, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (VLTCustomColor(VLTHasText)) color = VLTColorFromRGBA(gState.text);
    %orig(color);
}

%end

%end // group Battery

#pragma mark - Control Center (SpringBoard only)

static BOOL     gCCOn;
static CGFloat  gCCBlur = 1;            // 0 - 1, share of the system blur that is kept
static UIColor *gCCTint;
static CGFloat  gCCTintStrength;
static BOOL     gCCHideHeader;
static BOOL     gCCHaptic;
static BOOL     gCCRadiusOn;
static CGFloat  gCCRadius;
static CGFloat  gCCPlatter = 1;         // module background opacity
static UIColor *gCCModTint;
static CGFloat  gCCModTintStrength;
static CGFloat  gCCBorderWidth;
static UIColor *gCCBorderColor;
static UIColor *gCCToggleColor;
static CGFloat  gCCToggleShape = 1;     // 1 = circle, 0 = square

static const void *kCCBackground  = &kCCBackground;
static const void *kCCTintView    = &kCCTintView;
static const void *kCCHeaderMask  = &kCCHeaderMask;
static const void *kCCModuleTint  = &kCCModuleTint;
static const void *kCCModuleTouched = &kCCModuleTouched;
static const void *kCCToggleTouched = &kCCToggleTouched;
static const void *kCCRealRadius    = &kCCRealRadius;
static const void *kCCRealToggleColor = &kCCRealToggleColor;
static BOOL gCCApplying;   // YES while we call a hooked setter ourselves
static __weak UIViewController *gCCOverlay;   // the Control Center screen, once it exists

// Control Center keeps its tiles and buttons alive between openings, so they
// are remembered here and restyled the moment a setting changes.
static NSHashTable *VLTCCModules(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static NSHashTable *VLTCCToggles(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static inline BOOL VLTCCActive(void) { return VLTActive() && gCCOn; }
static inline CGFloat VLTClamp01(CGFloat x) { return fmin(fmax(x, 0), 1); }

static void VLTLoadCCPrefs(NSDictionary *p) {
    gCCOn              = VLTBool(p, @"ccEnabled", YES);
    gCCBlur            = VLTClamp01(VLTNum(p, @"ccBlur", 100) / 100.0);
    gCCTint            = VLTColorFromHex(p[@"ccTint"]);
    gCCTintStrength    = VLTClamp01(VLTNum(p, @"ccTintStrength", 35) / 100.0);
    gCCHideHeader      = VLTBool(p, @"ccHideHeader", NO);
    gCCHaptic          = VLTBool(p, @"ccHaptic", NO);
    gCCRadiusOn        = VLTBool(p, @"ccRadiusOn", NO);
    gCCRadius          = fmin(fmax(VLTNum(p, @"ccRadius", 19), 0), 40);
    gCCPlatter         = VLTClamp01(VLTNum(p, @"ccPlatter", 100) / 100.0);
    gCCModTint         = VLTColorFromHex(p[@"ccModTint"]);
    gCCModTintStrength = VLTClamp01(VLTNum(p, @"ccModTintStrength", 30) / 100.0);
    gCCBorderWidth     = fmin(fmax(VLTNum(p, @"ccBorderWidth", 0), 0), 4);
    gCCBorderColor     = VLTColorFromHex(p[@"ccBorderColor"]);
    gCCToggleColor     = VLTColorFromHex(p[@"ccToggleColor"]);
    gCCToggleShape     = VLTClamp01(VLTNum(p, @"ccToggleShape", 100) / 100.0);
}

// KVC lookup that never throws; finds a property or a "_name" ivar.
static UIView *VLTViewForKey(id object, NSString *key) {
    id value = nil;
    @try { value = [object valueForKey:key]; } @catch (__unused NSException *e) {}
    return [value isKindOfClass:[UIView class]] ? value : nil;
}

// The frosted tile behind a module. Usually a property; otherwise look for it.
static UIView *VLTModuleMaterial(UIView *container) {
    UIView *material = VLTViewForKey(container, @"moduleMaterialView");
    if (material) return material;
    Class materialClass = NSClassFromString(@"MTMaterialView");
    for (UIView *subview in container.subviews) {
        if (materialClass && [subview isKindOfClass:materialClass]) return subview;
    }
    return nil;
}

static UIView *VLTMakeTintView(void) {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.userInteractionEnabled = NO;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    return view;
}

static void VLTSetRadius(UIView *view, CGFloat radius) {
    if ([view respondsToSelector:@selector(_setContinuousCornerRadius:)]) {
        [view _setContinuousCornerRadius:radius];
    } else {
        view.layer.cornerRadius = radius;
        view.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

// Background blur + tint, and the status bar strip at the top.
static void VLTApplyCCBackground(UIViewController *controller) {
    BOOL active = VLTCCActive();
    gCCOverlay = controller;

    UIView *background = VLTViewForKey(controller, @"overlayBackgroundView");
    if (background) {
        objc_setAssociatedObject(background, kCCBackground, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIView *tint = objc_getAssociatedObject(background, kCCTintView);
        BOOL wantsTint = active && gCCTint && gCCTintStrength > 0.001;
        if (wantsTint && !tint) {
            tint = VLTMakeTintView();
            [background addSubview:tint];
            objc_setAssociatedObject(background, kCCTintView, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (tint) {
            tint.frame = background.bounds;
            tint.backgroundColor = gCCTint ?: [UIColor clearColor];
            // Follow the open/close progress when the background exposes it.
            CGFloat progress = 1;
            if ([background respondsToSelector:NSSelectorFromString(@"weighting")]) {
                @try { progress = [[background valueForKey:@"weighting"] doubleValue]; } @catch (__unused NSException *e) {}
            }
            tint.alpha = wantsTint ? VLTClamp01(progress) * gCCTintStrength : 0;
            [background bringSubviewToFront:tint];
        }
    }

    UIView *header = VLTViewForKey(controller, @"overlayHeaderView");
    if (header) {
        CALayer *ours = objc_getAssociatedObject(header, kCCHeaderMask);
        if (active && gCCHideHeader) {
            if (!header.layer.mask) {
                CALayer *mask = [CALayer layer];
                header.layer.mask = mask;
                objc_setAssociatedObject(header, kCCHeaderMask, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } else if (ours) {
            if (header.layer.mask == ours) header.layer.mask = nil;
            objc_setAssociatedObject(header, kCCHeaderMask, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static BOOL VLTModuleIsCompact(UIView *view) {
    @try {   // "_expanded" ivar on iOS 15 - 17
        id expanded = [view valueForKey:@"expanded"];
        if ([expanded respondsToSelector:@selector(boolValue)]) return ![expanded boolValue];
    } @catch (__unused NSException *e) {}
    return MAX(view.bounds.size.width, view.bounds.size.height) < 260;   // expanded modules are far larger
}

// Routes a radius through the module's own setter (hooked below), which is
// what iOS 15+ reads when it lays the tile out.
static void VLTSyncModuleRadius(UIView *container) {
    SEL setter = NSSelectorFromString(@"setCompactContinuousCornerRadius:");
    if (![container respondsToSelector:setter]) return;
    NSNumber *real = objc_getAssociatedObject(container, kCCRealRadius);
    BOOL custom = VLTCCActive() && gCCRadiusOn;
    if (!custom && !real) return;
    CGFloat wanted = custom ? gCCRadius : real.doubleValue;
    CGFloat current = -1;
    @try { current = [[container valueForKey:@"compactContinuousCornerRadius"] doubleValue]; } @catch (__unused NSException *e) {}
    if (fabs(current - wanted) < 0.01) return;
    gCCApplying = YES;
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(container, setter, wanted);
    gCCApplying = NO;
}

// One module tile: background opacity, tint, border, corner radius.
static void VLTApplyModuleStyle(UIView *container) {
    if (![container isKindOfClass:[UIView class]]) return;
    [VLTCCModules() addObject:container];
    BOOL active = VLTCCActive();
    BOOL touched = objc_getAssociatedObject(container, kCCModuleTouched) != nil;
    if (!active && !touched) return;

    UIView *material = VLTModuleMaterial(container);
    UIView *tint = objc_getAssociatedObject(container, kCCModuleTint);
    BOOL compact = VLTModuleIsCompact(container);
    VLTSyncModuleRadius(container);

    if (!active) {   // undo what we changed
        material.alpha = 1;
        container.layer.borderWidth = 0;
        [tint removeFromSuperview];
        NSNumber *real = objc_getAssociatedObject(container, kCCRealRadius);
        if (real && compact) {
            VLTSetRadius(container, real.doubleValue);
            if (material) VLTSetRadius(material, real.doubleValue);
        }
        objc_setAssociatedObject(container, kCCModuleTint, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(container, kCCModuleTouched, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    objc_setAssociatedObject(container, kCCModuleTouched, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (gCCRadiusOn && compact) {
        VLTSetRadius(container, gCCRadius);
        if (material) VLTSetRadius(material, gCCRadius);
    }
    CGFloat radius = [container respondsToSelector:@selector(_continuousCornerRadius)]
                   ? [container _continuousCornerRadius] : container.layer.cornerRadius;

    if (material) material.alpha = gCCPlatter;

    BOOL wantsTint = gCCModTint && gCCModTintStrength > 0.001;
    if (wantsTint && !tint) {
        tint = VLTMakeTintView();
        objc_setAssociatedObject(container, kCCModuleTint, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (tint) {
        if (wantsTint) {
            if (tint.superview != container) {
                if (material.superview == container) [container insertSubview:tint aboveSubview:material];
                else [container insertSubview:tint atIndex:0];
            }
            tint.frame = container.bounds;
            tint.backgroundColor = gCCModTint;
            tint.alpha = gCCModTintStrength;
            VLTSetRadius(tint, radius);
            tint.clipsToBounds = YES;
        } else {
            [tint removeFromSuperview];
        }
    }

    BOOL wantsBorder = gCCBorderWidth > 0.01 && gCCBorderColor;
    container.layer.borderWidth = wantsBorder ? gCCBorderWidth : 0;
    if (wantsBorder) container.layer.borderColor = gCCBorderColor.CGColor;
}

// Round toggles (Wi-Fi, Bluetooth, ...): active colour and shape.
static void VLTApplyToggleStyle(UIView *button) {
    [VLTCCToggles() addObject:button];
    BOOL active = VLTCCActive();
    BOOL touched = objc_getAssociatedObject(button, kCCToggleTouched) != nil;
    if (!active && !touched) return;

    UIView *normal = VLTViewForKey(button, @"normalStateBackgroundView");
    UIView *selected = VLTViewForKey(button, @"selectedStateBackgroundView");
    UIView *alternate = VLTViewForKey(button, @"alternateSelectedStateBackgroundView");
    CGFloat side = MIN(button.bounds.size.width, button.bounds.size.height);

    BOOL reshape = active && gCCToggleShape < 0.99;
    if (reshape || touched) {
        CGFloat radius = side / 2.0 * (reshape ? gCCToggleShape : 1);
        for (UIView *view in @[normal ?: (id)[NSNull null], selected ?: (id)[NSNull null], alternate ?: (id)[NSNull null]]) {
            if (![view isKindOfClass:[UIView class]]) continue;
            // Same private setter the button uses on itself; the frosted
            // background view overrides it to round its blur as well.
            if ([view respondsToSelector:@selector(_setCornerRadius:)]) [view _setCornerRadius:radius];
            else view.layer.cornerRadius = radius;
        }
    }

    BOOL recolor = active && gCCToggleColor != nil;
    if (selected) {
        UIColor *original = objc_getAssociatedObject(button, kCCRealToggleColor);
        if (recolor) {
            if (!original && selected.backgroundColor)
                objc_setAssociatedObject(button, kCCRealToggleColor, selected.backgroundColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            selected.backgroundColor = gCCToggleColor;
        } else if (original) {
            selected.backgroundColor = original;
            objc_setAssociatedObject(button, kCCRealToggleColor, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    objc_setAssociatedObject(button, kCCToggleTouched, (reshape || recolor) ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void VLTRefreshControlCenter(void) {
    for (UIView *container in VLTCCModules().allObjects) {
        VLTApplyModuleStyle(container);
        [container setNeedsLayout];
    }
    for (UIView *button in VLTCCToggles().allObjects) {
        VLTApplyToggleStyle(button);
        [button setNeedsLayout];
    }
    UIViewController *overlay = gCCOverlay;
    if (overlay.isViewLoaded) VLTApplyCCBackground(overlay);
}

%group ControlCenter

%hook CCUIModularControlCenterOverlayViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    VLTApplyCCBackground((UIViewController *)self);
    if (VLTCCActive() && gCCHaptic) {
        UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];
        [generator impactOccurred];
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    VLTApplyCCBackground((UIViewController *)self);
}

%end

// Control Center fades its backdrop in by animating "weighting" from 0 to 1.
// Only the view tagged in VLTApplyCCBackground is affected.
%hook MTMaterialView

- (void)setWeighting:(CGFloat)weighting {
    if (objc_getAssociatedObject(self, kCCBackground)) {
        BOOL active = VLTCCActive();
        UIView *tint = objc_getAssociatedObject(self, kCCTintView);
        if (tint) tint.alpha = (active && gCCTint) ? VLTClamp01(weighting) * gCCTintStrength : 0;
        if (active) weighting *= gCCBlur;
    }
    %orig(weighting);
}

%end

%hook CCUIContentModuleContentContainerView

- (void)layoutSubviews {
    %orig;
    VLTApplyModuleStyle((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    VLTApplyModuleStyle((UIView *)self);
}

// iOS 15+: the radius each tile uses while it is not expanded.
- (void)setCompactContinuousCornerRadius:(CGFloat)radius {
    if (!gCCApplying) objc_setAssociatedObject(self, kCCRealRadius, @(radius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (VLTCCActive() && gCCRadiusOn) radius = gCCRadius;
    %orig(radius);
}

%end

// Second route to the same tile, through the controller that owns it.
%hook CCUIContentModuleContainerViewController

- (void)viewWillLayoutSubviews {
    %orig;
    UIView *container = VLTViewForKey(self, @"contentContainerView");
    if (container) VLTApplyModuleStyle(container);
}

%end

%hook CCUIRoundButton

- (void)layoutSubviews {
    %orig;
    VLTApplyToggleStyle((UIView *)self);
}

%end

%end // group ControlCenter

#pragma mark - Settings plumbing

static void VLTRespring(void) {
    VLTGuardSet(@"expected", [NSDate date]);   // Crash Guard: this restart is on purpose
    Class actionClass = NSClassFromString(@"SBSRelaunchAction");
    Class serviceClass = NSClassFromString(@"FBSSystemService");
    SEL make = NSSelectorFromString(@"actionWithReason:options:targetURL:");
    SEL shared = NSSelectorFromString(@"sharedService");
    SEL send = NSSelectorFromString(@"sendActions:withResult:");
    if ([actionClass respondsToSelector:make] && [serviceClass respondsToSelector:shared]) {
        // options 4 = fade to black
        id action = ((id (*)(id, SEL, id, NSUInteger, id))objc_msgSend)(actionClass, make, @"Volta", 4, nil);
        id service = ((id (*)(id, SEL))objc_msgSend)(serviceClass, shared);
        if (action && [service respondsToSelector:send]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(service, send, [NSSet setWithObject:action], nil);
            return;
        }
    }
    exit(0);   // launchd restarts SpringBoard
}

// SpringBoard keeps the user's picture in memory and mirrors it to a file
// inside the jailbreak root, where sandboxed apps are able to read it.
static void VLTSyncCustomImage(NSDictionary *prefs) {
    NSData *data = prefs[@"batImageData"];
    gCustomImage = [data isKindOfClass:[NSData class]] ? [UIImage imageWithData:data] : nil;

    // The user's animation frames: keep them in memory, and mirror them to
    // numbered files for apps whenever they change.
    NSArray *stored = [prefs[@"batFrames"] isKindOfClass:[NSArray class]] ? prefs[@"batFrames"] : @[];
    NSMutableArray *frames = [NSMutableArray array], *frameData = [NSMutableArray array];
    for (id item in stored) {
        if (frames.count >= VLT_MAX_FRAMES) break;
        UIImage *image = [item isKindOfClass:[NSData class]] ? [UIImage imageWithData:item] : nil;
        if (image) { [frames addObject:image]; [frameData addObject:item]; }
    }
    gUserFrames = frames;
    if (gState.imageKind == VLT_IMAGE_ANIMATED) {
        if (!frames.count) {
            gState.imageKind = VLT_IMAGE_NONE;
            return;
        }
        gState.animFrames = (uint8_t)frames.count;
        NSFileManager *files = [NSFileManager defaultManager];
        BOOL same = [files contentsOfDirectoryAtPath:VLT_FRAMES_DIR error:NULL].count == frameData.count;
        for (NSUInteger i = 0; same && i < frameData.count; i++)
            same = [[NSData dataWithContentsOfFile:VLTFramePath(i)] isEqualToData:frameData[i]];
        if (!same) {
            [files removeItemAtPath:VLT_FRAMES_DIR error:NULL];
            [files createDirectoryAtPath:VLT_FRAMES_DIR withIntermediateDirectories:YES attributes:nil error:NULL];
            for (NSUInteger i = 0; i < frameData.count; i++) [frameData[i] writeToFile:VLTFramePath(i) atomically:YES];
        }
        return;
    }
    if (gState.imageKind != VLT_IMAGE_CUSTOM) return;
    if (!gCustomImage) {
        gState.imageKind = VLT_IMAGE_NONE;
        return;
    }
    NSFileManager *files = [NSFileManager defaultManager];
    if ([[NSData dataWithContentsOfFile:VLT_IMAGE_PATH] isEqualToData:data]) return;
    [files createDirectoryAtPath:VLT_IMAGE_DIR withIntermediateDirectories:YES attributes:nil error:NULL];
    if ([data writeToFile:VLT_IMAGE_PATH atomically:YES]) {
        [files setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:VLT_IMAGE_PATH error:NULL];
    } else {
        NSLog(@"[Volta] could not write %@; the picture will only show in SpringBoard", VLT_IMAGE_PATH);
    }
}

// SpringBoard: read real preferences, publish the battery part for apps.
static void VLTSpringBoardLoad(void) {
    NSDictionary *prefs = VLTCopyPrefs();
    gState = VLTStateFromPrefs(prefs);
    VLTSyncCustomImage(prefs);
    VLTLoadCCPrefs(prefs);
    [VLTImageCache() removeAllObjects];
    // Status bar text and the fake cutouts, for apps (written before they are told to reload).
    [[NSFileManager defaultManager] createDirectoryAtPath:VLT_IMAGE_DIR withIntermediateDirectories:YES attributes:nil error:NULL];
    NSDictionary *status = VLTStatusDict(prefs);
    if (![status isEqualToDictionary:[NSDictionary dictionaryWithContentsOfFile:VLT_STATUS_PATH] ?: @{}] ||
        ![[NSFileManager defaultManager] fileExistsAtPath:VLT_STATUS_PATH])
        [status writeToFile:VLT_STATUS_PATH atomically:YES];
    VLTStatePublish(&gState);
    notify_post(VLT_NOTIFY_APPLY);
}

static void VLTSpringBoardReload(void) {
    VLTSpringBoardLoad();
    VLTRefreshBattery();
    VLTRefreshControlCenter();
}

static void VLTPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ VLTSpringBoardReload(); });
}

static void VLTRespringRequested(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ VLTRespring(); });
}

// Apps: pick up the state SpringBoard published.
static void VLTStateChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gState = VLTStateRead();
        [VLTImageCache() removeAllObjects];
        VLTRefreshBattery();
    });
}

%ctor {
    @autoreleasepool {
        NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
        NSString *executable = [NSBundle mainBundle].executablePath ?: @"";
        gIsSpringBoard = [bundleID isEqualToString:@"com.apple.springboard"];

        // Only SpringBoard and real apps draw a status bar; skip daemons and extensions.
        if (!gIsSpringBoard) {
            if (!bundleID) return;
            if (![executable containsString:@"/Application"]) return;
            if ([executable containsString:@".appex/"]) return;
        }

        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        if (gIsSpringBoard) {
            VLTSpringBoardLoad();   // also notifies apps that outlived a respring

            CFNotificationCenterAddObserver(darwin, NULL, VLTPrefsChanged, CFSTR(VLT_NOTIFY_PREFS), NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(darwin, NULL, VLTRespringRequested, CFSTR(VLT_NOTIFY_RESPRING), NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
        } else {
            gState = VLTStateRead();
            CFNotificationCenterAddObserver(darwin, NULL, VLTStateChanged, CFSTR(VLT_NOTIFY_APPLY), NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        // Animations are dropped while an app is in the background; put them back.
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) { VLTRefreshStatusFun(); }];

        %init(Battery);
        if (gIsSpringBoard) %init(ControlCenter);
    }
}
