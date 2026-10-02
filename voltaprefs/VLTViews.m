#import "VLTViews.h"
#import <Preferences/PSSpecifier.h>
#import "VLTShared.h"

static UIFont *VLTRoundedFont(CGFloat size, UIFontWeight weight) {
    UIFont *font = [UIFont systemFontOfSize:size weight:weight];
    UIFontDescriptor *rounded = [font.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    return rounded ? [UIFont fontWithDescriptor:rounded size:size] : font;
}

#pragma mark - Header

@implementation VLTHeaderView {
    UIView *_card;
    CAGradientLayer *_gradient;
    UIImageView *_glyph;
    UILabel *_title;
    UILabel *_subtitle;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _card = [[UIView alloc] init];
        _card.layer.cornerRadius = 22;
        _card.layer.cornerCurve = kCACornerCurveContinuous;
        _card.clipsToBounds = YES;
        [self addSubview:_card];

        _gradient = [CAGradientLayer layer];
        _gradient.colors = @[(id)VLT_ACCENT.CGColor, (id)VLT_TEAL.CGColor];
        _gradient.startPoint = CGPointMake(0, 0);
        _gradient.endPoint = CGPointMake(1, 1);
        [_card.layer addSublayer:_gradient];

        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIImageSymbolWeightSemibold];
        _glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"bolt.fill" withConfiguration:config]];
        _glyph.tintColor = [UIColor whiteColor];
        _glyph.contentMode = UIViewContentModeCenter;
        _glyph.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
        _glyph.layer.cornerRadius = 18;
        _glyph.layer.cornerCurve = kCACornerCurveContinuous;
        [_card addSubview:_glyph];

        _title = [[UILabel alloc] init];
        _title.text = @"Volta";
        _title.font = VLTRoundedFont(32, UIFontWeightBold);
        _title.textColor = [UIColor whiteColor];
        [_card addSubview:_title];

        _subtitle = [[UILabel alloc] init];
        _subtitle.text = @"Your battery and Control Center, your way.";
        _subtitle.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        _subtitle.textColor = [UIColor colorWithWhite:1 alpha:0.85];
        _subtitle.numberOfLines = 2;
        [_card addSubview:_subtitle];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat inset = MAX(16, self.layoutMargins.left);
    _card.frame = CGRectMake(inset, 12, self.bounds.size.width - inset * 2, self.bounds.size.height - 20);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _gradient.frame = _card.bounds;
    [CATransaction commit];

    CGFloat h = _card.bounds.size.height, w = _card.bounds.size.width;
    _glyph.frame = CGRectMake(20, (h - 68) / 2, 68, 68);
    CGFloat x = CGRectGetMaxX(_glyph.frame) + 16;
    CGFloat textWidth = w - x - 16;
    CGSize sub = [_subtitle sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)];
    CGFloat total = 38 + 4 + sub.height;
    _title.frame = CGRectMake(x, (h - total) / 2, textWidth, 38);
    _subtitle.frame = CGRectMake(x, CGRectGetMaxY(_title.frame) + 4, textWidth, sub.height);
}

@end

#pragma mark - Battery preview

@implementation VLTBatteryPreview {
    NSArray<UIImage *> *_frames;      // the battery picture: one still, or an animation
    NSUInteger _frameIndex;
    NSTimer *_timer;
}

- (void)dealloc {
    [_timer invalidate];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self rebuildFrames];   // also stops the timer once the page is gone
}

// Same picture logic as the tweak, at preview size.
- (void)rebuildFrames {
    NSDictionary *p = self.prefs ?: @{};
    [_timer invalidate];
    _timer = nil;
    _frames = nil;
    _frameIndex = 0;
    if (!VLTBool(p, @"enabled", YES)) return;

    int kind = (int)VLTNum(p, @"batImage", VLT_IMAGE_NONE);
    CGFloat scale = fmin(fmax(VLTNum(p, @"batScale", 100), 50), 150) / 100.0;
    CGFloat height = VLT_IMAGE_HEIGHT * 3.5 * scale;
    double fps = VLT_EFFECT_FPS;
    if (kind == VLT_IMAGE_ANIMATED) {
        NSMutableArray *sources = [NSMutableArray array];
        for (id item in ([p[@"batFrames"] isKindOfClass:[NSArray class]] ? p[@"batFrames"] : @[])) {
            UIImage *image = [item isKindOfClass:[NSData class]] ? [UIImage imageWithData:item] : nil;
            if (image && sources.count < VLT_MAX_FRAMES) [sources addObject:image];
        }
        _frames = VLTFittedFrames(sources, height, 0);
        fps = fmin(fmax(VLTNum(p, @"batFps", 8), 1), 24);
    } else {
        UIImage *still = nil;
        if (kind == VLT_IMAGE_CUSTOM) {
            NSData *data = p[@"batImageData"];
            if ([data isKindOfClass:[NSData class]]) still = VLTFittedImage([UIImage imageWithData:data], height, 0);
        } else {
            still = VLTThemeImage(kind, height, 0);
        }
        if (still) _frames = VLTEffectFrames(still, (int)VLTNum(p, @"batEffect", VLTEffectNone)) ?: @[still];
    }
    if (_frames.count > 1 && self.window && !UIAccessibilityIsReduceMotionEnabled()) {
        __weak typeof(self) weakSelf = self;
        _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / fps repeats:YES block:^(NSTimer *timer) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) { [timer invalidate]; return; }
            strongSelf->_frameIndex++;
            [strongSelf setNeedsDisplay];
        }];
    }
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
        [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    }
    return self;
}

- (void)setPrefs:(NSDictionary *)prefs {
    _prefs = [prefs copy];
    [self rebuildFrames];
    [self setNeedsDisplay];
}

static UIBezierPath *VLTBoltPath(CGRect r) {
    static const CGFloat pts[][2] = {{0.60, 0.00}, {0.10, 0.57}, {0.45, 0.57}, {0.36, 1.00}, {0.90, 0.41}, {0.54, 0.41}};
    UIBezierPath *path = [UIBezierPath bezierPath];
    for (int i = 0; i < 6; i++) {
        CGPoint p = CGPointMake(r.origin.x + pts[i][0] * r.size.width, r.origin.y + pts[i][1] * r.size.height);
        if (i == 0) [path moveToPoint:p]; else [path addLineToPoint:p];
    }
    [path closePath];
    return path;
}

- (void)drawRect:(CGRect)rect {
    NSDictionary *p = self.prefs ?: @{};
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    // Card: a dark "wallpaper" so light and dark colors both read well.
    CGFloat inset = MAX(16, self.layoutMargins.left);
    CGRect card = CGRectMake(inset, 12, self.bounds.size.width - inset * 2, self.bounds.size.height - 20);
    UIBezierPath *cardPath = [UIBezierPath bezierPathWithRoundedRect:card cornerRadius:22];
    CGContextSaveGState(ctx);
    [cardPath addClip];
    NSArray *colors = @[(id)[UIColor colorWithRed:0.09 green:0.09 blue:0.20 alpha:1].CGColor,
                        (id)[UIColor colorWithRed:0.24 green:0.18 blue:0.45 alpha:1].CGColor];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
    CGContextDrawLinearGradient(ctx, gradient, card.origin, CGPointMake(CGRectGetMaxX(card), CGRectGetMaxY(card)), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
    CGContextRestoreGState(ctx);

    [@"PREVIEW" drawAtPoint:CGPointMake(card.origin.x + 16, card.origin.y + 12)
             withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold],
                              NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.55],
                              NSKernAttributeName: @1.2}];

    // ---- Resolve settings (mirrors the logic in Tweak.x) ----
    BOOL on = VLTBool(p, @"enabled", YES);
    #define ON(key, def) (on && VLTBool(p, key, def))

    float level = [UIDevice currentDevice].batteryLevel;
    double real = (level >= 0) ? level : 0.8;
    double fraction = ON(@"batFakeEnabled", NO) ? fmin(fmax(VLTNum(p, @"batFakeValue", 100), 0), 100) / 100.0 : real;
    NSInteger number = (NSInteger)lround(fraction * 100);

    int chargeMode = on ? (int)VLTNum(p, @"batCharging", 0) : 0;
    int saverMode  = on ? (int)VLTNum(p, @"batSaver", 0) : 0;
    int iconMode   = on ? (int)VLTNum(p, @"batInIcon", 0) : 0;
    UIDeviceBatteryState deviceState = [UIDevice currentDevice].batteryState;
    BOOL charging = (chargeMode == 1) || (chargeMode == 0 && (deviceState == UIDeviceBatteryStateCharging || deviceState == UIDeviceBatteryStateFull));
    BOOL saver = (saverMode == 1) || (saverMode == 0 && [NSProcessInfo processInfo].lowPowerModeEnabled);
    BOOL inIcon = (iconMode != 2);

    NSString *label = on ? [VLTStr(p, @"batLabel") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
    NSString *text = nil;
    if (!ON(@"batHidePercent", NO)) {
        if (label.length) text = label;
        else if ((inIcon && !VLTNum(p, @"batImage", 0)) || ON(@"batHideSymbol", NO)) text = [NSString stringWithFormat:@"%ld", (long)number];
        else text = [NSString stringWithFormat:@"%ld%%", (long)number];
    }

    BOOL custom = ON(@"batColors", NO);
    UIColor *white = [UIColor whiteColor];
    UIColor *fill = white;
    if (saver) fill = [UIColor systemYellowColor];
    if (charging) fill = [UIColor systemGreenColor];
    if (!saver && !charging && fraction <= 0.20) fill = [UIColor systemRedColor];
    BOOL special = saver || charging || fraction <= 0.20;
    if (custom && !(special && VLTBool(p, @"batKeepStatus", YES))) {
        if (VLTBool(p, @"batLevelColor", NO)) fill = VLTLevelColorFor(fraction);
        else fill = VLTColorFromHex(p[@"batFill"]) ?: fill;
    }
    UIColor *body = (custom ? VLTColorFromHex(p[@"batBody"]) : nil) ?: [UIColor colorWithWhite:1 alpha:0.35];
    UIColor *pin  = (custom ? VLTColorFromHex(p[@"batPin"])  : nil) ?: [UIColor colorWithWhite:1 alpha:0.45];
    UIColor *bolt = (custom ? VLTColorFromHex(p[@"batBolt"]) : nil);
    UIColor *textColor = (custom ? VLTColorFromHex(p[@"batText"]) : nil) ?: white;
    BOOL hideIcon = ON(@"batHideIcon", NO), hidePin = ON(@"batHidePin", NO);
    CGFloat scale = on ? fmin(fmax(VLTNum(p, @"batScale", 100), 50), 150) / 100.0 : 1.0;

    // Battery picture: a theme, the user's own, or one frame of an animation.
    UIImage *picture = _frames.count ? _frames[_frameIndex % _frames.count] : nil;
    if (picture && ON(@"batImageFill", NO)) picture = VLTLevelImage(picture, fraction);
    if (picture) inIcon = NO;   // a picture has no room for the number
    #undef ON

    // ---- Layout ----
    CGFloat bw = 92 * scale, bh = 42 * scale, pinW = 5 * scale, gap = 4 * scale;
    CGFloat iconW = hideIcon ? 0 : (picture ? picture.size.width : bw + gap + pinW);
    UIFont *sideFont = VLTRoundedFont(30, UIFontWeightSemibold);
    NSDictionary *sideAttrs = @{NSFontAttributeName: sideFont, NSForegroundColorAttributeName: textColor};
    BOOL textBeside = text.length && (!inIcon || hideIcon);
    CGSize sideSize = textBeside ? [text sizeWithAttributes:sideAttrs] : CGSizeZero;
    CGFloat spacing = (textBeside && !hideIcon) ? 12 : 0;
    CGFloat total = sideSize.width + spacing + iconW;
    CGFloat x = CGRectGetMidX(card) - total / 2;
    CGFloat cy = CGRectGetMidY(card) + 8;

    if (textBeside) {
        [text drawAtPoint:CGPointMake(x, cy - sideSize.height / 2) withAttributes:sideAttrs];
        x += sideSize.width + spacing;
    }
    if (hideIcon) return;
    if (picture) {
        [picture drawAtPoint:CGPointMake(x, cy - picture.size.height / 2)];
        return;
    }

    CGRect bodyRect = CGRectMake(x, cy - bh / 2, bw, bh);
    CGFloat radius = bh * 0.30;
    UIBezierPath *bodyPath = [UIBezierPath bezierPathWithRoundedRect:bodyRect cornerRadius:radius];
    [body setFill];
    [bodyPath fill];

    CGContextSaveGState(ctx);
    [bodyPath addClip];
    [fill setFill];
    UIRectFill(CGRectMake(bodyRect.origin.x, bodyRect.origin.y, bw * fraction, bh));
    CGContextRestoreGState(ctx);

    if (!hidePin) {
        CGRect pinRect = CGRectMake(CGRectGetMaxX(bodyRect) + gap, cy - bh * 0.16, pinW, bh * 0.32);
        [pin setFill];
        [[UIBezierPath bezierPathWithRoundedRect:pinRect byRoundingCorners:UIRectCornerTopRight | UIRectCornerBottomRight
                                    cornerRadii:CGSizeMake(pinW * 0.6, pinW * 0.6)] fill];
    }

    // Number and bolt inside the icon
    BOOL textInside = text.length && inIcon;
    CGFloat w = 0, a = 1;
    [fill getWhite:&w alpha:&a];
    CGFloat r = 0, g = 0, b = 0;
    if ([fill getRed:&r green:&g blue:&b alpha:&a]) w = 0.299 * r + 0.587 * g + 0.114 * b;
    UIColor *inside = (w > 0.6 && fraction > 0.45) ? [UIColor colorWithWhite:0 alpha:0.85] : white;

    CGFloat boltH = bh * (textInside ? 0.52 : 0.66), boltW = boltH * 0.62;
    CGFloat fontSize = bh * 0.60;
    NSDictionary *inAttrs = nil;
    CGSize inSize = CGSizeZero;
    if (textInside) {
        // Shrink long custom text to fit the body.
        for (; fontSize > 8; fontSize -= 1) {
            inAttrs = @{NSFontAttributeName: VLTRoundedFont(fontSize, UIFontWeightBold), NSForegroundColorAttributeName: inside};
            inSize = [text sizeWithAttributes:inAttrs];
            if (inSize.width + (charging ? boltW + 3 : 0) <= bw - 10) break;
        }
    }
    CGFloat contentW = inSize.width + ((charging && textInside) ? 3 : 0) + (charging ? boltW : 0);
    CGFloat ix = CGRectGetMidX(bodyRect) - contentW / 2;
    if (textInside) {
        [text drawAtPoint:CGPointMake(ix, cy - inSize.height / 2) withAttributes:inAttrs];
        ix += inSize.width + 3;
    }
    if (charging) {
        [(bolt ?: inside) setFill];
        [VLTBoltPath(CGRectMake(ix, cy - boltH / 2, boltW, boltH)) fill];
    }
}

@end

#pragma mark - Color cell

@implementation VLTColorCell

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];

    id target = specifier.target;
    id value = nil;
    if ([target respondsToSelector:@selector(readPreferenceValue:)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        value = [target performSelector:@selector(readPreferenceValue:) withObject:specifier];
        #pragma clang diagnostic pop
    }
    UIColor *color = VLTColorFromHex(value);

    if (color) {
        UIView *swatch = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
        swatch.backgroundColor = color;
        swatch.layer.cornerRadius = 15;
        swatch.layer.borderWidth = 1.0;
        swatch.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.45].CGColor;
        self.accessoryView = swatch;
    } else {
        UILabel *label = [[UILabel alloc] init];
        label.text = @"Default";
        label.textColor = [UIColor secondaryLabelColor];
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        [label sizeToFit];
        self.accessoryView = label;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Button cells are tinted like links by default; this should read as a normal row.
    self.textLabel.textColor = [UIColor labelColor];
    self.textLabel.textAlignment = NSTextAlignmentNatural;
}

@end

#pragma mark - Picture cell

@implementation VLTPictureCell

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];

    NSData *data = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("batImageData"), CFSTR(VLT_DOMAIN)));
    UIImage *image = [data isKindOfClass:[NSData class]] ? [UIImage imageWithData:data] : nil;
    if (image) {
        UIImageView *thumb = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 34, 34)];
        thumb.image = image;
        thumb.contentMode = UIViewContentModeScaleAspectFit;
        thumb.backgroundColor = [UIColor colorWithRed:0.12 green:0.11 blue:0.26 alpha:1];
        thumb.layer.cornerRadius = 8;
        thumb.layer.cornerCurve = kCACornerCurveContinuous;
        thumb.clipsToBounds = YES;
        self.accessoryView = thumb;
    } else {
        UILabel *label = [[UILabel alloc] init];
        label.text = @"None";
        label.textColor = [UIColor secondaryLabelColor];
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        [label sizeToFit];
        self.accessoryView = label;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.textColor = [UIColor labelColor];
    self.textLabel.textAlignment = NSTextAlignmentNatural;
}

@end
