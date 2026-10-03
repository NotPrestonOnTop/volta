// Volta settings - pages added in 2.0: Home Screen, Icons, Status Bar,
// Notifications and Profiles.
#import "VLTMore.h"
#import "VLTViews.h"
#import "VLTUnzip.h"
#import "VLTShared.h"
#import "VLTIconTheme.h"
#import <notify.h>
#import <ImageIO/ImageIO.h>

@interface PSListController (VLTMorePrivate)
- (id)cachedCellForSpecifier:(PSSpecifier *)specifier;
@end

#define MHEX(v) [UIColor colorWithRed:(((v) >> 16) & 0xFF) / 255.0 green:(((v) >> 8) & 0xFF) / 255.0 blue:((v) & 0xFF) / 255.0 alpha:1]

static void VLTMoreSet(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR(VLT_DOMAIN));
}

static void VLTMoreCommit(void) {
    CFPreferencesAppSynchronize(CFSTR(VLT_DOMAIN));
    notify_post(VLT_NOTIFY_PREFS);
}

static void VLTMoreAlertNow(UIViewController *host, NSString *title, NSString *message, int triesLeft) {
    if (!host.viewIfLoaded.window) return;
    // A picker may still be sliding away; an alert shown on top of it is dropped.
    if (host.presentedViewController && triesLeft > 0) {
        __weak UIViewController *weakHost = host;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakHost) VLTMoreAlertNow(weakHost, title, message, triesLeft - 1);
        });
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

static void VLTMoreAlert(UIViewController *host, NSString *title, NSString *message) {
    VLTMoreAlertNow(host, title, message, 4);
}

#pragma mark - Preview card

// The dark gradient card every preview sits on; returns the card rect.
static CGRect VLTMoreCard(UIView *view) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat inset = MAX(16, view.layoutMargins.left);
    CGRect card = CGRectMake(inset, 12, view.bounds.size.width - inset * 2, view.bounds.size.height - 20);
    CGContextSaveGState(ctx);
    [[UIBezierPath bezierPathWithRoundedRect:card cornerRadius:22] addClip];
    NSArray *colors = @[(id)MHEX(0x1B1746).CGColor, (id)MHEX(0x4B2D83).CGColor, (id)MHEX(0x1F6F8B).CGColor];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
    CGContextDrawLinearGradient(ctx, gradient, card.origin, CGPointMake(CGRectGetMaxX(card), CGRectGetMaxY(card)), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
    CGContextRestoreGState(ctx);
    [@"PREVIEW" drawAtPoint:CGPointMake(card.origin.x + 16, card.origin.y + 12)
             withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold],
                              NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.6],
                              NSKernAttributeName: @1.2}];
    return card;
}

@interface VLTMorePreview : UIView
@property (nonatomic, copy) NSDictionary *prefs;
@end

@implementation VLTMorePreview

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

@end

#pragma mark - Icons preview

// A stand-in app icon: gradient tile with a white symbol.
static UIImage *VLTSampleIcon(NSString *symbol, UIColor *top, UIColor *bottom, CGFloat side) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect rect = CGRectMake(0, 0, side, side);
        [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:side * 0.225] addClip];
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)@[(id)top.CGColor, (id)bottom.CGColor], NULL);
        CGContextDrawLinearGradient(context.CGContext, gradient, CGPointZero, CGPointMake(0, side), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:side * 0.46 weight:UIImageSymbolWeightSemibold];
        UIImage *glyph = [[UIImage systemImageNamed:symbol withConfiguration:config] imageWithTintColor:[UIColor whiteColor]
                                                                                           renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (glyph) [glyph drawAtPoint:CGPointMake((side - glyph.size.width) / 2, (side - glyph.size.height) / 2)];
    }];
}

@interface VLTIconsPreview : VLTMorePreview
@property (nonatomic) NSInteger packCount;
@end

@implementation VLTIconsPreview

- (void)drawRect:(CGRect)rect {
    NSDictionary *p = self.prefs ?: @{};
    CGRect card = VLTMoreCard(self);
    VLTIconStyle style = VLTIconStyleFromPrefs(p);
    NSArray *samples = @[@[@"message.fill", MHEX(0x5FE36B), MHEX(0x1FB141)], @[@"music.note", MHEX(0xFF5E7B), MHEX(0xF5263E)],
                         @[@"safari.fill", MHEX(0x4FC3FF), MHEX(0x0A6CFF)], @[@"camera.fill", MHEX(0xB0B5BD), MHEX(0x6B7078)],
                         @[@"star.fill", MHEX(0xFFD23E), MHEX(0xFF8A00)]];
    CGFloat side = 56, gap = 18;
    NSInteger count = samples.count;
    while (count > 2 && count * side + (count - 1) * gap > card.size.width - 32) count--;
    CGFloat x = CGRectGetMidX(card) - (count * side + (count - 1) * gap) / 2, y = CGRectGetMidY(card) - side / 2 + 8;
    for (NSInteger i = 0; i < count; i++) {
        UIImage *base = VLTSampleIcon(samples[i][0], samples[i][1], samples[i][2], side);
        UIImage *themed = VLTIconRender(base, nil, style) ?: base;
        [themed drawInRect:CGRectMake(x + i * (side + gap), y, side, side)];
    }
    if (self.packCount > 0) {
        NSString *text = [NSString stringWithFormat:@"%ld pack icon%@ installed", (long)self.packCount, self.packCount == 1 ? @"" : @"s"];
        NSDictionary *attributes = @{NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightMedium],
                                     NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.75]};
        CGSize size = [text sizeWithAttributes:attributes];
        [text drawAtPoint:CGPointMake(CGRectGetMaxX(card) - size.width - 16, card.origin.y + 11) withAttributes:attributes];
    }
}

@end

#pragma mark - Status bar preview

@interface VLTStatusPreview : VLTMorePreview
@end

@implementation VLTStatusPreview {
    NSTimer *_tick;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_tick invalidate];
    _tick = nil;
    if (!self.window) return;
    __weak typeof(self) weakSelf = self;
    _tick = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { [weakSelf setNeedsDisplay]; }];   // the clock ticks
}

- (void)dealloc { [_tick invalidate]; }

- (void)drawRect:(CGRect)rect {
    NSDictionary *p = self.prefs ?: @{};
    BOOL on = VLTBool(p, @"enabled", YES);
    CGRect card = VLTMoreCard(self);

    // A small "screen" with a status bar across its top.
    CGRect screen = CGRectInset(card, 18, 0);
    screen.origin.y = card.origin.y + 36;
    screen.size.height = CGRectGetMaxY(card) - 14 - screen.origin.y;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    [[UIBezierPath bezierPathWithRoundedRect:screen cornerRadius:14] addClip];
    [[UIColor colorWithWhite:0 alpha:0.28] setFill];
    UIRectFillUsingBlendMode(screen, kCGBlendModeNormal);

    NSDictionary *text = @{NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: [UIColor whiteColor]};
    static NSDateFormatter *formatter;
    if (!formatter) formatter = [[NSDateFormatter alloc] init];
    NSString *format = on ? VLTClockFormat(p) : nil;
    NSString *clock = nil;
    @try {
        formatter.dateFormat = format ?: @"h:mm a";
        clock = [formatter stringFromDate:[NSDate date]];
    } @catch (__unused NSException *e) {}
    if (clock.length == 0) clock = @"9:41 AM";
    CGFloat x = screen.origin.x + 14, y = screen.origin.y + 8;
    [clock drawAtPoint:CGPointMake(x, y) withAttributes:text];
    x += [clock sizeWithAttributes:text].width + 10;

    NSInteger dateMode = on ? (NSInteger)VLTNum(p, @"sbDateMode", 0) : 0;
    NSString *date = nil;
    if (dateMode == 2 && VLTStr(p, @"sbDateText").length) {
        date = VLTStr(p, @"sbDateText");
    } else if (dateMode != 1) {
        formatter.dateFormat = @"EEE MMM d";
        date = [formatter stringFromDate:[NSDate date]];
    }
    if (date) [date drawAtPoint:CGPointMake(x, y) withAttributes:text];

    // Right side: Wi-Fi and battery.
    CGFloat right = CGRectGetMaxX(screen) - 14;
    CGRect body = CGRectMake(right - 24, y + 3, 22, 11);
    [[UIColor colorWithWhite:1 alpha:0.45] setStroke];
    UIBezierPath *outline = [UIBezierPath bezierPathWithRoundedRect:body cornerRadius:3];
    outline.lineWidth = 1;
    [outline stroke];
    [[UIColor whiteColor] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectInset(body, 2, 2) cornerRadius:1.5] fill];
    if (!(on && VLTBool(p, @"sbHideWifi", NO))) {
        UIImage *wifi = [[UIImage systemImageNamed:@"wifi" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]]
                         imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
        [wifi drawAtPoint:CGPointMake(body.origin.x - wifi.size.width - 7, y + 1)];
    }

    // Fake cutout and home bar.
    NSInteger cutout = on ? (NSInteger)VLTNum(p, @"fakeCutout", 0) : 0;
    CGFloat k = 0.62;   // the preview screen is smaller than the real one
    CGFloat width = fmin(fmax(VLTNum(p, @"fakeWidth", 160), 60), 320) * k, height = fmin(fmax(VLTNum(p, @"fakeHeight", 30), 14), 60) * k;
    [[UIColor blackColor] setFill];
    CGRect cut = CGRectZero;
    if (cutout == 1) {
        cut = CGRectMake(CGRectGetMidX(screen) - width / 2, screen.origin.y, width, height);
        [[UIBezierPath bezierPathWithRoundedRect:cut byRoundingCorners:UIRectCornerBottomLeft | UIRectCornerBottomRight
                                     cornerRadii:CGSizeMake(height * 0.6, height * 0.6)] fill];
    } else if (cutout == 2) {
        CGFloat top = fmin(fmax(VLTNum(p, @"fakeTop", 6), 0), 30) * k;
        cut = CGRectMake(CGRectGetMidX(screen) - width / 2, screen.origin.y + top, width, height);
        [[UIBezierPath bezierPathWithRoundedRect:cut cornerRadius:height / 2] fill];
    }
    if (cutout && VLTBool(p, @"fakeLens", YES)) {
        CGFloat lens = MIN(7, height * 0.38);
        [MHEX(0x1A1F3A) setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(CGRectGetMaxX(cut) - height / 2 - lens / 2 - (cutout == 2 ? 1 : width * 0.16),
                                                           CGRectGetMidY(cut) - lens / 2, lens, lens)] fill];
    }
    if (on && VLTBool(p, @"fakeHomeBar", NO)) {
        CGFloat bar = MIN(screen.size.width * 0.34, 150);
        [[UIColor colorWithWhite:1 alpha:0.92] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(CGRectGetMidX(screen) - bar / 2, CGRectGetMaxY(screen) - 9, bar, 4) cornerRadius:2] fill];
    }
    CGContextRestoreGState(ctx);
}

@end

#pragma mark - Notification preview

@interface VLTNotifPreview : VLTMorePreview
@end

@implementation VLTNotifPreview

- (void)drawRect:(CGRect)rect {
    NSDictionary *p = self.prefs ?: @{};
    BOOL on = VLTBool(p, @"enabled", YES) && VLTBool(p, @"notifOn", NO);
    CGRect card = VLTMoreCard(self);
    CGFloat width = MIN(card.size.width - 36, 360), height = 68;
    CGRect banner = CGRectMake(CGRectGetMidX(card) - width / 2, CGRectGetMidY(card) - height / 2 + 9, width, height);
    CGFloat radius = (on && VLTBool(p, @"notifRadiusOn", NO)) ? fmin(fmax(VLTNum(p, @"notifRadius", 20), 0), height / 2) : 20;
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:banner cornerRadius:radius];

    if (!(on && VLTBool(p, @"notifHideBlur", NO))) {
        [[UIColor colorWithWhite:1 alpha:0.30] setFill];
        [path fill];
    }
    UIColor *tint = on ? VLTColorFromHex(p[@"notifTint"]) : nil;
    CGFloat strength = fmin(fmax(VLTNum(p, @"notifTintStrength", 50) / 100.0, 0), 1);
    if (tint && strength > 0.001) {
        [[tint colorWithAlphaComponent:strength * CGColorGetAlpha(tint.CGColor)] setFill];
        [path fill];
    }
    UIColor *border = on ? VLTColorFromHex(p[@"notifBorder"]) : nil;
    CGFloat borderWidth = on ? fmin(fmax(VLTNum(p, @"notifBorderWidth", 0), 0), 6) : 0;
    if (border && borderWidth > 0.01) {
        UIBezierPath *stroke = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(banner, borderWidth / 2, borderWidth / 2)
                                                          cornerRadius:MAX(0, radius - borderWidth / 2)];
        stroke.lineWidth = borderWidth;
        [border setStroke];
        [stroke stroke];
    }

    UIImage *icon = VLTSampleIcon(@"message.fill", MHEX(0x5FE36B), MHEX(0x1FB141), 38);
    [icon drawInRect:CGRectMake(banner.origin.x + 14, CGRectGetMidY(banner) - 19, 38, 38)];
    [@"Volta" drawAtPoint:CGPointMake(banner.origin.x + 64, banner.origin.y + 15)
           withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: [UIColor whiteColor]}];
    [@"This is what a notification looks like." drawInRect:CGRectMake(banner.origin.x + 64, banner.origin.y + 35, banner.size.width - 76, 20)
           withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:14], NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.85]}];
    [@"now" drawAtPoint:CGPointMake(CGRectGetMaxX(banner) - 40, banner.origin.y + 16)
         withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12], NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.6]}];
}

@end

#pragma mark - Home Screen

@implementation VLTHomeController

- (NSString *)plistName { return @"Home"; }

- (void)respring:(PSSpecifier *)specifier {
    notify_post(VLT_NOTIFY_RESPRING);
}

@end

#pragma mark - Status Bar

@implementation VLTStatusController {
    VLTStatusPreview *_preview;
}

- (NSString *)plistName { return @"StatusBar"; }

- (UIView *)makeHeaderView {
    _preview = [[VLTStatusPreview alloc] initWithFrame:CGRectZero];
    return _preview;
}

- (void)prefsDidChange {
    _preview.prefs = VLTCopyPrefs();
}

- (void)respring:(PSSpecifier *)specifier {
    notify_post(VLT_NOTIFY_RESPRING);
}

@end

#pragma mark - Notifications

@implementation VLTNotifController {
    VLTNotifPreview *_preview;
}

- (NSString *)plistName { return @"Notifications"; }

- (UIView *)makeHeaderView {
    _preview = [[VLTNotifPreview alloc] initWithFrame:CGRectZero];
    return _preview;
}

- (void)prefsDidChange {
    _preview.prefs = VLTCopyPrefs();
}

@end

#pragma mark - Icon pack storage

// The folder the pack lives in: the shared one if it can be written, else a
// fallback in the user's Library. SpringBoard is told which through "iconDir".
static NSString *VLTPackFolder(BOOL create) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *saved = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("iconDir"), CFSTR(VLT_DOMAIN)));
    if (!create) return [saved isKindOfClass:[NSString class]] && [saved isEqualToString:VLT_ICONS_DIR_ALT] ? VLT_ICONS_DIR_ALT : VLT_ICONS_DIR;
    for (NSString *folder in @[VLT_ICONS_DIR, VLT_ICONS_DIR_ALT]) {
        [files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *probe = [folder stringByAppendingPathComponent:@".probe"];
        if ([[NSData data] writeToFile:probe atomically:NO]) {
            [files removeItemAtPath:probe error:NULL];
            return folder;
        }
    }
    return nil;
}

static NSInteger VLTPackCount(void) {
    NSInteger count = 0;
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:VLTPackFolder(NO) error:NULL]) {
        if ([name.pathExtension.lowercaseString isEqualToString:@"png"]) count++;
    }
    return count;
}

// Bundle ids are letters, digits, dots, dashes and underscores.
static BOOL VLTLooksLikeBundleID(NSString *name) {
    if (name.length < 3 || name.length > 150 || [name rangeOfString:@"."].location == NSNotFound) return NO;
    static NSCharacterSet *bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"] invertedSet];
    });
    return [name rangeOfCharacterFromSet:bad].location == NSNotFound && ![name hasPrefix:@"."];
}

// "com.apple.mobilesafari-large@3x~ipad.png" -> "com.apple.mobilesafari"
static NSString *VLTBundleIDFromFileName(NSString *fileName) {
    NSString *name = [fileName stringByDeletingPathExtension];
    for (NSString *suffix in @[@"~ipad", @"~iphone", @"@3x", @"@2x", @"-large", @"-small"]) {
        if (name.length > suffix.length && [name.lowercaseString hasSuffix:suffix]) name = [name substringToIndex:name.length - suffix.length];
    }
    return VLTLooksLikeBundleID(name) ? name : nil;
}

// Loads a picture file at no more than 512 pixels a side, however large the
// file claims to be, so a tiny file cannot ask for a huge amount of memory.
static UIImage *VLTLoadSmallImage(NSString *path) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!source) return nil;
    UIImage *image = nil;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    double width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
    double height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
    if (width >= 8 && height >= 8 && width <= 8192 && height <= 8192) {
        NSDictionary *options = @{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                  (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @512,
                                  (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES};
        CGImageRef small = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        if (small) {
            image = [UIImage imageWithCGImage:small scale:1 orientation:UIImageOrientationUp];
            CGImageRelease(small);
        }
    }
    CFRelease(source);
    return image;
}

// Every stored icon is a plain 180 x 180 PNG, whatever came in.
static BOOL VLTStorePackIcon(UIImage *image, NSString *bundleID, NSString *folder) {
    if (!image || image.size.width < 8 || image.size.height < 8 || !VLTLooksLikeBundleID(bundleID)) return NO;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = NO;
    CGFloat side = 180;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
    NSData *png = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
        CGFloat scale = MAX(side / image.size.width, side / image.size.height);   // fill the square
        CGSize drawn = CGSizeMake(image.size.width * scale, image.size.height * scale);
        [image drawInRect:CGRectMake((side - drawn.width) / 2, (side - drawn.height) / 2, drawn.width, drawn.height)];
    }];
    NSString *path = [[folder stringByAppendingPathComponent:bundleID] stringByAppendingPathExtension:@"png"];
    return [png writeToFile:path atomically:YES];
}

static void VLTPackChanged(NSString *folder) {
    NSDictionary *prefs = VLTCopyPrefs();
    if (folder) VLTMoreSet(@"iconDir", folder);
    VLTMoreSet(@"iconGen", @((long)VLTNum(prefs, @"iconGen", 0) + 1));
    VLTMoreCommit();
}

#pragma mark - App picker (for "Set One App's Icon")

@interface VLTAppPickerController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, copy) void (^onPick)(NSString *bundleID, NSString *name);
@end

@implementation VLTAppPickerController {
    NSArray<NSDictionary *> *_apps, *_shown;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Choose an App";
    self.view.tintColor = VLT_ACCENT;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    // The system's list of installed apps. Private, so every step is checked.
    NSMutableArray *apps = [NSMutableArray array];
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = [workspaceClass respondsToSelector:@selector(defaultWorkspace)] ? [workspaceClass performSelector:@selector(defaultWorkspace)] : nil;
    NSArray *proxies = nil;
    @try {
        if ([workspace respondsToSelector:NSSelectorFromString(@"allInstalledApplications")]) proxies = [workspace valueForKey:@"allInstalledApplications"];
    } @catch (__unused NSException *e) {}
    for (id proxy in ([proxies isKindOfClass:[NSArray class]] ? proxies : @[])) {
        @try {
            NSString *bundleID = [proxy valueForKey:@"applicationIdentifier"];
            NSString *name = [proxy valueForKey:@"localizedName"];
            NSArray *tags = [proxy respondsToSelector:NSSelectorFromString(@"appTags")] ? [proxy valueForKey:@"appTags"] : nil;
            if (![bundleID isKindOfClass:[NSString class]] || ![name isKindOfClass:[NSString class]] || !name.length) continue;
            if ([tags isKindOfClass:[NSArray class]] && [tags containsObject:@"hidden"]) continue;
            if (!VLTLooksLikeBundleID(bundleID)) continue;
            [apps addObject:@{@"id": bundleID, @"name": name}];
        } @catch (__unused NSException *e) {}
    }
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]]; }];
    _apps = apps;
    _shown = apps;
}

- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (query.length == 0) {
        _shown = _apps;
    } else {
        _shown = [_apps filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *app, NSDictionary *bindings) {
            return [app[@"name"] localizedCaseInsensitiveContainsString:query] || [app[@"id"] localizedCaseInsensitiveContainsString:query];
        }]];
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _shown.count; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return _apps.count ? nil : @"Volta could not read the list of apps on this device.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
    NSDictionary *app = _shown[indexPath.row];
    cell.textLabel.text = app[@"name"];
    cell.detailTextLabel.text = app[@"id"];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *app = _shown[indexPath.row];
    void (^onPick)(NSString *, NSString *) = self.onPick;
    // The search field may be presenting on top of us; close everything first.
    self.navigationItem.searchController.active = NO;
    UIViewController *presenter = self.presentingViewController;
    dispatch_async(dispatch_get_main_queue(), ^{   // let the search field finish closing
        [presenter dismissViewControllerAnimated:YES completion:^{
            if (onPick) onPick(app[@"id"], app[@"name"]);
        }];
    });
}

@end

#pragma mark - Icons

@implementation VLTIconsController {
    VLTIconsPreview *_preview;
    NSString *_targetBundleID, *_targetName;   // the app waiting for a picture from Photos
}

- (NSString *)plistName { return @"Icons"; }

- (UIView *)makeHeaderView {
    _preview = [[VLTIconsPreview alloc] initWithFrame:CGRectZero];
    return _preview;
}

- (void)prefsDidChange {
    _preview.packCount = VLTPackCount();
    _preview.prefs = VLTCopyPrefs();
}

- (void)importPack:(PSSpecifier *)specifier {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    // Progress is a spinner in the navigation bar: nothing that has to be presented and dismissed in step with the picker.
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    UIBarButtonItem *previousItem = self.navigationItem.rightBarButtonItem;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *files = [NSFileManager defaultManager];
        NSString *scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"voltapack-" stringByAppendingString:[NSUUID UUID].UUIDString]];
        BOOL scoped = [url startAccessingSecurityScopedResource];
        int unzipped = vlt_unzip(url.fileSystemRepresentation, scratch.fileSystemRepresentation);
        if (scoped) [url stopAccessingSecurityScopedResource];

        NSInteger stored = 0;
        NSString *problem = nil;
        NSString *folder = nil;
        if (unzipped < 0) {
            problem = unzipped == VLTUnzipErrTooBig ? @"That pack is too large." : @"That file could not be opened as a .zip.";
        } else if (!(folder = VLTPackFolder(YES))) {
            problem = @"Volta could not create its icon folder.";
        } else {
            // Several sizes of the same icon may be present; keep the largest of each.
            NSMutableDictionary<NSString *, NSString *> *best = [NSMutableDictionary dictionary];
            NSMutableDictionary<NSString *, NSNumber *> *bestSize = [NSMutableDictionary dictionary];
            NSDirectoryEnumerator *walker = [files enumeratorAtPath:scratch];
            NSInteger looked = 0;
            for (NSString *relative in walker) {
                if (![relative.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
                if ([relative.lastPathComponent hasPrefix:@"."] || [relative containsString:@"__MACOSX"]) continue;
                if (++looked > 6000) break;
                NSString *bundleID = VLTBundleIDFromFileName(relative.lastPathComponent);
                if (!bundleID) continue;
                NSString *path = [scratch stringByAppendingPathComponent:relative];
                unsigned long long bytes = [[files attributesOfItemAtPath:path error:NULL] fileSize];
                if (bytes == 0 || bytes > 8 * 1024 * 1024) continue;
                if (bytes > bestSize[bundleID].unsignedLongLongValue) {
                    best[bundleID] = path;
                    bestSize[bundleID] = @(bytes);
                }
            }
            for (NSString *bundleID in best) {
                if (stored >= 1000) break;
                @autoreleasepool {
                    UIImage *image = VLTLoadSmallImage(best[bundleID]);
                    if (VLTStorePackIcon(image, bundleID, folder)) stored++;
                }
            }
            if (stored == 0) problem = @"No icons were found. A pack needs PNG files named after each app's bundle id, like com.apple.mobilesafari.png.";
        }
        [files removeItemAtPath:scratch error:NULL];

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (stored > 0) VLTPackChanged(folder);
            if (!strongSelf) return;
            strongSelf.navigationItem.rightBarButtonItem = previousItem;
            [strongSelf prefsDidChange];
            if (problem) VLTMoreAlert(strongSelf, @"Couldn't Import", problem);
            else VLTMoreAlert(strongSelf, @"Icon Pack Imported",
                              [NSString stringWithFormat:@"%ld icon%@ added. Turn on Theme Icons and Use Icon Pack to see them.", (long)stored, stored == 1 ? @"" : @"s"]);
        });
    });
}

- (void)setOneIcon:(PSSpecifier *)specifier {
    VLTAppPickerController *apps = [[VLTAppPickerController alloc] init];
    __weak typeof(self) weakSelf = self;
    apps.onPick = ^(NSString *bundleID, NSString *name) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_targetBundleID = [bundleID copy];
        strongSelf->_targetName = [name copy];
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.filter = [PHPickerFilter imagesFilter];
        config.selectionLimit = 1;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        picker.delegate = strongSelf;
        [strongSelf presentViewController:picker animated:YES completion:nil];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:apps];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSItemProvider *provider = results.firstObject.itemProvider;
    NSString *bundleID = _targetBundleID, *name = _targetName;
    if (!bundleID || ![provider canLoadObjectOfClass:[UIImage class]]) return;
    __weak typeof(self) weakSelf = self;
    [provider loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
        if (![(id)object isKindOfClass:[UIImage class]]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSString *folder = VLTPackFolder(YES);
            if (folder && VLTStorePackIcon((UIImage *)object, bundleID, folder)) {
                VLTPackChanged(folder);
                [strongSelf prefsDidChange];
                VLTMoreAlert(strongSelf, @"Icon Set", [NSString stringWithFormat:@"%@ has a new icon. Turn on Theme Icons and Use Icon Pack to see it.", name ?: bundleID]);
            } else {
                VLTMoreAlert(strongSelf, @"Couldn't Save Icon", @"Volta could not store that picture.");
            }
        });
    }];
}

- (void)clearPack:(PSSpecifier *)specifier {
    if (VLTPackCount() == 0) {
        VLTMoreAlert(self, @"No Pack Icons", @"There is nothing to remove.");
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Remove All Pack Icons?" message:@"Apps go back to their own pictures."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSFileManager *files = [NSFileManager defaultManager];
        for (NSString *folder in @[VLT_ICONS_DIR, VLT_ICONS_DIR_ALT]) {
            for (NSString *name in [files contentsOfDirectoryAtPath:folder error:NULL]) {
                if ([name.pathExtension.lowercaseString isEqualToString:@"png"]) [files removeItemAtPath:[folder stringByAppendingPathComponent:name] error:NULL];
            }
        }
        VLTPackChanged(nil);
        [weakSelf prefsDidChange];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Profiles

// Profiles live in their own preferences file, like saved animations.
#define VLT_PROFILE_DOMAIN CFSTR("com.notpreston.volta.profiles")
#define VLT_MAX_PROFILES 16
#define VLT_PROFILE_MAX_BYTES (24 * 1024 * 1024)

// Not part of a look: the update checker's bookkeeping, which apps are shown,
// and things only true of this device.
static BOOL VLTProfileSkipsKey(NSString *key) {
    return [key hasPrefix:@"update"] || [key isEqualToString:@"appPhone"] || [key isEqualToString:@"appCalc"] ||
           [key isEqualToString:@"iconDir"] || [key isEqualToString:@"ccModuleInfo"];   // facts about this device
}

// Settings that point at files on this device; they mean nothing elsewhere.
static BOOL VLTProfileKeyIsLocal(NSString *key) {
    return [key hasSuffix:@"Path"] || [key hasSuffix:@"Dir"];
}

// A small file can describe a huge tree (containers may be shared), so the
// whole check is limited to a fixed number of values.
static NSInteger gProfileBudget;

static BOOL VLTProfileValueOK(id value, int depth) {
    if (depth > 4 || --gProfileBudget < 0) return NO;
    if ([value isKindOfClass:[NSString class]]) return [value length] < 4096;
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSDate class]]) return YES;
    if ([value isKindOfClass:[NSData class]]) return [value length] < 8 * 1024 * 1024;
    if ([value isKindOfClass:[NSArray class]]) {
        if ([value count] > 512) return NO;
        for (id item in value) if (!VLTProfileValueOK(item, depth + 1)) return NO;
        return YES;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        if ([value count] > 512) return NO;
        for (id key in value) {
            if (![key isKindOfClass:[NSString class]] || !VLTProfileValueOK([value objectForKey:key], depth + 1)) return NO;
        }
        return YES;
    }
    return NO;
}

static BOOL VLTProfileKeyOK(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0 || key.length > 64) return NO;
    static NSCharacterSet *bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet];
    });
    return [key rangeOfCharacterFromSet:bad].location == NSNotFound;
}

// The current settings, as a profile's "prefs".
static NSDictionary *VLTProfileSnapshot(void) {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
    gProfileBudget = 20000;
    [VLTCopyPrefs() enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if (VLTProfileKeyOK(key) && !VLTProfileSkipsKey(key) && VLTProfileValueOK(value, 0)) prefs[key] = value;
    }];
    return prefs;
}

static NSArray<NSDictionary *> *VLTProfiles(void) {
    CFPreferencesAppSynchronize(VLT_PROFILE_DOMAIN);
    NSArray *saved = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("profiles"), VLT_PROFILE_DOMAIN));
    NSMutableArray *valid = [NSMutableArray array];
    for (id profile in ([saved isKindOfClass:[NSArray class]] ? saved : @[])) {
        if ([profile isKindOfClass:[NSDictionary class]] && [profile[@"prefs"] isKindOfClass:[NSDictionary class]]) [valid addObject:profile];
    }
    return valid;
}

static void VLTSetProfiles(NSArray *profiles) {
    CFPreferencesSetAppValue(CFSTR("profiles"), (__bridge CFPropertyListRef)profiles, VLT_PROFILE_DOMAIN);
    CFPreferencesAppSynchronize(VLT_PROFILE_DOMAIN);
}

NSInteger VLTProfileCount(void) { return VLTProfiles().count; }

// Replaces every setting with the profile's. Counters that tell the tweak
// "this picture changed" move forward so nothing stale stays cached.
static void VLTProfileApply(NSDictionary *profile) {
    NSDictionary *wanted = profile[@"prefs"];
    NSDictionary *current = VLTCopyPrefs();
    for (NSString *key in current.allKeys) {
        if (!VLTProfileSkipsKey(key)) VLTMoreSet(key, nil);
    }
    gProfileBudget = 20000;
    [wanted enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if (VLTProfileKeyOK(key) && !VLTProfileSkipsKey(key) && VLTProfileValueOK(value, 0)) VLTMoreSet(key, value);
    }];
    for (NSString *counter in @[@"batImageGen", @"wallGen", @"iconGen"]) {
        long next = MAX((long)VLTNum(current, counter, 0), (long)VLTNum(wanted, counter, 0)) + 1;
        VLTMoreSet(counter, @([counter isEqualToString:@"batImageGen"] ? next % 256 : next));
    }
    VLTMoreCommit();
}

@implementation VLTProfilesController {
    NSMutableArray<NSDictionary *> *_profiles;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Profiles";
    self.view.tintColor = VLT_ACCENT;
    _profiles = [VLTProfiles() mutableCopy];
}

- (void)store {
    VLTSetProfiles(_profiles);
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 2 : _profiles.count; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return (section == 1 && _profiles.count) ? @"Saved" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"A profile is a copy of every Volta setting: battery, Control Center, dock, wallpaper, icons, status bar, Lock Screen, notifications and Fun. Save a few and switch between them in one tap.";
    return _profiles.count ? @"Tap a profile to apply, update, rename, share or delete it. Profiles stay put when Volta is updated or its settings are reset. A shared profile carries your battery picture and animation, but not videos, sounds, .tendies wallpapers or icon packs."
                           : @"Nothing saved yet.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (indexPath.section == 0) {
        BOOL save = indexPath.row == 0;
        BOOL enabled = !save || _profiles.count < VLT_MAX_PROFILES;
        cell.textLabel.text = save ? @"Save Current Setup…" : @"Import From Files…";
        cell.textLabel.textColor = enabled ? VLT_ACCENT : [UIColor tertiaryLabelColor];
        cell.imageView.image = [UIImage systemImageNamed:save ? @"square.and.arrow.down.fill" : @"folder.fill"];
        cell.imageView.tintColor = enabled ? VLT_ACCENT : [UIColor tertiaryLabelColor];
        return cell;
    }
    NSDictionary *profile = _profiles[indexPath.row];
    NSDictionary *prefs = profile[@"prefs"];
    cell.textLabel.text = [profile[@"name"] isKindOfClass:[NSString class]] && [profile[@"name"] length] ? profile[@"name"] : @"Untitled";
    NSString *when = @"";
    if ([profile[@"date"] isKindOfClass:[NSDate class]]) {
        when = [[NSDateFormatter localizedStringFromDate:profile[@"date"] dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle] stringByAppendingString:@" · "];
    }
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%lu setting%@", when, (unsigned long)prefs.count, prefs.count == 1 ? @"" : @"s"];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.image = [UIImage systemImageNamed:@"square.stack.3d.up.fill"];
    cell.imageView.tintColor = VLT_ACCENT;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)askForName:(NSString *)title initial:(NSString *)initial then:(void (^)(NSString *name))then {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = initial;
        field.placeholder = @"Name";
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *name = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length > 40) name = [name substringToIndex:40];
        then(name.length ? name : @"Untitled");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)anchor:(UIViewController *)sheet toRow:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    __weak typeof(self) weakSelf = self;
    if (indexPath.section == 0 && indexPath.row == 0) {
        if (_profiles.count >= VLT_MAX_PROFILES) {
            VLTMoreAlert(self, @"All Slots Used", [NSString stringWithFormat:@"Volta keeps up to %d profiles. Delete one to make room.", VLT_MAX_PROFILES]);
            return;
        }
        [self askForName:@"Save Current Setup" initial:[NSString stringWithFormat:@"Setup %lu", (unsigned long)_profiles.count + 1] then:^(NSString *name) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf->_profiles addObject:@{@"name": name, @"date": [NSDate date], @"prefs": VLTProfileSnapshot()}];
            [strongSelf store];
        }];
        return;
    }
    if (indexPath.section == 0) {
        // ".voltaprofile" has no registered type, so allow any file and check it afterwards.
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
        return;
    }

    NSInteger row = indexPath.row;
    if (row >= (NSInteger)_profiles.count) return;
    NSDictionary *profile = _profiles[row];
    NSString *name = [profile[@"name"] isKindOfClass:[NSString class]] ? profile[@"name"] : @"Untitled";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Apply" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        VLTProfileApply(profile);
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        UIAlertController *done = [UIAlertController alertControllerWithTitle:@"Profile Applied"
                                                                      message:@"Most things change right away. Rows and columns and silly app names need a respring."
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
        [done addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { notify_post(VLT_NOTIFY_RESPRING); }]];
        [strongSelf presentViewController:done animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Replace With Current Setup" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || row >= (NSInteger)strongSelf->_profiles.count) return;
        strongSelf->_profiles[row] = @{@"name": name, @"date": [NSDate date], @"prefs": VLTProfileSnapshot()};
        [strongSelf store];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf askForName:@"Rename Profile" initial:name then:^(NSString *newName) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || row >= (NSInteger)strongSelf->_profiles.count) return;
            NSMutableDictionary *renamed = [strongSelf->_profiles[row] mutableCopy];
            renamed[@"name"] = newName;
            strongSelf->_profiles[row] = renamed;
            [strongSelf store];
        }];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Share…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf shareProfile:profile fromRow:indexPath];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || row >= (NSInteger)strongSelf->_profiles.count) return;
        [strongSelf->_profiles removeObjectAtIndex:row];
        [strongSelf store];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self anchor:sheet toRow:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}

// Writes the profile to a ".voltaprofile" file and opens the share sheet.
- (void)shareProfile:(NSDictionary *)profile fromRow:(NSIndexPath *)indexPath {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
    [(NSDictionary *)profile[@"prefs"] enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if (VLTProfileKeyOK(key) && !VLTProfileKeyIsLocal(key) && !VLTProfileSkipsKey(key)) prefs[key] = value;
    }];
    NSString *name = [profile[@"name"] isKindOfClass:[NSString class]] && [profile[@"name"] length] ? profile[@"name"] : @"Untitled";
    NSDictionary *file = @{@"voltaProfile": @1, @"madeWith": @VLT_VERSION, @"name": name, @"prefs": prefs};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:file format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    NSMutableString *safe = [NSMutableString string];
    for (NSUInteger i = 0; i < name.length && safe.length < 40; i++) {
        unichar c = [name characterAtIndex:i];
        [safe appendString:[[NSCharacterSet alphanumericCharacterSet] characterIsMember:c] ? [NSString stringWithCharacters:&c length:1] : @"-"];
    }
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[(safe.length ? safe : @"Profile") stringByAppendingPathExtension:@"voltaprofile"]];
    if (!data || ![data writeToFile:path atomically:YES]) {
        VLTMoreAlert(self, @"Couldn't Share", @"Volta could not write the profile file.");
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    [self anchor:share toRow:indexPath];
    [self presentViewController:share animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    NSData *data = (size && size.unsignedLongLongValue <= VLT_PROFILE_MAX_BYTES) ? [NSData dataWithContentsOfURL:url] : nil;
    if (scoped) [url stopAccessingSecurityScopedResource];

    // Only plain property-list values are accepted, and only keys that look like Volta's.
    id file = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL] : nil;
    NSDictionary *incoming = [file isKindOfClass:[NSDictionary class]] ? file[@"prefs"] : nil;
    if (![file isKindOfClass:[NSDictionary class]] || ![file[@"voltaProfile"] isKindOfClass:[NSNumber class]] ||
        ![incoming isKindOfClass:[NSDictionary class]] || incoming.count > 600) {
        VLTMoreAlert(self, @"Not a Volta Profile", @"Choose a .voltaprofile file shared from Volta.");
        return;
    }
    if (_profiles.count >= VLT_MAX_PROFILES) {
        VLTMoreAlert(self, @"All Slots Used", [NSString stringWithFormat:@"Volta keeps up to %d profiles. Delete one to make room.", VLT_MAX_PROFILES]);
        return;
    }
    NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
    gProfileBudget = 20000;
    [incoming enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (VLTProfileKeyOK(key) && !VLTProfileKeyIsLocal(key) && !VLTProfileSkipsKey(key) && VLTProfileValueOK(value, 0)) prefs[key] = value;
    }];
    NSString *name = [file[@"name"] isKindOfClass:[NSString class]] && [file[@"name"] length] ? file[@"name"] : url.lastPathComponent.stringByDeletingPathExtension;
    if (name.length > 40) name = [name substringToIndex:40];
    [_profiles addObject:@{@"name": name.length ? name : @"Imported", @"date": [NSDate date], @"prefs": prefs}];
    [self store];
    VLTMoreAlert(self, @"Profile Imported", [NSString stringWithFormat:@"“%@” was added to your saved profiles. Tap it and choose Apply to use it.", name]);
}

@end
