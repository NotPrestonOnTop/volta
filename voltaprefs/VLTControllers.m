#import "VLTControllers.h"
#import "VLTViews.h"
#import "VLTPreviews.h"
#import "VLTScene.h"
#import "VLTUnzip.h"
#import "VLTCreator.h"
#import "VLTAbout.h"
#import "VLTMore.h"
#import "VLTShared.h"

@interface PSListController (VLTPrivate)
- (UITableView *)table;
- (id)cachedCellForSpecifier:(PSSpecifier *)specifier;
@end

// Every on/off effect on the Fun page.
static NSArray<NSString *> *VLTFunKeys(void) {
    return @[@"funWobble", @"funRainbowCards", @"funFlip", @"funSpinCards", @"funTinyCards",
             @"funDance", @"funHeartbeat", @"funSizes", @"funDiscoIcons", @"funSpinTap", @"funGravity",
             @"funSparkle", @"funTrail", @"funShake", @"funTapSounds",
             @"funEmojiRain", @"funDisco", @"funCracked", @"funEyes", @"funBuddy",
             @"funRainbowDock", @"funHopDock", @"funThrow",
             @"funStatusWiggle", @"funStatusBounce", @"funStatusPulse", @"funStatusFlip",
             @"funConfetti", @"funFortune", @"funWobbleCC", @"funDizzyClock"];
}

#pragma mark - Base

@implementation VLTBaseController {
    PSSpecifier *_pickingSpecifier;
    BOOL _pickerChanged;
    UIView *_headerView;
    BOOL _hasAppeared;
}

- (NSString *)plistName { return @"Root"; }
- (UIView *)makeHeaderView { return nil; }
- (CGFloat)headerHeightForWidth:(CGFloat)width { return 150; }
- (void)prefsDidChange {}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:[self plistName] target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.tintColor = VLT_ACCENT;
    [UISwitch appearanceWhenContainedInInstancesOfClasses:@[[VLTBaseController class]]].onTintColor = VLT_ACCENT;

    _headerView = [self makeHeaderView];
    if (_headerView) {
        CGFloat width = self.view.bounds.size.width;
        _headerView.frame = CGRectMake(0, 0, width, [self headerHeightForWidth:width]);
        [self table].tableHeaderView = _headerView;
    }
    [self table].keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UITableView *table = [self table];
    CGFloat width = table.bounds.size.width;
    CGFloat height = [self headerHeightForWidth:width];
    if (_headerView && (fabs(_headerView.frame.size.width - width) > 0.5 || fabs(_headerView.frame.size.height - height) > 0.5)) {
        _headerView.frame = CGRectMake(0, 0, width, height);
        table.tableHeaderView = _headerView;   // re-assign so the table re-measures it
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Coming back from a sub-page (a preset, a picker): show the new values.
    if (_hasAppeared) [self reloadSpecifiers];
    _hasAppeared = YES;
    [self prefsDidChange];
}

#pragma mark Storage

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return nil;
    id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(VLT_DOMAIN)));
    id fallback = [specifier propertyForKey:@"default"];
    // Rows only ever store numbers and text. Anything else (say, from an imported
    // profile that was edited by hand) is ignored rather than handed to a switch.
    BOOL number = [value isKindOfClass:[NSNumber class]], text = [value isKindOfClass:[NSString class]];
    if (value && !number && !text) value = nil;
    if (value && fallback && ((number && [fallback isKindOfClass:[NSString class]]) || (text && [fallback isKindOfClass:[NSNumber class]]))) value = nil;
    return value ?: fallback;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR(VLT_DOMAIN));
    CFPreferencesAppSynchronize(CFSTR(VLT_DOMAIN));
    notify_post(VLT_NOTIFY_PREFS);
    [self prefsDidChange];
}

#pragma mark Color rows

- (void)pickColor:(PSSpecifier *)specifier {
    _pickingSpecifier = specifier;
    UIColor *current = VLTColorFromHex([self readPreferenceValue:specifier]);
    if (!current) {
        [self presentPickerWithColor:nil];
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:specifier.name message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Choose Color…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf presentPickerWithColor:current];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Use Default" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf setPreferenceValue:nil specifier:specifier];
        [weakSelf reloadSpecifier:specifier];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIView *cell = [self respondsToSelector:@selector(cachedCellForSpecifier:)] ? [self cachedCellForSpecifier:specifier] : nil;
    UIView *anchor = [cell isKindOfClass:[UIView class]] ? cell : self.view;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentPickerWithColor:(UIColor *)color {
    UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
    picker.delegate = self;
    picker.supportsAlpha = YES;
    picker.title = _pickingSpecifier.name;
    if (color) picker.selectedColor = color;
    _pickerChanged = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)storePickedColor:(UIColor *)color {
    if (!_pickingSpecifier || !color) return;
    [self setPreferenceValue:VLTHexFromColor(color) specifier:_pickingSpecifier];
    [self reloadSpecifier:_pickingSpecifier];
}

- (void)colorPickerViewController:(UIColorPickerViewController *)picker didSelectColor:(UIColor *)color continuously:(BOOL)continuously {
    _pickerChanged = YES;
    if (!continuously) [self storePickedColor:color];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)picker {
    if (_pickerChanged) [self storePickedColor:picker.selectedColor];
    _pickingSpecifier = nil;
}

@end

#pragma mark - Root

@implementation VLTRootListController {
    VLTDashboardView *_dashboard;
}

- (NSString *)plistName { return @"Root"; }

- (UIView *)makeHeaderView {
    _dashboard = [[VLTDashboardView alloc] initWithFrame:CGRectZero];
    __weak typeof(self) weakSelf = self;
    _dashboard.onSelect = ^(NSInteger index) { [weakSelf openPage:index]; };
    return _dashboard;
}

- (CGFloat)headerHeightForWidth:(CGFloat)width {
    return [_dashboard heightForWidth:width];
}

- (void)openPage:(NSInteger)index {
    if (index == VLTPageAbout) {   // About and Profiles are plain pages, not settings lists
        [self.navigationController pushViewController:[[VLTAboutController alloc] init] animated:YES];
        return;
    }
    if (index == VLTPageProfiles) {
        [self.navigationController pushViewController:[[VLTProfilesController alloc] init] animated:YES];
        return;
    }
    NSDictionary<NSNumber *, Class> *pages = @{
        @(VLTPageBattery): [VLTBatteryController class], @(VLTPageStatus): [VLTStatusController class],
        @(VLTPageCC): [VLTCCController class], @(VLTPageHome): [VLTHomeController class],
        @(VLTPageIcons): [VLTIconsController class], @(VLTPageDock): [VLTDockController class],
        @(VLTPageWallpaper): [VLTWallpaperController class], @(VLTPageLock): [VLTLockController class],
        @(VLTPageNotif): [VLTNotifController class], @(VLTPageFun): [VLTFunController class],
    };
    Class pageClass = pages[@(index)];
    if (!pageClass) return;
    PSListController *page = [[pageClass alloc] init];
    page.rootController = self.rootController;
    page.parentController = self;
    if ([self respondsToSelector:@selector(showController:animate:)]) [self showController:page animate:YES];
    else [self.navigationController pushViewController:page animated:YES];
}

// One-line summary under each card title.
- (void)prefsDidChange {
    NSDictionary *p = VLTCopyPrefs();
    BOOL on = VLTBool(p, @"enabled", YES);
    NSString *off = @"Off";

    NSString *battery = @"Standard icon";
    int picture = (int)VLTNum(p, @"batImage", 0);
    if (picture == VLT_IMAGE_CUSTOM) battery = @"My picture";
    else if (picture >= 1 && picture <= VLT_THEME_COUNT) battery = [NSString stringWithUTF8String:kVLTThemes[picture - 1].name];
    else if (VLTBool(p, @"batColors", NO)) battery = @"Custom colors";
    else if (VLTBool(p, @"batFakeEnabled", NO)) battery = @"Fake percentage";
    [_dashboard setStatus:on ? battery : off atIndex:VLTPageBattery];

    [_dashboard setStatus:(on && VLTBool(p, @"ccEnabled", YES)) ? @"On" : off atIndex:VLTPageCC];
    [_dashboard setStatus:(on && VLTBool(p, @"dockEnabled", YES)) ? @"On" : off atIndex:VLTPageDock];
    [_dashboard setStatus:on ? [VLTSceneView nameForKind:(NSInteger)VLTNum(p, @"wallKind", 0)] : off atIndex:VLTPageWallpaper];
    NSInteger style = (NSInteger)VLTNum(p, @"slideStyle", 0);
    NSString *gesture = style == 1 ? @"Swipe up to unlock" : (style == 2 ? @"Slider + swipe up" : @"Slide to unlock");
    NSString *lock = (on && VLTBool(p, @"slideOn", NO)) ? gesture : ((on && VLTBool(p, @"lockLookOn", NO)) ? @"Custom clock" : off);
    [_dashboard setStatus:lock atIndex:VLTPageLock];

    // Status bar: the fake cutout wins the summary, then the clock.
    NSInteger cutout = (NSInteger)VLTNum(p, @"fakeCutout", 0);
    NSString *status = cutout == 1 ? @"Fake notch" : (cutout == 2 ? @"Fake Dynamic Island" : (VLTClockFormat(p) ? @"Custom clock" : @"Standard"));
    [_dashboard setStatus:on ? status : off atIndex:VLTPageStatus];
    [_dashboard setStatus:(on && VLTBool(p, @"homeOn", NO)) ? @"On" : off atIndex:VLTPageHome];
    NSArray *shapes = @[@"Themed", @"Circle", @"Hexagon", @"Octagon", @"Leaf", @"Star", @"Heart", @"Diamond"];
    NSInteger shape = (NSInteger)VLTNum(p, @"iconShape", 0);
    [_dashboard setStatus:(on && VLTBool(p, @"iconOn", NO)) ? shapes[(shape >= 0 && shape < (NSInteger)shapes.count) ? shape : 0] : off atIndex:VLTPageIcons];
    [_dashboard setStatus:(on && VLTBool(p, @"notifOn", NO)) ? @"On" : off atIndex:VLTPageNotif];
    NSInteger profiles = VLTProfileCount();
    [_dashboard setStatus:profiles ? [NSString stringWithFormat:@"%ld saved", (long)profiles] : @"None saved" atIndex:VLTPageProfiles];
    NSInteger funCount = 0;
    for (NSString *key in VLTFunKeys()) funCount += VLTBool(p, key, NO) ? 1 : 0;
    if ((NSInteger)VLTNum(p, @"funAngle", 0) > 0) funCount++;
    if ((NSInteger)VLTNum(p, @"funNames", 0) > 0) funCount++;
    [_dashboard setStatus:(on && funCount) ? [NSString stringWithFormat:@"%ld on", (long)funCount] : off atIndex:VLTPageFun];
    [_dashboard setStatus:[VLTUpdater updateAvailable] ? @"Update available" : [@"Version " stringByAppendingString:@VLT_VERSION] atIndex:VLTPageAbout];

    // Once a day, quietly look for a newer version (only if a link is set).
    __weak typeof(self) weakSelf = self;
    [VLTUpdater checkIfDueWithCompletion:^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf->_dashboard setStatus:[VLTUpdater updateAvailable] ? @"Update available" : [@"Version " stringByAppendingString:@VLT_VERSION] atIndex:VLTPageAbout];
    }];
}

- (void)respring:(PSSpecifier *)specifier {
    notify_post(VLT_NOTIFY_RESPRING);   // handled by the tweak inside SpringBoard
}

- (void)resetAll:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset All Settings?"
                                                                   message:@"Every Volta option goes back to its default."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        for (NSString *key in VLTCopyPrefs().allKeys) {
            CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, CFSTR(VLT_DOMAIN));
        }
        CFPreferencesAppSynchronize(CFSTR(VLT_DOMAIN));
        notify_post(VLT_NOTIFY_PREFS);
        [weakSelf reloadSpecifiers];
        [weakSelf prefsDidChange];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Battery

@implementation VLTBatteryController {
    VLTBatteryPreview *_preview;
}

- (NSString *)plistName { return @"Battery"; }

- (UIView *)makeHeaderView {
    _preview = [[VLTBatteryPreview alloc] initWithFrame:CGRectZero];
    return _preview;
}

- (void)prefsDidChange {
    _preview.prefs = VLTCopyPrefs();
}

- (void)openCreator:(PSSpecifier *)specifier {
    [self.navigationController pushViewController:[[VLTAnimCreatorController alloc] init] animated:YES];
}

#pragma mark Own picture

static void VLTSetPref(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR(VLT_DOMAIN));
}

- (void)choosePicture:(PSSpecifier *)specifier {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Photo Library" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.filter = [PHPickerFilter imagesFilter];
        config.selectionLimit = 1;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        picker.delegate = weakSelf;
        [weakSelf presentViewController:picker animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Files" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage] asCopy:YES];
        picker.delegate = weakSelf;
        [weakSelf presentViewController:picker animated:YES completion:nil];
    }]];
    BOOL hasPicture = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("batImageData"), CFSTR(VLT_DOMAIN))) != nil;
    if (hasPicture) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove My Picture" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [weakSelf storePicture:nil];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIView *cell = [self respondsToSelector:@selector(cachedCellForSpecifier:)] ? [self cachedCellForSpecifier:specifier] : nil;
    UIView *anchor = [cell isKindOfClass:[UIView class]] ? cell : self.view;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// Saves a small copy (the status bar never needs more than ~130 pixels) and
// switches the Picture setting to it. nil removes the picture.
- (void)storePicture:(UIImage *)image {
    NSDictionary *prefs = VLTCopyPrefs();
    if (image) {
        CGFloat longest = MAX(image.size.width, image.size.height);
        CGFloat k = longest > 0 ? MIN(1.0, 144.0 / longest) : 1.0;
        CGSize size = CGSizeMake(MAX(1, round(image.size.width * k)), MAX(1, round(image.size.height * k)));
        UIImage *small = [VLTRenderer(size, 1) imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
        }];
        NSData *png = UIImagePNGRepresentation(small);
        if (!png) return;
        VLTSetPref(@"batImageData", png);
        VLTSetPref(@"batImage", @(VLT_IMAGE_CUSTOM));
    } else {
        VLTSetPref(@"batImageData", nil);
        if ((int)VLTNum(prefs, @"batImage", 0) == VLT_IMAGE_CUSTOM) VLTSetPref(@"batImage", @(VLT_IMAGE_NONE));
    }
    VLTSetPref(@"batImageGen", @(((long)VLTNum(prefs, @"batImageGen", 0) + 1) % 256));
    CFPreferencesAppSynchronize(CFSTR(VLT_DOMAIN));
    notify_post(VLT_NOTIFY_PREFS);
    [self reloadSpecifiers];
    [self prefsDidChange];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSItemProvider *provider = results.firstObject.itemProvider;
    if (![provider canLoadObjectOfClass:[UIImage class]]) return;
    __weak typeof(self) weakSelf = self;
    [provider loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
        if (![(id)object isKindOfClass:[UIImage class]]) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf storePicture:(UIImage *)object]; });
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (scoped) [url stopAccessingSecurityScopedResource];
    UIImage *image = data ? [UIImage imageWithData:data] : nil;
    if (image) [self storePicture:image];
}

@end

#pragma mark - Control Center

@implementation VLTCCController {
    VLTCCPreview *_preview;
}

- (NSString *)plistName { return @"ControlCenter"; }

- (UIView *)makeHeaderView {
    _preview = [[VLTCCPreview alloc] initWithFrame:CGRectZero];
    return _preview;
}

- (void)prefsDidChange {
    _preview.prefs = VLTCopyPrefs();
}

@end

#pragma mark - Dock

@implementation VLTDockController {
    VLTDockPreview *_preview;
}

- (NSString *)plistName { return @"Dock"; }

- (UIView *)makeHeaderView {
    _preview = [[VLTDockPreview alloc] initWithFrame:CGRectZero];
    return _preview;
}

- (void)prefsDidChange {
    _preview.prefs = VLTCopyPrefs();
}

@end

#pragma mark - Wallpaper

@implementation VLTWallpaperController {
    VLTWallpaperPreview *_preview;
    NSInteger _pickMode;    // what the Files picker was opened for: 0 video, 1 .tendies, 2 sound
}

- (NSString *)plistName { return @"Wallpaper"; }

- (UIView *)makeHeaderView {
    _preview = [[VLTWallpaperPreview alloc] initWithFrame:CGRectZero];
    return _preview;
}

- (CGFloat)headerHeightForWidth:(CGFloat)width { return 330; }

- (void)prefsDidChange {
    _preview.prefs = VLTCopyPrefs();
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _preview.paused = NO;
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    _preview.paused = YES;   // no need to animate off screen
}

#pragma mark Own video

- (void)chooseVideo:(PSSpecifier *)specifier {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Photo Library" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.filter = [PHPickerFilter videosFilter];
        config.selectionLimit = 1;
        config.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        picker.delegate = weakSelf;
        [weakSelf presentViewController:picker animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Files" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf) strongSelf->_pickMode = 0;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeMovie] asCopy:YES];
        picker.delegate = weakSelf;
        [weakSelf presentViewController:picker animated:YES completion:nil];
    }]];
    NSString *current = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("wallVideoPath"), CFSTR(VLT_DOMAIN)));
    if ([current isKindOfClass:[NSString class]] && current.length) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove My Video" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [[NSFileManager defaultManager] removeItemAtPath:current error:NULL];
            [weakSelf finishVideoWithPath:nil];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIView *cell = [self respondsToSelector:@selector(cachedCellForSpecifier:)] ? [self cachedCellForSpecifier:specifier] : nil;
    UIView *anchor = [cell isKindOfClass:[UIView class]] ? cell : self.view;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// Copies the video to a folder SpringBoard can read. Returns the new path.
static NSString *VLTStoreVideo(NSURL *source) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *extension = source.pathExtension.length ? source.pathExtension.lowercaseString : @"mov";
    for (NSString *folder in @[VLT_IMAGE_DIR, @"/var/mobile/Library/Volta"]) {
        [files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
        for (NSString *name in [files contentsOfDirectoryAtPath:folder error:NULL]) {
            if ([name hasPrefix:@"wallpaper."]) [files removeItemAtPath:[folder stringByAppendingPathComponent:name] error:NULL];
        }
        NSString *destination = [folder stringByAppendingPathComponent:[@"wallpaper." stringByAppendingString:extension]];
        if ([files copyItemAtPath:source.path toPath:destination error:NULL]) return destination;
    }
    return nil;
}

- (void)finishVideoWithPath:(NSString *)path {
    NSDictionary *prefs = VLTCopyPrefs();
    CFStringRef domain = CFSTR(VLT_DOMAIN);
    CFPreferencesSetAppValue(CFSTR("wallVideoPath"), (__bridge CFPropertyListRef)path, domain);
    if (path) {
        CFPreferencesSetAppValue(CFSTR("wallKind"), (__bridge CFPropertyListRef)@(VLTSceneVideo), domain);
    } else if ((NSInteger)VLTNum(prefs, @"wallKind", 0) == VLTSceneVideo) {
        CFPreferencesSetAppValue(CFSTR("wallKind"), (__bridge CFPropertyListRef)@(VLTSceneNone), domain);
    }
    CFPreferencesSetAppValue(CFSTR("wallGen"), (__bridge CFPropertyListRef)@((long)VLTNum(prefs, @"wallGen", 0) + 1), domain);
    CFPreferencesAppSynchronize(domain);
    notify_post(VLT_NOTIFY_PREFS);
    [self reloadSpecifiers];
    [self prefsDidChange];
}

- (void)videoCopyFailed {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't Save Video"
                                                                   message:@"Volta could not copy that video. Try a different one, or pick it from Files."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handlePickedVideo:(NSURL *)url {
    NSString *path = url ? VLTStoreVideo(url) : nil;   // must run before the picker's temporary file goes away
    dispatch_async(dispatch_get_main_queue(), ^{
        if (path) [self finishVideoWithPath:path];
        else [self videoCopyFailed];
    });
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSItemProvider *provider = results.firstObject.itemProvider;
    if (!provider) return;
    __weak typeof(self) weakSelf = self;
    [provider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *url, NSError *error) {
        [weakSelf handlePickedVideo:url];
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    if (_pickMode == 1) {
        [self handlePickedTendies:url];
        return;
    }
    if (_pickMode == 2) {
        [self handlePickedSound:url];
        return;
    }
    BOOL scoped = [url startAccessingSecurityScopedResource];
    [self handlePickedVideo:url];
    if (scoped) [url stopAccessingSecurityScopedResource];
}

#pragma mark Own sound

- (void)chooseSound:(PSSpecifier *)specifier {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Choose From Files" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_pickMode = 2;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeAudio] asCopy:YES];
        picker.delegate = strongSelf;
        [strongSelf presentViewController:picker animated:YES completion:nil];
    }]];
    NSString *current = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("wallAudioPath"), CFSTR(VLT_DOMAIN)));
    if ([current isKindOfClass:[NSString class]] && current.length) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove Sound File" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [[NSFileManager defaultManager] removeItemAtPath:current error:NULL];
            [weakSelf finishSoundWithPath:nil];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIView *cell = [self respondsToSelector:@selector(cachedCellForSpecifier:)] ? [self cachedCellForSpecifier:specifier] : nil;
    UIView *anchor = [cell isKindOfClass:[UIView class]] ? cell : self.view;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)finishSoundWithPath:(NSString *)path {
    NSDictionary *prefs = VLTCopyPrefs();
    CFStringRef domain = CFSTR(VLT_DOMAIN);
    CFPreferencesSetAppValue(CFSTR("wallAudioPath"), (__bridge CFPropertyListRef)path, domain);
    // A fresh sound file at volume 0 would be confusing; start it at a gentle 20.
    if (path && VLTNum(prefs, @"wallVolume", 0) < 1) CFPreferencesSetAppValue(CFSTR("wallVolume"), (__bridge CFPropertyListRef)@20, domain);
    CFPreferencesAppSynchronize(domain);
    notify_post(VLT_NOTIFY_PREFS);
    [self reloadSpecifiers];
    [self prefsDidChange];
}

- (void)handlePickedSound:(NSURL *)url {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *extension = url.pathExtension.length ? url.pathExtension.lowercaseString : @"mp3";
    NSString *stored = nil;
    for (NSString *folder in @[VLT_IMAGE_DIR, @"/var/mobile/Library/Volta"]) {
        [files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
        for (NSString *name in [files contentsOfDirectoryAtPath:folder error:NULL]) {
            if ([name hasPrefix:@"sound."]) [files removeItemAtPath:[folder stringByAppendingPathComponent:name] error:NULL];
        }
        NSString *destination = [folder stringByAppendingPathComponent:[@"sound." stringByAppendingString:extension]];
        if ([files copyItemAtPath:url.path toPath:destination error:NULL]) { stored = destination; break; }
    }
    if (stored) [self finishSoundWithPath:stored];
    else [self showMessage:@"Volta could not copy that sound file." title:@"Couldn't Save Sound"];
}

#pragma mark .tendies

- (void)importTendies:(PSSpecifier *)specifier {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Choose From Files" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_pickMode = 1;
        // ".tendies" has no registered type, so allow any file and check it afterwards.
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
        picker.delegate = strongSelf;
        [strongSelf presentViewController:picker animated:YES completion:nil];
    }]];
    NSString *current = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("wallTendiesPath"), CFSTR(VLT_DOMAIN)));
    if ([current isKindOfClass:[NSString class]] && current.length) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove Tendies Wallpaper" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [[NSFileManager defaultManager] removeItemAtPath:current error:NULL];
            [weakSelf finishTendiesWithPath:nil];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIView *cell = [self respondsToSelector:@selector(cachedCellForSpecifier:)] ? [self cachedCellForSpecifier:specifier] : nil;
    UIView *anchor = [cell isKindOfClass:[UIView class]] ? cell : self.view;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)finishTendiesWithPath:(NSString *)path {
    NSDictionary *prefs = VLTCopyPrefs();
    CFStringRef domain = CFSTR(VLT_DOMAIN);
    CFPreferencesSetAppValue(CFSTR("wallTendiesPath"), (__bridge CFPropertyListRef)path, domain);
    if (path) {
        CFPreferencesSetAppValue(CFSTR("wallKind"), (__bridge CFPropertyListRef)@(VLTSceneTendies), domain);
    } else if ((NSInteger)VLTNum(prefs, @"wallKind", 0) == VLTSceneTendies) {
        CFPreferencesSetAppValue(CFSTR("wallKind"), (__bridge CFPropertyListRef)@(VLTSceneNone), domain);
    }
    CFPreferencesSetAppValue(CFSTR("wallGen"), (__bridge CFPropertyListRef)@((long)VLTNum(prefs, @"wallGen", 0) + 1), domain);
    CFPreferencesAppSynchronize(domain);
    notify_post(VLT_NOTIFY_PREFS);
    [self reloadSpecifiers];
    [self prefsDidChange];
}

- (void)showMessage:(NSString *)message title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// A .tendies file is a zip. Unpack it where SpringBoard can read it, then
// see what is inside: Core Animation packages, or just a video.
- (void)handlePickedTendies:(NSURL *)url {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *files = [NSFileManager defaultManager];
        NSString *unpacked = nil;
        int result = VLTUnzipErrWrite;
        for (NSString *folder in @[VLT_IMAGE_DIR, @"/var/mobile/Library/Volta"]) {
            [files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
            NSString *destination = [folder stringByAppendingPathComponent:@"tendies"];
            [files removeItemAtPath:destination error:NULL];
            result = vlt_unzip(url.fileSystemRepresentation, destination.fileSystemRepresentation);
            if (result > 0) { unpacked = destination; break; }
            [files removeItemAtPath:destination error:NULL];
            if (result != VLTUnzipErrWrite) break;   // the file itself is the problem; another folder will not help
        }
        NSArray *packages = unpacked ? [VLTSceneView packagePathsInFolder:unpacked] : @[];
        NSString *video = unpacked ? [VLTSceneView videoPathInFolder:unpacked] : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (packages.count) {
                [strongSelf finishTendiesWithPath:unpacked];
            } else if (video) {
                [strongSelf finishVideoWithPath:video];
                [strongSelf showMessage:@"This file holds a video wallpaper, so it was set as My Video." title:@"Video Tendies"];
            } else if (result == VLTUnzipErrWrite) {
                [strongSelf showMessage:@"Volta could not save the unpacked wallpaper." title:@"Couldn't Import"];
            } else if (result == VLTUnzipErrTooBig) {
                [strongSelf showMessage:@"That file is larger than Volta will unpack (600 MB)." title:@"Couldn't Import"];
            } else if (result <= 0) {
                [strongSelf showMessage:@"That doesn't look like a .tendies file." title:@"Couldn't Import"];
            } else {
                [strongSelf showMessage:@"The file opened, but there is no animated wallpaper inside that Volta can show." title:@"Couldn't Import"];
            }
        });
    });
}

@end

#pragma mark - Fun

@implementation VLTFunController

- (NSString *)plistName { return @"Fun"; }

- (UIView *)makeHeaderView { return [[VLTFunHeader alloc] initWithFrame:CGRectZero]; }

- (void)setEverything:(BOOL)on {
    for (NSString *key in VLTFunKeys())
        CFPreferencesSetAppValue((__bridge CFStringRef)key, on ? kCFBooleanTrue : kCFBooleanFalse, CFSTR(VLT_DOMAIN));
    CFPreferencesSetAppValue(CFSTR("funAngle"), (__bridge CFPropertyListRef)@(on ? 1 : 0), CFSTR(VLT_DOMAIN));
    if (!on) CFPreferencesSetAppValue(CFSTR("funNames"), (__bridge CFPropertyListRef)@0, CFSTR(VLT_DOMAIN));
    CFPreferencesAppSynchronize(CFSTR(VLT_DOMAIN));
    notify_post(VLT_NOTIFY_PREFS);
    [self reloadSpecifiers];
}

- (void)say:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)chaosMode:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Unleash Chaos?"
                                                                   message:@"Every effect on this page gets switched on at once. Calm Down undoes it."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Do It" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf setEverything:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)calmDown:(PSSpecifier *)specifier {
    [self setEverything:NO];
}

- (void)explodeIcons:(PSSpecifier *)specifier {
    notify_post(VLT_DOMAIN "/explode");
    [self say:@"Armed 💥" message:@"Go to the Home Screen and touch anywhere."];
}

- (void)respring:(PSSpecifier *)specifier {
    notify_post(VLT_NOTIFY_RESPRING);
}

@end

#pragma mark - Lock Screen

@implementation VLTLockController {
    VLTLockPreview *_preview;
}

- (NSString *)plistName { return @"Lock"; }

- (UIView *)makeHeaderView {
    _preview = [[VLTLockPreview alloc] initWithFrame:CGRectZero];
    return _preview;
}

- (void)prefsDidChange {
    _preview.prefs = VLTCopyPrefs();
}

@end
