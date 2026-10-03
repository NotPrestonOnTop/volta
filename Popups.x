// Volta - things drawn over everything: a custom volume / brightness
// indicator, a charging animation, and the fake notch / Dynamic Island / home
// bar. SpringBoard only.
//
// All of it is drawn in one window of Volta's own that takes no touches and
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
static NSInteger gCutout;           // 0 none, 1 notch, 2 Dynamic Island
static CGFloat gCutWidth = 160, gCutHeight = 30, gCutTop = 6;
static BOOL gCutCharge = YES, gCutLens = YES, gHomeBar, gCutFixed;

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
    gCutout = on ? (NSInteger)VLTNum(p, @"fakeCutout", 0) : 0;
    if (gCutout < 0 || gCutout > 2) gCutout = 0;
    gCutWidth  = fmin(fmax(VLTNum(p, @"fakeWidth", 160), 60), 320);
    gCutHeight = fmin(fmax(VLTNum(p, @"fakeHeight", 30), 14), 60);
    gCutTop    = fmin(fmax(VLTNum(p, @"fakeTop", 6), 0), 30);
    gCutCharge = VLTBool(p, @"fakeCharge", YES);
    gCutLens   = VLTBool(p, @"fakeLens", YES);
    gHomeBar   = on && VLTBool(p, @"fakeHomeBar", NO);
    gCutFixed  = VLTBool(p, @"fakeFixed", NO);
}

#pragma mark - The window

@interface UIWindow (VLTPopupPrivate)
- (void)_setSecure:(BOOL)secure;
@end

@interface VLTPopupController : UIViewController
@end

static void VLTLayoutCutout(void);

@implementation VLTPopupController
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (gCutout != 0 || gHomeBar) VLTLayoutCutout();   // the window turned or changed size
}
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

#pragma mark - Fake notch, Dynamic Island and home bar

// Drawn once, here, for the whole device. (Each app drawing its own made two
// of them whenever an app and the Home Screen disagreed about which way is up.)

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
    CGRect cut = CGRectMake((size.width - width) / 2, island ? gCutTop : 0, width, height);

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
    _homeBar.frame = CGRectMake((size.width - barWidth) / 2, size.height - 13, barWidth, 5);
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

static VLTCutoutView *gCutoutView;
static BOOL gCutoutShown;

// Which way an interface's top edge points, as a clockwise angle from the
// device's own top (the short edge away from the Home button).
static CGFloat VLTTopAngle(UIInterfaceOrientation orientation) {
    switch (orientation) {
        case UIInterfaceOrientationPortraitUpsideDown: return M_PI;
        case UIInterfaceOrientationLandscapeLeft:      return M_PI_2;    // Home button on the left
        case UIInterfaceOrientationLandscapeRight:     return -M_PI_2;   // Home button on the right
        default:                                       return 0;
    }
}

// The way up for whatever is on screen right now, as SpringBoard sees it.
static UIInterfaceOrientation VLTActiveOrientation(void) {
    UIApplication *app = [UIApplication sharedApplication];
    SEL selector = NSSelectorFromString(@"activeInterfaceOrientation");
    if ([app respondsToSelector:selector]) {
        long long value = ((long long (*)(id, SEL))objc_msgSend)(app, selector);
        if (value >= UIInterfaceOrientationPortrait && value <= UIInterfaceOrientationLandscapeRight) return (UIInterfaceOrientation)value;
    }
    UIInterfaceOrientation mine = gWindow.windowScene.interfaceOrientation;
    return mine == UIInterfaceOrientationUnknown ? UIInterfaceOrientationPortrait : mine;
}

static NSInteger gCutoutApplied = -1;   // the orientation the cutout was last laid out for

// Shows, hides and turns the cutout. It sits at the top of what is on screen,
// or, with "fixed", on the device's own top edge like real hardware.
static void VLTLayoutCutout(void) {
    BOOL wanted = gCutout != 0 || gHomeBar;
    if (!wanted) {
        if (gCutoutShown) {
            [gCutoutView removeFromSuperview];
            gCutoutShown = NO;
            VLTPopupEnd();
        }
        return;
    }
    UIView *host = VLTPopupHost();
    if (!gCutoutView) gCutoutView = [[VLTCutoutView alloc] initWithFrame:host.bounds];
    if (!gCutoutShown) {
        gCutoutShown = YES;
        VLTPopupBegin();
    }
    if (gCutoutView.superview != host) [host addSubview:gCutoutView];
    else if (host.subviews.lastObject != gCutoutView) [host bringSubviewToFront:gCutoutView];

    UIInterfaceOrientation mine = gWindow.windowScene.interfaceOrientation;
    if (mine == UIInterfaceOrientationUnknown) mine = UIInterfaceOrientationPortrait;
    UIInterfaceOrientation target = gCutFixed ? UIInterfaceOrientationPortrait : VLTActiveOrientation();
    gCutoutApplied = target;
    CGFloat angle = VLTTopAngle(target) - VLTTopAngle(mine);
    BOOL sideways = fabs(fabs(remainder(angle, M_PI)) - M_PI_2) < 0.01;
    CGSize size = host.bounds.size;
    gCutoutView.transform = CGAffineTransformIdentity;
    gCutoutView.bounds = sideways ? CGRectMake(0, 0, size.height, size.width) : CGRectMake(0, 0, size.width, size.height);
    gCutoutView.center = CGPointMake(size.width / 2, size.height / 2);
    gCutoutView.transform = CGAffineTransformMakeRotation(angle);
    [gCutoutView setNeedsLayout];
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
    dispatch_async(dispatch_get_main_queue(), ^{
        VLTLoadPopupPrefs();
        VLTLayoutCutout();
    });
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
                if (is && !was && last != UIDeviceBatteryStateUnknown) {
                    if (gChargeOn) VLTPlayCharge();
                    float level = [UIDevice currentDevice].batteryLevel;
                    if (gCutoutShown && level >= 0) [gCutoutView announce:[NSString stringWithFormat:@"⚡ %ld%%", lround(level * 100)]];
                }
                last = state;
            }];

            // The cutout: put it up once SpringBoard has settled, and keep it at the top of
            // whatever is showing. Apps can be opened sideways without the device turning,
            // so besides the rotation notices there is a light check every two seconds.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ VLTLayoutCutout(); });
            void (^turned)(NSNotification *) = ^(NSNotification *note) {
                if (gCutout == 0 && !gHomeBar) return;
                VLTLayoutCutout();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ VLTLayoutCutout(); });
            };
            for (NSString *name in @[UIDeviceOrientationDidChangeNotification, @"UIApplicationDidChangeStatusBarOrientationNotification"])
                [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:turned];
            NSTimer *watch = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
                if (!gCutoutShown || gCutFixed) return;
                if ((NSInteger)VLTActiveOrientation() != gCutoutApplied) VLTLayoutCutout();
            }];
            watch.tolerance = 1;

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
