#import "VLTPreviews.h"
#import "VLTViews.h"
#import "VLTShared.h"
#import "VLTScene.h"
#import "VLTSlider.h"
#import <Preferences/PSSpecifier.h>

#define HEX(v) [UIColor colorWithRed:(((v) >> 16) & 0xFF) / 255.0 green:(((v) >> 8) & 0xFF) / 255.0 blue:((v) & 0xFF) / 255.0 alpha:1]

static UIFont *VLTRounded(CGFloat size, UIFontWeight weight) {
    UIFont *font = [UIFont systemFontOfSize:size weight:weight];
    UIFontDescriptor *rounded = [font.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    return rounded ? [UIFont fontWithDescriptor:rounded size:size] : font;
}

#pragma mark - Dashboard card

@interface VLTCard : UIControl
@property (nonatomic, strong) UILabel *statusLabel;
- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol from:(UIColor *)from to:(UIColor *)to;
@end

@implementation VLTCard {
    UIView *_tile;
    CAGradientLayer *_tileGradient;
    UIImageView *_glyph;
    UILabel *_title;
    UIImageView *_chevron;
}

- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol from:(UIColor *)from to:(UIColor *)to {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        self.layer.cornerRadius = 20;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = title;
        self.accessibilityTraits = UIAccessibilityTraitButton;

        _tile = [[UIView alloc] init];
        _tile.userInteractionEnabled = NO;
        _tile.layer.cornerRadius = 11;
        _tile.layer.cornerCurve = kCACornerCurveContinuous;
        _tile.clipsToBounds = YES;
        _tileGradient = [CAGradientLayer layer];
        _tileGradient.colors = @[(id)from.CGColor, (id)to.CGColor];
        _tileGradient.startPoint = CGPointMake(0, 0);
        _tileGradient.endPoint = CGPointMake(1, 1);
        [_tile.layer addSublayer:_tileGradient];
        [self addSubview:_tile];

        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
        UIImage *image = [UIImage systemImageNamed:symbol withConfiguration:config] ?: [UIImage systemImageNamed:@"circle.fill" withConfiguration:config];
        _glyph = [[UIImageView alloc] initWithImage:image];
        _glyph.tintColor = [UIColor whiteColor];
        _glyph.contentMode = UIViewContentModeCenter;
        [_tile addSubview:_glyph];

        _title = [[UILabel alloc] init];
        _title.text = title;
        _title.font = VLTRounded(17, UIFontWeightSemibold);
        _title.textColor = [UIColor labelColor];
        _title.adjustsFontSizeToFitWidth = YES;
        _title.minimumScaleFactor = 0.8;
        [self addSubview:_title];

        _statusLabel = [[UILabel alloc] init];
        _statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        _statusLabel.textColor = [UIColor secondaryLabelColor];
        [self addSubview:_statusLabel];

        UIImageSymbolConfiguration *small = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold];
        _chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:small]];
        _chevron.tintColor = [UIColor tertiaryLabelColor];
        _chevron.contentMode = UIViewContentModeCenter;
        [self addSubview:_chevron];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    _tile.frame = CGRectMake(14, 14, 38, 38);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _tileGradient.frame = _tile.bounds;
    [CATransaction commit];
    _glyph.frame = _tile.bounds;
    _chevron.frame = CGRectMake(w - 14 - 14, 26, 14, 14);
    _title.frame = CGRectMake(14, 62, w - 28, 22);
    _statusLabel.frame = CGRectMake(14, 84, w - 28, 18);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:highlighted ? 0.05 : 0.25 animations:^{
        self.alpha = highlighted ? 0.6 : 1;
        self.transform = highlighted ? CGAffineTransformMakeScale(0.97, 0.97) : CGAffineTransformIdentity;
    }];
}

@end

#pragma mark - Pages in lists

typedef struct { VLTPage page; const char *title; const char *symbol; uint32_t from, to; } VLTPageLook;

static const VLTPageLook kPageLooks[] = {
    { VLTPageBattery,   "Battery",           "battery.100",             0x4CD964, 0x1E9E4A },
    { VLTPageStatus,    "Clock, Items & Fakes", "wifi",                 0x64D2FF, 0x3A7BFF },
    { VLTPageCC,        "Control Center",    "switch.2",                0x5B5BF0, 0x19C8B9 },
    { VLTPageHome,      "Layout",            "square.grid.3x3.fill",    0x34C8A0, 0x0E8F8A },
    { VLTPageIcons,     "Icons",             "app.badge.fill",          0xFF9F0A, 0xFF5E3A },
    { VLTPageDock,      "Dock",              "dock.rectangle",          0xFFB020, 0xFF6B2C },
    { VLTPageWallpaper, "Wallpaper",         "sparkles",                0xBF5AF2, 0xFF4F8B },
    { VLTPageLock,      "Lock Screen",       "lock.fill",               0x40C8E0, 0x0A84FF },
    { VLTPageNotif,     "Notifications",     "bell.badge.fill",         0xFF6B6B, 0xD9304F },
    { VLTPageFun,       "Fun",               "party.popper.fill",       0xF953C6, 0xB91D73 },
    { VLTPageProfiles,  "Profiles",          "square.stack.3d.up.fill", 0x8E8CF5, 0x5B4BD6 },
    { VLTPageAbout,     "About & Updates",   "heart.fill",              0xFF6482, 0xFF2D55 },
    { VLTPageSwitcher,  "App Switcher",      "rectangle.stack.fill",    0x7D7AFF, 0x4B4BD8 },
    { VLTPageKeyboard,  "Keyboard",          "keyboard.fill",           0x8E8E93, 0x5C5C63 },
    { VLTPagePopups,    "Volume, Charging & Startup", "speaker.wave.2.fill", 0x30D158, 0x0FA36B },
    { VLTPageSounds,    "Sounds",            "music.note",              0xFF6FB5, 0xD9308A },
    { VLTPageSafety,    "Safety",            "shield.fill",             0x34C759, 0x0A8F6B },
};

static const VLTPageLook *VLTLookFor(VLTPage page) {
    for (size_t i = 0; i < sizeof(kPageLooks) / sizeof(kPageLooks[0]); i++) if (kPageLooks[i].page == page) return &kPageLooks[i];
    return &kPageLooks[0];
}

NSString *VLTPageTitle(VLTPage page) { return @(VLTLookFor(page)->title); }

UIImage *VLTPageTile(VLTPage page, CGFloat side) {
    const VLTPageLook *look = VLTLookFor(page);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side) cornerRadius:side * 0.28] addClip];
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)@[(id)HEX(look->from).CGColor, (id)HEX(look->to).CGColor], NULL);
        CGContextDrawLinearGradient(context.CGContext, gradient, CGPointZero, CGPointMake(side, side), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:side * 0.44 weight:UIImageSymbolWeightSemibold];
        UIImage *glyph = [[UIImage systemImageNamed:@(look->symbol) withConfiguration:config] ?: [UIImage systemImageNamed:@"circle.fill" withConfiguration:config]
                          imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
        [glyph drawAtPoint:CGPointMake((side - glyph.size.width) / 2, (side - glyph.size.height) / 2)];
    }];
}

#pragma mark - Dashboard

static const CGFloat kBannerHeight = 130, kCardHeight = 116, kCardGap = 12;

@implementation VLTDashboardView {
    VLTHeaderView *_banner;
    NSArray<VLTCard *> *_cards;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _banner = [[VLTHeaderView alloc] initWithFrame:CGRectZero];
        [self addSubview:_banner];
        _cards = @[   // same order as VLTGroup
            [[VLTCard alloc] initWithTitle:@"Status Bar" symbol:@"battery.100" from:HEX(0x4CD964) to:HEX(0x1E9E4A)],
            [[VLTCard alloc] initWithTitle:@"Home Screen" symbol:@"square.grid.3x3.fill" from:HEX(0xFF9F0A) to:HEX(0xFF5E3A)],
            [[VLTCard alloc] initWithTitle:@"Lock & Alerts" symbol:@"lock.fill" from:HEX(0x40C8E0) to:HEX(0x0A84FF)],
            [[VLTCard alloc] initWithTitle:@"Control Center" symbol:@"switch.2" from:HEX(0x5B5BF0) to:HEX(0x19C8B9)],
            [[VLTCard alloc] initWithTitle:@"Fun" symbol:@"party.popper.fill" from:HEX(0xF953C6) to:HEX(0xB91D73)],
            [[VLTCard alloc] initWithTitle:@"Safety" symbol:@"shield.fill" from:HEX(0x34C759) to:HEX(0x0A8F6B)],
            [[VLTCard alloc] initWithTitle:@"More" symbol:@"ellipsis" from:HEX(0x8E8CF5) to:HEX(0x5B4BD6)],
        ];
        NSInteger index = 0;
        for (VLTCard *card in _cards) {
            card.tag = index++;
            [card addTarget:self action:@selector(cardTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:card];
        }
    }
    return self;
}

- (void)cardTapped:(VLTCard *)card {
    if (self.onSelect) self.onSelect(card.tag);
}

- (void)setStatus:(NSString *)status atIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_cards.count) return;
    _cards[index].statusLabel.text = status;
    _cards[index].accessibilityValue = status;
}

- (NSInteger)columnsForWidth:(CGFloat)width { return width >= 520 ? 3 : 2; }

- (CGFloat)heightForWidth:(CGFloat)width {
    NSInteger columns = [self columnsForWidth:width];
    NSInteger rows = (_cards.count + columns - 1) / columns;
    return kBannerHeight + rows * kCardHeight + (rows - 1) * kCardGap + 14;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    _banner.frame = CGRectMake(0, 0, width, kBannerHeight);
    CGFloat inset = MAX(16, self.layoutMargins.left);
    NSInteger columns = [self columnsForWidth:width];
    NSInteger count = _cards.count, rows = (count + columns - 1) / columns;
    for (NSInteger i = 0; i < count; i++) {
        NSInteger row = i / columns, column = i % columns;
        // A short last row stretches to fill the width instead of leaving a gap.
        NSInteger inRow = (row == rows - 1) ? count - row * columns : columns;
        CGFloat cardWidth = floor((width - inset * 2 - kCardGap * (inRow - 1)) / inRow);
        // Skip the frame while a card is mid-press (it carries a transform).
        if (!CGAffineTransformIsIdentity(_cards[i].transform)) continue;
        _cards[i].frame = CGRectMake(inset + column * (cardWidth + kCardGap),
                                     kBannerHeight + row * (kCardHeight + kCardGap), cardWidth, kCardHeight);
    }
}

@end

#pragma mark - Shared preview card

// Dark "wallpaper" card with a PREVIEW caption; returns the card rect.
static CGRect VLTDrawPreviewCard(UIView *view) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat inset = MAX(16, view.layoutMargins.left);
    CGRect card = CGRectMake(inset, 12, view.bounds.size.width - inset * 2, view.bounds.size.height - 20);
    CGContextSaveGState(ctx);
    [[UIBezierPath bezierPathWithRoundedRect:card cornerRadius:22] addClip];
    NSArray *colors = @[(id)HEX(0x1B1746).CGColor, (id)HEX(0x4B2D83).CGColor, (id)HEX(0x1F6F8B).CGColor];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
    CGContextDrawLinearGradient(ctx, gradient, card.origin, CGPointMake(CGRectGetMaxX(card), CGRectGetMaxY(card)), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
    CGContextRestoreGState(ctx);
    return card;
}

static void VLTDrawPreviewCaption(CGRect card) {
    [@"PREVIEW" drawAtPoint:CGPointMake(card.origin.x + 16, card.origin.y + 12)
             withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold],
                              NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.6],
                              NSKernAttributeName: @1.2}];
}

// A frosted tile: white wash, optional tint, optional border.
static void VLTDrawPlatter(CGRect rect, CGFloat radius, CGFloat wash, UIColor *tint, CGFloat tintStrength, UIColor *border, CGFloat borderWidth) {
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
    [[UIColor colorWithWhite:1 alpha:wash] setFill];
    [path fill];
    if (tint && tintStrength > 0.001) {
        [[tint colorWithAlphaComponent:tintStrength * CGColorGetAlpha(tint.CGColor)] setFill];
        [path fill];
    }
    if (border && borderWidth > 0.01) {
        UIBezierPath *stroke = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, borderWidth / 2, borderWidth / 2)
                                                          cornerRadius:MAX(0, radius - borderWidth / 2)];
        stroke.lineWidth = borderWidth;
        [border setStroke];
        [stroke stroke];
    }
}

#pragma mark - Control Center preview

@implementation VLTCCPreview

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)setPrefs:(NSDictionary *)prefs {
    _prefs = [prefs copy];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    NSDictionary *p = self.prefs ?: @{};
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect card = VLTDrawPreviewCard(self);
    BOOL on = VLTBool(p, @"enabled", YES) && VLTBool(p, @"ccEnabled", YES);

    // Background tint over the whole "screen"
    UIColor *backTint = on ? VLTColorFromHex(p[@"ccTint"]) : nil;
    if (backTint) {
        CGContextSaveGState(ctx);
        [[UIBezierPath bezierPathWithRoundedRect:card cornerRadius:22] addClip];
        [[backTint colorWithAlphaComponent:VLTNum(p, @"ccTintStrength", 35) / 100.0 * CGColorGetAlpha(backTint.CGColor)] setFill];
        UIRectFillUsingBlendMode(card, kCGBlendModeNormal);
        CGContextRestoreGState(ctx);
    }
    VLTDrawPreviewCaption(card);

    // Modules are drawn at half their real size.
    CGFloat unit = 34, gap = 8, big = unit * 2 + gap;
    CGFloat radius = (on && VLTBool(p, @"ccRadiusOn", NO)) ? VLTNum(p, @"ccRadius", 19) * 0.5 : 9.5;
    CGFloat wash = 0.22 * (on ? VLTNum(p, @"ccPlatter", 100) / 100.0 : 1);
    UIColor *tint = on ? VLTColorFromHex(p[@"ccModTint"]) : nil;
    CGFloat tintStrength = VLTNum(p, @"ccModTintStrength", 30) / 100.0;
    UIColor *border = on ? VLTColorFromHex(p[@"ccBorderColor"]) : nil;
    CGFloat borderWidth = on ? VLTNum(p, @"ccBorderWidth", 0) * 0.75 : 0;
    UIColor *toggleColor = on ? VLTColorFromHex(p[@"ccToggleColor"]) : nil;
    CGFloat roundness = on ? fmin(fmax(VLTNum(p, @"ccToggleShape", 100) / 100.0, 0), 1) : 1;

    CGFloat total = big * 2 + unit * 2 + gap * 3;
    CGFloat x = CGRectGetMidX(card) - total / 2, y = CGRectGetMidY(card) - big / 2 + 9;
    CGRect connectivity = CGRectMake(x, y, big, big);
    CGRect media = CGRectMake(x + big + gap, y, big, big);
    CGRect sliderA = CGRectMake(x + (big + gap) * 2, y, unit, big);
    CGRect sliderB = CGRectMake(CGRectGetMaxX(sliderA) + gap, y, unit, big);
    for (NSValue *value in @[[NSValue valueWithCGRect:connectivity], [NSValue valueWithCGRect:media],
                             [NSValue valueWithCGRect:sliderA], [NSValue valueWithCGRect:sliderB]]) {
        VLTDrawPlatter(value.CGRectValue, radius, wash, tint, tintStrength, border, borderWidth);
    }

    // Round toggles: two on, two off
    CGFloat d = 26, pad = (big - d * 2) / 3;
    NSArray *active = @[toggleColor ?: [UIColor systemBlueColor], toggleColor ?: [UIColor systemGreenColor]];
    for (int i = 0; i < 4; i++) {
        CGRect toggle = CGRectMake(connectivity.origin.x + pad + (i % 2) * (d + pad),
                                   connectivity.origin.y + pad + (i / 2) * (d + pad), d, d);
        [(i == 0 || i == 3) ? active[i == 0 ? 0 : 1] : [UIColor colorWithWhite:1 alpha:0.25] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:toggle cornerRadius:d / 2 * roundness] fill];
    }

    // Media tile: two text bars and a play triangle
    [[UIColor colorWithWhite:1 alpha:0.85] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(media.origin.x + 12, media.origin.y + 14, 40, 6) cornerRadius:3] fill];
    [[UIColor colorWithWhite:1 alpha:0.45] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(media.origin.x + 12, media.origin.y + 25, 28, 5) cornerRadius:2.5] fill];
    UIBezierPath *play = [UIBezierPath bezierPath];
    CGPoint c = CGPointMake(CGRectGetMidX(media), media.origin.y + 54);
    [play moveToPoint:CGPointMake(c.x - 6, c.y - 8)];
    [play addLineToPoint:CGPointMake(c.x + 8, c.y)];
    [play addLineToPoint:CGPointMake(c.x - 6, c.y + 8)];
    [play closePath];
    [[UIColor colorWithWhite:1 alpha:0.9] setFill];
    [play fill];

    // Sliders: filled from the bottom
    CGFloat levels[2] = {0.62, 0.38};
    CGRect sliders[2] = {sliderA, sliderB};
    for (int i = 0; i < 2; i++) {
        CGContextSaveGState(ctx);
        [[UIBezierPath bezierPathWithRoundedRect:sliders[i] cornerRadius:radius] addClip];
        [[UIColor colorWithWhite:1 alpha:0.85] setFill];
        UIRectFillUsingBlendMode(CGRectMake(sliders[i].origin.x, CGRectGetMaxY(sliders[i]) - big * levels[i], unit, big * levels[i]), kCGBlendModeNormal);
        CGContextRestoreGState(ctx);
    }
}

@end

#pragma mark - Dock preview

@implementation VLTDockPreview

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)setPrefs:(NSDictionary *)prefs {
    _prefs = [prefs copy];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    NSDictionary *p = self.prefs ?: @{};
    CGRect card = VLTDrawPreviewCard(self);
    VLTDrawPreviewCaption(card);
    BOOL on = VLTBool(p, @"enabled", YES) && VLTBool(p, @"dockEnabled", YES);

    CGFloat icon = 44, spacing = 16, count = 4, padding = 12;
    CGFloat width = MIN(card.size.width - 32, count * icon + (count - 1) * spacing + padding * 2);
    CGFloat height = icon + padding * 2;
    CGRect dock = CGRectMake(CGRectGetMidX(card) - width / 2, CGRectGetMidY(card) - height / 2 + 9, width, height);

    CGFloat radius = (on && VLTBool(p, @"dockRadiusOn", NO)) ? MIN(VLTNum(p, @"dockRadius", 30), height / 2) : 26;
    CGFloat wash = 0.28 * (on ? VLTNum(p, @"dockOpacity", 100) / 100.0 : 1);
    VLTDrawPlatter(dock, radius, wash,
                   on ? VLTColorFromHex(p[@"dockTint"]) : nil, VLTNum(p, @"dockTintStrength", 40) / 100.0,
                   on ? VLTColorFromHex(p[@"dockBorderColor"]) : nil, on ? VLTNum(p, @"dockBorderWidth", 0) : 0);

    NSArray *colors = @[[UIColor systemGreenColor], [UIColor systemBlueColor], [UIColor systemOrangeColor], [UIColor systemPinkColor]];
    CGFloat step = (width - padding * 2 - icon) / (count - 1);
    for (int i = 0; i < count; i++) {
        CGRect r = CGRectMake(dock.origin.x + padding + i * step, dock.origin.y + padding, icon, icon);
        [(UIColor *)colors[i] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:10.5] fill];
    }
}

@end

#pragma mark - Wallpaper preview

// Faint icon grid and dock, so the scene reads as a Home Screen.
@interface VLTMockHomeView : UIView
@end

@implementation VLTMockHomeView

- (void)drawRect:(CGRect)rect {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat icon = w * 0.155, gapX = (w - icon * 4) / 5;
    [[UIColor colorWithWhite:1 alpha:0.22] setFill];
    for (int row = 0; row < 4; row++) {
        for (int column = 0; column < 4; column++) {
            CGRect r = CGRectMake(gapX + column * (icon + gapX), h * 0.10 + row * (icon + gapX * 1.25), icon, icon);
            [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:icon * 0.24] fill];
        }
    }
    CGRect dock = CGRectMake(gapX * 0.5, h - icon - gapX * 1.6, w - gapX, icon + gapX * 0.9);
    [[UIColor colorWithWhite:1 alpha:0.20] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:dock cornerRadius:dock.size.height * 0.36] fill];
    [[UIColor colorWithWhite:1 alpha:0.30] setFill];
    for (int column = 0; column < 4; column++) {
        CGRect r = CGRectMake(gapX + column * (icon + gapX), dock.origin.y + gapX * 0.45, icon, icon);
        [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:icon * 0.24] fill];
    }
}

@end

// The scene is built at real phone size and scaled down, so particles keep
// the same proportions they have on the actual wallpaper.
static const CGFloat kScreenW = 390, kScreenH = 844, kPreviewScale = 0.33;

@implementation VLTWallpaperPreview {
    UIView *_screen;
    CAGradientLayer *_standIn;     // stands in for "your wallpaper"
    VLTSceneView *_scene;
    VLTMockHomeView *_mock;
    UILabel *_caption;
    NSInteger _kind;
    BOOL _unlocked;                // .tendies preview state; tap to flip
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _screen = [[UIView alloc] init];
        _screen.clipsToBounds = YES;
        _screen.layer.cornerRadius = 22;
        _screen.layer.cornerCurve = kCACornerCurveContinuous;
        _screen.layer.borderWidth = 3;
        _screen.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.35].CGColor;
        [self addSubview:_screen];

        _standIn = [CAGradientLayer layer];
        _standIn.colors = @[(id)HEX(0x3A2D6B).CGColor, (id)HEX(0x1F6F8B).CGColor, (id)HEX(0xE98A5B).CGColor];
        [_screen.layer addSublayer:_standIn];

        _scene = [[VLTSceneView alloc] initWithFrame:CGRectMake(0, 0, kScreenW, kScreenH)];
        [_screen addSubview:_scene];

        _mock = [[VLTMockHomeView alloc] init];
        _mock.backgroundColor = [UIColor clearColor];
        _mock.userInteractionEnabled = NO;
        _mock.contentMode = UIViewContentModeRedraw;
        [_screen addSubview:_mock];

        _caption = [[UILabel alloc] init];
        _caption.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        _caption.textColor = [UIColor secondaryLabelColor];
        _caption.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_caption];

        [_screen addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(screenTapped)]];
    }
    return self;
}

// .tendies wallpapers have a locked and an unlocked look; tap to see both.
- (void)screenTapped {
    if (_kind != VLTSceneTendies) return;
    _unlocked = !_unlocked;
    [self updateStateAndCaption];
}

- (void)updateStateAndCaption {
    if (_kind == VLTSceneTendies) {
        [_scene setWallpaperState:_unlocked ? @"Unlock" : @"Locked"];
        _caption.text = _unlocked ? @"My Tendies · unlocked (tap to lock)" : @"My Tendies · locked (tap to unlock)";
    } else {
        _caption.text = (_kind == VLTSceneNone) ? @"Your current wallpaper" : [VLTSceneView nameForKind:_kind];
    }
    _mock.hidden = (_kind == VLTSceneTendies && !_unlocked);   // no icons on a locked screen
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = CGSizeMake(round(kScreenW * kPreviewScale), round(kScreenH * kPreviewScale));
    _screen.frame = CGRectMake(round((self.bounds.size.width - size.width) / 2), 14, size.width, size.height);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _standIn.frame = _screen.bounds;
    [CATransaction commit];
    _scene.transform = CGAffineTransformIdentity;
    _scene.bounds = CGRectMake(0, 0, kScreenW, kScreenH);
    _scene.center = CGPointMake(size.width / 2, size.height / 2);
    _scene.transform = CGAffineTransformMakeScale(size.width / kScreenW, size.height / kScreenH);
    _mock.frame = _screen.bounds;
    _caption.frame = CGRectMake(0, CGRectGetMaxY(_screen.frame) + 8, self.bounds.size.width, 18);
}

- (void)setPaused:(BOOL)paused {
    _paused = paused;
    _scene.paused = paused;
}

- (void)setPrefs:(NSDictionary *)prefs {
    _prefs = [prefs copy];
    NSDictionary *p = prefs ?: @{};
    NSInteger kind = VLTBool(p, @"enabled", YES) ? (NSInteger)VLTNum(p, @"wallKind", 0) : VLTSceneNone;
    NSString *video = VLTStr(p, @"wallVideoPath");
    NSString *tendies = VLTStr(p, @"wallTendiesPath");
    if (kind == VLTSceneVideo && !video.length) kind = VLTSceneNone;
    if (kind == VLTSceneTendies && !tendies.length) kind = VLTSceneNone;
    _kind = kind;
    [_scene configureWithKind:kind
               keepsWallpaper:VLTBool(p, @"wallKeep", NO)
                        speed:fmin(fmax(VLTNum(p, @"wallSpeed", 100) / 100.0, 0.5), 2)
                          dim:fmin(fmax(VLTNum(p, @"wallDim", 0) / 100.0, 0), 0.8)
                    videoPath:(kind == VLTSceneTendies ? tendies : video)
                   generation:(NSInteger)VLTNum(p, @"wallGen", 0)];
    _scene.volume = 0;   // previews never make sound
    _scene.fitMode = (NSInteger)VLTNum(p, @"wallFit", 0);
    _scene.zoom = fmin(fmax(VLTNum(p, @"wallZoom", 100) / 100.0, 0.5), 2);
    [self updateStateAndCaption];
}

@end

#pragma mark - Lock Screen preview

@implementation VLTLockPreview {
    VLTSlideToUnlock *_slider;
    VLTSwipeUpToUnlock *_swipe;
    NSInteger _style;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
        _swipe = [[VLTSwipeUpToUnlock alloc] initWithFrame:CGRectZero];
        [self addSubview:_swipe];
        _slider = [[VLTSlideToUnlock alloc] initWithFrame:CGRectZero];
        [self addSubview:_slider];
    }
    return self;
}

- (void)setPrefs:(NSDictionary *)prefs {
    _prefs = [prefs copy];
    _slider.text = VLTStr(prefs, @"slideText");
    _slider.knobColor = VLTColorFromHex(prefs[@"slideColor"]);
    CGFloat alpha = (VLTBool(prefs, @"enabled", YES) && VLTBool(prefs, @"slideOn", NO)) ? 1 : 0.45;
    _style = (NSInteger)VLTNum(prefs, @"slideStyle", 0);
    _slider.alpha = alpha;
    _swipe.alpha = alpha;
    _slider.hidden = (_style == 1);
    _swipe.hidden = (_style == 0);
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat inset = MAX(16, self.layoutMargins.left);
    CGRect card = CGRectMake(inset, 12, self.bounds.size.width - inset * 2, self.bounds.size.height - 20);
    CGSize size = [VLTSlideToUnlock preferredSizeForWidth:card.size.width];
    // With both showing, the slider moves up to leave the bottom edge to the swipe area.
    CGFloat sliderY = (_style == 2) ? card.origin.y + 34 : CGRectGetMidY(card) - size.height / 2 + 9;
    _slider.frame = CGRectMake(round(CGRectGetMidX(card) - size.width / 2), round(sliderY), size.width, size.height);
    CGFloat swipeHeight = MIN([VLTSwipeUpToUnlock preferredHeight], card.size.height - 30);
    if (CGAffineTransformIsIdentity(_swipe.transform))
        _swipe.frame = CGRectMake(card.origin.x, CGRectGetMaxY(card) - swipeHeight - 4, card.size.width, swipeHeight);
}

- (void)drawRect:(CGRect)rect {
    CGRect card = VLTDrawPreviewCard(self);
    [@"PREVIEW · TRY IT" drawAtPoint:CGPointMake(card.origin.x + 16, card.origin.y + 12)
                    withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold],
                                     NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.6],
                                     NSKernAttributeName: @1.2}];
}

@end

#pragma mark - Fun header

@implementation VLTFunHeader {
    UIView *_card;
    CAGradientLayer *_gradient;
    CAEmitterLayer *_confetti;
    UILabel *_title;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _card = [[UIView alloc] init];
        _card.clipsToBounds = YES;
        _card.layer.cornerRadius = 22;
        _card.layer.cornerCurve = kCACornerCurveContinuous;
        [self addSubview:_card];
        _gradient = [CAGradientLayer layer];
        _gradient.colors = @[(id)HEX(0x2A0845).CGColor, (id)HEX(0x6441A5).CGColor, (id)HEX(0xB91D73).CGColor];
        _gradient.startPoint = CGPointMake(0, 0);
        _gradient.endPoint = CGPointMake(1, 1);
        [_card.layer addSublayer:_gradient];

        _confetti = [CAEmitterLayer layer];
        _confetti.emitterShape = kCAEmitterLayerLine;
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.opaque = NO;
        UIImage *bit = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(8, 12) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [[UIColor whiteColor] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 8, 12) cornerRadius:2] fill];
        }];
        NSMutableArray *cells = [NSMutableArray array];
        for (int i = 0; i < 6; i++) {
            CAEmitterCell *cell = [CAEmitterCell emitterCell];
            cell.contents = (id)bit.CGImage;
            cell.color = [UIColor colorWithHue:i / 6.0 saturation:0.75 brightness:1 alpha:1].CGColor;
            cell.birthRate = UIAccessibilityIsReduceMotionEnabled() ? 0 : 2.2;
            cell.lifetime = 5;
            cell.velocity = 55;
            cell.velocityRange = 30;
            cell.emissionLongitude = M_PI_2;
            cell.emissionRange = M_PI / 6;
            cell.yAcceleration = 18;
            cell.spin = 2;
            cell.spinRange = 4;
            cell.scale = 0.7;
            cell.scaleRange = 0.35;
            [cells addObject:cell];
        }
        _confetti.emitterCells = cells;
        [_card.layer addSublayer:_confetti];

        _title = [[UILabel alloc] init];
        _title.text = @"Just for fun";
        _title.font = VLTRounded(30, UIFontWeightBold);
        _title.textColor = [UIColor whiteColor];
        _title.textAlignment = NSTextAlignmentCenter;
        _title.layer.shadowColor = [UIColor blackColor].CGColor;
        _title.layer.shadowOpacity = 0.35;
        _title.layer.shadowRadius = 6;
        _title.layer.shadowOffset = CGSizeZero;
        [_card addSubview:_title];
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
    _confetti.frame = _card.bounds;
    _confetti.emitterPosition = CGPointMake(CGRectGetMidX(_card.bounds), -8);
    _confetti.emitterSize = CGSizeMake(_card.bounds.size.width, 1);
    [CATransaction commit];
    _title.frame = _card.bounds;
}

@end

#pragma mark - Video cell

@implementation VLTVideoCell

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    NSString *key = [specifier propertyForKey:@"pathKey"] ?: @"wallVideoPath";
    NSString *path = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(VLT_DOMAIN)));
    BOOL has = [path isKindOfClass:[NSString class]] && [[NSFileManager defaultManager] fileExistsAtPath:path];
    UILabel *label = [[UILabel alloc] init];
    label.text = has ? @"Selected" : @"None";
    label.textColor = [UIColor secondaryLabelColor];
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [label sizeToFit];
    self.accessoryView = label;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.textColor = [UIColor labelColor];
    self.textLabel.textAlignment = NSTextAlignmentNatural;
}

@end
