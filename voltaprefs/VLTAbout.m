#import "VLTAbout.h"
#import "VLTViews.h"
#import "VLTShared.h"
#import "VLTScene.h"

#define HEX(v) [UIColor colorWithRed:(((v) >> 16) & 0xFF) / 255.0 green:(((v) >> 8) & 0xFF) / 255.0 blue:((v) & 0xFF) / 255.0 alpha:1]

static UIFont *VLTAboutRounded(CGFloat size, UIFontWeight weight) {
    UIFont *font = [UIFont systemFontOfSize:size weight:weight];
    UIFontDescriptor *rounded = [font.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    return rounded ? [UIFont fontWithDescriptor:rounded size:size] : font;
}

static id VLTAboutPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(VLT_DOMAIN)));
}

static void VLTAboutSetPref(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR(VLT_DOMAIN));
}

#pragma mark - Updater

// The feed is a small JSON file you host anywhere that serves it over https:
//   { "version": "2.3.0", "notes": "What changed", "url": "https://link-to-the-download" }
// A plain text file containing only a version number works too.
@implementation VLTUpdater

+ (NSString *)feedURLString {
    NSString *text = VLTAboutPref(@"updateFeedURL");
    text = [text isKindOfClass:[NSString class]] ? [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
    return text.length ? text : nil;
}

+ (NSString *)latestVersion {
    NSString *latest = VLTAboutPref(@"updateLatest");
    return [latest isKindOfClass:[NSString class]] && latest.length ? latest : nil;
}

+ (BOOL)isVersion:(NSString *)a newerThan:(NSString *)b {
    return [a compare:b options:NSNumericSearch] == NSOrderedDescending;
}

+ (BOOL)updateAvailable {
    NSString *latest = [self latestVersion];
    return latest && [self feedURLString] && [self isVersion:latest newerThan:@VLT_VERSION];
}

+ (void)checkWithCompletion:(void (^)(BOOL, NSString *))completion {
    void (^finish)(BOOL, NSString *) = ^(BOOL ok, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(ok, message); });
    };
    NSString *text = [self feedURLString];
    NSURL *url = text ? [NSURL URLWithString:text] : nil;
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"]) {
        finish(NO, text ? @"The update link has to start with https://" : @"No update link is set yet.");
        return;
    }
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 12;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        [session finishTasksAndInvalidate];
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (error || !data.length || status >= 400) {
            finish(NO, error ? error.localizedDescription : [NSString stringWithFormat:@"The update link answered with an error (%ld).", (long)status]);
            return;
        }
        NSString *version = nil, *notes = nil, *link = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([json isKindOfClass:[NSDictionary class]]) {
            version = [json[@"version"] isKindOfClass:[NSString class]] ? json[@"version"] : [json[@"version"] description];
            notes = [json[@"notes"] isKindOfClass:[NSString class]] ? json[@"notes"] : nil;
            link = [json[@"url"] isKindOfClass:[NSString class]] ? json[@"url"] : nil;
        } else if (data.length < 64) {
            version = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        // A version looks like digits and dots; anything else is not a feed.
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789."];
        if (!version.length || version.length > 20 || [version rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) {
            finish(NO, @"That link does not contain a version number Volta can read.");
            return;
        }
        VLTAboutSetPref(@"updateLatest", version);
        VLTAboutSetPref(@"updateNotes", notes);
        VLTAboutSetPref(@"updateLink", link);
        VLTAboutSetPref(@"updateChecked", [NSDate date]);
        CFPreferencesAppSynchronize(CFSTR(VLT_DOMAIN));
        if ([self isVersion:version newerThan:@VLT_VERSION]) {
            finish(YES, [NSString stringWithFormat:@"Version %@ is available.%@", version, notes.length ? [@"\n\n" stringByAppendingString:notes] : @""]);
        } else {
            finish(YES, [NSString stringWithFormat:@"You have the latest version (%@).", @VLT_VERSION]);
        }
    }] resume];
}

+ (void)checkIfDueWithCompletion:(void (^)(void))completion {
    if (![self feedURLString]) return;
    NSDate *last = VLTAboutPref(@"updateChecked");
    if ([last isKindOfClass:[NSDate class]] && fabs(last.timeIntervalSinceNow) < 24 * 60 * 60) return;
    [self checkWithCompletion:^(BOOL ok, NSString *message) { if (completion) completion(); }];
}

@end

#pragma mark - Card pieces

// A white rounded card holding a title and a stack of rows.
static UIView *VLTAboutCard(NSString *title, NSArray<UIView *> *rows) {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 22;
    card.layer.cornerCurve = kCACornerCurveContinuous;

    UILabel *heading = [[UILabel alloc] init];
    heading.text = title.uppercaseString;
    heading.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    heading.textColor = [UIColor secondaryLabelColor];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:[@[heading] arrayByAddingObjectsFromArray:rows]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
    ]];
    return card;
}

// Gradient tile with a symbol, then a name and what they did.
static UIView *VLTAboutPerson(NSString *symbol, UIColor *from, UIColor *to, NSString *name, NSString *role) {
    UIView *tile = [[UIView alloc] init];
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    tile.layer.cornerRadius = 13;
    tile.layer.cornerCurve = kCACornerCurveContinuous;
    tile.clipsToBounds = YES;
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.frame = CGRectMake(0, 0, 46, 46);
    gradient.colors = @[(id)from.CGColor, (id)to.CGColor];
    gradient.startPoint = CGPointMake(0, 0);
    gradient.endPoint = CGPointMake(1, 1);
    [tile.layer addSublayer:gradient];
    UIImageView *glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold]]];
    glyph.tintColor = [UIColor whiteColor];
    glyph.contentMode = UIViewContentModeCenter;
    glyph.frame = CGRectMake(0, 0, 46, 46);
    [tile addSubview:glyph];

    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.text = name;
    nameLabel.font = VLTAboutRounded(18, UIFontWeightSemibold);
    UILabel *roleLabel = [[UILabel alloc] init];
    roleLabel.text = role;
    roleLabel.font = [UIFont systemFontOfSize:14];
    roleLabel.textColor = [UIColor secondaryLabelColor];
    roleLabel.numberOfLines = 0;
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[nameLabel, roleLabel]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 2;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[tile, text]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 14;
    row.alignment = UIStackViewAlignmentCenter;
    [NSLayoutConstraint activateConstraints:@[[tile.widthAnchor constraintEqualToConstant:46], [tile.heightAnchor constraintEqualToConstant:46]]];
    row.isAccessibilityElement = YES;
    row.accessibilityLabel = [NSString stringWithFormat:@"%@. %@", name, role];
    return row;
}

static UILabel *VLTAboutText(NSString *text, UIColor *color) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:15];
    label.textColor = color;
    return label;
}

#pragma mark - About page

@interface VLTAboutController () <UITextFieldDelegate>
@end

@implementation VLTAboutController {
    UIScrollView *_scroll;
    UIView *_hero;
    VLTSceneView *_scene;
    UIImageView *_firefly;
    UILabel *_title, *_version, *_tagline;
    UIStackView *_cards;
    UILabel *_updateStatus;
    UIButton *_checkButton, *_openButton;
    UITextField *_feedField;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"About";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.view.tintColor = VLT_ACCENT;

    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.alwaysBounceVertical = YES;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:_scroll];

    // Hero: the Aurora scene, live, with the firefly floating over it.
    _hero = [[UIView alloc] init];
    _hero.clipsToBounds = YES;
    _hero.layer.cornerRadius = 28;
    _hero.layer.cornerCurve = kCACornerCurveContinuous;
    _hero.backgroundColor = HEX(0x05091C);
    [_scroll addSubview:_hero];
    _scene = [[VLTSceneView alloc] initWithFrame:CGRectZero];
    [_scene configureWithKind:VLTSceneAurora keepsWallpaper:NO speed:1.4 dim:0 videoPath:nil generation:0];
    [_hero addSubview:_scene];

    _firefly = [[UIImageView alloc] initWithImage:VLTThemeImage(7, 84, 0)];
    _firefly.contentMode = UIViewContentModeScaleAspectFit;
    _firefly.isAccessibilityElement = NO;
    [_hero addSubview:_firefly];

    _title = [[UILabel alloc] init];
    _title.text = @"Volta";
    _title.font = VLTAboutRounded(44, UIFontWeightBold);
    _title.textColor = [UIColor whiteColor];
    _title.textAlignment = NSTextAlignmentCenter;
    [_hero addSubview:_title];
    _version = [[UILabel alloc] init];
    _version.text = [NSString stringWithFormat:@"Version %@", @VLT_VERSION];
    _version.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
    _version.textColor = [UIColor colorWithWhite:1 alpha:0.8];
    _version.textAlignment = NSTextAlignmentCenter;
    [_hero addSubview:_version];
    _tagline = [[UILabel alloc] init];
    _tagline.text = @"Battery, Control Center, Dock, wallpapers and the Lock Screen, your way.";
    _tagline.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _tagline.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    _tagline.textAlignment = NSTextAlignmentCenter;
    _tagline.numberOfLines = 2;
    [_hero addSubview:_tagline];

    // Credits
    UIView *makers = VLTAboutCard(@"Made by", @[
        VLTAboutPerson(@"lightbulb.fill", HEX(0xFFB020), HEX(0xFF6B2C), @"notpreston",
                       @"The idea, every feature request, and all the testing on a real iPad."),
        VLTAboutPerson(@"sparkles", HEX(0x5B5BF0), HEX(0x19C8B9), @"Claude",
                       @"Code and design. An AI made by Anthropic, working without a device to test on."),
    ]);
    UIView *thanks = VLTAboutCard(@"Thanks to", @[
        VLTAboutPerson(@"hammer.fill", HEX(0x8E8E93), HEX(0x48484A), @"Theos", @"The build system every part of this is compiled with."),
        VLTAboutPerson(@"lock.open.fill", HEX(0xBF5AF2), HEX(0xFF4F8B), @"Dopamine, ElleKit and PreferenceLoader",
                       @"The jailbreak, the hooking engine, and the reason there is a Settings pane at all."),
        VLTAboutPerson(@"photo.stack.fill", HEX(0x40C8E0), HEX(0x0A84FF), @"The tendies community",
                       @"CAPlayground, Nugget and Pocket Poster, whose wallpaper format Volta can open."),
    ]);

    // Updates
    _updateStatus = VLTAboutText(@"", [UIColor labelColor]);
    _updateStatus.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    UIButtonConfiguration *check = [UIButtonConfiguration filledButtonConfiguration];
    check.title = @"Check for Updates";
    check.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    _checkButton = [UIButton buttonWithConfiguration:check primaryAction:nil];
    [_checkButton addTarget:self action:@selector(checkNow) forControlEvents:UIControlEventTouchUpInside];
    UIButtonConfiguration *open = [UIButtonConfiguration tintedButtonConfiguration];
    open.title = @"Open Download Page";
    open.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    _openButton = [UIButton buttonWithConfiguration:open primaryAction:nil];
    [_openButton addTarget:self action:@selector(openDownload) forControlEvents:UIControlEventTouchUpInside];

    _feedField = [[UITextField alloc] init];
    _feedField.placeholder = @"https://…/volta.json";
    _feedField.text = [VLTUpdater feedURLString];
    _feedField.borderStyle = UITextBorderStyleRoundedRect;
    _feedField.keyboardType = UIKeyboardTypeURL;
    _feedField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _feedField.autocorrectionType = UITextAutocorrectionTypeNo;
    _feedField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _feedField.returnKeyType = UIReturnKeyDone;
    _feedField.delegate = self;
    _feedField.accessibilityLabel = @"Update link";
    UIView *updates = VLTAboutCard(@"Updates", @[
        _updateStatus, _checkButton, _openButton,
        VLTAboutText(@"Update link", [UIColor secondaryLabelColor]), _feedField,
        VLTAboutText(@"Volta has no server of its own. Put a small file online that says what the newest version is, paste its link here, and Volta checks it once a day. The file looks like this:\n\n{ \"version\": \"2.3.0\", \"notes\": \"What changed\", \"url\": \"https://where-to-download\" }",
                     [UIColor secondaryLabelColor]),
    ]);

    UILabel *closing = VLTAboutText(@"Built in one very long conversation, October 2026.", [UIColor tertiaryLabelColor]);
    closing.textAlignment = NSTextAlignmentCenter;
    closing.font = [UIFont systemFontOfSize:13];

    _cards = [[UIStackView alloc] initWithArrangedSubviews:@[makers, thanks, updates, closing]];
    _cards.axis = UILayoutConstraintAxisVertical;
    _cards.spacing = 16;
    [_scroll addSubview:_cards];
    [self refreshUpdateStatus];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _scene.paused = NO;
    [self startFloating];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    _scene.paused = YES;
}

- (void)startFloating {
    if ([_firefly.layer animationForKey:@"float"] || UIAccessibilityIsReduceMotionEnabled()) return;
    CABasicAnimation *bob = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
    bob.fromValue = @-5;
    bob.toValue = @5;
    bob.duration = 2.2;
    bob.autoreverses = YES;
    bob.repeatCount = HUGE_VALF;
    bob.removedOnCompletion = NO;
    bob.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_firefly.layer addAnimation:bob forKey:@"float"];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width, inset = MAX(16, self.view.layoutMargins.left);
    CGFloat inner = MIN(width - inset * 2, 640), x = round((width - inner) / 2);
    _hero.frame = CGRectMake(x, 14, inner, 280);
    _scene.frame = _hero.bounds;
    _firefly.frame = CGRectMake((inner - 84) / 2, 34, 84, 84);
    _title.frame = CGRectMake(16, 128, inner - 32, 52);
    _version.frame = CGRectMake(16, 182, inner - 32, 20);
    _tagline.frame = CGRectMake(28, 212, inner - 56, 40);

    CGSize size = [_cards systemLayoutSizeFittingSize:CGSizeMake(inner, UILayoutFittingCompressedSize.height)
                        withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    _cards.frame = CGRectMake(x, CGRectGetMaxY(_hero.frame) + 16, inner, size.height);
    _scroll.contentSize = CGSizeMake(width, CGRectGetMaxY(_cards.frame) + 30);
}

#pragma mark Updates

- (void)refreshUpdateStatus {
    NSString *latest = [VLTUpdater latestVersion];
    NSString *link = VLTAboutPref(@"updateLink");
    BOOL available = [VLTUpdater updateAvailable];
    if (![VLTUpdater feedURLString]) {
        _updateStatus.text = @"Update checks are not set up yet.";
        _updateStatus.textColor = [UIColor secondaryLabelColor];
    } else if (available) {
        _updateStatus.text = [NSString stringWithFormat:@"Version %@ is available.", latest];
        _updateStatus.textColor = [UIColor systemOrangeColor];
    } else if (latest) {
        _updateStatus.text = @"Volta is up to date.";
        _updateStatus.textColor = [UIColor systemGreenColor];
    } else {
        _updateStatus.text = @"Not checked yet.";
        _updateStatus.textColor = [UIColor secondaryLabelColor];
    }
    _openButton.hidden = !(available && [link isKindOfClass:[NSString class]] && [link hasPrefix:@"https://"]);
    [self.view setNeedsLayout];
}

- (void)saveFeed {
    NSString *text = [_feedField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text isEqualToString:[VLTUpdater feedURLString] ?: @""]) return;
    VLTAboutSetPref(@"updateFeedURL", text.length ? text : nil);
    // A different link means the old answer no longer applies.
    for (NSString *key in @[@"updateLatest", @"updateNotes", @"updateLink", @"updateChecked"]) VLTAboutSetPref(key, nil);
    CFPreferencesAppSynchronize(CFSTR(VLT_DOMAIN));
    [self refreshUpdateStatus];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    [self saveFeed];
}

- (void)checkNow {
    [_feedField resignFirstResponder];
    [self saveFeed];
    _checkButton.enabled = NO;
    _updateStatus.text = @"Checking…";
    _updateStatus.textColor = [UIColor secondaryLabelColor];
    __weak typeof(self) weakSelf = self;
    [VLTUpdater checkWithCompletion:^(BOOL ok, NSString *message) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_checkButton.enabled = YES;
        [strongSelf refreshUpdateStatus];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:ok ? @"Update Check" : @"Couldn't Check"
                                                                       message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [strongSelf presentViewController:alert animated:YES completion:nil];
    }];
}

- (void)openDownload {
    NSString *link = VLTAboutPref(@"updateLink");
    NSURL *url = [link isKindOfClass:[NSString class]] ? [NSURL URLWithString:link] : nil;
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

@end
