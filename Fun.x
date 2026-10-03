//
//  Volta - Fun.x  (SpringBoard only, part of VoltaHome)
//
//  Things with no practical use. Everything is off until switched on, and
//  every visual lives inside views that already exist (the Home Screen window,
//  switcher cards, the dock, Control Center tiles): nothing is ever laid over
//  the whole system, so nothing here can get between you and your touches.
//
//  Also the on/off switches for the Phone and Calculator apps.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <spawn.h>
#import <sys/wait.h>
#import <CoreMotion/CoreMotion.h>
#import <AudioToolbox/AudioToolbox.h>
#import "VLTShared.h"

extern char **environ;

@interface UIView (VLTFunPrivate)
- (CGFloat)_continuousCornerRadius;
- (void)_setContinuousCornerRadius:(CGFloat)radius;
@end

#pragma mark - Settings

// App switcher
static BOOL gWobble, gRainbowCards, gFlip, gSpinCards, gTinyCards;
// Icons
static BOOL gDance, gSizes, gHeartbeat, gDiscoIcons, gSpinTap, gGravity;
// Touch
static BOOL gSparkle, gTrail, gShake, gTapSounds;
// Home Screen overlays
static BOOL gEmojiRain, gDisco, gCracked, gEyes, gBuddy;
static NSString *gEmoji;
static NSInteger gAngle;        // 0 normal, 1 tilted, 2 upside down, 3 mirrored
// Dock
static BOOL gRainbowDock, gHopDock, gThrow, gReturn = YES;
static CGFloat gBounce = 0.55, gPull = 1.4;
// Elsewhere
static BOOL gConfetti, gFortune, gWobbleCC, gDizzyClock;
static NSInteger gNames;        // 0 off, 1 backwards, 2 sPoNgE, 3 everything is Bob (read once, at launch)
static BOOL gAppPhone = YES, gAppCalc = YES, gAppTweaks = YES, gAppWeather = YES, gAppCompass = YES, gAppMemos = YES, gAppWallet = YES, gAppSaved = YES;
static BOOL gLocked;            // screen is locked: the busy effects take a break
static BOOL gExplodeArmed;      // set from Settings; goes off on the next Home Screen touch

static void VLTLoadFunPrefs(void) {
    NSDictionary *p = VLTCopyPrefs();
    BOOL on = VLTBool(p, @"enabled", YES);
    #define FUN(key) (on && VLTBool(p, key, NO))
    gWobble = FUN(@"funWobble");  gRainbowCards = FUN(@"funRainbowCards");  gFlip = FUN(@"funFlip");
    gSpinCards = FUN(@"funSpinCards");  gTinyCards = FUN(@"funTinyCards");
    gDance = FUN(@"funDance");  gSizes = FUN(@"funSizes");  gHeartbeat = FUN(@"funHeartbeat");
    gDiscoIcons = FUN(@"funDiscoIcons");  gSpinTap = FUN(@"funSpinTap");  gGravity = FUN(@"funGravity");
    gSparkle = FUN(@"funSparkle");  gTrail = FUN(@"funTrail");  gShake = FUN(@"funShake");  gTapSounds = FUN(@"funTapSounds");
    gEmojiRain = FUN(@"funEmojiRain");  gDisco = FUN(@"funDisco");  gCracked = FUN(@"funCracked");
    gEyes = FUN(@"funEyes");  gBuddy = FUN(@"funBuddy");
    gRainbowDock = FUN(@"funRainbowDock");  gHopDock = FUN(@"funHopDock");  gThrow = FUN(@"funThrow");
    gConfetti = FUN(@"funConfetti");  gFortune = FUN(@"funFortune");  gWobbleCC = FUN(@"funWobbleCC");  gDizzyClock = FUN(@"funDizzyClock");
    #undef FUN
    gReturn = VLTBool(p, @"funReturn", YES);
    gBounce = fmin(fmax(VLTNum(p, @"funBounce", 55) / 100.0, 0), 0.95);
    gPull   = fmin(fmax(VLTNum(p, @"funPull", 140) / 100.0, 0), 3);
    gAngle  = on ? (NSInteger)VLTNum(p, @"funAngle", 0) : 0;
    if (gAngle < 0 || gAngle > 3) gAngle = 0;
    NSString *emoji = [VLTStr(p, @"funEmoji") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    gEmoji = emoji.length ? emoji : @"🎉😂🔥⭐️";
    // The apps are independent of the master switch: turning Volta off should not make icons vanish.
    gAppPhone = VLTBool(p, @"appPhone", YES);
    gAppCalc  = VLTBool(p, @"appCalc", YES);
    gAppTweaks = VLTBool(p, @"appTweaks", YES);
    gAppWeather = VLTBool(p, @"appWeather", YES);
    gAppCompass = VLTBool(p, @"appCompass", YES);
    gAppMemos = VLTBool(p, @"appMemos", YES);
    gAppWallet = VLTBool(p, @"appWallet", YES);
    gAppSaved = VLTBool(p, @"appSaved", YES);
}

static inline BOOL VLTCalm(void) { return UIAccessibilityIsReduceMotionEnabled(); }

static NSHashTable *VLTFunTable(int which) {
    static NSHashTable *tables[5];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ for (int i = 0; i < 5; i++) tables[i] = [NSHashTable weakObjectsHashTable]; });
    return tables[which];
}
#define VLTCards()     VLTFunTable(0)
#define VLTIcons()     VLTFunTable(1)
#define VLTDockHosts() VLTFunTable(2)
#define VLTModules()   VLTFunTable(3)
#define VLTClocks()    VLTFunTable(4)

#pragma mark - Animation helpers

// All of these are "additive": they add to whatever transform the system gives
// the layer, so layout and the system's own animations carry on underneath.

static NSArray *VLTRainbow(CGFloat alpha) {
    NSMutableArray *colors = [NSMutableArray array];
    for (int i = 0; i <= 6; i++) [colors addObject:(id)[UIColor colorWithHue:(i % 6) / 6.0 saturation:0.85 brightness:1 alpha:alpha].CGColor];
    return colors;
}

// Back-and-forth between two offsets.
static void VLTSetLoop(CALayer *layer, NSString *key, NSString *keyPath, BOOL on, CGFloat from, CGFloat to, CFTimeInterval duration) {
    if (!on || VLTCalm()) { [layer removeAnimationForKey:key]; return; }
    if ([layer animationForKey:key]) return;
    CABasicAnimation *loop = [CABasicAnimation animationWithKeyPath:keyPath];
    loop.fromValue = @(from);
    loop.toValue = @(to);
    loop.additive = YES;
    loop.duration = duration * (0.85 + arc4random_uniform(30) / 100.0);
    loop.autoreverses = YES;
    loop.repeatCount = HUGE_VALF;
    loop.removedOnCompletion = NO;
    loop.timeOffset = arc4random_uniform(100) / 100.0 * duration;   // so they are not all in step
    loop.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [layer addAnimation:loop forKey:key];
}

// A fixed offset (used for "upside down", "tiny", "random size"). Not skipped
// for Reduce Motion: nothing moves.
static void VLTSetOffset(CALayer *layer, NSString *key, NSString *keyPath, BOOL on, CGFloat value) {
    if (!on) { [layer removeAnimationForKey:key]; return; }
    if ([layer animationForKey:key]) return;
    CABasicAnimation *hold = [CABasicAnimation animationWithKeyPath:keyPath];
    hold.fromValue = hold.toValue = @(value);
    hold.additive = YES;
    hold.duration = 3600;
    hold.repeatCount = HUGE_VALF;
    hold.removedOnCompletion = NO;
    [layer addAnimation:hold forKey:key];
}

// Round and round.
static void VLTSetSpin(CALayer *layer, NSString *key, BOOL on, CFTimeInterval duration) {
    if (!on || VLTCalm()) { [layer removeAnimationForKey:key]; return; }
    if ([layer animationForKey:key]) return;
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @0;
    spin.toValue = @(2 * M_PI);
    spin.additive = YES;
    spin.duration = duration;
    spin.repeatCount = HUGE_VALF;
    spin.removedOnCompletion = NO;
    spin.timeOffset = arc4random_uniform(100) / 100.0 * duration;
    [layer addAnimation:spin forKey:key];
}

static void VLTSetRainbowKey(CALayer *layer, NSString *keyPath, BOOL on, CGFloat alpha, CFTimeInterval duration) {
    NSString *key = [@"vltRainbow." stringByAppendingString:keyPath];
    if (!on || VLTCalm()) { [layer removeAnimationForKey:key]; return; }
    if ([layer animationForKey:key]) return;
    CAKeyframeAnimation *cycle = [CAKeyframeAnimation animationWithKeyPath:keyPath];
    cycle.values = VLTRainbow(alpha);
    cycle.duration = duration;
    cycle.repeatCount = HUGE_VALF;
    cycle.removedOnCompletion = NO;
    cycle.timeOffset = arc4random_uniform(100) / 100.0 * duration;
    [layer addAnimation:cycle forKey:key];
}

#pragma mark - App switcher cards

static const void *kCardBordered = &kCardBordered;

static void VLTApplyCard(UIView *card) {
    [VLTCards() addObject:card];
    CALayer *layer = card.layer;
    VLTSetLoop(layer, @"vltWobble", @"transform.rotation.z", gWobble, -0.035, 0.035, 0.9);
    VLTSetOffset(layer, @"vltFlip", @"transform.rotation.z", gFlip, M_PI);
    VLTSetSpin(layer, @"vltSpin", gSpinCards, 7);
    VLTSetOffset(layer, @"vltTiny", @"transform.scale", gTinyCards, -0.4);

    BOOL bordered = objc_getAssociatedObject(card, kCardBordered) != nil;
    if (gRainbowCards) {
        layer.borderWidth = 4;
        layer.cornerRadius = 18;
        if (!bordered) layer.borderColor = (__bridge CGColorRef)VLTRainbow(1).firstObject;
        objc_setAssociatedObject(card, kCardBordered, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (bordered) {
        layer.borderWidth = 0;
        layer.cornerRadius = 0;
        objc_setAssociatedObject(card, kCardBordered, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    VLTSetRainbowKey(layer, @"borderColor", gRainbowCards, 1, 4);
}

#pragma mark - Icons

static __weak UIWindow *gHomeWindow;
static const void *kIconSize  = &kIconSize;
static const void *kIconDisco = &kIconDisco;

static void VLTApplyIcon(UIView *icon) {
    [VLTIcons() addObject:icon];
    Class homeWindow = NSClassFromString(@"SBHomeScreenWindow");
    if (icon.window && homeWindow && [icon.window isKindOfClass:homeWindow]) gHomeWindow = icon.window;
    CALayer *layer = icon.layer;

    VLTSetLoop(layer, @"vltDance", @"transform.rotation.z", gDance, -0.06, 0.06, 0.5);
    VLTSetLoop(layer, @"vltBeat", @"transform.scale", gHeartbeat, 0, 0.09, 0.45);

    // Each icon keeps its own random size for as long as it lives.
    NSNumber *size = objc_getAssociatedObject(icon, kIconSize);
    if (gSizes && !size) {
        size = @(-0.32 + arc4random_uniform(60) / 100.0);   // 68 % to 128 %
        objc_setAssociatedObject(icon, kIconSize, size, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    VLTSetOffset(layer, @"vltSize", @"transform.scale", gSizes, size.doubleValue);

    // Disco: a colour wash over the icon picture, cycling through the rainbow.
    CALayer *disco = objc_getAssociatedObject(icon, kIconDisco);
    if (gDiscoIcons) {
        UIView *image = nil;
        @try {
            id value = [icon valueForKey:@"_iconImageView"];
            if ([value isKindOfClass:[UIView class]]) image = value;
        } @catch (__unused NSException *e) {}
        CGRect frame = image ? [icon convertRect:image.bounds fromView:image] : CGRectMake(0, 0, icon.bounds.size.width, icon.bounds.size.width);
        if (!disco) {
            disco = [CALayer layer];
            disco.cornerCurve = kCACornerCurveContinuous;
            disco.zPosition = 50;
            [layer addSublayer:disco];
            objc_setAssociatedObject(icon, kIconDisco, disco, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        disco.frame = frame;
        disco.cornerRadius = frame.size.width * 0.225;
        disco.backgroundColor = (__bridge CGColorRef)VLTRainbow(0.42).firstObject;
        [CATransaction commit];
        VLTSetRainbowKey(disco, @"backgroundColor", YES, 0.42, 3.5);
    } else if (disco) {
        [disco removeFromSuperlayer];
        objc_setAssociatedObject(icon, kIconDisco, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static UIView *VLTIconAncestor(UIView *view) {
    Class iconClass = NSClassFromString(@"SBIconView");
    for (UIView *v = view; v && iconClass; v = v.superview) if ([v isKindOfClass:iconClass]) return v;
    return nil;
}

#pragma mark - Physics bodies

// UIKit Dynamics moves "items". A body stands in for a real view (the dock,
// an icon): instead of changing the view's frame, which SpringBoard owns, it
// turns its position and rotation into a transform on that view.
@interface VLTBody : NSObject <UIDynamicItem>
@property (nonatomic, weak) UIView *view;
@property (nonatomic) CGPoint home;
@property (nonatomic) CGSize size;
@property (nonatomic) CGPoint center;
@property (nonatomic) CGAffineTransform transform;
@end

@implementation VLTBody

- (instancetype)init {
    if ((self = [super init])) _transform = CGAffineTransformIdentity;
    return self;
}

- (CGRect)bounds { return CGRectMake(0, 0, MAX(_size.width, 1), MAX(_size.height, 1)); }

- (void)apply {
    self.view.transform = CGAffineTransformConcat(_transform, CGAffineTransformMakeTranslation(_center.x - _home.x, _center.y - _home.y));
}

- (void)setCenter:(CGPoint)center { _center = center; [self apply]; }
- (void)setTransform:(CGAffineTransform)transform { _transform = transform; [self apply]; }

@end

#pragma mark - Icon gravity

// Icons on the current Home Screen page fall, pile up, and slide around as
// the device is tilted. They stay tappable. Turning it off puts them back.
@interface VLTIconPhysics : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) BOOL hasGravity;
- (void)startWithGravity:(BOOL)gravity;
- (void)stop;
- (void)explode;
- (void)setTiltPaused:(BOOL)paused;
@end

@implementation VLTIconPhysics {
    UIDynamicAnimator *_animator;
    NSMutableArray<VLTBody *> *_bodies;
    UIGravityBehavior *_gravity;
    CMMotionManager *_motion;
    NSUInteger _generation;
}

+ (instancetype)shared {
    static VLTIconPhysics *physics;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ physics = [[VLTIconPhysics alloc] init]; });
    return physics;
}

- (BOOL)running { return _animator != nil; }
- (BOOL)hasGravity { return _gravity != nil; }

- (void)startWithGravity:(BOOL)gravity {
    UIWindow *window = gHomeWindow;
    if (!window || _animator || VLTCalm() || gAngle != 0 || gLocked) return;
    _bodies = [NSMutableArray array];
    for (UIView *icon in VLTIcons().allObjects) {
        if (icon.window != window || icon.hidden || icon.alpha < 0.05) continue;
        CGRect frame = [window convertRect:icon.bounds fromView:icon];
        if (!CGRectIntersectsRect(CGRectInset(window.bounds, 4, 4), frame)) continue;   // only the page on screen
        if (!CGAffineTransformIsIdentity(icon.transform)) continue;
        VLTBody *body = [[VLTBody alloc] init];
        body.view = icon;
        CGFloat side = MIN(frame.size.width, frame.size.height) * 0.82;
        body.size = CGSizeMake(side, side);   // the icon picture, not its label
        body.home = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        body.center = body.home;
        [_bodies addObject:body];
        if (_bodies.count >= 48) break;
    }
    if (!_bodies.count) { _bodies = nil; return; }

    _generation++;
    _animator = [[UIDynamicAnimator alloc] initWithReferenceView:window];
    UICollisionBehavior *collision = [[UICollisionBehavior alloc] initWithItems:_bodies];
    collision.translatesReferenceBoundsIntoBoundary = YES;
    [_animator addBehavior:collision];
    UIDynamicItemBehavior *material = [[UIDynamicItemBehavior alloc] initWithItems:_bodies];
    material.elasticity = 0.42;
    material.friction = 0.25;
    material.resistance = 0.25;
    material.angularResistance = 0.6;
    [_animator addBehavior:material];

    if (gravity) {
        _gravity = [[UIGravityBehavior alloc] initWithItems:_bodies];
        _gravity.magnitude = 1.6;
        [_animator addBehavior:_gravity];
        [self setTiltPaused:NO];
    }
}

// Reads the accelerometer so "down" is wherever down really is.
- (void)setTiltPaused:(BOOL)paused {
    if (paused || !_gravity) {
        [_motion stopAccelerometerUpdates];
        return;
    }
    if (!_motion) _motion = [[CMMotionManager alloc] init];
    if (!_motion.accelerometerAvailable || _motion.accelerometerActive) return;
    _motion.accelerometerUpdateInterval = 1.0 / 30;
    __weak typeof(self) weakSelf = self;
    [_motion startAccelerometerUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMAccelerometerData *data, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !data || !strongSelf->_gravity) return;
        double x = data.acceleration.x, y = data.acceleration.y;
        NSInteger orientation = 1;
        @try { orientation = [[[UIApplication sharedApplication] valueForKey:@"activeInterfaceOrientation"] integerValue]; } @catch (__unused NSException *e) {}
        CGVector down;
        switch (orientation) {
            case 2:  down = CGVectorMake(-x, y); break;    // upside down
            case 3:  down = CGVectorMake(-y, -x); break;   // landscape, Home button right
            case 4:  down = CGVectorMake(y, x); break;     // landscape, Home button left
            default: down = CGVectorMake(x, -y); break;    // portrait
        }
        // Lying flat there is hardly any "down" at all; let things drift gently.
        strongSelf->_gravity.gravityDirection = CGVectorMake(down.dx * 1.8, down.dy * 1.8);
    }];
}

- (void)explode {
    BOOL temporary = !_animator;
    if (temporary) [self startWithGravity:NO];
    if (!_animator) return;
    NSMutableArray *pushes = [NSMutableArray array];
    for (VLTBody *body in _bodies) {
        UIPushBehavior *push = [[UIPushBehavior alloc] initWithItems:@[body] mode:UIPushBehaviorModeInstantaneous];
        push.angle = arc4random_uniform(628) / 100.0;
        push.magnitude = 0.6 + arc4random_uniform(120) / 100.0;
        [push setTargetOffsetFromCenter:UIOffsetMake((CGFloat)arc4random_uniform(20) - 10, (CGFloat)arc4random_uniform(20) - 10) forItem:body];   // off-centre, so they tumble
        [_animator addBehavior:push];
        [pushes addObject:push];
    }
    UIDynamicAnimator *animator = _animator;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (UIPushBehavior *push in pushes) [animator removeBehavior:push];
    });
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy] impactOccurred];
    if (temporary) {
        NSUInteger generation = _generation;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf && strongSelf->_generation == generation && !gGravity) [strongSelf stop];
        });
    }
}

- (void)stop {
    if (!_animator) return;
    _generation++;
    [_motion stopAccelerometerUpdates];
    [_animator removeAllBehaviors];
    _animator = nil;
    _gravity = nil;
    NSArray *bodies = _bodies;
    _bodies = nil;
    [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0 options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{ for (VLTBody *body in bodies) body.view.transform = CGAffineTransformIdentity; }
                     completion:nil];
}

@end

static void VLTSyncGravity(void) {
    VLTIconPhysics *physics = [VLTIconPhysics shared];
    BOOL wanted = gGravity && !VLTCalm() && gAngle == 0 && !gLocked;
    if (physics.running && (!wanted || !physics.hasGravity)) [physics stop];   // also ends a leftover explosion
    if (wanted && !physics.running) [physics startWithGravity:YES];
}

#pragma mark - Bursts, trails, sounds

static UIImage *VLTBitImage(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.opaque = NO;
        format.scale = 2;
        image = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(10, 14) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [[UIColor whiteColor] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 10, 14) cornerRadius:2.5] fill];
        }];
    });
    return image;
}

// A short burst of colored bits, then the layer removes itself.
static void VLTBurst(UIView *host, CGPoint point, BOOL confetti) {
    if (!host || VLTCalm()) return;
    CAEmitterLayer *emitter = [CAEmitterLayer layer];
    emitter.frame = host.bounds;
    emitter.zPosition = 10000;
    NSMutableArray *cells = [NSMutableArray array];
    for (int i = 0; i < 6; i++) {
        CAEmitterCell *cell = [CAEmitterCell emitterCell];
        cell.contents = (id)VLTBitImage().CGImage;
        cell.color = [UIColor colorWithHue:i / 6.0 saturation:0.8 brightness:1 alpha:1].CGColor;
        cell.spin = 3;
        cell.spinRange = 6;
        if (confetti) {
            cell.birthRate = 26;  cell.lifetime = 4.5;  cell.velocity = 240;  cell.velocityRange = 130;
            cell.emissionLongitude = M_PI_2;  cell.emissionRange = M_PI / 5;  cell.yAcceleration = 260;
            cell.scale = 0.75;  cell.scaleRange = 0.35;
        } else {
            cell.birthRate = 36;  cell.lifetime = 0.7;  cell.velocity = 150;  cell.velocityRange = 70;
            cell.emissionRange = 2 * M_PI;  cell.yAcceleration = 220;
            cell.scale = 0.35;  cell.scaleRange = 0.2;  cell.alphaSpeed = -1.4;
        }
        [cells addObject:cell];
    }
    emitter.emitterCells = cells;
    if (confetti) {
        emitter.emitterShape = kCAEmitterLayerLine;
        emitter.emitterPosition = CGPointMake(CGRectGetMidX(host.bounds), -10);
        emitter.emitterSize = CGSizeMake(host.bounds.size.width, 1);
    } else {
        emitter.emitterShape = kCAEmitterLayerPoint;
        emitter.emitterPosition = point;
    }
    emitter.beginTime = CACurrentMediaTime();
    [host.layer addSublayer:emitter];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((confetti ? 0.45 : 0.08) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        emitter.birthRate = 0;   // stop making new ones; let the rest fall
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((confetti ? 5.2 : 1.0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [emitter removeFromSuperlayer];
    });
}

// One glowing dot that shrinks and fades: strung together they make a trail.
static void VLTTrailDot(UIView *host, CGPoint point) {
    static NSUInteger hue;
    CALayer *dot = [CALayer layer];
    dot.bounds = CGRectMake(0, 0, 18, 18);
    dot.cornerRadius = 9;
    dot.position = point;
    dot.zPosition = 10000;
    dot.backgroundColor = [UIColor colorWithHue:(hue++ % 40) / 40.0 saturation:0.8 brightness:1 alpha:0.9].CGColor;
    [host.layer addSublayer:dot];
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{ [dot removeFromSuperlayer]; }];
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.9;  fade.toValue = @0;
    CABasicAnimation *shrink = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    shrink.fromValue = @1;  shrink.toValue = @0.2;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[fade, shrink];
    group.duration = 0.55;
    group.removedOnCompletion = NO;
    group.fillMode = kCAFillModeForwards;
    [dot addAnimation:group forKey:@"fade"];
    [CATransaction commit];
}

static void VLTShakeWindow(UIView *window) {
    if (VLTCalm() || [window.layer animationForKey:@"vltShake"]) return;
    CAKeyframeAnimation *shake = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    shake.values = @[@0, @-9, @8, @-6, @4, @-2, @0];
    shake.duration = 0.32;
    shake.additive = YES;
    [window.layer addAnimation:shake forKey:@"vltShake"];
}

static void VLTTapSound(void) {
    static const SystemSoundID sounds[] = {1057, 1104, 1105, 1306, 1016, 1103};
    AudioServicesPlaySystemSound(sounds[arc4random_uniform(sizeof(sounds) / sizeof(sounds[0]))]);
}

#pragma mark - Home Screen overlay

@interface VLTEyesView : UIView
- (void)lookAt:(CGPoint)point;   // in this view's coordinates
@end

@implementation VLTEyesView {
    CALayer *_pupils[2];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        for (int i = 0; i < 2; i++) {
            CALayer *white = [CALayer layer];
            white.frame = CGRectMake(i * 56, 0, 48, 48);
            white.cornerRadius = 24;
            white.backgroundColor = [UIColor whiteColor].CGColor;
            white.borderColor = [UIColor colorWithWhite:0 alpha:0.75].CGColor;
            white.borderWidth = 2.5;
            [self.layer addSublayer:white];
            _pupils[i] = [CALayer layer];
            _pupils[i].bounds = CGRectMake(0, 0, 20, 20);
            _pupils[i].cornerRadius = 10;
            _pupils[i].backgroundColor = [UIColor blackColor].CGColor;
            _pupils[i].position = CGPointMake(i * 56 + 24, 24);
            [self.layer addSublayer:_pupils[i]];
        }
    }
    return self;
}

- (void)lookAt:(CGPoint)point {
    for (int i = 0; i < 2; i++) {
        CGPoint center = CGPointMake(i * 56 + 24, 24);
        CGFloat dx = point.x - center.x, dy = point.y - center.y, distance = MAX(hypot(dx, dy), 1);
        CGFloat reach = MIN(distance, 300) / 300 * 12;   // pupils stay inside the eye
        _pupils[i].position = CGPointMake(center.x + dx / distance * reach, center.y + dy / distance * reach);
    }
}

@end

// Everything drawn over the Home Screen sits in this one view. It never takes
// touches, so icons underneath work as usual.
@interface VLTChaosOverlay : UIView
- (void)sync;
- (void)touchAt:(CGPoint)point;
- (void)showFortune;
@end

@implementation VLTChaosOverlay {
    CALayer *_disco;
    CALayer *_cracks;
    CAEmitterLayer *_rain;
    NSString *_rainEmoji;
    VLTEyesView *_eyes;
    UIImageView *_buddy;
    UIDynamicAnimator *_buddyAnimator;
    UILabel *_fortune;
    CGSize _laidOut;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (CGSizeEqualToSize(_laidOut, self.bounds.size)) return;
    _laidOut = self.bounds.size;
    // Size changed (rotation): rebuild the pieces that depend on it.
    [_cracks removeFromSuperlayer];  _cracks = nil;
    [_rain removeFromSuperlayer];  _rain = nil;
    [self stopBuddy];
    [self sync];
}

static UIImage *VLTEmojiImage(NSString *emoji) {
    UIFont *font = [UIFont systemFontOfSize:30];
    CGSize size = [emoji sizeWithAttributes:@{NSFontAttributeName: font}];
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(MAX(size.width, 8), MAX(size.height, 8)) format:format]
            imageWithActions:^(UIGraphicsImageRendererContext *context) { [emoji drawAtPoint:CGPointZero withAttributes:@{NSFontAttributeName: font}]; }];
}

// A believable crack: a few long jagged lines from one impact point, with
// short rings joining them.
- (CALayer *)makeCracks {
    CGSize size = self.bounds.size;
    CGPoint impact = CGPointMake(size.width * 0.68, size.height * 0.30);
    UIBezierPath *path = [UIBezierPath bezierPath];
    srand48(7);   // the same crack every time, so it does not jump around
    int spokes = 11;
    CGPoint ends[11][3];
    for (int i = 0; i < spokes; i++) {
        CGFloat angle = (2 * M_PI / spokes) * i + (drand48() - 0.5) * 0.4;
        CGFloat length = MAX(size.width, size.height) * (0.35 + drand48() * 0.6);
        CGPoint p = impact;
        [path moveToPoint:p];
        for (int step = 1; step <= 6; step++) {
            angle += (drand48() - 0.5) * 0.35;
            p = CGPointMake(p.x + cos(angle) * length / 6, p.y + sin(angle) * length / 6);
            [path addLineToPoint:p];
            if (step <= 3) ends[i][step - 1] = p;
        }
    }
    for (int ring = 0; ring < 3; ring++) {
        for (int i = 0; i < spokes; i++) {
            if (drand48() < 0.25) continue;
            [path moveToPoint:ends[i][ring]];
            [path addLineToPoint:ends[(i + 1) % spokes][ring]];
        }
    }
    CAShapeLayer *cracks = [CAShapeLayer layer];
    cracks.frame = self.bounds;
    cracks.path = path.CGPath;
    cracks.fillColor = NULL;
    cracks.strokeColor = [UIColor colorWithWhite:1 alpha:0.75].CGColor;
    cracks.lineWidth = 1.2;
    cracks.lineJoin = kCALineJoinRound;
    cracks.shadowColor = [UIColor blackColor].CGColor;
    cracks.shadowOpacity = 0.7;
    cracks.shadowRadius = 1;
    cracks.shadowOffset = CGSizeMake(1, 1);
    return cracks;
}

- (void)stopBuddy {
    [_buddyAnimator removeAllBehaviors];
    _buddyAnimator = nil;
    [_buddy removeFromSuperview];
    _buddy = nil;
}

- (void)sync {
    CGSize size = self.bounds.size;
    if (size.width < 10) return;

    // Disco lights
    if (gDisco && !_disco) {
        _disco = [CALayer layer];
        _disco.backgroundColor = (__bridge CGColorRef)VLTRainbow(0.2).firstObject;
        [self.layer insertSublayer:_disco atIndex:0];
    } else if (!gDisco && _disco) {
        [_disco removeFromSuperlayer];
        _disco = nil;
    }
    _disco.frame = self.bounds;
    if (_disco) VLTSetRainbowKey(_disco, @"backgroundColor", YES, 0.2, 5);

    // Cracked screen
    if (gCracked && !_cracks) {
        _cracks = [self makeCracks];
        [self.layer addSublayer:_cracks];
    } else if (!gCracked && _cracks) {
        [_cracks removeFromSuperlayer];
        _cracks = nil;
    }

    // Emoji rain
    BOOL wantsRain = gEmojiRain && !VLTCalm() && !gLocked;
    if (_rain && (!wantsRain || ![_rainEmoji isEqualToString:gEmoji])) {
        [_rain removeFromSuperlayer];
        _rain = nil;
    }
    if (wantsRain && !_rain) {
        NSMutableArray *cells = [NSMutableArray array];
        [gEmoji enumerateSubstringsInRange:NSMakeRange(0, gEmoji.length) options:NSStringEnumerationByComposedCharacterSequences
                                usingBlock:^(NSString *emoji, NSRange range, NSRange enclosing, BOOL *stop) {
            if ([emoji stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length == 0 || cells.count >= 8) return;
            CAEmitterCell *cell = [CAEmitterCell emitterCell];
            cell.contents = (id)VLTEmojiImage(emoji).CGImage;
            cell.lifetime = size.height / 90 + 2;
            cell.velocity = 110;  cell.velocityRange = 50;
            cell.emissionLongitude = M_PI_2;  cell.emissionRange = M_PI / 10;
            cell.spin = 0;  cell.spinRange = 1.5;
            cell.scale = 0.8;  cell.scaleRange = 0.35;
            [cells addObject:cell];
        }];
        for (CAEmitterCell *cell in cells) cell.birthRate = 2.4 * (size.width / 390.0) / cells.count;
        if (cells.count) {
            _rain = [CAEmitterLayer layer];
            _rain.frame = self.bounds;
            _rain.emitterShape = kCAEmitterLayerLine;
            _rain.emitterPosition = CGPointMake(size.width / 2, -24);
            _rain.emitterSize = CGSizeMake(size.width, 1);
            _rain.emitterCells = cells;
            [self.layer addSublayer:_rain];
            _rainEmoji = [gEmoji copy];
        }
    }

    // Googly eyes
    if (gEyes && !_eyes) {
        _eyes = [[VLTEyesView alloc] initWithFrame:CGRectZero];
        [self addSubview:_eyes];
    } else if (!gEyes && _eyes) {
        [_eyes removeFromSuperview];
        _eyes = nil;
    }
    _eyes.frame = CGRectMake(size.width / 2 - 52, MAX(self.safeAreaInsets.top, 20) + 14, 104, 48);

    // The firefly, bouncing around like a screensaver
    BOOL wantsBuddy = gBuddy && !VLTCalm() && !gLocked;
    if (wantsBuddy && !_buddy) {
        _buddy = [[UIImageView alloc] initWithImage:VLTThemeImage(7, 58, 0)];
        _buddy.frame = CGRectMake(size.width * 0.3, size.height * 0.4, 58, 58);
        [self addSubview:_buddy];
        _buddyAnimator = [[UIDynamicAnimator alloc] initWithReferenceView:self];
        UICollisionBehavior *walls = [[UICollisionBehavior alloc] initWithItems:@[_buddy]];
        walls.translatesReferenceBoundsIntoBoundary = YES;
        [_buddyAnimator addBehavior:walls];
        UIDynamicItemBehavior *material = [[UIDynamicItemBehavior alloc] initWithItems:@[_buddy]];
        material.elasticity = 1;  material.friction = 0;  material.resistance = 0;  material.allowsRotation = NO;
        [material addLinearVelocity:CGPointMake(130, 95) forItem:_buddy];   // never loses speed
        [_buddyAnimator addBehavior:material];
    } else if (!wantsBuddy && _buddy) {
        [self stopBuddy];
    }
}

- (void)touchAt:(CGPoint)point {
    if (_eyes) [_eyes lookAt:[_eyes convertPoint:point fromView:self]];
}

- (void)showFortune {
    static NSArray *fortunes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fortunes = @[@"You unlocked it. Incredible work.", @"Welcome back. Nothing happened while you were gone. Probably.",
                     @"Today's lucky app: whichever one you open by mistake.", @"The icons missed you.",
                     @"Unlock number who-knows-what. Still got it.", @"A great notification is coming. Eventually.",
                     @"Your battery believes in you.", @"Fun fact: this message is pointless.",
                     @"You look like someone about to check one thing and stay for an hour.", @"The dock is behaving. For now.",
                     @"Reminder: you came here to do something. What was it?", @"Plot twist: there is nothing new.",
                     @"Certified unlocker.", @"Swipe responsibly.", @"The firefly says hi.", @"Achievement unlocked: unlocking."];
    });
    if (!_fortune) {
        _fortune = [[UILabel alloc] init];
        _fortune.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _fortune.textColor = [UIColor whiteColor];
        _fortune.textAlignment = NSTextAlignmentCenter;
        _fortune.numberOfLines = 2;
        _fortune.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
        _fortune.layer.cornerRadius = 18;
        _fortune.layer.cornerCurve = kCACornerCurveContinuous;
        _fortune.clipsToBounds = YES;
        _fortune.alpha = 0;
        [self addSubview:_fortune];
    }
    _fortune.text = fortunes[arc4random_uniform((uint32_t)fortunes.count)];
    CGFloat width = MIN(self.bounds.size.width - 48, 420);
    CGSize fit = [_fortune sizeThatFits:CGSizeMake(width - 32, 100)];
    _fortune.frame = CGRectMake((self.bounds.size.width - width) / 2, MAX(self.safeAreaInsets.top, 20) + 76, width, fit.height + 22);
    [self bringSubviewToFront:_fortune];
    UILabel *label = _fortune;
    [UIView animateWithDuration:0.3 animations:^{ label.alpha = 1; } completion:^(BOOL done) {
        [UIView animateWithDuration:0.5 delay:2.8 options:UIViewAnimationOptionAllowUserInteraction animations:^{ label.alpha = 0; } completion:nil];
    }];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, _fortune.text);
}

@end

static const void *kOverlayKey = &kOverlayKey;

static VLTChaosOverlay *VLTOverlay(BOOL create) {
    UIWindow *window = gHomeWindow;
    if (!window) return nil;
    VLTChaosOverlay *overlay = objc_getAssociatedObject(window, kOverlayKey);
    BOOL needed = gDisco || gCracked || gEmojiRain || gEyes || gBuddy || gFortune;
    if (!overlay && create && needed) {
        overlay = [[VLTChaosOverlay alloc] initWithFrame:window.bounds];
        [window addSubview:overlay];
        objc_setAssociatedObject(window, kOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (overlay && !needed) {
        [overlay removeFromSuperview];
        objc_setAssociatedObject(window, kOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return nil;
    }
    if (overlay && window.subviews.lastObject != overlay) [window bringSubviewToFront:overlay];
    return overlay;
}

// Tilted, upside down or mirrored: a real transform on the Home Screen's
// content, so touches still land where things appear.
static const void *kAngleApplied = &kAngleApplied;

static void VLTApplyAngle(void) {
    UIView *content = gHomeWindow.rootViewController.view;
    if (!content) return;
    NSNumber *applied = objc_getAssociatedObject(content, kAngleApplied);
    if (!applied && gAngle == 0) return;
    // A frame set while the view is rotated changes its size; put it back.
    CGRect full = gHomeWindow.bounds;
    if (!CGSizeEqualToSize(content.bounds.size, full.size)) {
        content.bounds = CGRectMake(0, 0, full.size.width, full.size.height);
        content.center = CGPointMake(CGRectGetMidX(full), CGRectGetMidY(full));
    }
    CGAffineTransform transform = CGAffineTransformIdentity;
    if (gAngle == 1) transform = CGAffineTransformScale(CGAffineTransformMakeRotation(0.07), 0.94, 0.94);
    else if (gAngle == 2) transform = CGAffineTransformMakeRotation(M_PI);
    else if (gAngle == 3) transform = CGAffineTransformMakeScale(-1, 1);
    if (applied.integerValue == gAngle && CGAffineTransformEqualToTransform(content.transform, transform)) return;
    [UIView animateWithDuration:0.45 animations:^{ content.transform = transform; }];
    objc_setAssociatedObject(content, kAngleApplied, gAngle ? @(gAngle) : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Dock

static const void *kRainbowView = &kRainbowView;

static void VLTApplyRainbowDock(UIView *host) {
    [VLTDockHosts() addObject:host];
    UIView *background = nil;
    @try {
        id value = [host valueForKey:@"backgroundView"];
        if ([value isKindOfClass:[UIView class]]) background = value;
    } @catch (__unused NSException *e) {}
    UIView *rainbow = objc_getAssociatedObject(host, kRainbowView);
    if (!gRainbowDock || !background) {
        if (rainbow) {
            [rainbow removeFromSuperview];
            objc_setAssociatedObject(host, kRainbowView, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (!rainbow) {
        rainbow = [[UIView alloc] initWithFrame:CGRectZero];
        rainbow.userInteractionEnabled = NO;
        rainbow.clipsToBounds = YES;
        objc_setAssociatedObject(host, kRainbowView, rainbow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *parent = background.superview ?: host;
    if (rainbow.superview != parent) [parent insertSubview:rainbow aboveSubview:background];
    rainbow.frame = background.frame;
    CGFloat radius = [background respondsToSelector:@selector(_continuousCornerRadius)] ? [background _continuousCornerRadius] : background.layer.cornerRadius;
    if ([rainbow respondsToSelector:@selector(_setContinuousCornerRadius:)]) [rainbow _setContinuousCornerRadius:radius];
    else rainbow.layer.cornerRadius = radius;
    rainbow.layer.backgroundColor = (__bridge CGColorRef)VLTRainbow(0.38).firstObject;
    VLTSetRainbowKey(rainbow.layer, @"backgroundColor", YES, 0.38, 6);
}

// Grab the dock with two fingers and throw it.
@interface VLTDockThrower : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *dock;
@property (nonatomic, strong) UIPanGestureRecognizer *pan;
- (void)goHomeAnimated:(BOOL)animated;
@end

@implementation VLTDockThrower {
    UIDynamicAnimator *_animator;
    VLTBody *_body;
    UIAttachmentBehavior *_grip;
    UIGravityBehavior *_gravity;
    UIDynamicItemBehavior *_material;
    UISnapBehavior *_snap;
    BOOL _returning, _holding;
    NSUInteger _generation;   // cancels a pending trip home when the dock is grabbed again
}

- (void)attachTo:(UIView *)dock {
    self.dock = dock;
    self.pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    self.pan.minimumNumberOfTouches = 2;   // one finger still belongs to the icons
    self.pan.maximumNumberOfTouches = 2;
    self.pan.delegate = self;
    [dock addGestureRecognizer:self.pan];
}

- (void)detach {
    [self goHomeAnimated:NO];
    [self.dock removeGestureRecognizer:self.pan];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer { return gThrow && self.dock.superview != nil; }

// Sets up the physics world the first time the dock is grabbed.
- (BOOL)prepare {
    UIView *dock = self.dock, *reference = dock.superview;
    if (!dock || !reference) return NO;
    if (_animator) return YES;

    // The part that looks like the dock: the platter on iPad, the whole bar on iPhone.
    UIView *shape = dock;
    @try {
        id platter = [dock valueForKey:@"mainPlatterView"];
        if ([platter isKindOfClass:[UIView class]]) shape = platter;
    } @catch (__unused NSException *e) {}

    _body = [[VLTBody alloc] init];
    _body.view = dock;
    _body.size = shape.bounds.size;
    _body.home = [reference convertPoint:CGPointMake(CGRectGetMidX(shape.bounds), CGRectGetMidY(shape.bounds)) fromView:shape];
    _body.center = _body.home;

    _animator = [[UIDynamicAnimator alloc] initWithReferenceView:reference];

    // Walls: the edges of the screen, not of the dock's small container.
    UICollisionBehavior *walls = [[UICollisionBehavior alloc] initWithItems:@[_body]];
    CGRect screen = dock.window ? [reference convertRect:dock.window.bounds fromView:nil] : reference.bounds;
    [walls addBoundaryWithIdentifier:@"screen" forPath:[UIBezierPath bezierPathWithRect:screen]];
    [_animator addBehavior:walls];

    _material = [[UIDynamicItemBehavior alloc] initWithItems:@[_body]];
    _material.friction = 0.4;
    _material.resistance = 0.5;
    _material.angularResistance = 1.2;
    _material.density = 0.6;
    [_animator addBehavior:_material];

    _gravity = [[UIGravityBehavior alloc] initWithItems:@[_body]];
    return YES;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *reference = self.dock.superview;
    CGPoint point = [pan locationInView:reference];
    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            if (![self prepare]) return;
            _generation++;
            _holding = YES;
            _returning = NO;
            _material.elasticity = gBounce;     // the Fun page sliders
            _gravity.magnitude = gPull;
            if (_snap) { [_animator removeBehavior:_snap]; _snap = nil; }
            [_animator removeBehavior:_gravity];
            // Hold it where the fingers are, so it swings like a real object.
            UIOffset offset = UIOffsetMake(point.x - _body.center.x, point.y - _body.center.y);
            _grip = [[UIAttachmentBehavior alloc] initWithItem:_body offsetFromCenter:offset attachedToAnchor:point];
            _grip.length = 0;
            _grip.damping = 0.9;
            _grip.frequency = 4;
            [_animator addBehavior:_grip];
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
            break;
        }
        case UIGestureRecognizerStateChanged:
            _grip.anchorPoint = point;
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (!_grip) return;
            [_animator removeBehavior:_grip];
            _grip = nil;
            _holding = NO;
            // Let go: it keeps the speed it had, and now gravity applies.
            if (gPull > 0.01) [_animator addBehavior:_gravity];
            [self scheduleReturn];
            break;
        }
        default: break;
    }
}

// Once it has had time to bounce and settle, bring it back (if that is on).
- (void)scheduleReturn {
    if (!gReturn) return;
    NSUInteger generation = _generation;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_generation == generation && !strongSelf->_holding) [strongSelf goHomeAnimated:YES];
    });
}

- (void)goHomeAnimated:(BOOL)animated {
    if (!_animator) return;
    _generation++;
    if (!animated || VLTCalm()) {
        [_animator removeAllBehaviors];
        _animator = nil;  _body = nil;  _grip = nil;  _snap = nil;  _material = nil;
        self.dock.transform = CGAffineTransformIdentity;
        return;
    }
    _returning = YES;
    [_animator removeBehavior:_gravity];
    if (_snap) [_animator removeBehavior:_snap];
    _snap = [[UISnapBehavior alloc] initWithItem:_body snapToPoint:_body.home];   // also straightens it
    _snap.damping = 0.6;
    [_animator addBehavior:_snap];
    NSUInteger generation = _generation;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_generation == generation && strongSelf->_returning) [strongSelf goHomeAnimated:NO];   // land exactly
    });
}

@end

static const void *kThrowerKey = &kThrowerKey;

// Puts every thrown dock back (locking, rotating).
static void VLTDocksGoHome(void) {
    for (UIView *host in VLTDockHosts().allObjects) {
        VLTDockThrower *thrower = objc_getAssociatedObject(host, kThrowerKey);
        [thrower goHomeAnimated:NO];
    }
}

// dock: SBDockView (iPhone) or SBFloatingDockView (iPad).
static void VLTApplyDockFun(UIView *dock) {
    [VLTDockHosts() addObject:dock];
    VLTDockThrower *thrower = objc_getAssociatedObject(dock, kThrowerKey);
    if (gThrow && !thrower) {
        thrower = [[VLTDockThrower alloc] init];
        [thrower attachTo:dock];
        objc_setAssociatedObject(dock, kThrowerKey, thrower, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (!gThrow && thrower) {
        [thrower detach];
        objc_setAssociatedObject(dock, kThrowerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // A little hop every few seconds.
    CALayer *layer = dock.layer;
    if (gHopDock && !VLTCalm()) {
        if (![layer animationForKey:@"vltHop"]) {
            CAKeyframeAnimation *hop = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.y"];
            hop.values = @[@0, @-16, @0, @-7, @0, @0];
            hop.keyTimes = @[@0, @0.07, @0.14, @0.19, @0.24, @1];
            hop.duration = 3.4;
            hop.additive = YES;
            hop.repeatCount = HUGE_VALF;
            hop.removedOnCompletion = NO;
            [layer addAnimation:hop forKey:@"vltHop"];
        }
    } else {
        [layer removeAnimationForKey:@"vltHop"];
    }
}

#pragma mark - Silly app names

static NSString *VLTSillyName(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || !name.length) return name;
    switch (gNames) {
        case 1: {   // backwards, one whole character at a time so emoji survive
            NSMutableString *reversed = [NSMutableString string];
            [name enumerateSubstringsInRange:NSMakeRange(0, name.length)
                                     options:NSStringEnumerationReverse | NSStringEnumerationByComposedCharacterSequences
                                  usingBlock:^(NSString *part, NSRange range, NSRange enclosing, BOOL *stop) { [reversed appendString:part]; }];
            return reversed;
        }
        case 2: {   // sPoNgE cAsE
            NSMutableString *sponge = [NSMutableString string];
            __block BOOL upper = NO;
            [name enumerateSubstringsInRange:NSMakeRange(0, name.length) options:NSStringEnumerationByComposedCharacterSequences
                                  usingBlock:^(NSString *part, NSRange range, NSRange enclosing, BOOL *stop) {
                BOOL letter = [part rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location != NSNotFound;
                [sponge appendString:letter ? (upper ? part.uppercaseString : part.lowercaseString) : part];
                if (letter) upper = !upper;
            }];
            return sponge;
        }
        case 3: return @"Bob";
        default: return name;
    }
}

#pragma mark - Phone and Calculator on / off

static BOOL VLTAppRegistered(NSString *bundleID) {
    @try {
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        SEL make = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (![proxyClass respondsToSelector:make]) return YES;
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, make, bundleID);
        return [[proxy valueForKey:@"isInstalled"] boolValue];
    } @catch (__unused NSException *e) { return YES; }
}

// Registers or unregisters each app with the system so its icon appears or
// disappears. Uses the jailbreak's own "uicache" tool; at most one try per app
// per setting, so a failure can never turn into a loop.
static void VLTSyncApps(void) {
    static NSMutableSet *attempted;
    if (!attempted) attempted = [NSMutableSet set];
    NSArray *apps = @[@[@"com.notpreston.volta.phone", @"/var/jb/Applications/VoltaPhone.app", @(gAppPhone)],
                      @[@"com.notpreston.volta.calculator", @"/var/jb/Applications/VoltaCalc.app", @(gAppCalc)],
                      @[@"com.notpreston.volta.tweaks", @"/var/jb/Applications/Voltweaks.app", @(gAppTweaks)],
                      @[@"com.notpreston.volta.weather", @"/var/jb/Applications/VoltaWeather.app", @(gAppWeather)],
                      @[@"com.notpreston.volta.compass", @"/var/jb/Applications/VoltaCompass.app", @(gAppCompass)],
                      @[@"com.notpreston.volta.memos", @"/var/jb/Applications/VoltaMemos.app", @(gAppMemos)],
                      @[@"com.notpreston.volta.wallet", @"/var/jb/Applications/VoltaWallet.app", @(gAppWallet)],
                      @[@"com.notpreston.volta.saved", @"/var/jb/Applications/VoltaSaved.app", @(gAppSaved)]];
    for (NSArray *app in apps) {
        NSString *bundleID = app[0], *path = app[1];
        BOOL wanted = [app[2] boolValue];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        if (VLTAppRegistered(bundleID) == wanted) continue;
        NSString *attempt = [NSString stringWithFormat:@"%@-%d", bundleID, wanted];
        if ([attempted containsObject:attempt]) continue;
        [attempted addObject:attempt];
        [attempted removeObject:[NSString stringWithFormat:@"%@-%d", bundleID, !wanted]];
        static dispatch_queue_t queue;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ queue = dispatch_queue_create("com.notpreston.volta.uicache", DISPATCH_QUEUE_SERIAL); });
        dispatch_async(queue, ^{
            const char *tool = "/var/jb/usr/bin/uicache";
            char *const arguments[] = {(char *)tool, (char *)(wanted ? "-p" : "-u"), (char *)path.fileSystemRepresentation, NULL};
            pid_t pid = 0;
            if (posix_spawn(&pid, tool, NULL, NULL, arguments, environ) == 0) {
                int status = 0;
                waitpid(pid, &status, 0);
            } else {
                NSLog(@"[Volta] could not run uicache for %@", bundleID);
            }
        });
    }
}

#pragma mark - Hooks

%group Fun

%hook SBFluidSwitcherItemContainer

- (void)layoutSubviews {
    %orig;
    VLTApplyCard((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    VLTApplyCard((UIView *)self);
}

%end

%hook SBIconView

- (void)didMoveToWindow {
    %orig;
    VLTApplyIcon((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    if (gDiscoIcons) VLTApplyIcon((UIView *)self);   // keep the colour wash sized to the icon
}

%end

%hook SBHomeScreenWindow

- (void)sendEvent:(UIEvent *)event {
    %orig;
    gHomeWindow = (UIWindow *)self;
    if (event.type != UIEventTypeTouches) return;
    if (gExplodeArmed) {
        for (UITouch *touch in event.allTouches) {
            if (touch.phase != UITouchPhaseBegan) continue;
            gExplodeArmed = NO;
            VLTBurst((UIView *)self, [touch locationInView:(UIView *)self], YES);
            [[VLTIconPhysics shared] explode];
            break;
        }
    }
    if (!(gSparkle || gTrail || gShake || gTapSounds || gSpinTap || gEyes)) return;
    static CFTimeInterval lastDot;
    UIView *window = (UIView *)self;
    for (UITouch *touch in event.allTouches) {
        CGPoint point = [touch locationInView:window];
        if (gEyes) [VLTOverlay(NO) touchAt:point];
        if (touch.phase == UITouchPhaseBegan) {
            if (gSparkle) VLTBurst(window, point, NO);
            if (gShake) VLTShakeWindow(window);
            if (gTapSounds) VLTTapSound();
            if (gSpinTap && !VLTCalm()) {
                UIView *icon = VLTIconAncestor(touch.view);
                if (icon && ![icon.layer animationForKey:@"vltTapSpin"]) {
                    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
                    spin.fromValue = @0;
                    spin.toValue = @(2 * M_PI);
                    spin.additive = YES;
                    spin.duration = 0.45;
                    [icon.layer addAnimation:spin forKey:@"vltTapSpin"];
                }
            }
        } else if (touch.phase == UITouchPhaseMoved && gTrail && !VLTCalm()) {
            CFTimeInterval now = CACurrentMediaTime();
            if (now - lastDot > 0.022) {
                lastDot = now;
                VLTTrailDot(window, point);
            }
        }
    }
}

- (void)layoutSubviews {
    %orig;
    gHomeWindow = (UIWindow *)self;
    static CGSize lastSize;
    CGSize size = ((UIView *)self).bounds.size;
    if (!CGSizeEqualToSize(size, lastSize)) {   // rotated: the physics captured the old layout
        BOOL first = CGSizeEqualToSize(lastSize, CGSizeZero);
        lastSize = size;
        if (!first) {
            [[VLTIconPhysics shared] stop];
            VLTDocksGoHome();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ VLTSyncGravity(); });
        }
    }
    VLTOverlay(YES);
    VLTApplyAngle();
}

%end

%hook SBDockView

- (void)layoutSubviews {
    %orig;
    VLTApplyRainbowDock((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    VLTApplyDockFun((UIView *)self);
}

%end

%hook SBFloatingDockPlatterView

- (void)layoutSubviews {
    %orig;
    VLTApplyRainbowDock((UIView *)self);
}

%end

%hook SBFloatingDockView

- (void)didMoveToWindow {
    %orig;
    VLTApplyDockFun((UIView *)self);
}

%end

// Control Center tiles
%hook CCUIContentModuleContentContainerView

- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window) return;
    [VLTModules() addObject:self];
    VLTSetLoop(((UIView *)self).layer, @"vltWobble", @"transform.rotation.z", gWobbleCC, -0.03, 0.03, 0.8);
}

%end

// The big clock on the Lock Screen
%hook SBFLockScreenDateView

- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window) return;
    [VLTClocks() addObject:self];
    VLTSetLoop(((UIView *)self).layer, @"vltDizzy", @"transform.rotation.z", gDizzyClock, -0.07, 0.07, 1.5);
}

%end

%end // group Fun

// Icon labels. Read once at launch: the Home Screen keeps finished labels, so
// a change only shows after a respring anyway.
%group SillyNames

%hook SBLeafIcon

- (id)displayNameForLocation:(id)location {
    id name = %orig;
    return VLTSillyName(name);
}

%end

%end // group SillyNames

#pragma mark - Setup

static void VLTRefreshFun(void) {
    Class platter = NSClassFromString(@"SBFloatingDockPlatterView");
    Class floating = NSClassFromString(@"SBFloatingDockView");
    Class phoneDock = NSClassFromString(@"SBDockView");
    for (UIView *card in VLTCards().allObjects) VLTApplyCard(card);
    for (UIView *icon in VLTIcons().allObjects) VLTApplyIcon(icon);
    for (UIView *host in VLTDockHosts().allObjects) {
        BOOL isPlatter = platter && [host isKindOfClass:platter];
        BOOL isPhoneDock = phoneDock && [host isKindOfClass:phoneDock];
        if (isPlatter || isPhoneDock) VLTApplyRainbowDock(host);
        if (isPhoneDock || (floating && [host isKindOfClass:floating])) VLTApplyDockFun(host);
    }
    for (UIView *module in VLTModules().allObjects)
        VLTSetLoop(module.layer, @"vltWobble", @"transform.rotation.z", gWobbleCC, -0.03, 0.03, 0.8);
    for (UIView *clock in VLTClocks().allObjects)
        VLTSetLoop(clock.layer, @"vltDizzy", @"transform.rotation.z", gDizzyClock, -0.07, 0.07, 1.5);
    [VLTOverlay(YES) sync];
    VLTApplyAngle();
    VLTSyncGravity();
    VLTSyncApps();
}

static void VLTFunPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VLTLoadFunPrefs();
        VLTRefreshFun();
    });
}

static void VLTExplodeRequested(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ gExplodeArmed = YES; });
}

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        VLTLoadFunPrefs();
        gNames = VLTBool(VLTCopyPrefs(), @"enabled", YES) ? (NSInteger)VLTNum(VLTCopyPrefs(), @"funNames", 0) : 0;

        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(darwin, NULL, VLTFunPrefsChanged, CFSTR(VLT_NOTIFY_PREFS), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(darwin, NULL, VLTExplodeRequested, CFSTR(VLT_DOMAIN "/explode"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        // Locked <-> unlocked
        static int lockToken;
        static uint64_t wasLocked = 1;
        notify_register_dispatch("com.apple.springboard.lockstate", &lockToken, dispatch_get_main_queue(), ^(int token) {
            uint64_t locked = 0;
            notify_get_state(token, &locked);
            if (wasLocked && !locked) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (gConfetti) VLTBurst(gHomeWindow, CGPointZero, YES);
                    if (gFortune) [VLTOverlay(YES) showFortune];
                    VLTSyncGravity();
                });
            }
            // Nothing busy runs behind a locked screen.
            gLocked = locked != 0;
            if (gLocked) {
                [[VLTIconPhysics shared] stop];
                VLTDocksGoHome();
            }
            [VLTOverlay(NO) sync];
            wasLocked = locked;
        });

        uint64_t lockedNow = 0;
        if (notify_get_state(lockToken, &lockedNow) == NOTIFY_STATUS_OK) gLocked = lockedNow != 0;

        %init(Fun);
        if (gNames >= 1 && gNames <= 3) %init(SillyNames);

        // An update re-installs both apps; put a switched-off one away again.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            VLTSyncApps();
            VLTSyncGravity();
        });
    }
}
