#import "VLTSlider.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kInset = 5;

@implementation VLTSlideToUnlock {
    UIVisualEffectView *_track;
    UILabel *_label;
    CAGradientLayer *_shimmer;      // mask over the label; its bright band sweeps left to right
    UIView *_knob;
    UIImageView *_arrow;
    CGFloat _offset;                // knob travel, 0 ... maxOffset
    CGFloat _startOffset;
    BOOL _completed;
}

+ (CGSize)preferredSizeForWidth:(CGFloat)available {
    return CGSizeMake(MIN(MAX(available - 48, 200), 330), 62);
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _track = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        _track.clipsToBounds = YES;
        _track.layer.borderWidth = 1;
        _track.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
        _track.userInteractionEnabled = NO;
        [self addSubview:_track];

        _label = [[UILabel alloc] init];
        _label.font = [UIFont systemFontOfSize:19 weight:UIFontWeightRegular];
        _label.textColor = [UIColor whiteColor];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.6;
        _label.text = @"slide to unlock";
        [self addSubview:_label];

        _shimmer = [CAGradientLayer layer];
        _shimmer.startPoint = CGPointMake(0, 0.5);
        _shimmer.endPoint = CGPointMake(1, 0.5);
        UIColor *dim = [UIColor colorWithWhite:1 alpha:0.38];
        _shimmer.colors = @[(id)dim.CGColor, (id)[UIColor whiteColor].CGColor, (id)dim.CGColor];
        _shimmer.locations = @[@0.0, @0.15, @0.3];
        _label.layer.mask = _shimmer;

        _knob = [[UIView alloc] init];
        _knob.backgroundColor = [UIColor whiteColor];
        _knob.layer.cornerCurve = kCACornerCurveContinuous;
        _knob.layer.shadowColor = [UIColor blackColor].CGColor;
        _knob.layer.shadowOpacity = 0.25;
        _knob.layer.shadowRadius = 4;
        _knob.layer.shadowOffset = CGSizeMake(0, 1);
        [self addSubview:_knob];

        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
        _arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.right" withConfiguration:config]];
        _arrow.contentMode = UIViewContentModeCenter;
        _arrow.tintColor = [UIColor colorWithWhite:0.25 alpha:1];
        [_knob addSubview:_arrow];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.delegate = self;
        pan.maximumNumberOfTouches = 1;
        [_knob addGestureRecognizer:pan];

        self.isAccessibilityElement = YES;
        self.accessibilityLabel = @"Slide to unlock";
        self.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return self;
}

// VoiceOver and Switch Control users activate instead of dragging.
- (BOOL)accessibilityActivate {
    [self finishUnlock];
    return YES;
}

- (void)setText:(NSString *)text {
    _text = [text copy];
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    _label.text = trimmed.length ? trimmed : @"slide to unlock";
}

- (void)setKnobColor:(UIColor *)color {
    _knobColor = color;
    UIColor *fill = color ?: [UIColor whiteColor];
    _knob.backgroundColor = fill;
    // Dark arrow on a light knob, light arrow on a dark one.
    CGFloat r = 1, g = 1, b = 1, a = 1, w = 1;
    if ([fill getRed:&r green:&g blue:&b alpha:&a]) w = 0.299 * r + 0.587 * g + 0.114 * b;
    else [fill getWhite:&w alpha:&a];
    _arrow.tintColor = w > 0.6 ? [UIColor colorWithWhite:0.2 alpha:1] : [UIColor whiteColor];
}

- (CGFloat)knobWidth { return self.bounds.size.height - kInset * 2 + 14; }
- (CGFloat)maxOffset { return MAX(self.bounds.size.width - kInset * 2 - [self knobWidth], 1); }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height, w = self.bounds.size.width;
    _track.frame = self.bounds;
    _track.layer.cornerRadius = h / 2;
    CGFloat knobW = [self knobWidth], knobH = h - kInset * 2;
    _knob.bounds = CGRectMake(0, 0, knobW, knobH);
    _knob.layer.cornerRadius = knobH / 2;
    _arrow.frame = _knob.bounds;
    [self placeKnob];
    CGFloat textX = kInset + knobW + 8;
    _label.frame = CGRectMake(textX, 0, w - textX - 18, h);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shimmer.frame = _label.bounds;
    [CATransaction commit];
    [self startShimmer];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) [self startShimmer];   // animations are dropped when a view leaves its window
}

- (void)startShimmer {
    if ([_shimmer animationForKey:@"shimmer"] || UIAccessibilityIsReduceMotionEnabled()) return;
    CABasicAnimation *sweep = [CABasicAnimation animationWithKeyPath:@"locations"];
    sweep.fromValue = @[@-0.3, @-0.15, @0.0];
    sweep.toValue = @[@1.0, @1.15, @1.3];
    sweep.duration = 2.4;
    sweep.repeatCount = HUGE_VALF;
    sweep.removedOnCompletion = NO;
    [_shimmer addAnimation:sweep forKey:@"shimmer"];
}

- (void)placeKnob {
    CGFloat knobW = [self knobWidth];
    _knob.center = CGPointMake(kInset + knobW / 2 + _offset, self.bounds.size.height / 2);
    _label.alpha = MAX(0, 1 - (_offset / [self maxOffset]) * 2.2);   // text fades as the knob moves
}

- (void)reset {
    _completed = NO;
    _offset = 0;
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [self placeKnob]; } completion:nil];
}

- (void)finishUnlock {
    if (_completed) return;
    _completed = YES;
    _offset = [self maxOffset];
    [UIView animateWithDuration:0.15 animations:^{ [self placeKnob]; }];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    if (self.onUnlock) self.onUnlock();
    // If the unlock did not go through (wrong passcode, cancelled), be ready again.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf reset]; });
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (_completed) return;
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            _startOffset = _offset;
            break;
        case UIGestureRecognizerStateChanged: {
            CGFloat x = _startOffset + [pan translationInView:self].x;
            _offset = MIN(MAX(x, 0), [self maxOffset]);
            [self placeKnob];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            BOOL far = _offset >= [self maxOffset] * 0.86;
            BOOL flung = [pan velocityInView:self].x > 900 && _offset >= [self maxOffset] * 0.5;
            if (pan.state == UIGestureRecognizerStateEnded && (far || flung)) [self finishUnlock];
            else [self reset];
            break;
        }
        default: break;
    }
}

// The Lock Screen pages sideways; while a finger is on the knob, that
// scrolling (and anything else that pans) has to wait for us.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return other.view != _knob;
}

@end

#pragma mark - Swipe up

@implementation VLTSwipeUpToUnlock {
    UIView *_content;      // hint + bar; follows the finger
    UILabel *_hint;
    UIView *_bar;
    UIPanGestureRecognizer *_pan;
    BOOL _completed;
}

+ (CGFloat)preferredHeight { return 96; }

- (void)setPassive:(BOOL)passive {
    _passive = passive;
    _pan.enabled = !passive;
    self.userInteractionEnabled = !passive;
}

- (void)setHintInset:(CGFloat)inset {
    if (fabs(inset - _hintInset) < 0.5) return;
    _hintInset = inset;
    [self setNeedsLayout];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _content = [[UIView alloc] init];
        _content.userInteractionEnabled = NO;
        [self addSubview:_content];

        _hint = [[UILabel alloc] init];
        _hint.text = @"Swipe up to unlock";
        _hint.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _hint.textColor = [UIColor colorWithWhite:1 alpha:0.9];
        _hint.textAlignment = NSTextAlignmentCenter;
        _hint.layer.shadowColor = [UIColor blackColor].CGColor;
        _hint.layer.shadowOpacity = 0.35;
        _hint.layer.shadowRadius = 3;
        _hint.layer.shadowOffset = CGSizeZero;
        [_content addSubview:_hint];

        _bar = [[UIView alloc] init];
        _bar.backgroundColor = [UIColor whiteColor];
        _bar.layer.cornerRadius = 2.5;
        _bar.layer.shadowColor = [UIColor blackColor].CGColor;
        _bar.layer.shadowOpacity = 0.3;
        _bar.layer.shadowRadius = 3;
        _bar.layer.shadowOffset = CGSizeZero;
        [_content addSubview:_bar];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.delegate = self;
        pan.maximumNumberOfTouches = 1;
        [self addGestureRecognizer:pan];
        _pan = pan;
        _hintInset = 37;

        self.isAccessibilityElement = YES;
        self.accessibilityLabel = @"Swipe up to unlock";
        self.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return self;
}

- (BOOL)accessibilityActivate {
    [self finishUnlock];
    return YES;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!CGAffineTransformIsIdentity(_content.transform)) return;   // mid-swipe
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    _content.frame = self.bounds;
    _bar.frame = CGRectMake(round((w - 140) / 2), h - 14, 140, 5);
    _hint.frame = CGRectMake(0, h - _hintInset - 11, w, 22);
    [self startBob];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) [self startBob];
}

// A small nudge upward now and then, as a hint.
- (void)startBob {
    if ([_hint.layer animationForKey:@"bob"] || UIAccessibilityIsReduceMotionEnabled()) return;
    CAKeyframeAnimation *bob = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.y"];
    bob.values = @[@0, @-7, @0, @0];
    bob.keyTimes = @[@0, @0.18, @0.36, @1];
    bob.duration = 3.2;
    bob.repeatCount = HUGE_VALF;
    bob.removedOnCompletion = NO;
    bob.timingFunctions = @[[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut],
                            [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn],
                            [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear]];
    [_hint.layer addAnimation:bob forKey:@"bob"];
}

- (void)reset {
    _completed = NO;
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self->_content.transform = CGAffineTransformIdentity;
        self->_content.alpha = 1;
    } completion:nil];
}

- (void)finishUnlock {
    if (_completed) return;
    _completed = YES;
    [UIView animateWithDuration:0.18 animations:^{
        self->_content.transform = CGAffineTransformMakeTranslation(0, -220);
        self->_content.alpha = 0;
    }];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    if (self.onUnlock) self.onUnlock();
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf reset]; });
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (_completed) return;
    CGFloat y = MIN([pan translationInView:self].y, 0);   // upward only
    switch (pan.state) {
        case UIGestureRecognizerStateChanged:
            _content.transform = CGAffineTransformMakeTranslation(0, MAX(y, -220));
            _content.alpha = MAX(0.25, 1 + y / 260);
            break;
        case UIGestureRecognizerStateEnded: {
            BOOL far = y < -90;
            BOOL flung = [pan velocityInView:self].y < -700 && y < -30;
            if (far || flung) [self finishUnlock];
            else [self reset];
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self reset];
            break;
        default: break;
    }
}

// Only take swipes that start out heading up; sideways ones stay with the
// Lock Screen's own paging.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (![recognizer isKindOfClass:[UIPanGestureRecognizer class]]) return YES;
    CGPoint velocity = [(UIPanGestureRecognizer *)recognizer velocityInView:self];
    return velocity.y < 0 && fabs(velocity.y) > fabs(velocity.x);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return other.view != self;
}

@end
