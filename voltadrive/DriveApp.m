//
//  Drive (part of Volta). A big-button car dashboard: a rail with the clock,
//  battery and temperature, and cards for the map, the music and other apps.
//

#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/message.h>

#define HEX(v) [UIColor colorWithRed:(((v) >> 16) & 0xFF) / 255.0 green:(((v) >> 8) & 0xFF) / 255.0 blue:((v) & 0xFF) / 255.0 alpha:1]
#define kNavy HEX(0x0F1020)
#define kCard HEX(0x262842)
#define kCardLight HEX(0x3D4066)
#define kIndigo HEX(0x5B5BF0)
#define kTeal HEX(0x19C8B9)
#define kDim [UIColor colorWithWhite:1 alpha:0.62]

// Written by Volta's Weather app; Drive only reads it.
static NSString *const kWeatherPath = @"/var/jb/Library/Application Support/Volta/weather.plist";
static NSString *const kAwakeKey = @"keepAwake";
static NSString *const kMphKey = @"useMph";

static UIFont *DriveFont(CGFloat size, UIFontWeight weight) {
    UIFont *font = [UIFont systemFontOfSize:size weight:weight];
    UIFontDescriptor *rounded = [font.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    return rounded ? [UIFont fontWithDescriptor:rounded size:size] : font;
}

static UILabel *DriveLabel(CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *label = [[UILabel alloc] init];
    label.font = DriveFont(size, weight);
    label.textColor = color;
    label.textAlignment = NSTextAlignmentCenter;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.5;
    return label;
}

static UIView *DriveCard(void) {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = kCard;
    card.layer.cornerRadius = 26;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    return card;
}

static UIImage *DriveSymbol(NSString *name) {
    return name ? [UIImage systemImageNamed:name] : nil;
}

// Opens one of Volta's own apps, which have no URL scheme. Private API, so every step is checked.
static BOOL DriveOpenBundle(NSString *bundleID) {
    @try {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        SEL shared = NSSelectorFromString(@"defaultWorkspace"), open = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (!workspaceClass || ![workspaceClass respondsToSelector:shared]) return NO;
        id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, shared);
        if (![workspace respondsToSelector:open]) return NO;
        return ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, open, bundleID);
    } @catch (NSException *exception) {
        return NO;
    }
}

#pragma mark - Button

// One button for everything: a symbol, a title, or both. With a plate it is a launcher tile
// (symbol on a colored square, label beside or below); with a detail label it is the speed readout.
@interface DriveButton : UIControl
@property (nonatomic, strong, readonly) UIImageView *icon;
@property (nonatomic, strong, readonly) UILabel *label;
@property (nonatomic, strong) UIView *plate;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) NSDictionary *info;
- (instancetype)initWithSymbol:(NSString *)symbol title:(NSString *)title;
- (void)setSymbol:(NSString *)symbol;
@end

@implementation DriveButton

- (instancetype)initWithSymbol:(NSString *)symbol title:(NSString *)title {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = kCardLight;
        self.layer.cornerRadius = 20;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        _icon = [[UIImageView alloc] initWithImage:DriveSymbol(symbol)];
        _icon.contentMode = UIViewContentModeCenter;
        _icon.tintColor = [UIColor whiteColor];
        [self addSubview:_icon];
        _label = DriveLabel(19, UIFontWeightBold, [UIColor whiteColor]);
        _label.text = title;
        [self addSubview:_label];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.accessibilityLabel = title;
    }
    return self;
}

- (void)setSymbol:(NSString *)symbol {
    _icon.image = DriveSymbol(symbol);
    [self setNeedsLayout];
}

- (void)setPlate:(UIView *)plate {
    _plate = plate;
    plate.userInteractionEnabled = NO;
    plate.layer.cornerCurve = kCACornerCurveContinuous;
    [self insertSubview:plate atIndex:0];
}

- (void)setDetailLabel:(UILabel *)detailLabel {
    _detailLabel = detailLabel;
    [self addSubview:detailLabel];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:highlighted ? 0.03 : 0.25 animations:^{ self.alpha = highlighted ? 0.55 : 1; }];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height, symbolSize = 24;
    BOOL hasIcon = _icon.image != nil, hasText = _label.text.length > 0;
    _icon.hidden = !hasIcon;
    _label.hidden = !hasText;
    if (w < 1 || h < 1) return;

    if (_plate) {
        CGFloat side;
        if (w > h * 1.8) {   // wide and short: label to the right
            side = MAX(MIN(h - 8, 76), 20);
            _plate.frame = CGRectMake(6, (h - side) / 2, side, side);
            _label.frame = CGRectMake(side + 18, 0, MAX(w - side - 24, 0), h);
            _label.textAlignment = NSTextAlignmentNatural;
        } else {             // label below
            CGFloat labelHeight = 24;
            side = MAX(MIN(MIN(w - 8, h - labelHeight - 6), 120), 20);
            CGFloat top = (h - side - labelHeight - 4) / 2;
            _plate.frame = CGRectMake((w - side) / 2, top, side, side);
            _label.frame = CGRectMake(0, top + side + 4, w, labelHeight);
            _label.textAlignment = NSTextAlignmentCenter;
        }
        _plate.layer.cornerRadius = side * 0.28;
        _icon.frame = _plate.frame;
        symbolSize = side * 0.42;
    } else if (_detailLabel) {
        _label.frame = CGRectMake(6, h * 0.06, w - 12, h * 0.62);
        _detailLabel.frame = CGRectMake(6, h * 0.64, w - 12, h * 0.28);
    } else if (hasIcon && hasText) {
        if (w < 170) {       // narrow: symbol above the title
            _icon.frame = CGRectMake(0, h * 0.12, w, h * 0.46);
            _label.frame = CGRectMake(4, h * 0.56, w - 8, h * 0.34);
            symbolSize = 22;
        } else {
            CGFloat textWidth = MIN(ceil([_label sizeThatFits:CGSizeMake(CGFLOAT_MAX, h)].width), w - 70);
            CGFloat x = (w - textWidth - 40) / 2;
            _icon.frame = CGRectMake(x, 0, 30, h);
            _label.frame = CGRectMake(x + 40, 0, textWidth, h);
        }
    } else if (hasIcon) {
        _icon.frame = self.bounds;
        symbolSize = MIN(MIN(w, h) * 0.4, 40);
    } else {
        _label.frame = CGRectInset(self.bounds, 8, 0);
    }
    _icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:symbolSize weight:UIImageSymbolWeightSemibold];
}

@end

// Lets a drag that starts on a button still scroll the dashboard.
@interface DriveScrollView : UIScrollView
@end

@implementation DriveScrollView
- (BOOL)touchesShouldCancelInContentView:(UIView *)view { return YES; }
@end

#pragma mark - Dashboard

@interface DriveViewController : UIViewController <CLLocationManagerDelegate, MKMapViewDelegate>
@end

@implementation DriveViewController {
    // Rail
    UIView *_rail;
    UILabel *_clock, *_date, *_temp, *_city, *_batteryLabel;
    UIImageView *_weatherIcon, *_batteryIcon;
    DriveButton *_awakeButton;
    NSDateFormatter *_clockFormat, *_dateFormat;
    NSTimer *_timer;
    NSInteger _ticks;
    BOOL _active, _keepAwake, _hasWeather;

    // Cards
    DriveScrollView *_scroll;
    UIView *_mapCard, *_musicCard, *_appsCard;

    // Map
    MKMapView *_map;
    CLLocationManager *_location;
    CLLocation *_lastLocation;
    DriveButton *_whereButton, *_speedButton, *_recenterButton, *_settingsButton;
    UIView *_blocked;
    UIImageView *_blockedIcon;
    UILabel *_blockedLabel;
    BOOL _mph, _centeredOnce;

    // Now playing
    MPMusicPlayerController *_player;
    BOOL _playerNotifying, _askedMusic;
    UIImageView *_artwork;
    UILabel *_songTitle, *_songArtist;
    DriveButton *_previousButton, *_playButton, *_nextButton, *_openMusicButton;

    // Launcher
    NSMutableArray<DriveButton *> *_tiles;

    UILabel *_toast;
    NSInteger _toastCount;
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = kNavy;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // Miles per hour where the road signs use them, kilometres everywhere else.
    NSString *country = [NSLocale currentLocale].countryCode ?: @"";
    [defaults registerDefaults:@{kAwakeKey: @YES, kMphKey: @([@[@"US", @"GB", @"LR", @"MM"] containsObject:country])}];
    _keepAwake = [defaults boolForKey:kAwakeKey];
    _mph = [defaults boolForKey:kMphKey];
    _active = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;

    [self buildRail];
    _scroll = [[DriveScrollView alloc] init];
    _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scroll.delaysContentTouches = NO;
    _scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:_scroll];
    [self buildMapCard];
    [self buildMusicCard];
    [self buildAppsCard];

    _toast = DriveLabel(17, UIFontWeightSemibold, [UIColor whiteColor]);
    _toast.backgroundColor = kIndigo;
    _toast.layer.cornerRadius = 22;
    _toast.layer.cornerCurve = kCACornerCurveContinuous;
    _toast.clipsToBounds = YES;
    _toast.alpha = 0;
    [self.view addSubview:_toast];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(becameActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(resignedActive) name:UIApplicationWillResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(refreshBattery) name:UIDeviceBatteryLevelDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(refreshBattery) name:UIDeviceBatteryStateDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(makeFormats) name:NSCurrentLocaleDidChangeNotification object:nil];
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;

    [self makeFormats];
    [self refreshBattery];
    [self reloadWeather];
    [self refreshSpeed];
    [self refreshAwake];
    [self refreshMusic];
    [self applyLocationAccess];
    if (_active) [self becameActive];
}

- (void)dealloc {
    [_timer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_playerNotifying) [_player endGeneratingPlaybackNotifications];
    [_location stopUpdatingLocation];
    _location.delegate = nil;
    _map.delegate = nil;
}

#pragma mark Active / idle

- (void)becameActive {
    _active = YES;
    [UIApplication sharedApplication].idleTimerDisabled = _keepAwake;
    [_timer invalidate];
    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { [weakSelf tick]; }];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    [self refreshClock];
    [self refreshBattery];
    [self reloadWeather];
    [self setUpMusic];
    [self applyLocationAccess];
}

- (void)resignedActive {
    _active = NO;
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [_timer invalidate];
    _timer = nil;
    [_location stopUpdatingLocation];
}

- (void)tick {
    [self refreshClock];
    [self refreshSpeed];   // goes back to "--" when fixes stop coming
    if (++_ticks % 60 == 0) [self reloadWeather];
}

- (void)toggleAwake {
    _keepAwake = !_keepAwake;
    [[NSUserDefaults standardUserDefaults] setBool:_keepAwake forKey:kAwakeKey];
    if (_active) [UIApplication sharedApplication].idleTimerDisabled = _keepAwake;
    [self refreshAwake];
    [self toast:_keepAwake ? @"Screen stays on" : @"Screen can lock"];
}

- (void)refreshAwake {
    _awakeButton.backgroundColor = _keepAwake ? kTeal : kCardLight;
    UIColor *ink = _keepAwake ? HEX(0x06282A) : [UIColor whiteColor];
    _awakeButton.icon.tintColor = ink;
    _awakeButton.label.textColor = ink;
    [_awakeButton setSymbol:_keepAwake ? @"sun.max.fill" : @"moon.zzz.fill"];
    _awakeButton.accessibilityLabel = @"Keep screen awake";
    _awakeButton.accessibilityValue = _keepAwake ? @"On" : @"Off";
}

#pragma mark Rail

- (void)buildRail {
    _rail = DriveCard();
    [self.view addSubview:_rail];
    _clock = DriveLabel(46, UIFontWeightHeavy, [UIColor whiteColor]);
    _date = DriveLabel(16, UIFontWeightSemibold, kDim);
    _temp = DriveLabel(34, UIFontWeightBold, [UIColor whiteColor]);
    _city = DriveLabel(15, UIFontWeightSemibold, kDim);
    _batteryLabel = DriveLabel(18, UIFontWeightBold, [UIColor whiteColor]);
    _weatherIcon = [[UIImageView alloc] init];
    _batteryIcon = [[UIImageView alloc] init];
    for (UIImageView *icon in @[_weatherIcon, _batteryIcon]) {
        icon.contentMode = UIViewContentModeCenter;
        icon.tintColor = kTeal;
        icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
    }
    _awakeButton = [[DriveButton alloc] initWithSymbol:@"sun.max.fill" title:nil];
    _awakeButton.label.font = DriveFont(14, UIFontWeightBold);
    [_awakeButton addTarget:self action:@selector(toggleAwake) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *view in @[_clock, _date, _weatherIcon, _temp, _city, _batteryIcon, _batteryLabel, _awakeButton]) [_rail addSubview:view];
}

// The rail runs down the left side in landscape and across the top otherwise.
- (void)layoutRail:(BOOL)side {
    CGFloat w = _rail.bounds.size.width, h = _rail.bounds.size.height, pad = 12;
    _awakeButton.label.text = side ? (_keepAwake ? @"Awake" : @"Auto-lock") : nil;
    [_awakeButton setNeedsLayout];
    if (side) {
        BOOL roomy = h >= 440;
        _clock.textAlignment = NSTextAlignmentCenter;
        _clock.frame = CGRectMake(pad, 14, w - pad * 2, 54);
        _date.hidden = !roomy;
        _date.frame = CGRectMake(pad, 68, w - pad * 2, 22);
        CGFloat y = roomy ? 112 : 74;
        _weatherIcon.hidden = !roomy || !_hasWeather;
        _weatherIcon.frame = CGRectMake(pad, y, w - pad * 2, 32);
        if (roomy) y += 34;
        _temp.frame = CGRectMake(pad, y, w - pad * 2, 42);
        _city.hidden = !_hasWeather;
        _city.frame = CGRectMake(pad, y + 42, w - pad * 2, 20);
        _awakeButton.frame = CGRectMake(pad, h - pad - 68, w - pad * 2, 68);
        CGFloat batteryY = h - pad - 68 - 14 - 28, x = MAX((w - 94) / 2, 4);
        _batteryIcon.frame = CGRectMake(x, batteryY, 38, 28);
        _batteryLabel.frame = CGRectMake(x + 42, batteryY, MAX(w - x - 46, 0), 28);
        _batteryLabel.textAlignment = NSTextAlignmentNatural;
    } else {
        BOOL roomy = w >= 430;
        _awakeButton.frame = CGRectMake(w - pad - 64, (h - 64) / 2, 64, 64);
        CGFloat x = CGRectGetMinX(_awakeButton.frame) - 8 - 58;
        _batteryIcon.frame = CGRectMake(x, h / 2 - 27, 58, 28);
        _batteryLabel.frame = CGRectMake(x, h / 2 + 2, 58, 24);
        _batteryLabel.textAlignment = NSTextAlignmentCenter;
        CGFloat weatherWidth = _hasWeather ? (roomy ? 110 : 66) : 0;
        x -= weatherWidth + (_hasWeather ? 8 : 0);
        _weatherIcon.hidden = YES;
        _city.hidden = !roomy || !_hasWeather;
        _temp.frame = roomy ? CGRectMake(x, h / 2 - 30, weatherWidth, 38) : CGRectMake(x, 0, weatherWidth, h);
        _city.frame = CGRectMake(x, h / 2 + 8, weatherWidth, 20);
        _clock.textAlignment = NSTextAlignmentNatural;
        _date.hidden = !roomy;
        CGFloat clockWidth = MAX(x - 8 - pad - 6, 0);
        _clock.frame = roomy ? CGRectMake(pad + 6, h / 2 - 34, clockWidth, 46) : CGRectMake(pad + 6, 0, clockWidth, h);
        _date.frame = CGRectMake(pad + 6, h / 2 + 12, clockWidth, 20);
    }
    _date.textAlignment = _clock.textAlignment;
}

- (void)makeFormats {
    // The user's 12 or 24 hour style, without the AM/PM mark.
    NSString *format = [NSDateFormatter dateFormatFromTemplate:@"jmm" options:0 locale:[NSLocale currentLocale]] ?: @"HH:mm";
    format = [[format stringByReplacingOccurrencesOfString:@"a" withString:@""] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    _clockFormat = [[NSDateFormatter alloc] init];
    _clockFormat.dateFormat = format;
    _dateFormat = [[NSDateFormatter alloc] init];
    [_dateFormat setLocalizedDateFormatFromTemplate:@"EEEdMMM"];
    [self refreshClock];
}

- (void)refreshClock {
    NSDate *now = [NSDate date];
    NSString *time = [_clockFormat stringFromDate:now];
    if (![_clock.text isEqualToString:time]) _clock.text = time;
    NSString *day = [_dateFormat stringFromDate:now];
    if (![_date.text isEqualToString:day]) _date.text = day;
}

- (void)refreshBattery {
    UIDevice *device = [UIDevice currentDevice];
    float level = device.batteryLevel;
    BOOL charging = device.batteryState == UIDeviceBatteryStateCharging || device.batteryState == UIDeviceBatteryStateFull;
    _batteryLabel.text = level < 0 ? @"--" : [NSString stringWithFormat:@"%ld%%", lroundf(level * 100)];
    NSString *symbol = charging ? @"battery.100.bolt" : (level < 0 || level > 0.5 ? @"battery.100" : (level > 0.15 ? @"battery.25" : @"battery.0"));
    _batteryIcon.image = DriveSymbol(symbol) ?: DriveSymbol(@"battery.100");
    _batteryIcon.tintColor = (!charging && level >= 0 && level <= 0.15) ? HEX(0xF0567A) : kTeal;
}

#pragma mark Weather

// Shows the temperature only when the shared file is well formed and under three hours old.
- (void)reloadWeather {
    NSString *temperature = nil, *city = nil, *symbol = nil, *spoken = nil;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:kWeatherPath];
    if ([info isKindOfClass:[NSDictionary class]]) {
        NSNumber *temp = info[@"temp"], *code = info[@"code"], *fahrenheit = info[@"fahrenheit"];
        NSDate *updated = info[@"updated"];
        if ([temp isKindOfClass:[NSNumber class]] && [updated isKindOfClass:[NSDate class]]) {
            NSTimeInterval age = -[updated timeIntervalSinceNow];
            double value = temp.doubleValue;
            if (age >= 0 && age <= 3 * 3600 && isfinite(value) && fabs(value) < 200) {
                temperature = [NSString stringWithFormat:@"%ld°", lround(value)];
                spoken = [NSString stringWithFormat:@"%ld degrees", lround(value)];
                if ([fahrenheit isKindOfClass:[NSNumber class]])
                    spoken = [spoken stringByAppendingString:fahrenheit.boolValue ? @" Fahrenheit" : @" Celsius"];
                if ([info[@"city"] isKindOfClass:[NSString class]]) city = info[@"city"];
                if ([code isKindOfClass:[NSNumber class]]) symbol = [self symbolForWeatherCode:code.integerValue];
            }
        }
    }
    BOOL changed = _hasWeather != (temperature != nil);
    _hasWeather = temperature != nil;
    _temp.text = temperature;
    _temp.accessibilityLabel = spoken;
    _city.text = city;
    _weatherIcon.image = DriveSymbol(symbol);
    if (changed) [self.view setNeedsLayout];
}

// WMO weather codes, as Open-Meteo reports them.
- (NSString *)symbolForWeatherCode:(NSInteger)code {
    if (code == 0) return @"sun.max.fill";
    if (code <= 2) return @"cloud.sun.fill";
    if (code == 3) return @"cloud.fill";
    if (code == 45 || code == 48) return @"cloud.fog.fill";
    if (code >= 51 && code <= 57) return @"cloud.drizzle.fill";
    if ((code >= 61 && code <= 67) || (code >= 80 && code <= 82)) return @"cloud.rain.fill";
    if ((code >= 71 && code <= 77) || code == 85 || code == 86) return @"cloud.snow.fill";
    if (code >= 95 && code <= 99) return @"cloud.bolt.rain.fill";
    return nil;
}

#pragma mark Map

- (void)buildMapCard {
    _mapCard = DriveCard();
    _mapCard.clipsToBounds = YES;
    [_scroll addSubview:_mapCard];

    _map = [[MKMapView alloc] init];
    _map.delegate = self;
    _map.showsTraffic = YES;
    _map.showsCompass = NO;
    [_mapCard addSubview:_map];

    // Covers the map when location access is off.
    _blocked = [[UIView alloc] init];
    _blocked.backgroundColor = kCard;
    _blocked.hidden = YES;
    _blockedIcon = [[UIImageView alloc] initWithImage:DriveSymbol(@"location.slash.fill")];
    _blockedIcon.contentMode = UIViewContentModeCenter;
    _blockedIcon.tintColor = kTeal;
    _blockedIcon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIImageSymbolWeightSemibold];
    _blockedLabel = DriveLabel(18, UIFontWeightBold, [UIColor whiteColor]);
    _blockedLabel.numberOfLines = 0;
    _blockedLabel.text = @"Location is off for Drive.\nTurn it on in Settings to see the map and your speed.";
    _settingsButton = [[DriveButton alloc] initWithSymbol:nil title:@"Open Settings"];
    [_settingsButton addTarget:self action:@selector(openLocationSettings) forControlEvents:UIControlEventTouchUpInside];
    [_blocked addSubview:_blockedIcon];
    [_blocked addSubview:_blockedLabel];
    [_blocked addSubview:_settingsButton];
    [_mapCard addSubview:_blocked];

    _whereButton = [[DriveButton alloc] initWithSymbol:@"magnifyingglass" title:@"Where to?"];
    _whereButton.backgroundColor = kIndigo;
    _whereButton.label.font = DriveFont(22, UIFontWeightBold);
    [_whereButton addTarget:self action:@selector(askDestination) forControlEvents:UIControlEventTouchUpInside];
    [_mapCard addSubview:_whereButton];

    _speedButton = [[DriveButton alloc] initWithSymbol:nil title:@"--"];
    _speedButton.backgroundColor = [kNavy colorWithAlphaComponent:0.9];
    _speedButton.label.font = DriveFont(52, UIFontWeightHeavy);
    _speedButton.detailLabel = DriveLabel(16, UIFontWeightBold, kTeal);
    _speedButton.accessibilityHint = @"Switches between miles and kilometres per hour";
    [_speedButton addTarget:self action:@selector(toggleUnit) forControlEvents:UIControlEventTouchUpInside];
    [_mapCard addSubview:_speedButton];

    _recenterButton = [[DriveButton alloc] initWithSymbol:@"location.fill" title:nil];
    _recenterButton.backgroundColor = [kNavy colorWithAlphaComponent:0.9];
    _recenterButton.accessibilityLabel = @"Centre on my location";
    [_recenterButton addTarget:self action:@selector(recenter) forControlEvents:UIControlEventTouchUpInside];
    [_mapCard addSubview:_recenterButton];

    _location = [[CLLocationManager alloc] init];
    _location.delegate = self;
    _location.desiredAccuracy = kCLLocationAccuracyBestForNavigation;
    _location.activityType = CLActivityTypeAutomotiveNavigation;
}

- (void)layoutMapCard {
    CGFloat w = _mapCard.bounds.size.width, h = _mapCard.bounds.size.height, pad = 12;
    _map.frame = _mapCard.bounds;
    _blocked.frame = _mapCard.bounds;
    _whereButton.frame = CGRectMake(pad, pad, MIN(w - pad * 2, 300), 68);
    _speedButton.frame = CGRectMake(pad, h - pad - 104, 136, 104);
    _recenterButton.frame = CGRectMake(w - pad - 68, h - pad - 68, 68, 68);
    // The message sits between the "Where to?" button and the Settings button.
    CGFloat top = pad + 68 + 8, buttonWidth = MIN(w - pad * 2, 300);
    _settingsButton.frame = CGRectMake((w - buttonWidth) / 2, h - pad - 68, buttonWidth, 68);
    CGFloat space = MAX(CGRectGetMinY(_settingsButton.frame) - 8 - top, 0);
    _blockedIcon.hidden = space < 150;
    _blockedIcon.frame = CGRectMake(0, top + space * 0.08, w, 48);
    CGFloat labelTop = _blockedIcon.hidden ? top : CGRectGetMaxY(_blockedIcon.frame);
    _blockedLabel.frame = CGRectMake(20, labelTop, MAX(w - 40, 0), MAX(top + space - labelTop, 0));
}

- (void)applyLocationAccess {
    CLAuthorizationStatus status = _location.authorizationStatus;
    BOOL allowed = status == kCLAuthorizationStatusAuthorizedWhenInUse || status == kCLAuthorizationStatusAuthorizedAlways;
    BOOL blocked = status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted;
    _map.showsUserLocation = allowed;
    _blocked.hidden = !blocked;
    _speedButton.hidden = blocked;
    _recenterButton.hidden = blocked;
    if (!allowed) {
        _lastLocation = nil;
        _centeredOnce = NO;
        [_location stopUpdatingLocation];
        [self refreshSpeed];
    } else if (_active) {
        [_location startUpdatingLocation];
    }
    if (status == kCLAuthorizationStatusNotDetermined && _active) [_location requestWhenInUseAuthorization];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    [self applyLocationAccess];   // delivered on the main thread, where the manager was made
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *latest = locations.lastObject;
    if (!latest || latest.horizontalAccuracy < 0 || !CLLocationCoordinate2DIsValid(latest.coordinate)) return;
    _lastLocation = latest;
    [self refreshSpeed];
    if (!_centeredOnce) [self follow:NO];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    // A missing fix is not fatal; the readout shows "--" until one arrives.
}

- (void)mapView:(MKMapView *)mapView didChangeUserTrackingMode:(MKUserTrackingMode)mode animated:(BOOL)animated {
    _recenterButton.icon.tintColor = mode == MKUserTrackingModeNone ? [UIColor whiteColor] : kTeal;
}

// Centres on the user about half a kilometre out, then keeps following.
- (void)follow:(BOOL)animated {
    CLLocation *place = _lastLocation ?: _map.userLocation.location;
    if (!place || !CLLocationCoordinate2DIsValid(place.coordinate) || _map.bounds.size.width < 1) return;
    _centeredOnce = YES;
    [_map setRegion:MKCoordinateRegionMakeWithDistance(place.coordinate, 900, 900) animated:NO];
    [_map setUserTrackingMode:MKUserTrackingModeFollow animated:animated];
}

- (void)recenter {
    if (!_lastLocation && !_map.userLocation.location) [self toast:@"Still finding you"];
    else [self follow:YES];
}

- (void)refreshSpeed {
    CLLocation *place = _lastLocation;
    BOOL known = place && place.speed >= 0 && -[place.timestamp timeIntervalSinceNow] < 10;
    NSString *unit = _mph ? @"mph" : @"km/h";
    NSString *text = known ? [NSString stringWithFormat:@"%ld", lround(place.speed * (_mph ? 2.236936 : 3.6))] : @"--";
    if (![_speedButton.label.text isEqualToString:text]) _speedButton.label.text = text;
    _speedButton.detailLabel.text = unit;
    _speedButton.accessibilityLabel = known ? [NSString stringWithFormat:@"Speed %@ %@", text, _mph ? @"miles per hour" : @"kilometres per hour"] : @"Speed unknown";
}

- (void)toggleUnit {
    _mph = !_mph;
    [[NSUserDefaults standardUserDefaults] setBool:_mph forKey:kMphKey];
    [self refreshSpeed];
}

- (void)openLocationSettings {
    [self openURL:@"App-prefs:Privacy&path=LOCATION" fallback:@"App-prefs:" name:@"Settings"];
}

- (void)askDestination {
    if (self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Where to?" message:@"Maps will open with your search." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Address or place";
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.returnKeyType = UIReturnKeyGo;
    }];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIAlertAction *go = [UIAlertAction actionWithTitle:@"Go" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf openDestination:weakAlert.textFields.firstObject.text];
    }];
    [alert addAction:go];
    alert.preferredAction = go;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openDestination:(NSString *)text {
    NSString *query = [text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length == 0) return;
    // Only letters, digits and -._~ go through as they are; everything else is percent-encoded.
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-._~"];
    NSString *encoded = [query stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    if (encoded.length == 0) { [self toast:@"Couldn't read that place"]; return; }
    [self openURL:[@"maps://?q=" stringByAppendingString:encoded]
         fallback:[@"https://maps.apple.com/?q=" stringByAppendingString:encoded] name:@"Maps"];
}

#pragma mark Now playing

- (void)buildMusicCard {
    _musicCard = DriveCard();
    [_scroll addSubview:_musicCard];
    _artwork = [[UIImageView alloc] init];
    _artwork.backgroundColor = kCardLight;
    _artwork.tintColor = kTeal;
    _artwork.clipsToBounds = YES;
    _artwork.layer.cornerRadius = 18;
    _artwork.layer.cornerCurve = kCACornerCurveContinuous;
    _artwork.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIImageSymbolWeightSemibold];
    _songTitle = DriveLabel(24, UIFontWeightBold, [UIColor whiteColor]);
    _songTitle.textAlignment = NSTextAlignmentNatural;
    _songTitle.numberOfLines = 2;
    _songTitle.minimumScaleFactor = 0.75;
    _songArtist = DriveLabel(19, UIFontWeightSemibold, kDim);
    _songArtist.textAlignment = NSTextAlignmentNatural;
    _songArtist.adjustsFontSizeToFitWidth = NO;

    _previousButton = [[DriveButton alloc] initWithSymbol:@"backward.fill" title:nil];
    _previousButton.accessibilityLabel = @"Previous";
    [_previousButton addTarget:self action:@selector(previousSong) forControlEvents:UIControlEventTouchUpInside];
    _playButton = [[DriveButton alloc] initWithSymbol:@"play.fill" title:nil];
    _playButton.backgroundColor = kIndigo;
    [_playButton addTarget:self action:@selector(playPause) forControlEvents:UIControlEventTouchUpInside];
    _nextButton = [[DriveButton alloc] initWithSymbol:@"forward.fill" title:nil];
    _nextButton.accessibilityLabel = @"Next";
    [_nextButton addTarget:self action:@selector(nextSong) forControlEvents:UIControlEventTouchUpInside];
    _openMusicButton = [[DriveButton alloc] initWithSymbol:@"music.note" title:@"Open Music"];
    _openMusicButton.backgroundColor = kIndigo;
    _openMusicButton.label.font = DriveFont(21, UIFontWeightBold);
    [_openMusicButton addTarget:self action:@selector(openMusic) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *view in @[_artwork, _songTitle, _songArtist, _previousButton, _playButton, _nextButton, _openMusicButton]) [_musicCard addSubview:view];
}

- (void)layoutMusicCard {
    CGFloat w = _musicCard.bounds.size.width, h = _musicCard.bounds.size.height, pad = 16, gap = 10;
    CGFloat buttonHeight = MAX(MIN(floor(h * 0.32), 96), 64);
    CGFloat topSpace = MAX(h - pad * 2 - 12 - buttonHeight, 40);
    CGFloat art = MAX(MIN(MIN(topSpace, floor(w * 0.36)), 170), 40);
    CGFloat artY = pad + (topSpace - art) / 2, textX = pad + art + 14, textWidth = MAX(w - textX - pad, 0);
    _artwork.frame = CGRectMake(pad, artY, art, art);
    _songTitle.frame = CGRectMake(textX, artY, textWidth, floor(art * 0.64));
    _songArtist.frame = CGRectMake(textX, artY + floor(art * 0.64), textWidth, floor(art * 0.36));
    CGFloat y = h - pad - buttonHeight, each = floor((w - pad * 2 - gap * 2) / 3);
    _previousButton.frame = CGRectMake(pad, y, each, buttonHeight);
    _playButton.frame = CGRectMake(pad + each + gap, y, w - pad * 2 - (each + gap) * 2, buttonHeight);
    _nextButton.frame = CGRectMake(w - pad - each, y, each, buttonHeight);
    _openMusicButton.frame = CGRectMake(pad, y, w - pad * 2, buttonHeight);
}

// Runs each time the app comes to the front; asks for media access once.
- (void)setUpMusic {
    MPMediaLibraryAuthorizationStatus status = [MPMediaLibrary authorizationStatus];
    if (status == MPMediaLibraryAuthorizationStatusAuthorized) {
        [self startPlayer];
    } else if (status == MPMediaLibraryAuthorizationStatusNotDetermined && !_askedMusic) {
        _askedMusic = YES;
        __weak typeof(self) weakSelf = self;
        [MPMediaLibrary requestAuthorization:^(MPMediaLibraryAuthorizationStatus answer) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (answer == MPMediaLibraryAuthorizationStatusAuthorized) [weakSelf startPlayer];
                [weakSelf refreshMusic];
            });
        }];
    }
    [self refreshMusic];
}

// Only touched once the user has allowed media access.
- (void)startPlayer {
    if (_player) return;
    _player = [MPMusicPlayerController systemMusicPlayer];
    if (!_player) return;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(musicChanged) name:MPMusicPlayerControllerNowPlayingItemDidChangeNotification object:_player];
    [center addObserver:self selector:@selector(musicChanged) name:MPMusicPlayerControllerPlaybackStateDidChangeNotification object:_player];
    [_player beginGeneratingPlaybackNotifications];
    _playerNotifying = YES;
}

- (void)musicChanged {
    if ([NSThread isMainThread]) [self refreshMusic];
    else {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refreshMusic]; });
    }
}

- (void)refreshMusic {
    MPMediaItem *item = _player.nowPlayingItem;
    BOOL playing = _player && _player.playbackState == MPMusicPlaybackStatePlaying;
    BOOL denied = [MPMediaLibrary authorizationStatus] == MPMediaLibraryAuthorizationStatusDenied
               || [MPMediaLibrary authorizationStatus] == MPMediaLibraryAuthorizationStatusRestricted;
    UIImage *cover = nil;
    if (item) {
        NSString *title = item.title, *artist = item.artist ?: item.albumTitle;
        _songTitle.text = title.length ? title : @"Unknown title";
        _songArtist.text = artist.length ? artist : @"";
        cover = [item.artwork imageWithSize:CGSizeMake(340, 340)];
    } else {
        _songTitle.text = @"Nothing playing";
        _songArtist.text = denied ? @"Music access is off for Drive" : @"Start something in Music";
    }
    _artwork.image = cover ?: DriveSymbol(@"music.note");
    _artwork.contentMode = cover ? UIViewContentModeScaleAspectFill : UIViewContentModeCenter;
    _previousButton.hidden = _playButton.hidden = _nextButton.hidden = (item == nil);
    _openMusicButton.hidden = (item != nil);
    [_playButton setSymbol:playing ? @"pause.fill" : @"play.fill"];
    _playButton.accessibilityLabel = playing ? @"Pause" : @"Play";
}

- (void)playPause {
    if (!_player) return;
    if (_player.playbackState == MPMusicPlaybackStatePlaying) [_player pause];
    else [_player play];
}

- (void)previousSong { [_player skipToPreviousItem]; }
- (void)nextSong { [_player skipToNextItem]; }
- (void)openMusic { [self openURL:@"music://" fallback:nil name:@"Music"]; }

#pragma mark Launcher

- (void)buildAppsCard {
    _appsCard = DriveCard();
    [_scroll addSubview:_appsCard];
    // Phone and Weather are Volta's own apps and open by bundle id; the rest have URL schemes.
    NSArray<NSDictionary *> *apps = @[
        @{@"name": @"Phone", @"symbol": @"phone.fill", @"color": @0x2FBF71, @"bundle": @"com.notpreston.volta.phone"},
        @{@"name": @"Music", @"symbol": @"music.note", @"color": @0xF0567A, @"url": @"music://"},
        @{@"name": @"Maps", @"symbol": @"map.fill", @"color": @0x19C8B9, @"url": @"maps://"},
        @{@"name": @"Messages", @"symbol": @"message.fill", @"color": @0x5B5BF0, @"url": @"sms:"},
        @{@"name": @"Podcasts", @"symbol": @"antenna.radiowaves.left.and.right", @"color": @0x9B5BF0, @"url": @"podcasts://"},
        @{@"name": @"Calendar", @"symbol": @"calendar", @"color": @0xF08A3C, @"url": @"calshow://"},
        @{@"name": @"Weather", @"symbol": @"cloud.sun.fill", @"color": @0x3C9BF0, @"bundle": @"com.notpreston.volta.weather"},
        @{@"name": @"Settings", @"symbol": @"gearshape.fill", @"color": @0x6B6F96, @"url": @"App-prefs:"},
    ];
    _tiles = [NSMutableArray array];
    for (NSDictionary *app in apps) {
        DriveButton *tile = [[DriveButton alloc] initWithSymbol:app[@"symbol"] title:app[@"name"]];
        tile.backgroundColor = [UIColor clearColor];
        tile.label.font = DriveFont(17, UIFontWeightBold);
        tile.info = app;
        UIView *plate = [[UIView alloc] init];
        plate.backgroundColor = HEX([app[@"color"] unsignedIntValue]);
        tile.plate = plate;
        [tile addTarget:self action:@selector(openTile:) forControlEvents:UIControlEventTouchUpInside];
        [_appsCard addSubview:tile];
        [_tiles addObject:tile];
    }
}

// Four across when each tile can be at least 72 pt wide, otherwise three.
- (NSInteger)tileColumnsForWidth:(CGFloat)width {
    return (width - 24 - 30) / 4 >= 72 ? 4 : 3;
}

- (CGFloat)appsHeightForWidth:(CGFloat)width {
    NSInteger columns = [self tileColumnsForWidth:width];
    NSInteger rows = ((NSInteger)_tiles.count + columns - 1) / columns;
    return 24 + rows * 108 + (rows - 1) * 10;
}

- (void)layoutAppsCard {
    CGFloat w = _appsCard.bounds.size.width, h = _appsCard.bounds.size.height, pad = 12, gap = 10;
    NSInteger columns = [self tileColumnsForWidth:w];
    NSInteger rows = ((NSInteger)_tiles.count + columns - 1) / columns;
    CGFloat tileWidth = floor((w - pad * 2 - gap * (columns - 1)) / columns);
    CGFloat tileHeight = floor((h - pad * 2 - gap * (rows - 1)) / rows);
    for (NSInteger i = 0; i < (NSInteger)_tiles.count; i++) {
        _tiles[i].frame = CGRectMake(pad + (i % columns) * (tileWidth + gap), pad + (i / columns) * (tileHeight + gap), tileWidth, tileHeight);
    }
}

- (void)openTile:(DriveButton *)tile {
    NSString *name = tile.info[@"name"], *bundle = tile.info[@"bundle"];
    if (bundle) {
        if (!DriveOpenBundle(bundle)) [self toast:[NSString stringWithFormat:@"Couldn't open %@", name]];
    } else {
        [self openURL:tile.info[@"url"] fallback:nil name:name];
    }
}

- (void)openURL:(NSString *)string fallback:(NSString *)fallback name:(NSString *)name {
    NSURL *url = string ? [NSURL URLWithString:string] : nil;
    if (!url) { [self toast:[NSString stringWithFormat:@"Couldn't open %@", name]]; return; }
    __weak typeof(self) weakSelf = self;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL opened) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (opened) return;
            if (fallback) [weakSelf openURL:fallback fallback:nil name:name];
            else [weakSelf toast:[NSString stringWithFormat:@"Couldn't open %@", name]];
        });
    }];
}

#pragma mark Toast and layout

- (void)toast:(NSString *)message {
    _toast.text = message;
    [self layoutToast];
    NSInteger count = ++_toastCount;
    [UIView animateWithDuration:0.2 animations:^{ self->_toast.alpha = 1; }];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf hideToast:count];
    });
}

- (void)hideToast:(NSInteger)count {
    if (count != _toastCount) return;   // a newer message is showing
    [UIView animateWithDuration:0.3 animations:^{ self->_toast.alpha = 0; }];
}

- (void)layoutToast {
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGSize bounds = self.view.bounds.size;
    CGFloat width = MIN(ceil([_toast sizeThatFits:CGSizeMake(CGFLOAT_MAX, 44)].width) + 44, bounds.width - safe.left - safe.right - 24);
    _toast.frame = CGRectMake((bounds.width - width) / 2, bounds.height - safe.bottom - 24 - 48, width, 48);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect area = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    CGFloat gap = area.size.width < 500 ? 10 : 14;
    area = CGRectInset(area, gap, gap);
    if (area.size.width < 100 || area.size.height < 100) return;

    // Rail down the side when the screen is wide, across the top when it is not.
    BOOL side = area.size.width > area.size.height && area.size.width >= 640;
    CGRect main = area;
    if (side) {
        CGFloat railWidth = area.size.width >= 900 ? 164 : 132;
        _rail.frame = CGRectMake(area.origin.x, area.origin.y, railWidth, area.size.height);
        main.origin.x += railWidth + gap;
        main.size.width -= railWidth + gap;
    } else {
        _rail.frame = CGRectMake(area.origin.x, area.origin.y, area.size.width, 88);
        main.origin.y += 88 + gap;
        main.size.height -= 88 + gap;
    }
    [self layoutRail:side];
    _scroll.frame = main;

    CGFloat w = main.size.width, h = main.size.height;
    if (w >= 620 && h >= 560) {
        // Two columns: the map on the left, music above the launcher on the right.
        CGFloat left = floor((w - gap) * 0.56), right = w - gap - left;
        CGFloat musicHeight = MAX(MIN(floor(h * 0.42), 320), 210);
        _mapCard.frame = CGRectMake(0, 0, left, h);
        _musicCard.frame = CGRectMake(left + gap, 0, right, musicHeight);
        _appsCard.frame = CGRectMake(left + gap, musicHeight + gap, right, h - musicHeight - gap);
        _scroll.contentSize = CGSizeMake(w, h);
    } else {
        // One column. The map takes what is left, and the whole thing scrolls when it is too tall.
        CGFloat musicHeight = 210, appsHeight = [self appsHeightForWidth:w];
        CGFloat mapHeight = MAX(h - musicHeight - appsHeight - gap * 2, 270);
        _mapCard.frame = CGRectMake(0, 0, w, mapHeight);
        _musicCard.frame = CGRectMake(0, mapHeight + gap, w, musicHeight);
        _appsCard.frame = CGRectMake(0, mapHeight + musicHeight + gap * 2, w, appsHeight);
        _scroll.contentSize = CGSizeMake(w, mapHeight + musicHeight + appsHeight + gap * 2);
    }
    [self layoutMapCard];
    [self layoutMusicCard];
    [self layoutAppsCard];
    [self layoutToast];
}

@end

#pragma mark - App

@interface DriveAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation DriveAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;   // always dark, map included
    self.window.rootViewController = [[DriveViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

// The dashboard turns the idle timer on with its own toggle; this makes sure it is off again when we leave.
- (void)applicationWillResignActive:(UIApplication *)application {
    application.idleTimerDisabled = NO;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([DriveAppDelegate class]));
    }
}
