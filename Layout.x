//
//  Volta - Layout.x  (SpringBoard only, part of VoltaHome)
//
//  1. Control Center layout: order, size and visibility of every module, plus
//     the grid's tile size and spacing. Read once when SpringBoard starts, so
//     layout changes need a respring - Control Center builds its grid early
//     and rebuilding it live is not worth the risk.
//  2. Custom controls: a row of your own buttons and a label under the modules.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "VLTShared.h"
#import "VLTActions.h"

typedef struct { unsigned long long width, height; } CCUILayoutSize;

static inline CGFloat VLTLClamp(CGFloat x, CGFloat lo, CGFloat hi) { return fmin(fmax(x, lo), hi); }

static UIView *VLTLViewForKey(id object, NSString *key) {
    id value = nil;
    @try { value = [object valueForKey:key]; } @catch (__unused NSException *e) {}
    return [value isKindOfClass:[UIView class]] ? value : nil;
}

#pragma mark - Layout settings (frozen at launch)

static BOOL          gLayoutOn;
static NSArray      *gOrder;        // module identifiers, in the user's order
static NSSet        *gHidden;
static NSDictionary *gSizes;        // identifier -> @"WxH"
static CGFloat       gItemScale = 1;
static BOOL          gSpacingOn;
static CGFloat       gSpacing;

static void VLTLoadLayoutPrefs(NSDictionary *p) {
    gLayoutOn = VLTBool(p, @"enabled", YES) && VLTBool(p, @"ccLayoutOn", NO);
    NSArray *order = p[@"ccOrder"];
    NSArray *hidden = p[@"ccHidden"];
    NSDictionary *sizes = p[@"ccSizes"];
    gOrder  = [order isKindOfClass:[NSArray class]] ? [order copy] : @[];
    gHidden = [hidden isKindOfClass:[NSArray class]] ? [NSSet setWithArray:hidden] : [NSSet set];
    gSizes  = [sizes isKindOfClass:[NSDictionary class]] ? [sizes copy] : @{};
    gItemScale = VLTLClamp(VLTNum(p, @"ccItemScale", 100) / 100.0, 0.6, 1.3);
    gSpacingOn = VLTBool(p, @"ccSpacingOn", NO);
    gSpacing   = VLTLClamp(VLTNum(p, @"ccSpacing", 14), 0, 30);
}

// @"2x1" -> {2, 1}. Returns NO for anything that is not a sane size.
static BOOL VLTParseSize(id value, CCUILayoutSize *out) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSArray *parts = [(NSString *)value componentsSeparatedByString:@"x"];
    if (parts.count != 2) return NO;
    NSInteger w = [parts[0] integerValue], h = [parts[1] integerValue];
    if (w < 1 || w > 4 || h < 1 || h > 4) return NO;
    out->width = (unsigned long long)w;
    out->height = (unsigned long long)h;
    return YES;
}

#pragma mark - Telling the Settings pane which modules exist

static NSMutableArray *gSeenOrder;                 // system order, before our changes
static NSMutableDictionary *gDefaultSizes;         // identifier -> @"WxH"
static dispatch_queue_t VLTInfoQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.notpreston.volta.moduleinfo", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSString *VLTPrettyName(NSString *raw) {
    NSString *name = [raw componentsSeparatedByString:@"."].lastObject ?: raw;
    for (NSString *suffix in @[@"Module", @"ControlCenter", @"UI"]) {
        if (name.length > suffix.length && [name hasSuffix:suffix]) name = [name substringToIndex:name.length - suffix.length];
    }
    // "OrientationLock" -> "Orientation Lock"
    NSMutableString *spaced = [NSMutableString string];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        BOOL upper = [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:c];
        BOOL previousLower = i > 0 && [[NSCharacterSet lowercaseLetterCharacterSet] characterIsMember:[name characterAtIndex:i - 1]];
        if (upper && previousLower) [spaced appendString:@" "];
        [spaced appendFormat:@"%C", c];
    }
    if (spaced.length) [spaced replaceCharactersInRange:NSMakeRange(0, 1) withString:[[spaced substringToIndex:1] uppercaseString]];
    return spaced.length ? spaced : raw;
}

static NSString *VLTModuleName(NSString *identifier) {
    static NSDictionary *known;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        known = @{
            @"com.apple.control-center.ConnectivityModule": @"Connectivity (Wi-Fi, Bluetooth…)",
            @"com.apple.mediaremote.controlcenter.nowplaying": @"Now Playing",
            @"com.apple.control-center.DisplayModule": @"Brightness",
            @"com.apple.mediaremote.controlcenter.audio": @"Volume",
            @"com.apple.control-center.OrientationLockModule": @"Orientation Lock",
            @"com.apple.control-center.MuteModule": @"Silent Mode",
            @"com.apple.FocusUIModule": @"Focus",
            @"com.apple.donotdisturb.DoNotDisturbModule": @"Do Not Disturb",
            @"com.apple.mediaremote.controlcenter.airplaymirroring": @"Screen Mirroring",
            @"com.apple.replaykit.controlcenter.screencapture": @"Screen Recording",
            @"com.apple.Home.ControlCenter": @"Home",
            @"com.apple.control-center.AppearanceModule": @"Dark Mode",
            @"com.apple.control-center.LowPowerModule": @"Low Power Mode",
            @"com.apple.accessibility.controlcenter.text.size": @"Text Size",
        };
    });
    if (known[identifier]) return known[identifier];

    // Ask the module's own bundle for its name.
    @try {
        Class managerClass = NSClassFromString(@"CCUIModuleInstanceManager");
        SEL shared = NSSelectorFromString(@"sharedInstance");
        id manager = [managerClass respondsToSelector:shared] ? ((id (*)(id, SEL))objc_msgSend)(managerClass, shared) : nil;
        for (id instance in [manager valueForKey:@"moduleInstances"]) {
            id metadata = [instance valueForKey:@"metadata"];
            if (![[metadata valueForKey:@"moduleIdentifier"] isEqual:identifier]) continue;
            NSBundle *bundle = [NSBundle bundleWithURL:[metadata valueForKey:@"moduleBundleURL"]];
            NSString *display = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
            if ([display isKindOfClass:[NSString class]] && display.length) return display;
            NSString *plain = [bundle objectForInfoDictionaryKey:@"CFBundleName"];
            if ([plain isKindOfClass:[NSString class]] && plain.length) return VLTPrettyName(plain);
        }
    } @catch (__unused NSException *e) {}
    return VLTPrettyName(identifier);
}

// Writes the list the module editor shows: [{id, name, size}], in system order.
static void VLTPublishModuleInfo(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        __block NSArray *order;
        __block NSDictionary *sizes;
        dispatch_sync(VLTInfoQueue(), ^{
            order = [gSeenOrder copy];
            sizes = [gDefaultSizes copy];
        });
        if (!order.count) return;
        NSMutableArray *info = [NSMutableArray array];
        for (NSString *identifier in order) {
            [info addObject:@{@"id": identifier, @"name": VLTModuleName(identifier), @"size": sizes[identifier] ?: @""}];
        }
        CFStringRef domain = CFSTR(VLT_DOMAIN);
        NSArray *existing = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("ccModuleInfo"), domain));
        if ([existing isEqual:info]) return;
        CFPreferencesSetAppValue(CFSTR("ccModuleInfo"), (__bridge CFPropertyListRef)info, domain);
        CFPreferencesAppSynchronize(domain);
    });
}

#pragma mark - Layout hooks

%group Layout

%hook CCUIModuleSettingsManager

// The order Control Center lays modules out in.
- (id)orderedEnabledModuleIdentifiers {
    NSArray *original = %orig;
    if (![original isKindOfClass:[NSArray class]]) return original;

    dispatch_sync(VLTInfoQueue(), ^{
        if (!gSeenOrder) gSeenOrder = [NSMutableArray array];
        if (![gSeenOrder isEqualToArray:original]) [gSeenOrder setArray:original];
    });
    if (!gLayoutOn) return original;

    // Keep only what the system offered, minus hidden modules, in the user's
    // order. Modules the user has not placed keep their system position at the end.
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *identifier in gOrder) {
        if ([original containsObject:identifier] && ![gHidden containsObject:identifier] && ![result containsObject:identifier])
            [result addObject:identifier];
    }
    for (NSString *identifier in original) {
        if (![gHidden containsObject:identifier] && ![result containsObject:identifier]) [result addObject:identifier];
    }
    return result.count ? result : original;   // never hand back an empty Control Center
}

// How many grid cells a module takes.
- (id)moduleSettingsForModuleIdentifier:(id)identifier prototypeSize:(CCUILayoutSize)prototype {
    id original = %orig;
    SEL sizeSel = NSSelectorFromString(@"layoutSizeForInterfaceOrientation:");
    if ([identifier isKindOfClass:[NSString class]] && [original respondsToSelector:sizeSel]) {
        CCUILayoutSize size = ((CCUILayoutSize (*)(id, SEL, long long))objc_msgSend)(original, sizeSel, 1);
        NSString *text = [NSString stringWithFormat:@"%llux%llu", size.width, size.height];
        dispatch_sync(VLTInfoQueue(), ^{
            if (!gDefaultSizes) gDefaultSizes = [NSMutableDictionary dictionary];
            gDefaultSizes[identifier] = text;
        });
    }
    if (!gLayoutOn) return original;

    CCUILayoutSize custom;
    if (!VLTParseSize(gSizes[identifier], &custom)) return original;
    Class settingsClass = [original class] ?: NSClassFromString(@"CCUIModuleSettings");
    SEL initSel = NSSelectorFromString(@"initWithPortraitLayoutSize:landscapeLayoutSize:");
    if (![settingsClass instancesRespondToSelector:initSel]) return original;
    id replacement = ((id (*)(id, SEL, CCUILayoutSize, CCUILayoutSize))objc_msgSend)([settingsClass alloc], initSel, custom, custom);
    return replacement ?: original;
}

%end

// Tile size and the gap between tiles, for the whole grid.
%hook CCUILayoutOptions

- (double)itemEdgeSize {
    double value = %orig;
    return gLayoutOn ? value * gItemScale : value;
}

- (double)itemSpacing {
    double value = %orig;
    return (gLayoutOn && gSpacingOn) ? gSpacing : value;
}

%end

%end // group Layout

#pragma mark - Custom controls settings (live)

static BOOL      gCustomOn;
static NSString *gCustomLabel;
static NSArray  *gButtons;
static CGFloat   gTileRadius = 19;
static UIColor  *gTileTint;
static CGFloat   gTileTintStrength;
static UIColor  *gTileBorder;
static CGFloat   gTileBorderWidth;
static CGFloat   gTileOpacity = 1;

static void VLTLoadCustomPrefs(NSDictionary *p) {
    BOOL on = VLTBool(p, @"enabled", YES);
    gCustomOn = on && VLTBool(p, @"ccCustomOn", NO);
    gCustomLabel = [VLTStr(p, @"ccCustomLabel") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *buttons = p[@"ccCustomButtons"];
    NSMutableArray *valid = [NSMutableArray array];
    if ([buttons isKindOfClass:[NSArray class]]) {
        for (id button in buttons) {
            if ([button isKindOfClass:[NSDictionary class]] && valid.count < VLT_MAX_BUTTONS) [valid addObject:button];
        }
    }
    gButtons = valid;

    // Match the module styling chosen on the main Control Center page.
    BOOL styled = on && VLTBool(p, @"ccEnabled", YES);
    gTileRadius       = (styled && VLTBool(p, @"ccRadiusOn", NO)) ? VLTLClamp(VLTNum(p, @"ccRadius", 19), 0, 40) : 19;
    gTileTint         = styled ? VLTColorFromHex(p[@"ccModTint"]) : nil;
    gTileTintStrength = VLTLClamp(VLTNum(p, @"ccModTintStrength", 30) / 100.0, 0, 1);
    gTileBorder       = styled ? VLTColorFromHex(p[@"ccBorderColor"]) : nil;
    gTileBorderWidth  = styled ? VLTLClamp(VLTNum(p, @"ccBorderWidth", 0), 0, 4) : 0;
    gTileOpacity      = styled ? VLTLClamp(VLTNum(p, @"ccPlatter", 100) / 100.0, 0, 1) : 1;
}

#pragma mark - Actions

static __weak UIViewController *gOverlay;   // the Control Center screen

static id VLTSharedObject(NSString *className, NSString *selector) {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(selector);
    if (![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
}

static void VLTOpenURL(NSURL *url) {
    if (!url) return;
    id workspace = VLTSharedObject(@"LSApplicationWorkspace", @"defaultWorkspace");
    SEL sensitive = NSSelectorFromString(@"openSensitiveURL:withOptions:");
    if ([workspace respondsToSelector:sensitive]) {
        ((BOOL (*)(id, SEL, id, id))objc_msgSend)(workspace, sensitive, url, nil);
        return;
    }
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

static id VLTBatterySaver(void) {
    if (!NSClassFromString(@"_CDBatterySaver")) dlopen("/System/Library/PrivateFrameworks/CoreDuet.framework/CoreDuet", RTLD_LAZY);
    return VLTSharedObject(@"_CDBatterySaver", @"batterySaver");
}

static id VLTStyleMode(void) {
    Class cls = NSClassFromString(@"UISUserInterfaceStyleMode");
    return cls ? [[cls alloc] init] : nil;
}

// For toggle-type buttons: is the thing currently on?
static BOOL VLTActionIsOn(NSInteger action) {
    @try {
        switch (action) {
            case VLTActionDarkMode: {
                id mode = VLTStyleMode();
                return mode ? [[mode valueForKey:@"modeValue"] integerValue] == 2 : NO;
            }
            case VLTActionLowPower: {
                id saver = VLTBatterySaver();
                SEL get = NSSelectorFromString(@"getPowerMode");
                return [saver respondsToSelector:get] ? ((long long (*)(id, SEL))objc_msgSend)(saver, get) == 1 : NO;
            }
            case VLTActionRotation: {
                id manager = VLTSharedObject(@"SBOrientationLockManager", @"sharedInstance");
                SEL locked = NSSelectorFromString(@"isUserLocked");
                return [manager respondsToSelector:locked] ? ((BOOL (*)(id, SEL))objc_msgSend)(manager, locked) : NO;
            }
            default: return NO;
        }
    } @catch (__unused NSException *e) { return NO; }
}

static void VLTRunAction(NSInteger action, NSString *target) {
    @try {
        switch (action) {
            case VLTActionOpenApp: {
                id workspace = VLTSharedObject(@"LSApplicationWorkspace", @"defaultWorkspace");
                SEL open = NSSelectorFromString(@"openApplicationWithBundleID:");
                if (target.length && [workspace respondsToSelector:open])
                    ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, open, target);
                break;
            }
            case VLTActionOpenURL: {
                NSString *text = target;
                if (text.length && ![text containsString:@":"]) text = [@"https://" stringByAppendingString:text];
                VLTOpenURL([NSURL URLWithString:text]);
                break;
            }
            case VLTActionShortcut: {
                NSString *name = [target stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
                if (name.length) VLTOpenURL([NSURL URLWithString:[@"shortcuts://run-shortcut?name=" stringByAppendingString:name]]);
                break;
            }
            case VLTActionVoltaPrefs:
                VLTOpenURL([NSURL URLWithString:@"prefs:root=Volta"]);
                break;
            case VLTActionRespring:
                notify_post(VLT_NOTIFY_RESPRING);   // handled in Tweak.x
                break;
            case VLTActionLock: {
                UIApplication *springBoard = [UIApplication sharedApplication];
                SEL lock = NSSelectorFromString(@"_simulateLockButtonPress");
                if ([springBoard respondsToSelector:lock]) ((void (*)(id, SEL))objc_msgSend)(springBoard, lock);
                break;
            }
            case VLTActionDarkMode: {
                id mode = VLTStyleMode();
                BOOL dark = [[mode valueForKey:@"modeValue"] integerValue] == 2;
                [mode setValue:@(dark ? 1 : 2) forKey:@"modeValue"];
                break;
            }
            case VLTActionLowPower: {
                id saver = VLTBatterySaver();
                SEL set = NSSelectorFromString(@"setPowerMode:error:");
                if ([saver respondsToSelector:set])
                    ((BOOL (*)(id, SEL, long long, id *))objc_msgSend)(saver, set, VLTActionIsOn(VLTActionLowPower) ? 0 : 1, NULL);
                break;
            }
            case VLTActionRotation: {
                id manager = VLTSharedObject(@"SBOrientationLockManager", @"sharedInstance");
                SEL toggle = NSSelectorFromString(VLTActionIsOn(VLTActionRotation) ? @"unlock" : @"lock");
                if ([manager respondsToSelector:toggle]) ((void (*)(id, SEL))objc_msgSend)(manager, toggle);
                break;
            }
            default: break;
        }
    } @catch (NSException *e) {
        NSLog(@"[Volta] custom button action %ld failed: %@", (long)action, e);
    }
}

static BOOL VLTActionLeavesControlCenter(NSInteger action) {
    return action == VLTActionOpenApp || action == VLTActionOpenURL || action == VLTActionShortcut ||
           action == VLTActionVoltaPrefs || action == VLTActionLock;
}

#pragma mark - Custom bar

@interface VLTCustomTile : UIControl
@property (nonatomic) NSInteger action;
@property (nonatomic, copy) NSString *target;
- (void)refreshState;
@end

@implementation VLTCustomTile {
    UIVisualEffectView *_blur;
    UIView *_tint;
    UIImageView *_glyph;
    UILabel *_title;
}

- (instancetype)initWithButton:(NSDictionary *)button {
    if ((self = [super initWithFrame:CGRectZero])) {
        _action = [button[@"a"] respondsToSelector:@selector(integerValue)] ? [button[@"a"] integerValue] : 0;
        _target = [button[@"v"] isKindOfClass:[NSString class]] ? button[@"v"] : nil;
        NSString *title = [button[@"t"] isKindOfClass:[NSString class]] ? button[@"t"] : @"";
        NSString *symbol = [button[@"s"] isKindOfClass:[NSString class]] ? button[@"s"] : nil;

        self.clipsToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = title.length ? title : VLTActionName(_action);
        self.accessibilityTraits = UIAccessibilityTraitButton;

        _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialLight]];
        _blur.userInteractionEnabled = NO;
        [self addSubview:_blur];
        _tint = [[UIView alloc] init];
        _tint.userInteractionEnabled = NO;
        [self addSubview:_tint];

        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightMedium];
        UIImage *image = [UIImage systemImageNamed:(symbol.length ? symbol : VLTActionDefaultSymbol(_action)) withConfiguration:config]
                      ?: [UIImage systemImageNamed:VLTActionDefaultSymbol(_action) withConfiguration:config];
        _glyph = [[UIImageView alloc] initWithImage:image];
        _glyph.contentMode = UIViewContentModeCenter;
        [self addSubview:_glyph];

        _title = [[UILabel alloc] init];
        _title.text = title;
        _title.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        _title.textAlignment = NSTextAlignmentCenter;
        _title.adjustsFontSizeToFitWidth = YES;
        _title.minimumScaleFactor = 0.75;
        [self addSubview:_title];

        [self refreshState];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    self.layer.cornerRadius = MIN(gTileRadius, MIN(w, h) / 2);
    self.layer.borderWidth = gTileBorder ? gTileBorderWidth : 0;
    self.layer.borderColor = gTileBorder.CGColor;
    _blur.frame = self.bounds;
    _tint.frame = self.bounds;
    BOOL hasTitle = _title.text.length > 0;
    _glyph.frame = hasTitle ? CGRectMake(0, h * 0.14, w, h * 0.52) : self.bounds;
    _title.frame = CGRectMake(4, h * 0.68, w - 8, h * 0.22);
    _title.hidden = !hasTitle;
}

// Toggle buttons light up like the system ones: white tile, dark glyph.
- (void)refreshState {
    BOOL on = VLTActionIsOn(_action);
    _blur.alpha = on ? 0 : gTileOpacity;
    if (on) {
        _tint.backgroundColor = [UIColor whiteColor];
    } else if (gTileTint && gTileTintStrength > 0.001) {
        _tint.backgroundColor = [gTileTint colorWithAlphaComponent:gTileTintStrength * CGColorGetAlpha(gTileTint.CGColor)];
    } else {
        _tint.backgroundColor = [UIColor clearColor];
    }
    UIColor *foreground = on ? [UIColor colorWithWhite:0.1 alpha:1] : [UIColor whiteColor];
    _glyph.tintColor = foreground;
    _title.textColor = [foreground colorWithAlphaComponent:0.85];
    self.accessibilityValue = (_action == VLTActionDarkMode || _action == VLTActionLowPower || _action == VLTActionRotation) ? (on ? @"On" : @"Off") : nil;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:highlighted ? 0.05 : 0.25 animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.93, 0.93) : CGAffineTransformIdentity;
        self.alpha = highlighted ? 0.75 : 1;
    }];
}

@end

@interface VLTCustomBar : UIView
- (void)rebuild;
- (CGFloat)heightForWidth:(CGFloat)width;
- (void)refreshStates;
@end

static const CGFloat kBarColumns = 4, kBarGap = 14, kBarLabelHeight = 24;

@implementation VLTCustomBar {
    UILabel *_label;
    NSMutableArray<VLTCustomTile *> *_tiles;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _tiles = [NSMutableArray array];
        _label = [[UILabel alloc] init];
        _label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _label.textColor = [UIColor colorWithWhite:1 alpha:0.9];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.7;
        [self addSubview:_label];
        [UIDevice currentDevice].batteryMonitoringEnabled = YES;
        [self rebuild];
    }
    return self;
}

// {date}, {time} and {battery} are filled in each time Control Center opens.
- (NSString *)resolvedLabel {
    NSString *text = gCustomLabel ?: @"";
    if (![text containsString:@"{"]) return text;
    NSDate *now = [NSDate date];
    NSString *date = [NSDateFormatter localizedStringFromDate:now dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterNoStyle];
    NSString *time = [NSDateFormatter localizedStringFromDate:now dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle];
    float level = [UIDevice currentDevice].batteryLevel;
    NSString *battery = level >= 0 ? [NSString stringWithFormat:@"%d%%", (int)lroundf(level * 100)] : @"";
    text = [text stringByReplacingOccurrencesOfString:@"{date}" withString:date];
    text = [text stringByReplacingOccurrencesOfString:@"{time}" withString:time];
    text = [text stringByReplacingOccurrencesOfString:@"{battery}" withString:battery];
    return text;
}

- (void)rebuild {
    for (VLTCustomTile *tile in _tiles) [tile removeFromSuperview];
    [_tiles removeAllObjects];
    for (NSDictionary *button in gButtons) {
        VLTCustomTile *tile = [[VLTCustomTile alloc] initWithButton:button];
        [tile addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:tile];
        [_tiles addObject:tile];
    }
    _label.text = [self resolvedLabel];
    [self setNeedsLayout];
}

- (void)refreshStates {
    _label.text = [self resolvedLabel];
    for (VLTCustomTile *tile in _tiles) [tile refreshState];
}

- (CGFloat)tileSizeForWidth:(CGFloat)width {
    return floor((width - kBarGap * (kBarColumns - 1)) / kBarColumns);
}

- (CGFloat)heightForWidth:(CGFloat)width {
    CGFloat height = 0;
    if (_label.text.length) height += kBarLabelHeight + (_tiles.count ? 8 : 0);
    NSInteger rows = (NSInteger)ceil(_tiles.count / kBarColumns);
    if (rows > 0) height += rows * [self tileSizeForWidth:width] + (rows - 1) * kBarGap;
    return height;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width, y = 0;
    _label.hidden = _label.text.length == 0;
    if (!_label.hidden) {
        _label.frame = CGRectMake(0, 0, width, kBarLabelHeight);
        y = kBarLabelHeight + 8;
    }
    CGFloat size = [self tileSizeForWidth:width];
    for (NSInteger i = 0; i < (NSInteger)_tiles.count; i++) {
        if (!CGAffineTransformIsIdentity(_tiles[i].transform)) continue;   // mid-press
        NSInteger row = i / (NSInteger)kBarColumns, column = i % (NSInteger)kBarColumns;
        _tiles[i].frame = CGRectMake(column * (size + kBarGap), y + row * (size + kBarGap), size, size);
    }
}

- (void)tileTapped:(VLTCustomTile *)tile {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    NSInteger action = tile.action;
    NSString *target = tile.target;
    UIViewController *overlay = gOverlay;
    SEL dismiss = NSSelectorFromString(@"dismissAnimated:withCompletionHandler:");
    if (VLTActionLeavesControlCenter(action) && [overlay respondsToSelector:dismiss]) {
        // Close Control Center first, then act.
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(overlay, dismiss, YES, nil);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            VLTRunAction(action, target);
        });
        return;
    }
    VLTRunAction(action, target);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshStates];
    });
}

@end

static const void *kBarKey        = &kBarKey;
static const void *kBarBackground = &kBarBackground;
static BOOL gBarDirty;   // settings changed since the bar was last built
// Weak on purpose: the bar can be removed at any time, and the backdrop hook
// below must then see nil rather than a stale pointer.
static __weak UIView *gBar;

// Adds, updates or removes the custom bar under the module grid.
static void VLTApplyCustomBar(UIViewController *overlay) {
    gOverlay = overlay;
    UIScrollView *scroll = (UIScrollView *)VLTLViewForKey(overlay, @"overlayScrollView");
    UIView *collection = VLTLViewForKey(overlay, @"overlayModuleCollectionView");
    UIView *host = [scroll isKindOfClass:[UIScrollView class]] ? scroll : overlay.view;
    VLTCustomBar *bar = objc_getAssociatedObject(overlay, kBarKey);

    BOOL wanted = gCustomOn && collection && (gButtons.count > 0 || gCustomLabel.length > 0);
    if (!wanted) {
        if (bar) {
            [bar removeFromSuperview];
            objc_setAssociatedObject(overlay, kBarKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (!bar) {
        bar = [[VLTCustomBar alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(overlay, kBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gBarDirty = NO;
    } else if (gBarDirty) {
        [bar rebuild];
        gBarDirty = NO;
    }
    if (bar.superview != host) [host addSubview:bar];

    CGRect grid = [host convertRect:collection.bounds fromView:collection];
    if (grid.size.width < 40) return;
    CGFloat height = [bar heightForWidth:grid.size.width];
    CGRect frame = CGRectMake(grid.origin.x, CGRectGetMaxY(grid) + 18, grid.size.width, height);
    if (!CGRectEqualToRect(bar.frame, frame)) bar.frame = frame;

    // Make sure it can be scrolled to on small screens.
    if ([host isKindOfClass:[UIScrollView class]]) {
        CGFloat needed = CGRectGetMaxY(frame) + 24;
        if (scroll.contentSize.height < needed) scroll.contentSize = CGSizeMake(scroll.contentSize.width, needed);
    }

    // Fade with Control Center's own backdrop (see the MTMaterialView hook).
    UIView *background = VLTLViewForKey(overlay, @"overlayBackgroundView");
    gBar = bar;
    if (background) objc_setAssociatedObject(background, kBarBackground, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%group CustomControls

%hook CCUIModularControlCenterOverlayViewController

- (void)viewDidLayoutSubviews {
    %orig;
    VLTApplyCustomBar((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    VLTApplyCustomBar((UIViewController *)self);
    [(VLTCustomBar *)objc_getAssociatedObject(self, kBarKey) refreshStates];
    VLTPublishModuleInfo();
}

- (void)presentAnimated:(BOOL)animated withCompletionHandler:(id)completion {
    VLTApplyCustomBar((UIViewController *)self);
    [(VLTCustomBar *)objc_getAssociatedObject(self, kBarKey) refreshStates];
    %orig;
}

%end

%hook MTMaterialView

- (void)setWeighting:(CGFloat)weighting {
    %orig;
    if (objc_getAssociatedObject(self, kBarBackground)) {
        UIView *bar = gBar;
        if (bar) bar.alpha = VLTLClamp(weighting * 1.25, 0, 1);
    }
}

%end

%end // group CustomControls

#pragma mark - Setup

static void VLTLayoutPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VLTLoadCustomPrefs(VLTCopyPrefs());   // layout settings stay frozen until the next respring
        gBarDirty = YES;
        UIViewController *overlay = gOverlay;
        if (overlay.isViewLoaded) VLTApplyCustomBar(overlay);
    });
}

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        NSDictionary *prefs = VLTCopyPrefs();
        VLTLoadLayoutPrefs(prefs);
        VLTLoadCustomPrefs(prefs);

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, VLTLayoutPrefsChanged,
                                        CFSTR(VLT_NOTIFY_PREFS), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        %init(Layout);
        %init(CustomControls);

        // Give Control Center time to load its modules, then tell Settings about them.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            VLTPublishModuleInfo();
        });
    }
}
