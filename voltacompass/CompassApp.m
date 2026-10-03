//
//  Compass (part of Volta). A magnetic compass with a bubble level, driven by
//  Core Motion device motion. It needs no location permission.
//

#import <UIKit/UIKit.h>
#import <CoreMotion/CoreMotion.h>
#include <math.h>

#define HEX(v) [UIColor colorWithRed:(((v) >> 16) & 0xFF) / 255.0 green:(((v) >> 8) & 0xFF) / 255.0 blue:((v) & 0xFF) / 255.0 alpha:1]

// ---- angle helpers (plain C) ----

// Any angle in degrees -> [0, 360).
static double CompassWrap360(double a) {
    a = fmod(a, 360.0);
    if (a < 0) a += 360.0;
    return a >= 360.0 ? 0.0 : a;
}

// Shortest signed turn from one angle to another, in [-180, 180).
static double CompassDelta(double from, double to) {
    return CompassWrap360(to - from + 180.0) - 180.0;
}

// Low-pass step: move a fraction k of the way to the target, the short way round.
static double CompassSmooth(double shown, double target, double k) {
    return CompassWrap360(shown + CompassDelta(shown, target) * k);
}

// Compass point name for a heading, e.g. 247 -> "SW".
static const char *CompassPoint(double heading) {
    static const char *names[8] = {"N", "NE", "E", "SE", "S", "SW", "W", "NW"};
    return names[(int)floor(CompassWrap360(heading + 22.5) / 45.0) % 8];
}

// A vector in device axes (x right, y up) seen from a screen whose top is the
// device top turned clockwise by `degrees`. Gives screen-right and screen-up parts.
static void CompassToScreen(double x, double y, double degrees, double *right, double *up) {
    double a = degrees * M_PI / 180.0;
    *right = x * cos(a) - y * sin(a);
    *up = x * sin(a) + y * cos(a);
}

// ---- end angle helpers ----

static const double kHeadingSmoothing = 0.25;   // per sample at 30 Hz
static const double kTiltSmoothing = 0.3;
static const double kFlatTilt = 0.035;          // sine of about 2 degrees

@interface CompassViewController : UIViewController
@end

@implementation CompassViewController {
    CMMotionManager *_motion;
    BOOL _available;
    BOOL _hasHeading;       // NO until the first good sample after (re)starting
    double _heading;        // smoothed, degrees, already corrected for screen orientation
    double _tiltRight, _tiltUp;   // smoothed bubble offset in screen axes, -1...1
    BOOL _flat;

    UIView *_dial;          // rotates
    CAShapeLayer *_minorTicks, *_majorTicks, *_pointer;
    NSMutableArray<UILabel *> *_marks;   // numbers and letters; tag is the angle
    UIView *_levelRing, *_levelTarget, *_bubble;
    UILabel *_readout, *_hint, *_missing;
    CGFloat _radius, _bubbleTravel;
    CGPoint _dialCenter;
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

- (UILabel *)labelWithColor:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.textColor = color;
    label.textAlignment = NSTextAlignmentCenter;
    return label;
}

- (CAShapeLayer *)shapeWithColor:(UIColor *)color {
    CAShapeLayer *layer = [CAShapeLayer layer];
    layer.strokeColor = color.CGColor;
    layer.fillColor = nil;
    return layer;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = HEX(0x0F1020);
    UIColor *accent = HEX(0x19C8B9);

    _dial = [[UIView alloc] init];
    _dial.backgroundColor = HEX(0x191B33);
    [self.view addSubview:_dial];
    _minorTicks = [self shapeWithColor:HEX(0x5A5E8C)];
    _majorTicks = [self shapeWithColor:[UIColor whiteColor]];
    [_dial.layer addSublayer:_minorTicks];
    [_dial.layer addSublayer:_majorTicks];

    // Twelve numbers, then the four letters. Each stands upright on its own spoke.
    _marks = [NSMutableArray array];
    NSArray *letters = @[@"N", @"E", @"S", @"W"];
    for (NSInteger i = 0; i < 16; i++) {
        BOOL letter = i >= 12;
        UILabel *mark = [self labelWithColor:letter ? (i == 12 ? accent : [UIColor whiteColor]) : HEX(0xA9ACD0)];
        mark.tag = letter ? (i - 12) * 90 : i * 30;
        mark.text = letter ? letters[i - 12] : [NSString stringWithFormat:@"%ld", (long)mark.tag];
        [_dial addSubview:mark];
        [_marks addObject:mark];
    }

    // Fixed parts: the pointer above the dial and the bubble level in the middle.
    _pointer = [CAShapeLayer layer];
    _pointer.fillColor = accent.CGColor;
    [self.view.layer addSublayer:_pointer];
    _levelRing = [[UIView alloc] init];
    _levelRing.backgroundColor = HEX(0x0F1020);
    _levelRing.layer.borderColor = HEX(0x3D4066).CGColor;
    _levelTarget = [[UIView alloc] init];
    _levelTarget.layer.borderColor = HEX(0x5A5E8C).CGColor;
    _bubble = [[UIView alloc] init];
    for (UIView *view in @[_levelRing, _levelTarget, _bubble]) {
        view.userInteractionEnabled = NO;
        [self.view addSubview:view];
    }

    _readout = [self labelWithColor:[UIColor whiteColor]];
    _readout.adjustsFontSizeToFitWidth = YES;
    _readout.minimumScaleFactor = 0.5;
    _readout.accessibilityLabel = @"Heading";
    _hint = [self labelWithColor:HEX(0x8A8DB5)];
    _hint.numberOfLines = 2;
    _hint.adjustsFontSizeToFitWidth = YES;
    _hint.minimumScaleFactor = 0.6;
    _missing = [self labelWithColor:HEX(0xA9ACD0)];
    _missing.numberOfLines = 0;
    _missing.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
    _missing.text = @"This device has no compass sensor";
    for (UIView *view in @[_readout, _hint, _missing]) [self.view addSubview:view];

    _motion = [[CMMotionManager alloc] init];
    _motion.deviceMotionUpdateInterval = 1.0 / 30.0;
    _available = _motion.isDeviceMotionAvailable &&
        ([CMMotionManager availableAttitudeReferenceFrames] & CMAttitudeReferenceFrameXMagneticNorthZVertical) != 0;

    // Without a compass, show only the message.
    _missing.hidden = _available;
    for (UIView *view in @[_dial, _levelRing, _levelTarget, _bubble, _readout, _hint]) view.hidden = !_available;
    _pointer.hidden = !_available;
    [self showFlat:NO];
    [self showHeading];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(stopUpdates) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(startUpdates) name:UIApplicationWillEnterForegroundNotification object:nil];
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateBackground) [self startUpdates];
}

- (void)dealloc {
    [_motion stopDeviceMotionUpdates];
}

#pragma mark Motion

- (void)startUpdates {
    if (!_available || _motion.isDeviceMotionActive) return;
    _hasHeading = NO;   // the first new sample sets the dial directly
    __weak typeof(self) weakSelf = self;
    [_motion startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXMagneticNorthZVertical
                                                 toQueue:[NSOperationQueue mainQueue]
                                             withHandler:^(CMDeviceMotion *motion, NSError *error) {
        [weakSelf handleMotion:motion];
    }];
}

- (void)stopUpdates {
    if (_motion.isDeviceMotionActive) [_motion stopDeviceMotionUpdates];
}

// How far the top of the screen is turned clockwise from the top of the device.
- (double)screenTurn {
    switch (self.view.window.windowScene.interfaceOrientation) {
        case UIInterfaceOrientationPortraitUpsideDown: return 180;
        case UIInterfaceOrientationLandscapeRight: return 90;    // device top is on the left
        case UIInterfaceOrientationLandscapeLeft: return -90;    // device top is on the right
        default: return 0;
    }
}

- (void)handleMotion:(CMDeviceMotion *)motion {
    if (!motion) return;
    double turn = [self screenTurn];

    // Heading is -1 until the magnetometer has settled.
    double raw = motion.heading;
    if (raw >= 0 && isfinite(raw)) {
        double target = CompassWrap360(raw + turn);
        _heading = _hasHeading ? CompassSmooth(_heading, target, kHeadingSmoothing) : target;
        _hasHeading = YES;
    } else {
        _hasHeading = NO;
    }
    [self showHeading];

    // Gravity along the device's x and y axes, from pitch and roll. The bubble goes the other way.
    double pitch = motion.attitude.pitch, roll = motion.attitude.roll;
    double gx = cos(pitch) * sin(roll), gy = -sin(pitch);
    if (!isfinite(gx) || !isfinite(gy)) return;
    double right, up;
    CompassToScreen(-gx, -gy, turn, &right, &up);
    // Full travel at a 30 degree tilt.
    right = MAX(-1, MIN(1, right * 2));
    up = MAX(-1, MIN(1, up * 2));
    _tiltRight += (right - _tiltRight) * kTiltSmoothing;
    _tiltUp += (up - _tiltUp) * kTiltSmoothing;
    [self placeBubble];
    [self showFlat:hypot(gx, gy) < kFlatTilt];
}

- (void)showHeading {
    NSString *text = @"--°", *hint = @"Move the device in a figure 8 to calibrate";
    if (_hasHeading) {
        long degrees = lround(_heading) % 360;
        text = [NSString stringWithFormat:@"%ld° %s", degrees, CompassPoint(degrees)];
        hint = @"Magnetic north";
        // The dial turns against the heading so the heading sits under the pointer.
        _dial.transform = CGAffineTransformMakeRotation(-_heading * M_PI / 180.0);
    }
    if (![_readout.text isEqualToString:text]) _readout.text = text;
    if (![_hint.text isEqualToString:hint]) _hint.text = hint;
}

- (void)showFlat:(BOOL)flat {
    if (flat == _flat && _bubble.backgroundColor) return;
    _flat = flat;
    _bubble.backgroundColor = flat ? HEX(0x3DDC84) : [UIColor colorWithWhite:1 alpha:0.85];
}

- (void)placeBubble {
    // Keep the bubble inside the ring.
    double right = _tiltRight, up = _tiltUp, length = hypot(right, up);
    if (length > 1) { right /= length; up /= length; }
    _bubble.center = CGPointMake(_dialCenter.x + right * _bubbleTravel, _dialCenter.y - up * _bubbleTravel);
}

#pragma mark Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat pad = 16;
    CGRect area = CGRectInset(UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets), pad, pad);
    CGFloat width = MAX(area.size.width, 0), height = MAX(area.size.height, 0);
    _missing.frame = area;

    // The text goes below the dial or beside it, whichever leaves the bigger dial.
    CGFloat font = MAX(30, MIN(MIN(width, height) * 0.14, 76));
    CGFloat textWidth = font * 4.4, textHeight = font * 2.1;
    CGFloat below = MIN(width, height - textHeight - pad), beside = MIN(height, width - textWidth - pad);
    BOOL sideways = beside > below;
    CGFloat size = MAX(80, MIN(sideways ? beside : below, 640));
    CGRect text;
    CGPoint middle;
    if (sideways) {
        CGFloat x = area.origin.x + (width - (size + pad + textWidth)) / 2;
        middle = CGPointMake(x + size / 2, CGRectGetMidY(area));
        text = CGRectMake(x + size + pad, CGRectGetMidY(area) - textHeight / 2, textWidth, textHeight);
    } else {
        CGFloat y = area.origin.y + (height - (size + pad + textHeight)) / 2;
        middle = CGPointMake(CGRectGetMidX(area), y + size / 2);
        text = CGRectMake(area.origin.x, y + size + pad, width, textHeight);
    }
    _readout.frame = CGRectMake(text.origin.x, text.origin.y, text.size.width, font * 1.2);
    _readout.font = [UIFont monospacedDigitSystemFontOfSize:font weight:UIFontWeightLight];
    _hint.frame = CGRectMake(text.origin.x, text.origin.y + font * 1.2, text.size.width, font * 0.9);
    _hint.font = [UIFont systemFontOfSize:MAX(13, font * 0.3) weight:UIFontWeightRegular];

    // The pointer sits on top of the dial, inside the same square.
    CGFloat pointer = size * 0.05, radius = size / 2 - pointer;
    _dialCenter = CGPointMake(middle.x, middle.y + pointer / 2);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // Bounds and center only: the dial has a rotation, so its frame must not be set.
    _dial.bounds = CGRectMake(0, 0, radius * 2, radius * 2);
    _dial.center = _dialCenter;
    _dial.layer.cornerRadius = radius;
    if (fabs(radius - _radius) > 0.01) {
        _radius = radius;
        [self drawDial];
    }

    UIBezierPath *arrow = [UIBezierPath bezierPath];
    CGFloat top = _dialCenter.y - radius;
    [arrow moveToPoint:CGPointMake(_dialCenter.x, top + pointer * 0.5)];
    [arrow addLineToPoint:CGPointMake(_dialCenter.x - pointer * 0.55, top - pointer)];
    [arrow addLineToPoint:CGPointMake(_dialCenter.x + pointer * 0.55, top - pointer)];
    [arrow closePath];
    _pointer.frame = self.view.bounds;
    _pointer.path = arrow.CGPath;
    [CATransaction commit];

    CGFloat ring = radius * 0.24, bubble = ring * 0.34;
    _bubbleTravel = ring - bubble - 3;
    [self round:_levelRing radius:ring border:1.5];
    [self round:_levelTarget radius:bubble + 3 border:1];
    [self round:_bubble radius:bubble border:0];
    [self placeBubble];
}

- (void)round:(UIView *)view radius:(CGFloat)radius border:(CGFloat)border {
    view.bounds = CGRectMake(0, 0, radius * 2, radius * 2);
    view.center = _dialCenter;
    view.layer.cornerRadius = radius;
    view.layer.borderWidth = border;
}

// Ticks every 2 degrees (longer every 30), numbers every 30, and the four letters.
- (void)drawDial {
    CGFloat r = _radius;
    UIBezierPath *minor = [UIBezierPath bezierPath], *major = [UIBezierPath bezierPath];
    for (NSInteger degrees = 0; degrees < 360; degrees += 2) {
        BOOL big = degrees % 30 == 0;
        CGFloat a = degrees * M_PI / 180.0, x = sin(a), y = -cos(a);
        CGFloat inner = r * (big ? 0.87 : 0.92), outer = r * 0.98;
        UIBezierPath *path = big ? major : minor;
        [path moveToPoint:CGPointMake(r + x * inner, r + y * inner)];
        [path addLineToPoint:CGPointMake(r + x * outer, r + y * outer)];
    }
    CGRect bounds = CGRectMake(0, 0, r * 2, r * 2);
    _minorTicks.frame = bounds;
    _minorTicks.path = minor.CGPath;
    _minorTicks.lineWidth = MAX(1, r * 0.006);
    _majorTicks.frame = bounds;
    _majorTicks.path = major.CGPath;
    _majorTicks.lineWidth = MAX(1.5, r * 0.013);

    UIFont *numberFont = [UIFont monospacedDigitSystemFontOfSize:MAX(8, r * 0.075) weight:UIFontWeightMedium];
    UIFont *letterFont = [UIFont systemFontOfSize:MAX(12, r * 0.17) weight:UIFontWeightBold];
    for (NSUInteger i = 0; i < _marks.count; i++) {
        UILabel *mark = _marks[i];
        BOOL letter = i >= 12;
        CGFloat a = mark.tag * M_PI / 180.0, distance = r * (letter ? 0.56 : 0.77);
        mark.transform = CGAffineTransformIdentity;
        mark.font = letter ? letterFont : numberFont;
        [mark sizeToFit];
        mark.center = CGPointMake(r + sin(a) * distance, r - cos(a) * distance);
        mark.transform = CGAffineTransformMakeRotation(a);
    }
}

@end

@interface CompassAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation CompassAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[CompassViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([CompassAppDelegate class]));
    }
}
