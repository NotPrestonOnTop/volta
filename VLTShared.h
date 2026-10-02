//
//  VLTShared.h
//  Shared between the tweak and the Settings pane.
//
//  How settings travel:
//    Settings pane --(CFPreferences + "prefs" notification)--> SpringBoard
//    SpringBoard   --(Darwin notify state + "apply" notification)--> every app
//
//  Sandboxed apps cannot read another domain's preferences, but they can read
//  Darwin notification state. So SpringBoard packs the battery settings into a
//  48-byte struct and publishes it as six 64-bit notify states.
//

#import <UIKit/UIKit.h>
#import <notify.h>

#define VLT_DOMAIN          "com.notpreston.volta"
#define VLT_NOTIFY_PREFS    VLT_DOMAIN "/prefs"     // Settings -> SpringBoard: prefs changed
#define VLT_NOTIFY_APPLY    VLT_DOMAIN "/apply"     // SpringBoard -> everyone: state republished
#define VLT_NOTIFY_RESPRING VLT_DOMAIN "/respring"  // Settings -> SpringBoard
#define VLT_VERSION         "2.0.0"   // keep in step with the "control" file
#define VLT_STATE_VERSION   3

// Custom battery picture. SpringBoard writes it here so that apps, which can
// read inside the jailbreak root but not in /var/mobile, can load it.
#define VLT_IMAGE_DIR         @"/var/jb/Library/Application Support/Volta"
#define VLT_IMAGE_PATH        VLT_IMAGE_DIR @"/battery.png"
#define VLT_IMAGE_NONE        0      // 1 ... VLT_THEME_COUNT are built-in themes
#define VLT_IMAGE_CUSTOM      100
#define VLT_IMAGE_ANIMATED    101    // the user's own frames, from the animation creator
#define VLT_MAX_FRAMES        24
#define VLT_FRAMES_DIR        VLT_IMAGE_DIR @"/frames"
// Status bar settings for apps (text does not fit in the notify state).
#define VLT_STATUS_PATH       VLT_IMAGE_DIR @"/status.plist"
// The icon pack: one PNG per app, named <bundle id>.png
#define VLT_ICONS_DIR         VLT_IMAGE_DIR @"/Icons"
#define VLT_ICONS_DIR_ALT     @"/var/mobile/Library/Volta/Icons"   // used when the first is not writable

// Motion added to a still battery picture (a theme or My Picture).
enum {
    VLTEffectNone = 0, VLTEffectPulse, VLTEffectBounce, VLTEffectWobble, VLTEffectSpin, VLTEffectBlink, VLTEffectShake,
    VLTEffectCount
};
#define VLT_EFFECT_FPS 12.0
#define VLT_IMAGE_HEIGHT      16.0   // points, before the size setting
#define VLT_IMAGE_MAX_ASPECT  1.75   // widest picture allowed, as width / height

// flags1
enum {
    VLTOn          = 1 << 0,
    VLTFake        = 1 << 1,
    VLTHidePercent = 1 << 2,
    VLTHideSymbol  = 1 << 3,
    VLTHideIcon    = 1 << 4,
    VLTHidePin     = 1 << 5,
    VLTColors      = 1 << 6,
    VLTLevelColor  = 1 << 7,
};
// flags2
enum {
    VLTKeepStatus = 1 << 0,
    VLTHasFill    = 1 << 1,
    VLTHasBody    = 1 << 2,
    VLTHasPin     = 1 << 3,
    VLTHasBolt    = 1 << 4,
    VLTHasText    = 1 << 5,
    VLTImageFill  = 1 << 6,   // picture fills up with the charge level
};
// reserved[0]: status bar fun, shown in every app
enum {
    VLTStatusWiggle = 1 << 0,
    VLTStatusFlip   = 1 << 1,
    VLTStatusBounce = 1 << 2,
    VLTStatusPulse  = 1 << 3,
};

typedef struct {
    uint8_t  version;      // 0 = nothing published yet
    uint8_t  flags1;
    uint8_t  flags2;
    uint8_t  fakePercent;  // 0 - 100
    uint8_t  scale;        // 50 - 150 (percent)
    uint8_t  chargeMode;   // 0 system, 1 always, 2 never
    uint8_t  saverMode;    // 0 system, 1 always, 2 never
    uint8_t  inIconMode;   // 0 system, 1 always, 2 never
    uint32_t fill, body, pin, bolt, text;   // 0xRRGGBBAA
    uint8_t  imageKind;    // VLT_IMAGE_NONE, a theme number, or VLT_IMAGE_CUSTOM
    uint8_t  imageGen;     // bumped whenever the custom picture or frames change
    uint8_t  animEffect;   // VLTEffect..., for still pictures
    uint8_t  animFrames;   // how many user frames exist (VLT_IMAGE_ANIMATED)
    char     label[16];    // UTF-8, NUL terminated
    uint8_t  animFps;      // playback speed of the user's frames
    uint8_t  reserved[7];
} VLTState;

#define VLT_STATE_WORDS 7
_Static_assert(sizeof(VLTState) == VLT_STATE_WORDS * sizeof(uint64_t), "VLTState must be 56 bytes");

#pragma mark - Preferences

static inline NSDictionary *VLTCopyPrefs(void) {
    CFStringRef app = CFSTR(VLT_DOMAIN);
    CFPreferencesAppSynchronize(app);
    CFArrayRef keys = CFPreferencesCopyKeyList(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!keys) return @{};
    NSDictionary *d = CFBridgingRelease(CFPreferencesCopyMultiple(keys, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    CFRelease(keys);
    return d ?: @{};
}

static inline BOOL VLTBool(NSDictionary *d, NSString *key, BOOL fallback) {
    id v = d[key];
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : fallback;
}

static inline double VLTNum(NSDictionary *d, NSString *key, double fallback) {
    id v = d[key];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : fallback;
}

static inline NSString *VLTStr(NSDictionary *d, NSString *key) {
    id v = d[key];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

#pragma mark - Colors ("#RRGGBBAA")

static inline BOOL VLTParseHex(NSString *hex, uint32_t *out) {
    if (![hex isKindOfClass:[NSString class]]) return NO;
    NSString *s = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
    if (s.length != 6 && s.length != 8) return NO;
    unsigned int v = 0;
    NSScanner *scanner = [NSScanner scannerWithString:s];
    if (![scanner scanHexInt:&v] || !scanner.isAtEnd) return NO;
    if (s.length == 6) v = (v << 8) | 0xFF;
    *out = v;
    return YES;
}

static inline UIColor *VLTColorFromRGBA(uint32_t c) {
    return [UIColor colorWithRed:((c >> 24) & 0xFF) / 255.0
                           green:((c >> 16) & 0xFF) / 255.0
                            blue:((c >> 8) & 0xFF) / 255.0
                           alpha:(c & 0xFF) / 255.0];
}

static inline UIColor *VLTColorFromHex(NSString *hex) {
    uint32_t c;
    return VLTParseHex(hex, &c) ? VLTColorFromRGBA(c) : nil;
}

static inline NSString *VLTHexFromColor(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0;
        [color getWhite:&w alpha:&a];
        r = g = b = w;
    }
    #define VLT_BYTE(x) ((int)lround(fmin(fmax((x), 0), 1) * 255))
    return [NSString stringWithFormat:@"#%02X%02X%02X%02X", VLT_BYTE(r), VLT_BYTE(g), VLT_BYTE(b), VLT_BYTE(a)];
    #undef VLT_BYTE
}

// Red at empty, yellow in the middle, green when full.
static inline UIColor *VLTLevelColorFor(double fraction) {
    double f = fmin(fmax(fraction, 0), 1);
    return [UIColor colorWithHue:f * (120.0 / 360.0) saturation:0.85 brightness:0.95 alpha:1];
}

#pragma mark - Built-in battery pictures

// Each theme is a short list of filled shapes on a 100 x 100 canvas.
// Path syntax is a small subset of SVG: M, L, C, Z (absolute) plus
// "E cx,cy rx,ry" for an ellipse. Color 0 punches a transparent hole.
// To add a theme: append an entry here, bump VLT_THEME_COUNT, and add its
// name to the "Battery Picture" list in voltaprefs/Resources/Battery.plist.
typedef struct { const char *path; uint32_t rgba; } VLTShape;
typedef struct { const char *name; CGRect box; VLTShape shapes[8]; } VLTTheme;

#define VLT_THEME_COUNT 7
static const VLTTheme kVLTThemes[VLT_THEME_COUNT] = {
    { "Pumpkin", {{2, 4}, {96, 92}}, {
        { "M45,24 C44,14 49,7 59,5 L62,12 C57,14 55,18 55,24 Z", 0x4E9A3AFF },
        { "E50,58 46,36", 0xF26A0FFF },
        { "E50,58 31,36", 0xFF8A1FFF },
        { "E50,58 14,36", 0xFFA53DFF },
        { "M22,50 L42,50 L32,35 Z", 0x00000000 },
        { "M58,50 L78,50 L68,35 Z", 0x00000000 },
        { "M20,62 L31,68 L40,62 L50,69 L60,62 L69,68 L80,62 L72,81 L59,75 L50,83 L41,75 L28,81 Z", 0x00000000 },
    } },
    { "Ghost", {{14, 4}, {72, 92}}, {
        { "M18,92 L18,44 C18,22 32,8 50,8 C68,8 82,22 82,44 L82,92 L71,81 L60.5,92 L50,81 L39.5,92 L29,81 Z", 0x9A86E0FF },
        { "M24,81 L24,44 C24,26 35,14 50,14 C65,14 76,26 76,44 L76,81 L71,75 L60.5,85.5 L50,75 L39.5,85.5 L29,75 Z", 0xF4F0FFFF },
        { "E38,42 6.5,9", 0x352B63FF },
        { "E62,42 6.5,9", 0x352B63FF },
        { "E50,63 5.5,7", 0x352B63FF },
    } },
    { "Candy Corn", {{6, 4}, {88, 92}}, {
        { "M50,6 C54,6 57,9 59,13 L67,32 L33,32 L41,13 C43,9 46,6 50,6 Z", 0xFFF6E0FF },
        { "M33,32 L67,32 L80,62 L20,62 Z", 0xFF8A1FFF },
        { "M20,62 L80,62 L90,84 C93,90 90,94 84,94 L16,94 C10,94 7,90 10,84 Z", 0xFFD21FFF },
    } },
    { "Bat", {{0, 18}, {100, 52}}, {
        { "M50,32 L45,20 L42,35 C36,31 28,31 22,37 C14,33 6,35 2,43 C10,43 14,49 14,57 C20,51 28,51 32,59 C36,53 44,55 50,68 C56,55 64,53 68,59 C72,51 80,51 86,57 C86,49 90,43 98,43 C94,35 86,33 78,37 C72,31 64,31 58,35 L55,20 Z", 0x9B5DE5FF },
        { "E45,40 2.2,2.2", 0x00000000 },
        { "E55,40 2.2,2.2", 0x00000000 },
    } },
    { "Heart", {{4, 8}, {92, 84}}, {
        { "M50,90 C20,68 6,50 6,33 C6,19 16,10 28,10 C38,10 46,16 50,25 C54,16 62,10 72,10 C84,10 94,19 94,33 C94,50 80,68 50,90 Z", 0xFF3B5CFF },
    } },
    { "Star", {{3, 4}, {94, 92}}, {
        { "M50.0,5.0 L61.8,36.8 L95.7,38.2 L69.0,59.2 L78.2,91.8 L50.0,73.0 L21.8,91.8 L31.0,59.2 L4.3,38.2 L38.2,36.8 Z", 0xFFCC00FF },
    } },
    // Claude's own pick: a firefly, whose glow suits "Fill With Charge".
    { "Firefly", {{4, 6}, {92, 92}}, {
        { "E50,68 29,28", 0xFFE0664D },
        { "M47,46 C32,28 10,32 7,47 C5,61 27,64 47,54 Z M53,46 C68,28 90,32 93,47 C95,61 73,64 53,54 Z", 0x9CCBF5FF },
        { "E50,69 18,23", 0xFFC81FFF },
        { "E50,65 10,14", 0xFFF1A1FF },
        { "M43,31 L35,13 L39,11.5 L47,29 Z M57,31 L65,13 L61,11.5 L53,29 Z", 0x3E7C8AFF },
        { "E50,41 14,13 36.5,12 4,4 63.5,12 4,4", 0x3E7C8AFF },
        { "E44.5,38.5 3.2,3.2 55.5,38.5 3.2,3.2", 0xFFFFFFFF },
    } },
};

static inline UIBezierPath *VLTPathFromString(const char *s) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    char cmd = 0;
    while (*s) {
        while (*s == ' ' || *s == ',') s++;
        if (!*s) break;
        if ((*s >= 'A' && *s <= 'Z')) {
            cmd = *s++;
            if (cmd == 'Z') [path closePath];
            continue;
        }
        int need = (cmd == 'C') ? 6 : (cmd == 'E') ? 4 : 2;
        double n[6] = {0};
        for (int i = 0; i < need; i++) {
            char *end = NULL;
            n[i] = strtod(s, &end);
            if (end == s) return path;   // malformed: stop quietly
            s = end;
            while (*s == ' ' || *s == ',') s++;
        }
        switch (cmd) {
            case 'M': [path moveToPoint:CGPointMake(n[0], n[1])]; cmd = 'L'; break;
            case 'L': [path addLineToPoint:CGPointMake(n[0], n[1])]; break;
            case 'C': [path addCurveToPoint:CGPointMake(n[4], n[5]) controlPoint1:CGPointMake(n[0], n[1]) controlPoint2:CGPointMake(n[2], n[3])]; break;
            case 'E': [path appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(n[0] - n[2], n[1] - n[3], n[2] * 2, n[3] * 2)]]; break;
            default: return path;
        }
    }
    return path;
}

static inline UIGraphicsImageRenderer *VLTRenderer(CGSize size, CGFloat scale) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    format.scale = scale > 0 ? scale : [UIScreen mainScreen].scale;
    return [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(MAX(size.width, 1), MAX(size.height, 1)) format:format];
}

// kind is 1-based. Returns nil for anything that is not a built-in theme.
static inline UIImage *VLTThemeImage(int kind, CGFloat height, CGFloat scale) {
    if (kind < 1 || kind > VLT_THEME_COUNT) return nil;
    const VLTTheme *theme = &kVLTThemes[kind - 1];
    CGFloat k = height / theme->box.size.height;
    CGSize size = CGSizeMake(theme->box.size.width * k, height);
    return [VLTRenderer(size, scale) imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef ctx = context.CGContext;
        CGContextScaleCTM(ctx, k, k);
        CGContextTranslateCTM(ctx, -theme->box.origin.x, -theme->box.origin.y);
        for (int i = 0; i < 8 && theme->shapes[i].path; i++) {
            UIBezierPath *path = VLTPathFromString(theme->shapes[i].path);
            if (theme->shapes[i].rgba == 0) {
                [path fillWithBlendMode:kCGBlendModeClear alpha:1];
            } else {
                [VLTColorFromRGBA(theme->shapes[i].rgba) setFill];
                [path fill];
            }
        }
    }];
}

// Scales any picture to the given height, keeping its shape; very wide
// pictures are capped at VLT_IMAGE_MAX_ASPECT and get shorter instead.
static inline UIImage *VLTFittedImage(UIImage *source, CGFloat height, CGFloat scale) {
    if (!source || source.size.width < 1 || source.size.height < 1) return nil;
    CGFloat aspect = source.size.width / source.size.height;
    CGSize size = (aspect > VLT_IMAGE_MAX_ASPECT)
        ? CGSizeMake(height * VLT_IMAGE_MAX_ASPECT, height * VLT_IMAGE_MAX_ASPECT / aspect)
        : CGSizeMake(height * aspect, height);
    return [VLTRenderer(size, scale) imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [source drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
}

// "Fill with charge": the whole picture faint, the charged share (from the
// bottom up) at full strength.
static inline UIImage *VLTLevelImage(UIImage *base, double fraction) {
    if (!base) return nil;
    CGSize size = base.size;
    double f = fmin(fmax(fraction, 0), 1);
    return [VLTRenderer(size, base.scale) imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect all = CGRectMake(0, 0, size.width, size.height);
        [base drawInRect:all blendMode:kCGBlendModeNormal alpha:0.28];
        CGContextClipToRect(context.CGContext, CGRectMake(0, size.height * (1 - f), size.width, size.height * f));
        [base drawInRect:all];
    }];
}

#pragma mark - Animation frames

static inline NSString *VLTFramePath(NSUInteger index) {
    return [VLT_FRAMES_DIR stringByAppendingPathComponent:[NSString stringWithFormat:@"%02lu.png", (unsigned long)index]];
}

static inline NSString *VLTEffectName(int effect) {
    switch (effect) {
        case VLTEffectPulse:  return @"Pulse";
        case VLTEffectBounce: return @"Bounce";
        case VLTEffectWobble: return @"Wobble";
        case VLTEffectSpin:   return @"Spin";
        case VLTEffectBlink:  return @"Blink";
        case VLTEffectShake:  return @"Shake";
        default:              return @"None";
    }
}

// Turns one still picture into a short loop. The canvas is a little larger
// than the picture so that bouncing and spinning are not clipped. Returns nil
// for VLTEffectNone.
static inline NSArray<UIImage *> *VLTEffectFrames(UIImage *base, int effect) {
    if (!base || effect <= VLTEffectNone || effect >= VLTEffectCount) return nil;
    int count = (effect == VLTEffectSpin) ? 16 : (effect == VLTEffectShake ? 8 : 12);
    CGSize size = base.size;
    CGFloat side = MAX(size.width, size.height);
    CGSize canvas = (effect == VLTEffectSpin) ? CGSizeMake(side * 1.3, side * 1.3)
                                              : CGSizeMake(size.width * 1.3, size.height * 1.3);
    NSMutableArray *frames = [NSMutableArray arrayWithCapacity:count];
    for (int i = 0; i < count; i++) {
        double t = (double)i / count, wave = sin(t * 2 * M_PI);
        CGFloat scale = 1, angle = 0, dx = 0, dy = 0, alpha = 1;
        switch (effect) {
            case VLTEffectPulse:  scale = 1 + 0.14 * (0.5 - 0.5 * cos(t * 2 * M_PI)); break;
            case VLTEffectBounce: dy = -size.height * 0.13 * fabs(sin(t * M_PI)); break;
            case VLTEffectWobble: angle = 0.21 * wave; break;
            case VLTEffectSpin:   angle = t * 2 * M_PI; break;
            case VLTEffectBlink:  alpha = 0.35 + 0.65 * (0.5 + 0.5 * cos(t * 2 * M_PI)); break;
            case VLTEffectShake:  dx = size.width * 0.09 * wave; break;
        }
        UIImage *frame = [VLTRenderer(canvas, base.scale) imageWithActions:^(UIGraphicsImageRendererContext *context) {
            CGContextRef ctx = context.CGContext;
            CGContextTranslateCTM(ctx, canvas.width / 2 + dx, canvas.height / 2 + dy);
            CGContextRotateCTM(ctx, angle);
            CGContextScaleCTM(ctx, scale, scale);
            [base drawInRect:CGRectMake(-size.width / 2, -size.height / 2, size.width, size.height) blendMode:kCGBlendModeNormal alpha:alpha];
        }];
        if (frame) [frames addObject:frame];
    }
    return frames;
}

// Scales the user's frames to one common canvas (the first frame's shape),
// so they can be flipped through as a single animation.
static inline NSArray<UIImage *> *VLTFittedFrames(NSArray<UIImage *> *sources, CGFloat height, CGFloat scale) {
    UIImage *first = VLTFittedImage(sources.firstObject, height, scale);
    if (!first) return nil;
    CGSize canvas = first.size;
    NSMutableArray *frames = [NSMutableArray arrayWithObject:first];
    for (NSUInteger i = 1; i < sources.count && i < VLT_MAX_FRAMES; i++) {
        UIImage *source = sources[i];
        if (source.size.width < 1 || source.size.height < 1) continue;
        CGFloat k = MIN(canvas.width / source.size.width, canvas.height / source.size.height);
        CGSize fitted = CGSizeMake(source.size.width * k, source.size.height * k);
        UIImage *frame = [VLTRenderer(canvas, first.scale) imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [source drawInRect:CGRectMake((canvas.width - fitted.width) / 2, (canvas.height - fitted.height) / 2, fitted.width, fitted.height)];
        }];
        if (frame) [frames addObject:frame];
    }
    return frames;
}

#pragma mark - State packing

static inline VLTState VLTStateFromPrefs(NSDictionary *p) {
    VLTState s;
    memset(&s, 0, sizeof(s));
    s.version = VLT_STATE_VERSION;

    if (VLTBool(p, @"enabled", YES))        s.flags1 |= VLTOn;
    if (VLTBool(p, @"batFakeEnabled", NO))  s.flags1 |= VLTFake;
    if (VLTBool(p, @"batHidePercent", NO))  s.flags1 |= VLTHidePercent;
    if (VLTBool(p, @"batHideSymbol", NO))   s.flags1 |= VLTHideSymbol;
    if (VLTBool(p, @"batHideIcon", NO))     s.flags1 |= VLTHideIcon;
    if (VLTBool(p, @"batHidePin", NO))      s.flags1 |= VLTHidePin;
    if (VLTBool(p, @"batColors", NO))       s.flags1 |= VLTColors;
    if (VLTBool(p, @"batLevelColor", NO))   s.flags1 |= VLTLevelColor;
    if (VLTBool(p, @"batKeepStatus", YES))  s.flags2 |= VLTKeepStatus;
    if (VLTBool(p, @"batImageFill", NO))    s.flags2 |= VLTImageFill;
    if (VLTBool(p, @"funStatusWiggle", NO)) s.reserved[0] |= VLTStatusWiggle;
    if (VLTBool(p, @"funStatusFlip", NO))   s.reserved[0] |= VLTStatusFlip;
    if (VLTBool(p, @"funStatusBounce", NO)) s.reserved[0] |= VLTStatusBounce;
    if (VLTBool(p, @"funStatusPulse", NO))  s.reserved[0] |= VLTStatusPulse;

    int kind = (int)VLTNum(p, @"batImage", VLT_IMAGE_NONE);
    BOOL validKind = (kind >= 1 && kind <= VLT_THEME_COUNT) ||
                     (kind == VLT_IMAGE_CUSTOM && [p[@"batImageData"] isKindOfClass:[NSData class]]);
    NSArray *frames = p[@"batFrames"];
    NSUInteger frameCount = [frames isKindOfClass:[NSArray class]] ? MIN(frames.count, (NSUInteger)VLT_MAX_FRAMES) : 0;
    if (kind == VLT_IMAGE_ANIMATED && frameCount > 0) validKind = YES;
    s.animFrames = (uint8_t)frameCount;
    s.animFps    = (uint8_t)lround(fmin(fmax(VLTNum(p, @"batFps", 8), 1), 24));
    int effect   = (int)VLTNum(p, @"batEffect", VLTEffectNone);
    s.animEffect = (effect > 0 && effect < VLTEffectCount) ? (uint8_t)effect : VLTEffectNone;
    s.imageKind = validKind ? (uint8_t)kind : VLT_IMAGE_NONE;
    s.imageGen  = (uint8_t)((long)VLTNum(p, @"batImageGen", 0) & 0xFF);

    s.fakePercent = (uint8_t)lround(fmin(fmax(VLTNum(p, @"batFakeValue", 100), 0), 100));
    s.scale       = (uint8_t)lround(fmin(fmax(VLTNum(p, @"batScale", 100), 50), 150));
    s.chargeMode  = (uint8_t)((int)VLTNum(p, @"batCharging", 0) % 3);
    s.saverMode   = (uint8_t)((int)VLTNum(p, @"batSaver", 0) % 3);
    s.inIconMode  = (uint8_t)((int)VLTNum(p, @"batInIcon", 0) % 3);

    if (VLTParseHex(p[@"batFill"], &s.fill)) s.flags2 |= VLTHasFill;
    if (VLTParseHex(p[@"batBody"], &s.body)) s.flags2 |= VLTHasBody;
    if (VLTParseHex(p[@"batPin"],  &s.pin))  s.flags2 |= VLTHasPin;
    if (VLTParseHex(p[@"batBolt"], &s.bolt)) s.flags2 |= VLTHasBolt;
    if (VLTParseHex(p[@"batText"], &s.text)) s.flags2 |= VLTHasText;

    // Copy whole characters only, so the 15-byte limit never splits an emoji.
    NSString *label = [VLTStr(p, @"batLabel") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    __block size_t used = 0;
    char *dst = s.label;
    [label enumerateSubstringsInRange:NSMakeRange(0, label.length)
                              options:NSStringEnumerationByComposedCharacterSequences
                           usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) {
        const char *utf8 = sub.UTF8String;
        size_t n = utf8 ? strlen(utf8) : 0;
        if (n == 0 || used + n > sizeof(((VLTState *)0)->label) - 1) { *stop = YES; return; }
        memcpy(dst + used, utf8, n);
        used += n;
    }];
    return s;
}

static inline NSString *VLTStateLabel(const VLTState *s) {
    if (!s->label[0]) return nil;
    char buf[17] = {0};
    memcpy(buf, s->label, 16);
    return [NSString stringWithUTF8String:buf];
}

// Tokens are kept for the life of the process: notifyd drops a name's state
// once nobody is registered for it.
static inline int *VLTStateTokens(void) {
    static int tokens[VLT_STATE_WORDS];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (int i = 0; i < VLT_STATE_WORDS; i++) {
            char name[64];
            snprintf(name, sizeof(name), VLT_DOMAIN "/state.%d", i);
            if (notify_register_check(name, &tokens[i]) != NOTIFY_STATUS_OK) tokens[i] = -1;
        }
    });
    return tokens;
}

static inline void VLTStatePublish(const VLTState *s) {
    uint64_t words[VLT_STATE_WORDS];
    memcpy(words, s, sizeof(words));
    int *tokens = VLTStateTokens();
    // Word 0 carries the version byte, so write it last: readers see either
    // "not published" or a complete record.
    for (int i = VLT_STATE_WORDS - 1; i >= 0; i--) {
        if (tokens[i] >= 0) notify_set_state(tokens[i], words[i]);
    }
}

static inline VLTState VLTStateRead(void) {
    uint64_t words[VLT_STATE_WORDS] = {0};
    int *tokens = VLTStateTokens();
    for (int i = 0; i < VLT_STATE_WORDS; i++) {
        if (tokens[i] >= 0) notify_get_state(tokens[i], &words[i]);
    }
    VLTState s;
    memcpy(&s, words, sizeof(s));
    if (s.version != VLT_STATE_VERSION) memset(&s, 0, sizeof(s));
    return s;
}

#pragma mark - Status bar settings (written by SpringBoard, read by apps)

static inline NSArray<NSString *> *VLTStatusKeys(void) {
    return @[@"enabled",
             @"sbClockMode", @"sbClockFormat", @"sbDateMode", @"sbDateText", @"sbCarrier",
             @"sbHideWifi", @"sbHideCell", @"sbHideLocation", @"sbHideFocus", @"sbHideRotation",
             @"sbHideAlarm", @"sbHideAirplane", @"sbHideVPN", @"sbHideBluetooth",
             @"fakeCutout", @"fakeWidth", @"fakeHeight", @"fakeTop", @"fakeCharge", @"fakeLens", @"fakeHomeBar"];
}

static inline NSDictionary *VLTStatusDict(NSDictionary *prefs) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *key in VLTStatusKeys()) {
        id value = prefs[key];
        if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) out[key] = value;
    }
    return out;
}

// The clock formats offered on the Status Bar page; 5 is the user's own.
static inline NSString *VLTClockFormat(NSDictionary *settings) {
    switch ((int)VLTNum(settings, @"sbClockMode", 0)) {
        case 1: return @"h:mm:ss";
        case 2: return @"HH:mm:ss";
        case 3: return @"EEE h:mm";
        case 4: return @"h:mm · MMM d";
        case 5: {
            NSString *custom = VLTStr(settings, @"sbClockFormat");
            return custom.length ? (custom.length > 40 ? [custom substringToIndex:40] : custom) : nil;
        }
        default: return nil;
    }
}
