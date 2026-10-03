// Volta - things that pop up over everything: a custom volume / brightness
// indicator and a charging animation. SpringBoard only.
//
// Both are drawn in one small window of Volta's own that takes no touches and
// is hidden whenever nothing is showing.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import "VLTShared.h"

#pragma mark - Settings

static BOOL gHudOn, gHudBrightness, gHudPercent = YES;
static NSInteger gHudStyle;         // 0 pill, 1 slim bar, 2 side bar
static UIColor *gHudColor;
static BOOL gChargeOn;
static NSInteger gChargeStyle;      // 0 ring, 1 battery filling up, 2 bolt
static UIColor *gChargeColor;

static void VLTLoadPopupPrefs(void) {
    NSDictionary *p = VLTCopyPrefs();
    BOOL on = VLTBool(p, @"enabled", YES);
    gHudOn = on && VLTBool(p, @"hudOn", NO);
    gHudBrightness = gHudOn && VLTBool(p, @"hudBrightness", NO);
    gHudPercent = VLTBool(p, @"hudPercent", YES);
    gHudStyle = (NSInteger)VLTNum(p, @"hudStyle", 0);
    if (gHudStyle < 0 || gHudStyle > 2) gHudStyle = 0;
    gHudColor = VLTColorFromHex(p[@"hudColor"]) ?: [UIColor colorWithRed:0.357 green:0.357 blue:0.941 alpha:1];
    gChargeOn = on && VLTBool(p, @"chargeOn", NO);
    gChargeStyle = (NSInteger)VLTNum(p, @"chargeStyle", 0);
    if (gChargeStyle < 0 || gChargeStyle > 2) gChargeStyle = 0;
    gChargeColor = VLTColorFromHex(p[@"chargeColor"]) ?: [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1];
}

#pragma mark - The window

@interface UIWindow (VLTPopupPrivate)
- (void)_setSecure:(BOOL)secure;
@end

@interface VLTPopupController : UIViewController
@end

@implementation VLTPopupController
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)prefersStatusBarHidden { return NO; }
@end

@interface VLTPopupWindow : UIWindow
@end

@implementation VLTPopupWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }   // never takes a touch
- (BOOL)canBecomeKeyWindow { return NO; }
@end

static VLTPopupWindow *gWindow;
static NSInteger gShowing;   // how many things are on screen; the window hides at zero

static UIView *VLTPopupHost(void) {
    if (!gWindow) {
        gWindow = [[VLTPopupWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        if (!gWindow.windowScene) {   // normally it joins SpringBoard's scene by itself
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]] && ((UIWindowScene *)scene).screen == [UIScreen mainScreen]) {
                    gWindow.windowScene = (UIWindowScene *)scene;
                    break;
                }
            }
        }
        gWindow.windowLevel = UIWindowLevelStatusBar + 200;
        gWindow.backgroundColor = [UIColor clearColor];
        gWindow.userInteractionEnabled = NO;
        gWindow.rootViewController = [[VLTPopupController alloc] init];
        gWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
        gWindow.rootViewController.view.userInteractionEnabled = NO;
        gWindow.rootViewController.view.accessibilityElementsHidden = YES;
        if ([gWindow respondsToSelector:@selector(_setSecure:)]) [gWindow _setSecure:YES];   // also shown over the Lock Screen
    }
    gWindow.hidden = NO;
    return gWindow.rootViewController.view;
}

static void VLTPopupBegin(void) { gShowing++; }

static void VLTPopupEnd(void) {
    if (gShowing > 0) gShowing--;
    if (gShowing == 0) gWindow.hidden = YES;
}

#pragma mark - Volume / brightness indicator

@interface VLTHUDView : UIView
- (void)showKind:(NSInteger)kind level:(CGFloat)level;   // 0 volume, 1 brightness
@end

@implementation VLTHUDView {
    UIVisualEffectView *_plate;
    UIView *_track, *_fill;
    UIImageView *_icon;
    UILabel *_percent;
    NSInteger _kind, _style;
    CGFloat _level;
    NSUInteger _generation;
    BOOL _visible;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _plate = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
        _plate.clipsToBounds = YES;
        _plate.layer.cornerCurve = kCACornerCurveContinuous;
        _plate.alpha = 0;
        [self addSubview:_plate];
        _track = [[UIView alloc] init];
        _track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
        _track.clipsToBounds = YES;
        [_plate.contentView addSubview:_track];
        _fill = [[UIView alloc] init];
        [_track addSubview:_fill];
        _icon = [[UIImageView alloc] init];
        _icon.tintColor = [UIColor whiteColor];
        _icon.contentMode = UIViewContentModeCenter;
        [_plate.contentView addSubview:_icon];
        _percent = [[UILabel alloc] init];
        _percent.textColor = [UIColor whiteColor];
        _percent.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
        _percent.textAlignment = NSTextAlignmentRight;
        [_plate.contentView addSubview:_percent];
    }
    return self;
}

- (NSString *)symbol {
    if (_kind == 1) return _level < 0.5 ? @"sun.min.fill" : @"sun.max.fill";
    if (_level < 0.005) return @"speaker.slash.fill";
    return _level < 0.34 ? @"speaker.wave.1.fill" : (_level < 0.67 ? @"speaker.wave.2.fill" : @"speaker.wave.3.fill");
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    CGFloat top = MAX(self.safeAreaInsets.top, 24) + 8;
    BOOL label = gHudPercent && _style != 1;
    _percent.hidden = !label;
    _icon.hidden = _style == 1;
    _fill.backgroundColor = gHudColor;
    if (_style == 0) {          // pill, top centre
        CGFloat width = MIN(260, size.width - 40), height = 44;
        _plate.frame = CGRectMake((size.width - width) / 2, top, width, height);
        _plate.layer.cornerRadius = height / 2;
        _icon.frame = CGRectMake(10, 0, 30, height);
        _percent.frame = CGRectMake(width - 56, 0, 44, height);
        CGFloat trackRight = label ? width - 60 : width - 18;
        _track.frame = CGRectMake(46, (height - 6) / 2, trackRight - 46, 6);
        _track.layer.cornerRadius = 3;
        _fill.frame = CGRectMake(0, 0, _track.bounds.size.width * _level, 6);
    } else if (_style == 1) {   // slim bar across the top
        CGFloat width = MIN(size.width - 60, 520);
        _plate.frame = CGRectMake((size.width - width) / 2, top, width, 8);
        _plate.layer.cornerRadius = 4;
        _track.frame = _plate.bounds;
        _track.layer.cornerRadius = 4;
        _fill.frame = CGRectMake(0, 0, width * _level, 8);
    } else {                    // side bar, left edge
        CGFloat width = 46, height = MIN(190, size.height - 120);
        _plate.frame = CGRectMake(MAX(self.safeAreaInsets.left, 0) + 14, (size.height - height) / 2, width, height);
        _plate.layer.cornerRadius = 16;
        _icon.frame = CGRectMake(0, height - 38, width, 30);
        _percent.frame = CGRectMake(0, 8, width, 18);
        _percent.textAlignment = NSTextAlignmentCenter;
        CGFloat trackTop = label ? 32 : 14, trackHeight = height - 44 - trackTop;
        _track.frame = CGRectMake((width - 8) / 2, trackTop, 8, trackHeight);
        _track.layer.cornerRadius = 4;
        _fill.frame = CGRectMake(0, trackHeight * (1 - _level), 8, trackHeight * _level);
    }
    if (_style != 2) _percent.textAlignment = NSTextAlignmentRight;
}

- (void)showKind:(NSInteger)kind level:(CGFloat)level {
    _kind = kind;
    _level = fmin(fmax(level, 0), 1);
    BOOL styleChanged = _style != gHudStyle;
    _style = gHudStyle;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
    _icon.image = [UIImage systemImageNamed:[self symbol] withConfiguration:config];
    _percent.text = [NSString stringWithFormat:@"%ld", lround(_level * 100)];

    NSUInteger generation = ++_generation;
    if (!_visible) {
        _visible = YES;
        VLTPopupBegin();
        [self setNeedsLayout];
        [self layoutIfNeeded];
        _plate.transform = _style == 2 ? CGAffineTransformMakeTranslation(-20, 0) : CGAffineTransformMakeTranslation(0, -16);
        [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            self->_plate.alpha = 1;
            self->_plate.transform = CGAffineTransformIdentity;
        } completion:nil];
    } else {
        // Already up (or on its way out): bring it back to full and move the bar.
        if (styleChanged) {
            [self setNeedsLayout];
            [self layoutIfNeeded];
        }
        [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            self->_plate.alpha = 1;
            [self setNeedsLayout];
            [self layoutIfNeeded];
        } completion:nil];
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_generation != generation) return;   // changed again since; a newer timer is running
        [UIView animateWithDuration:0.3 animations:^{ strongSelf->_plate.alpha = 0; } completion:^(BOOL finished) {
            if (strongSelf->_generation != generation) return;
            strongSelf->_visible = NO;
            VLTPopupEnd();
        }];
    });
}

@end

static void VLTShowHUD(NSInteger kind, CGFloat level) {
    static VLTHUDView *hud;
    UIView *host = VLTPopupHost();
    if (!hud) hud = [[VLTHUDView alloc] initWithFrame:host.bounds];
    if (hud.superview != host) {
        hud.frame = host.bounds;
        [host addSubview:hud];
    }
    [hud showKind:kind level:level];
}

#pragma mark - Charging animation

@interface VLTChargeView : UIView
- (void)playWithLevel:(CGFloat)level completion:(void (^)(void))completion;
@end

@implementation VLTChargeView {
    UIView *_dim, *_stage;
    UILabel *_percent, *_caption;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _dim = [[UIView alloc] initWithFrame:self.bounds];
        _dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
        [self addSubview:_dim];
        _stage = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 240, 240)];
        [self addSubview:_stage];
        _percent = [[UILabel alloc] init];
        _percent.textColor = [UIColor whiteColor];
        _percent.font = [UIFont monospacedDigitSystemFontOfSize:46 weight:UIFontWeightBold];
        _percent.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_percent];
        _caption = [[UILabel alloc] init];
        _caption.textColor = [UIColor colorWithWhite:1 alpha:0.7];
        _caption.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        _caption.textAlignment = NSTextAlignmentCenter;
        _caption.text = @"Charging";
        [self addSubview:_caption];
        self.alpha = 0;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGPoint center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds) - 30);
    _stage.center = center;
    _percent.frame = CGRectMake(0, center.y + 130, self.bounds.size.width, 54);
    _caption.frame = CGRectMake(0, center.y + 184, self.bounds.size.width, 24);
}

- (CALayer *)boltLayerOfSize:(CGFloat)side color:(UIColor *)color {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:side weight:UIImageSymbolWeightBold];
    UIImage *bolt = [[UIImage systemImageNamed:@"bolt.fill" withConfiguration:config] imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    CALayer *layer = [CALayer layer];
    layer.contents = (__bridge id)bolt.CGImage;
    layer.contentsGravity = kCAGravityResizeAspect;
    layer.bounds = CGRectMake(0, 0, bolt.size.width, bolt.size.height);
    layer.position = CGPointMake(120, 120);
    return layer;
}

// Ring: a circle that fills to the charge level, with ripples.
- (void)buildRing:(CGFloat)level moving:(BOOL)moving {
    UIBezierPath *circle = [UIBezierPath bezierPathWithArcCenter:CGPointMake(120, 120) radius:96 startAngle:-M_PI_2 endAngle:M_PI * 1.5 clockwise:YES];
    CAShapeLayer *track = [CAShapeLayer layer];
    track.path = circle.CGPath;
    track.fillColor = NULL;
    track.strokeColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
    track.lineWidth = 14;
    [_stage.layer addSublayer:track];
    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.path = circle.CGPath;
    ring.fillColor = NULL;
    ring.strokeColor = gChargeColor.CGColor;
    ring.lineWidth = 14;
    ring.lineCap = kCALineCapRound;
    ring.strokeEnd = level;
    [_stage.layer addSublayer:ring];
    [_stage.layer addSublayer:[self boltLayerOfSize:64 color:gChargeColor]];
    if (!moving) return;
    CABasicAnimation *fill = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    fill.fromValue = @0;
    fill.toValue = @(level);
    fill.duration = 1.2;
    fill.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [ring addAnimation:fill forKey:@"fill"];
    for (int i = 0; i < 2; i++) {
        CAShapeLayer *ripple = [CAShapeLayer layer];
        ripple.path = circle.CGPath;
        ripple.frame = CGRectMake(0, 0, 240, 240);
        ripple.fillColor = NULL;
        ripple.strokeColor = gChargeColor.CGColor;
        ripple.lineWidth = 2;
        ripple.opacity = 0;
        [_stage.layer insertSublayer:ripple atIndex:0];
        CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        grow.fromValue = @1;
        grow.toValue = @1.7;
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @0.7;
        fade.toValue = @0;
        CAAnimationGroup *group = [CAAnimationGroup animation];
        group.animations = @[grow, fade];
        group.duration = 1.5;
        group.beginTime = CACurrentMediaTime() + 0.2 + i * 0.6;
        [ripple addAnimation:group forKey:@"ripple"];
    }
}

// Battery: an outline that fills up from the bottom.
- (void)buildBattery:(CGFloat)level moving:(BOOL)moving {
    CGRect body = CGRectMake(60, 38, 120, 184);
    CAShapeLayer *outline = [CAShapeLayer layer];
    outline.path = [UIBezierPath bezierPathWithRoundedRect:body cornerRadius:26].CGPath;
    outline.fillColor = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
    outline.strokeColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
    outline.lineWidth = 5;
    CAShapeLayer *tip = [CAShapeLayer layer];
    tip.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(98, 20, 44, 14) cornerRadius:6].CGPath;
    tip.fillColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;

    CGRect inner = CGRectInset(body, 10, 10);
    CALayer *well = [CALayer layer];
    well.frame = inner;
    well.cornerRadius = 17;
    well.masksToBounds = YES;
    CALayer *liquid = [CALayer layer];
    liquid.backgroundColor = gChargeColor.CGColor;
    liquid.anchorPoint = CGPointMake(0.5, 1);
    liquid.bounds = CGRectMake(0, 0, inner.size.width, inner.size.height * MAX(level, 0.04));
    liquid.position = CGPointMake(inner.size.width / 2, inner.size.height);
    [well addSublayer:liquid];
    [_stage.layer addSublayer:well];
    [_stage.layer addSublayer:outline];
    [_stage.layer addSublayer:tip];
    [_stage.layer addSublayer:[self boltLayerOfSize:48 color:[UIColor whiteColor]]];
    if (!moving) return;
    CABasicAnimation *rise = [CABasicAnimation animationWithKeyPath:@"bounds.size.height"];
    rise.fromValue = @0;
    rise.toValue = @(liquid.bounds.size.height);
    rise.duration = 1.3;
    rise.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [liquid addAnimation:rise forKey:@"rise"];
}

// Bolt: a big bolt that lands with sparks.
- (void)buildBolt:(BOOL)moving {
    CALayer *bolt = [self boltLayerOfSize:150 color:gChargeColor];
    bolt.shadowColor = gChargeColor.CGColor;
    bolt.shadowOpacity = 0.9;
    bolt.shadowRadius = 26;
    bolt.shadowOffset = CGSizeZero;
    [_stage.layer addSublayer:bolt];
    if (!moving) return;
    CAKeyframeAnimation *land = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    land.values = @[@0.2, @1.18, @0.94, @1];
    land.keyTimes = @[@0, @0.5, @0.75, @1];
    land.duration = 0.6;
    [bolt addAnimation:land forKey:@"land"];

    CAEmitterLayer *sparks = [CAEmitterLayer layer];
    sparks.emitterPosition = CGPointMake(120, 120);
    sparks.emitterShape = kCAEmitterLayerCircle;
    sparks.emitterSize = CGSizeMake(60, 60);
    sparks.beginTime = CACurrentMediaTime() + 0.25;
    CAEmitterCell *spark = [CAEmitterCell emitterCell];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(8, 8)];
    spark.contents = (__bridge id)[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor whiteColor] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 8, 8)] fill];
    }].CGImage;
    spark.color = gChargeColor.CGColor;
    spark.birthRate = 90;
    spark.lifetime = 0.9;
    spark.velocity = 220;
    spark.velocityRange = 90;
    spark.emissionRange = 2 * M_PI;
    spark.scale = 0.7;
    spark.scaleSpeed = -0.6;
    spark.alphaSpeed = -1.1;
    sparks.emitterCells = @[spark];
    [_stage.layer insertSublayer:sparks atIndex:0];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ sparks.birthRate = 0; });
}

- (void)playWithLevel:(CGFloat)level completion:(void (^)(void))completion {
    level = fmin(fmax(level, 0), 1);
    for (CALayer *layer in [_stage.layer.sublayers copy]) [layer removeFromSuperlayer];
    BOOL moving = !UIAccessibilityIsReduceMotionEnabled();
    if (gChargeStyle == 1) [self buildBattery:level moving:moving];
    else if (gChargeStyle == 2) [self buildBolt:moving];
    else [self buildRing:level moving:moving];
    _percent.text = [NSString stringWithFormat:@"%ld%%", lround(level * 100)];
    [self setNeedsLayout];

    [UIView animateWithDuration:0.3 animations:^{ self.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.45 animations:^{ self.alpha = 0; } completion:^(BOOL finished) {
            for (CALayer *layer in [self->_stage.layer.sublayers copy]) [layer removeFromSuperlayer];
            if (completion) completion();
        }];
    });
}

@end

static void VLTPlayCharge(void) {
    static VLTChargeView *view;
    static BOOL playing;
    if (playing) return;
    float level = [UIDevice currentDevice].batteryLevel;
    if (level < 0) return;   // unknown
    UIView *host = VLTPopupHost();
    if (!view) view = [[VLTChargeView alloc] initWithFrame:host.bounds];
    view.frame = host.bounds;
    if (view.superview != host) [host insertSubview:view atIndex:0];
    playing = YES;
    VLTPopupBegin();
    [view playWithLevel:level completion:^{
        playing = NO;
        VLTPopupEnd();
    }];
}

#pragma mark - Hooks and observers

%group Popups

%hook SBVolumeControl

// The system calls this to put up its own volume indicator; ours takes its place.
- (void)_presentVolumeHUDWithVolume:(float)volume {
    if (!gHudOn) {
        %orig;
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ VLTShowHUD(0, volume); });
        return;
    }
    VLTShowHUD(0, volume);
}

%end

%end // group Popups

static void VLTPopupPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ VLTLoadPopupPrefs(); });
}

// Fired from Settings: "Preview" buttons.
static void VLTPopupPreview(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    BOOL charge = name && CFStringHasSuffix(name, CFSTR("/previewCharge"));
    dispatch_async(dispatch_get_main_queue(), ^{
        VLTLoadPopupPrefs();
        if (charge) VLTPlayCharge();
        else VLTShowHUD(0, 0.6);
    });
}

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        VLTLoadPopupPrefs();
        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(darwin, NULL, VLTPopupPrefsChanged, CFSTR(VLT_NOTIFY_PREFS), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(darwin, NULL, VLTPopupPreview, CFSTR(VLT_DOMAIN "/previewCharge"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(darwin, NULL, VLTPopupPreview, CFSTR(VLT_DOMAIN "/previewHUD"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        %init(Popups);

        // Plugged in: play the animation. Only on a real change from "not charging".
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIDevice currentDevice].batteryMonitoringEnabled = YES;
            __block UIDeviceBatteryState last = [UIDevice currentDevice].batteryState;
            [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceBatteryStateDidChangeNotification object:nil queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                UIDeviceBatteryState state = [UIDevice currentDevice].batteryState;
                BOOL was = last == UIDeviceBatteryStateCharging || last == UIDeviceBatteryStateFull;
                BOOL is = state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull;
                if (gChargeOn && is && !was && last != UIDeviceBatteryStateUnknown) VLTPlayCharge();
                last = state;
            }];

            // Brightness: only for a clear change (a drag), not the slow drift of auto-brightness.
            __block CGFloat baseline = [UIScreen mainScreen].brightness;
            __block CFTimeInterval baselineTime = CACurrentMediaTime(), lastShown = 0;
            [[NSNotificationCenter defaultCenter] addObserverForName:UIScreenBrightnessDidChangeNotification object:nil queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                CGFloat value = [UIScreen mainScreen].brightness;
                CFTimeInterval now = CACurrentMediaTime();
                BOOL continuing = now - lastShown < 1.5;
                if (gHudBrightness && (continuing || fabs(value - baseline) >= 0.1)) {
                    lastShown = now;
                    VLTShowHUD(1, value);
                }
                if (now - baselineTime > 1.2 || continuing) {
                    baseline = value;
                    baselineTime = now;
                }
            }];
        });
    }
}
