// Volta - Home Screen layout and icon themes (SpringBoard only).
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import "VLTShared.h"
#import "VLTLook.h"
#import "VLTIconTheme.h"

@interface SBIcon : NSObject
- (NSString *)applicationBundleID;
- (BOOL)isFolderIcon;
- (BOOL)isWidgetIcon;
@end

@interface SBIconView : UIView
@property (nonatomic, copy) NSString *location;
@property (nonatomic) CGFloat iconLabelAlpha;
@end

@interface SBIconImageView : UIView
- (SBIcon *)icon;
- (void)updateImageAnimated:(BOOL)animated;
- (UIImage *)contentsImage;
@end

@interface SBIconListGridLayoutConfiguration : NSObject
@property (nonatomic) NSUInteger numberOfPortraitRows;
@property (nonatomic) NSUInteger numberOfPortraitColumns;
@property (nonatomic) NSUInteger numberOfLandscapeRows;
@property (nonatomic) NSUInteger numberOfLandscapeColumns;
@end

#pragma mark - Settings

static BOOL gOn;                // master switch
// Layout
static BOOL gHomeOn;
static CGFloat gIconScale = 1;  // 0.5 ... 1.5
static BOOL gHideLabels, gHideDots;
static NSInteger gRows, gCols, gRowsL, gColsL;   // 0 = leave alone; read once, at launch
// Theme
static VLTIconStyle gStyle;
static BOOL gPackOn;
static NSString *gPackDir;      // one of the two known folders
static NSInteger gThemeGen;     // bumped whenever the look of icons changes
static BOOL gThemeChanged;

static void VLTLoadIconPrefs(BOOL launch) {
    NSDictionary *p = VLTCopyPrefs();
    gOn = VLTBool(p, @"enabled", YES);
    gHomeOn = gOn && VLTBool(p, @"homeOn", NO);
    gIconScale = fmin(fmax(VLTNum(p, @"homeIconScale", 100) / 100.0, 0.5), 1.5);
    gHideLabels = gHomeOn && VLTBool(p, @"homeHideLabels", NO);
    gHideDots = gHomeOn && VLTBool(p, @"homeHideDots", NO);
    if (launch && gHomeOn && VLTBool(p, @"homeGridOn", NO)) {
        #define GRID(key) ({ NSInteger v = (NSInteger)VLTNum(p, key, 0); (v >= 2 && v <= 12) ? v : 0; })
        gRows = GRID(@"homeRows");  gCols = GRID(@"homeCols");
        gRowsL = GRID(@"homeRowsL");  gColsL = GRID(@"homeColsL");
        #undef GRID
    }
    gStyle = VLTIconStyleFromPrefs(p);
    gPackOn = gOn && VLTBool(p, @"iconOn", NO) && VLTBool(p, @"iconPackOn", YES);
    gPackDir = [VLTStr(p, @"iconDir") isEqualToString:VLT_ICONS_DIR_ALT] ? VLT_ICONS_DIR_ALT : VLT_ICONS_DIR;
    // Only re-draw icons when something about their look really changed.
    static NSString *lastLook;
    NSString *look = [NSString stringWithFormat:@"%d-%u-%.3f-%d-%d-%ld", gStyle.tintMode, gStyle.tint, gStyle.strength, gStyle.shape,
                      gPackOn, (long)VLTNum(p, @"iconGen", 0)];
    gThemeChanged = ![look isEqualToString:lastLook];
    if (gThemeChanged) gThemeGen++;
    lastLook = look;
}

static NSHashTable *VLTIconTable(int which) {
    static NSHashTable *tables[3];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ for (int i = 0; i < 3; i++) tables[i] = [NSHashTable weakObjectsHashTable]; });
    return tables[which];
}
#define VLTIconViews()   VLTIconTable(0)
#define VLTImageViews()  VLTIconTable(1)
#define VLTPageDots()    VLTIconTable(2)

#pragma mark - Layout: size, labels, page dots

// Home Screen pages, the dock and folders; not the App Library or search.
static BOOL VLTIsHomeIcon(UIView *iconView) {
    NSString *location = [iconView respondsToSelector:@selector(location)] ? [(SBIconView *)iconView location] : nil;
    if (![location isKindOfClass:[NSString class]]) return NO;
    return [location hasPrefix:@"SBIconLocationRoot"] || [location containsString:@"Dock"] || [location containsString:@"Folder"];
}

static void VLTApplyIconLayout(UIView *iconView) {
    BOOL home = VLTIsHomeIcon(iconView);
    VLTPinOffset(iconView.layer, @"vltIconSize", @"transform.scale", gHomeOn && home, gIconScale - 1);
}

static const void *kDotsMask = &kDotsMask;

static void VLTRefreshIconLayout(void) {
    static BOOL lastHideLabels;
    BOOL labelsChanged = lastHideLabels != gHideLabels;
    lastHideLabels = gHideLabels;
    for (SBIconView *iconView in VLTIconViews().allObjects) {
        VLTApplyIconLayout(iconView);
        if (labelsChanged && VLTIsHomeIcon(iconView) && [iconView respondsToSelector:@selector(setIconLabelAlpha:)])
            [iconView setIconLabelAlpha:1];   // goes through the hook below, which turns it into 0 while hiding
    }
    for (UIView *dots in VLTPageDots().allObjects) VLTSetMasked(dots, gHideDots, kDotsMask);
}

#pragma mark - Theme

static const void *kThemed = &kThemed;        // on the system's image: @[generation, themed image or NSNull]
static const void *kThemedMark = &kThemedMark; // on images we made, so they are never themed twice

static UIImage *VLTPackArtwork(NSString *bundleID) {
    static NSCache *cache;
    static NSInteger cacheGen = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 400; });
    if (!gPackOn || bundleID.length == 0 || bundleID.length > 200 || [bundleID containsString:@"/"]) return nil;
    if (cacheGen != gThemeGen) {
        [cache removeAllObjects];
        cacheGen = gThemeGen;
    }
    id cached = [cache objectForKey:bundleID];
    if (cached) return cached == [NSNull null] ? nil : cached;
    NSString *path = [[gPackDir stringByAppendingPathComponent:bundleID] stringByAppendingPathExtension:@"png"];
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (image && (image.size.width < 8 || image.size.height < 8)) image = nil;
    [cache setObject:image ?: (id)[NSNull null] forKey:bundleID];
    return image;
}

// The themed version of an icon picture, or nil to leave it alone.
static UIImage *VLTThemedImage(UIView *imageView, UIImage *image) {
    if (![image isKindOfClass:[UIImage class]]) return nil;
    if (objc_getAssociatedObject(image, kThemedMark)) return nil;
    if (!gPackOn && VLTIconStyleIsPlain(gStyle)) return nil;

    NSArray *entry = objc_getAssociatedObject(image, kThemed);
    if (entry.count == 2 && [entry[0] integerValue] == gThemeGen) return entry[1] == [NSNull null] ? nil : entry[1];

    UIImage *themed = nil;
    SBIcon *icon = [imageView respondsToSelector:@selector(icon)] ? [(SBIconImageView *)imageView icon] : nil;
    BOOL folder = [icon respondsToSelector:@selector(isFolderIcon)] && [icon isFolderIcon];
    BOOL widget = [icon respondsToSelector:@selector(isWidgetIcon)] && [icon isWidgetIcon];
    if (icon && !folder && !widget) {
        NSString *bundleID = [icon respondsToSelector:@selector(applicationBundleID)] ? [icon applicationBundleID] : nil;
        UIImage *artwork = [bundleID isKindOfClass:[NSString class]] ? VLTPackArtwork(bundleID) : nil;
        themed = VLTIconRender(image, artwork, gStyle);
        if (themed) objc_setAssociatedObject(themed, kThemedMark, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(image, kThemed, @[@(gThemeGen), themed ?: (id)[NSNull null]], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return themed;
}

static void VLTRefreshTheme(void) {
    for (SBIconImageView *imageView in VLTImageViews().allObjects) {
        if (imageView.window && [imageView respondsToSelector:@selector(updateImageAnimated:)]) [imageView updateImageAnimated:NO];
    }
}

#pragma mark - Hooks

%group IconLook

%hook SBIconView

- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window) return;
    [VLTIconViews() addObject:self];
    VLTApplyIconLayout((UIView *)self);
    if (gHideLabels && VLTIsHomeIcon((UIView *)self) && [self respondsToSelector:@selector(setIconLabelAlpha:)]) [self setIconLabelAlpha:0];
}

- (void)layoutSubviews {
    %orig;
    VLTApplyIconLayout((UIView *)self);
}

- (void)setLocation:(NSString *)location {
    %orig;
    VLTApplyIconLayout((UIView *)self);
    if (gHideLabels && VLTIsHomeIcon((UIView *)self) && [self respondsToSelector:@selector(setIconLabelAlpha:)]) [self setIconLabelAlpha:0];
}

- (void)setIconLabelAlpha:(CGFloat)alpha {
    if (gHideLabels && VLTIsHomeIcon((UIView *)self)) alpha = 0;
    %orig(alpha);
}

%end

%hook SBIconListPageControl

- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window) return;
    [VLTPageDots() addObject:self];
    VLTSetMasked((UIView *)self, gHideDots, kDotsMask);
}

%end

%hook SBIconImageView

- (id)contentsImage {
    UIImage *image = %orig;
    UIImage *themed = VLTThemedImage((UIView *)self, image);
    return themed ?: image;
}

- (void)updateImageAnimated:(BOOL)animated {
    %orig;
    if (((UIView *)self).window) [VLTImageViews() addObject:self];
    // Belt and braces: if the picture reached the layer some other way, swap it there too.
    if (!gPackOn && VLTIconStyleIsPlain(gStyle)) return;
    UIImage *image = [self respondsToSelector:@selector(contentsImage)] ? [self contentsImage] : nil;
    if (![image isKindOfClass:[UIImage class]] || !objc_getAssociatedObject(image, kThemedMark) || !image.CGImage) return;
    CALayer *layer = ((UIView *)self).layer;
    id contents = layer.contents;
    if (contents && CFGetTypeID((__bridge CFTypeRef)contents) == CGImageGetTypeID() && contents != (__bridge id)image.CGImage)
        layer.contents = (__bridge id)image.CGImage;
}

- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) [VLTImageViews() addObject:self];
}

%end

%end // group IconLook

%group IconGrid

// Rows and columns of the Home Screen pages. The numbers are baked into the
// layout when SpringBoard starts, so changes need a respring.
%hook SBHDefaultIconListLayoutProvider

- (id)makeLayoutForIconLocation:(NSString *)location {
    id layout = %orig;
    if (!layout || ![location isKindOfClass:[NSString class]] || ![location hasPrefix:@"SBIconLocationRoot"]) return layout;
    Ivar ivar = class_getInstanceVariable(object_getClass(layout), "_layoutConfiguration");
    if (!ivar) return layout;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return layout;
    SBIconListGridLayoutConfiguration *config = object_getIvar(layout, ivar);
    if (![config respondsToSelector:@selector(setNumberOfPortraitRows:)] ||
        ![config respondsToSelector:@selector(setNumberOfLandscapeColumns:)]) return layout;
    if (gRows)  config.numberOfPortraitRows = (NSUInteger)gRows;
    if (gCols)  config.numberOfPortraitColumns = (NSUInteger)gCols;
    if (gRowsL) config.numberOfLandscapeRows = (NSUInteger)gRowsL;
    if (gColsL) config.numberOfLandscapeColumns = (NSUInteger)gColsL;
    return layout;
}

%end

%end // group IconGrid

static void VLTIconPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VLTLoadIconPrefs(NO);
        VLTRefreshIconLayout();
        if (gThemeChanged) VLTRefreshTheme();
    });
}

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        VLTLoadIconPrefs(YES);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, VLTIconPrefsChanged,
                                        CFSTR(VLT_NOTIFY_PREFS), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        %init(IconLook);
        if (gRows || gCols || gRowsL || gColsL) %init(IconGrid);
    }
}
