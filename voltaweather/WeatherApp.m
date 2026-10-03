//
//  Weather for iPad and iPhone (part of Volta). Forecasts come from the free
//  Open-Meteo API. The current reading is also saved to a shared file so the
//  Lock Screen can show it.
//

#import <UIKit/UIKit.h>

#define HEX(v) [UIColor colorWithRed:(((v) >> 16) & 0xFF) / 255.0 green:(((v) >> 8) & 0xFF) / 255.0 blue:((v) & 0xFF) / 255.0 alpha:1]

static NSString *const kSharedPath = @"/var/jb/Library/Application Support/Volta/weather.plist";

#pragma mark - Helpers

// The network is never trusted: every value is type-checked before use.
static NSDictionary *WDict(id o) { return [o isKindOfClass:[NSDictionary class]] ? o : nil; }
static NSArray *WArr(id o) { return [o isKindOfClass:[NSArray class]] ? o : nil; }
static NSNumber *WNum(id o) { return [o isKindOfClass:[NSNumber class]] ? o : nil; }
static NSString *WStr(id o) { return [o isKindOfClass:[NSString class]] ? o : nil; }
static id WAt(NSArray *array, NSUInteger index) { return index < array.count ? array[index] : nil; }

// WMO weather code -> words. A negative code means "unknown".
static NSString *WConditionText(NSInteger c) {
    if (c == 0) return @"Clear";
    if (c == 1) return @"Mostly Clear";
    if (c == 2) return @"Partly Cloudy";
    if (c == 3) return @"Overcast";
    if (c == 45 || c == 48) return @"Fog";
    if (c >= 51 && c <= 55) return @"Drizzle";
    if (c == 56 || c == 57) return @"Freezing Drizzle";
    if (c >= 61 && c <= 65) return c == 61 ? @"Light Rain" : (c == 65 ? @"Heavy Rain" : @"Rain");
    if (c == 66 || c == 67) return @"Freezing Rain";
    if (c >= 71 && c <= 77) return c == 71 ? @"Light Snow" : (c == 75 ? @"Heavy Snow" : @"Snow");
    if (c >= 80 && c <= 82) return c == 82 ? @"Heavy Showers" : @"Showers";
    if (c == 85 || c == 86) return @"Snow Showers";
    if (c >= 95 && c <= 99) return c == 95 ? @"Thunderstorm" : @"Thunderstorm with Hail";
    return @"Unknown";
}

static NSString *WSymbolName(NSInteger c, BOOL day) {
    if (c == 0) return day ? @"sun.max.fill" : @"moon.stars.fill";
    if (c == 1 || c == 2) return day ? @"cloud.sun.fill" : @"cloud.moon.fill";
    if (c == 45 || c == 48) return @"cloud.fog.fill";
    if (c >= 51 && c <= 55) return @"cloud.drizzle.fill";
    if (c == 56 || c == 57 || c == 66 || c == 67) return @"cloud.sleet.fill";
    if (c >= 61 && c <= 65) return c == 65 ? @"cloud.heavyrain.fill" : @"cloud.rain.fill";
    if ((c >= 71 && c <= 77) || c == 85 || c == 86) return @"cloud.snow.fill";
    if (c >= 80 && c <= 82) return c == 82 ? @"cloud.heavyrain.fill" : (day ? @"cloud.sun.rain.fill" : @"cloud.moon.rain.fill");
    if (c >= 95 && c <= 99) return @"cloud.bolt.rain.fill";
    return @"cloud.fill";   // overcast and anything unknown
}

static UIImage *WSymbol(NSInteger code, BOOL day, CGFloat pointSize) {
    UIImageSymbolConfiguration *config = [[UIImageSymbolConfiguration configurationWithPointSize:pointSize]
        configurationByApplyingConfiguration:[UIImageSymbolConfiguration configurationPreferringMulticolor]];
    return [UIImage systemImageNamed:WSymbolName(code, day) withConfiguration:config];
}

// Top and bottom sky colors for a condition.
static NSArray *WSkyColors(NSInteger c, BOOL day) {
    NSUInteger top, bottom;
    if (c >= 95 && c <= 99)                          { top = day ? 0x2B2540 : 0x110F1F; bottom = day ? 0x5A5470 : 0x3A3550; }
    else if ((c >= 71 && c <= 77) || c == 85 || c == 86) { top = day ? 0x5F7FA6 : 0x1C2740; bottom = day ? 0xA9BFD6 : 0x55698A; }
    else if (c >= 51 && c <= 82)                     { top = day ? 0x3A4E6B : 0x141C2B; bottom = day ? 0x6E8CA8 : 0x34435A; }
    else if (c == 45 || c == 48)                     { top = day ? 0x6C7A88 : 0x232A33; bottom = day ? 0xA3AFBA : 0x4A545F; }
    else if (c == 2 || c == 3)                       { top = day ? 0x4F7396 : 0x1B2433; bottom = day ? 0x93ADC4 : 0x3C4A5E; }
    else                                             { top = day ? 0x2678E0 : 0x0B1026; bottom = day ? 0x74BEF2 : 0x2B3A67; }
    return @[(id)HEX(top).CGColor, (id)HEX(bottom).CGColor];
}

static UILabel *WLabel(CGFloat size, UIFontWeight weight, CGFloat alpha) {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = [UIColor colorWithWhite:1 alpha:alpha];
    return label;
}

// A formatter in GMT: API times are already local to the city, so no zone shifting is wanted.
static NSDateFormatter *WFormatter(NSString *fixedFormat, NSString *localTemplate) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    if (fixedFormat) {
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = fixedFormat;
    } else {
        [formatter setLocalizedDateFormatFromTemplate:localTemplate];
    }
    return formatter;
}

// Loads a JSON object. `done` always runs on the main queue; nil means failure.
static NSURLSessionDataTask *WFetch(NSString *address, void (^done)(NSDictionary *json)) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 15;
        config.timeoutIntervalForResource = 30;
        session = [NSURLSession sessionWithConfiguration:config];
    });
    NSURL *url = [NSURL URLWithString:address];
    if (!url) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
        return nil;
    }
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *json = nil;
        BOOL ok = [response isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)response).statusCode == 200;
        if (!error && ok && data.length) json = WDict([NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]);
        dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
    }];
    [task resume];
    return task;
}

#pragma mark - Small views

@interface WeatherSkyView : UIView
@end

@implementation WeatherSkyView
+ (Class)layerClass { return [CAGradientLayer class]; }
@end

// The bar in a day row: shows where that day's low-high sits within the week's range.
@interface WeatherRangeBar : UIView
@property (nonatomic) CGFloat start, end;   // 0...1
@end

@implementation WeatherRangeBar {
    UIView *_fill;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
        _fill = [[UIView alloc] init];
        _fill.backgroundColor = HEX(0xFFD15C);
        [self addSubview:_fill];
    }
    return self;
}
- (CGSize)intrinsicContentSize { return CGSizeMake(UIViewNoIntrinsicMetric, 5); }
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width, height = self.bounds.size.height;
    CGFloat x = width * MAX(0, MIN(1, self.start)), right = width * MAX(0, MIN(1, self.end));
    _fill.frame = CGRectMake(x, 0, MAX(height, right - x), height);
    self.layer.cornerRadius = _fill.layer.cornerRadius = height / 2;
}
@end

#pragma mark - City search

@interface WeatherSearchController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, copy) void (^onPick)(NSString *name, double latitude, double longitude);
@end

@implementation WeatherSearchController {
    UITextField *_field;
    UITableView *_table;
    UILabel *_status;
    NSArray<NSDictionary *> *_results;
    NSURLSessionDataTask *_task;
    NSUInteger _generation;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Choose a City";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                         target:self action:@selector(cancel)];
    _field = [[UITextField alloc] init];
    _field.borderStyle = UITextBorderStyleRoundedRect;
    _field.placeholder = @"Search for a city";
    _field.returnKeyType = UIReturnKeySearch;
    _field.clearButtonMode = UITextFieldViewModeWhileEditing;
    _field.autocorrectionType = UITextAutocorrectionTypeNo;
    _field.autocapitalizationType = UITextAutocapitalizationTypeWords;
    _field.delegate = self;
    [_field addTarget:self action:@selector(textChanged) forControlEvents:UIControlEventEditingChanged];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.dataSource = self;
    _table.delegate = self;
    _table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [_table registerClass:[UITableViewCell class] forCellReuseIdentifier:@"city"];

    _status = [[UILabel alloc] init];
    _status.textColor = [UIColor secondaryLabelColor];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 0;
    _status.text = @"Type a city name to find it.";

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    for (UIView *view in @[_field, _table, _status]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [_field.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [_field.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_field.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_field.heightAnchor constraintEqualToConstant:40],
        [_table.topAnchor constraintEqualToAnchor:_field.bottomAnchor constant:8],
        [_table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [_status.topAnchor constraintEqualToAnchor:_field.bottomAnchor constant:36],
        [_status.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [_status.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [_field becomeFirstResponder];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(search) object:nil];
    [_task cancel];
    _generation++;
}

- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }

// Wait for a short pause in typing before asking the server.
- (void)textChanged {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(search) object:nil];
    [self performSelector:@selector(search) withObject:nil afterDelay:0.35];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(search) object:nil];
    [self search];
    return YES;
}

- (void)showResults:(NSArray *)results status:(NSString *)status {
    _results = results;
    _status.text = status;
    _status.hidden = results.count > 0;
    [_table reloadData];
}

- (void)search {
    [_task cancel];
    NSUInteger generation = ++_generation;   // answers to older questions are dropped
    NSString *text = [_field.text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length < 2) {
        [self showResults:nil status:@"Type a city name to find it."];
        return;
    }
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                               @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *encoded = [text stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    if (!encoded) return;
    if (!_results.count) [self showResults:nil status:@"Searching…"];
    __weak typeof(self) weakSelf = self;
    _task = WFetch([NSString stringWithFormat:@"https://geocoding-api.open-meteo.com/v1/search?name=%@&count=8&language=en&format=json", encoded],
                   ^(NSDictionary *json) {
        WeatherSearchController *me = weakSelf;
        if (!me || generation != me->_generation) return;
        if (!json) {
            [me showResults:nil status:@"Couldn't search. Check your connection."];
            return;
        }
        NSMutableArray *found = [NSMutableArray array];
        for (id item in WArr(json[@"results"])) {   // "results" is missing when nothing matches
            NSDictionary *place = WDict(item);
            if (WStr(place[@"name"]).length && WNum(place[@"latitude"]) && WNum(place[@"longitude"])) [found addObject:place];
        }
        [me showResults:found status:@"No cities found."];
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_results.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"city" forIndexPath:indexPath];
    NSDictionary *place = WAt(_results, (NSUInteger)indexPath.row);
    NSMutableArray *where = [NSMutableArray array];
    if (WStr(place[@"admin1"]).length) [where addObject:place[@"admin1"]];
    if (WStr(place[@"country"]).length) [where addObject:place[@"country"]];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = WStr(place[@"name"]);
    content.secondaryText = [where componentsJoinedByString:@", "];
    content.secondaryTextProperties.color = [UIColor secondaryLabelColor];
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *place = WAt(_results, (NSUInteger)indexPath.row);
    NSString *name = WStr(place[@"name"]);
    NSNumber *latitude = WNum(place[@"latitude"]), *longitude = WNum(place[@"longitude"]);
    if (!name || !latitude || !longitude) return;
    void (^onPick)(NSString *, double, double) = self.onPick;
    [self dismissViewControllerAnimated:YES completion:nil];
    if (onPick) onPick(name, latitude.doubleValue, longitude.doubleValue);
}

@end

#pragma mark - Main screen

@interface WeatherViewController : UIViewController
@end

@implementation WeatherViewController {
    // Saved settings
    NSString *_city;
    double _latitude, _longitude;
    BOOL _fahrenheit;
    // Latest forecast, and the unit it was loaded in
    NSDictionary *_forecast;
    BOOL _forecastFahrenheit;
    NSDate *_loadedAt;
    BOOL _loading, _failed, _prompted;
    NSUInteger _generation;
    // Last reading written to the shared file
    NSNumber *_sharedTemp, *_sharedCode;
    NSDate *_sharedUpdated;

    WeatherSkyView *_sky;
    UIButton *_cityButton, *_unitButton, *_refreshButton, *_messageButton;
    UIScrollView *_scroll;
    UIStackView *_content, *_hero, *_hourStack, *_dayStack, *_message;
    UIActivityIndicatorView *_spinner;
    UIImageView *_icon;
    UILabel *_tempLabel, *_conditionLabel, *_rangeLabel, *_feelsLabel, *_windLabel, *_humidityLabel, *_messageLabel, *_footer;
    UIView *_hourCard, *_dayCard;
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

- (void)viewDidLoad {
    [super viewDidLoad];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *city = WStr([defaults objectForKey:@"city"]);
    NSNumber *latitude = WNum([defaults objectForKey:@"latitude"]), *longitude = WNum([defaults objectForKey:@"longitude"]);
    if (city.length && latitude && longitude) {
        _city = city;
        _latitude = latitude.doubleValue;
        _longitude = longitude.doubleValue;
    }
    NSNumber *unit = WNum([defaults objectForKey:@"fahrenheit"]);
    _fahrenheit = unit ? unit.boolValue : ![[NSLocale currentLocale] usesMetricSystem];

    // Keep the last shared reading, if it is for this city, so a unit change can rewrite it.
    NSDictionary *shared = [NSDictionary dictionaryWithContentsOfFile:kSharedPath];
    if (_city && [WStr(shared[@"city"]) isEqualToString:_city] && WNum(shared[@"temp"]) && WNum(shared[@"fahrenheit"])) {
        double temp = [shared[@"temp"] doubleValue];
        if ([shared[@"fahrenheit"] boolValue] != _fahrenheit) temp = _fahrenheit ? temp * 9 / 5 + 32 : (temp - 32) * 5 / 9;
        _sharedTemp = @(temp);
        _sharedCode = WNum(shared[@"code"]);
        _sharedUpdated = [shared[@"updated"] isKindOfClass:[NSDate class]] ? shared[@"updated"] : nil;
    }

    [self buildViews];
    [self render];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(becameActive)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];
    if (_city) [self refresh];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!_city && !_prompted) {   // first launch: ask for a city straight away
        _prompted = YES;
        [self changeCity];
    }
}

// Coming back to the app after a while: get fresh numbers.
- (void)becameActive {
    if (_city && !_loading && (!_loadedAt || -[_loadedAt timeIntervalSinceNow] > 600)) [self refresh];
}

#pragma mark Building

- (UIButton *)pillButtonWithSymbol:(NSString *)symbol action:(SEL)action label:(NSString *)label {
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.baseForegroundColor = [UIColor whiteColor];
    config.background.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.imagePadding = 6;
    config.titleLineBreakMode = NSLineBreakByTruncatingTail;
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    if (symbol) config.image = [UIImage systemImageNamed:symbol];
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    button.accessibilityLabel = label;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)setTitle:(NSString *)title ofButton:(UIButton *)button {
    UIButtonConfiguration *config = button.configuration;
    config.attributedTitle = [[NSAttributedString alloc] initWithString:title ?: @""
        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]}];
    button.configuration = config;
}

// A translucent rounded panel with a small heading above its body.
- (UIView *)cardWithTitle:(NSString *)title body:(UIView *)body {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    card.layer.cornerRadius = 18;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    UILabel *heading = WLabel(12, UIFontWeightSemibold, 0.7);
    heading.text = title;
    for (UIView *view in @[heading, body]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [heading.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [heading.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [heading.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [body.topAnchor constraintEqualToAnchor:heading.bottomAnchor constant:10],
        [body.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [body.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
    ]];
    return card;
}

// One of the three small facts under the temperature. Returns the value label through `value`.
- (UIView *)statWithTitle:(NSString *)title value:(UILabel *__strong *)value {
    UILabel *heading = WLabel(12, UIFontWeightSemibold, 0.7);
    heading.text = title;
    UILabel *label = WLabel(18, UIFontWeightSemibold, 1);
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.6;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[heading, label]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 3;
    stack.layoutMargins = UIEdgeInsetsMake(10, 6, 10, 6);
    stack.layoutMarginsRelativeArrangement = YES;
    stack.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    stack.layer.cornerRadius = 14;
    stack.layer.cornerCurve = kCACornerCurveContinuous;
    *value = label;
    return stack;
}

- (void)buildViews {
    _sky = [[WeatherSkyView alloc] initWithFrame:self.view.bounds];
    _sky.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_sky];

    // Top bar: city on the left, unit and refresh on the right.
    _cityButton = [self pillButtonWithSymbol:@"magnifyingglass" action:@selector(changeCity) label:@"Change city"];
    _unitButton = [self pillButtonWithSymbol:nil action:@selector(toggleUnit) label:@"Temperature unit"];
    _refreshButton = [self pillButtonWithSymbol:@"arrow.clockwise" action:@selector(refresh) label:@"Refresh"];
    [_cityButton setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIView *gap = [[UIView alloc] init];
    [gap setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *bar = [[UIStackView alloc] initWithArrangedSubviews:@[_cityButton, gap, _unitButton, _refreshButton]];
    bar.spacing = 8;

    _scroll = [[UIScrollView alloc] init];
    _scroll.alwaysBounceVertical = YES;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.refreshControl = [[UIRefreshControl alloc] init];
    _scroll.refreshControl.tintColor = [UIColor whiteColor];
    [_scroll.refreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];

    // Message (no city yet, or loading failed) with one button.
    _messageLabel = WLabel(17, UIFontWeightMedium, 1);
    _messageLabel.numberOfLines = 0;
    _messageLabel.textAlignment = NSTextAlignmentCenter;
    _messageButton = [self pillButtonWithSymbol:nil action:@selector(messageButtonTapped) label:nil];
    _message = [[UIStackView alloc] initWithArrangedSubviews:@[_messageLabel, _messageButton]];
    _message.axis = UILayoutConstraintAxisVertical;
    _message.alignment = UIStackViewAlignmentCenter;
    _message.spacing = 14;
    _message.layoutMargins = UIEdgeInsetsMake(24, 12, 12, 12);
    _message.layoutMarginsRelativeArrangement = YES;
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _spinner.color = [UIColor whiteColor];

    // Current conditions.
    _icon = [[UIImageView alloc] init];
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    _icon.tintColor = [UIColor whiteColor];
    _tempLabel = WLabel(96, UIFontWeightThin, 1);
    _conditionLabel = WLabel(22, UIFontWeightMedium, 1);
    _rangeLabel = WLabel(16, UIFontWeightMedium, 0.8);
    UILabel *feels, *wind, *humidity;
    UIStackView *stats = [[UIStackView alloc] initWithArrangedSubviews:@[[self statWithTitle:@"FEELS LIKE" value:&feels],
                                                                         [self statWithTitle:@"WIND" value:&wind],
                                                                         [self statWithTitle:@"HUMIDITY" value:&humidity]]];
    _feelsLabel = feels; _windLabel = wind; _humidityLabel = humidity;
    stats.distribution = UIStackViewDistributionFillEqually;
    stats.spacing = 10;
    _hero = [[UIStackView alloc] initWithArrangedSubviews:@[_icon, _tempLabel, _conditionLabel, _rangeLabel, stats]];
    _hero.axis = UILayoutConstraintAxisVertical;
    _hero.alignment = UIStackViewAlignmentCenter;
    _hero.spacing = 2;
    [_hero setCustomSpacing:18 afterView:_rangeLabel];

    // Next 24 hours: a strip that scrolls sideways.
    _hourStack = [[UIStackView alloc] init];
    _hourStack.spacing = 6;
    _hourStack.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *hourScroll = [[UIScrollView alloc] init];
    hourScroll.showsHorizontalScrollIndicator = NO;
    hourScroll.contentInset = UIEdgeInsetsMake(0, 10, 0, 10);
    [hourScroll addSubview:_hourStack];
    _hourCard = [self cardWithTitle:@"NEXT 24 HOURS" body:hourScroll];

    _dayStack = [[UIStackView alloc] init];
    _dayStack.axis = UILayoutConstraintAxisVertical;
    _dayStack.spacing = 12;
    _dayStack.layoutMargins = UIEdgeInsetsMake(2, 16, 2, 16);
    _dayStack.layoutMarginsRelativeArrangement = YES;
    _dayCard = [self cardWithTitle:@"7-DAY FORECAST" body:_dayStack];

    _footer = WLabel(12, UIFontWeightRegular, 0.6);
    _footer.textAlignment = NSTextAlignmentCenter;
    _footer.numberOfLines = 0;

    // render adds the sections that apply.
    UIStackView *content = _content = [[UIStackView alloc] init];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 18;
    [_scroll addSubview:content];

    for (UIView *view in @[bar, _scroll, content]) view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_scroll];
    [self.view addSubview:bar];

    // Content is centered and never wider than 640 points, so it also reads well on a wide iPad.
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *wide = [content.widthAnchor constraintEqualToConstant:640];
    wide.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [bar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [bar.heightAnchor constraintEqualToConstant:38],
        [_refreshButton.widthAnchor constraintEqualToConstant:44],
        [_scroll.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:8],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_scroll.contentLayoutGuide.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor],
        [content.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:8],
        [content.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [content.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [content.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-32],
        wide,
        [_icon.heightAnchor constraintEqualToConstant:84],
        [stats.widthAnchor constraintEqualToAnchor:_hero.widthAnchor],
        [_hourStack.topAnchor constraintEqualToAnchor:hourScroll.contentLayoutGuide.topAnchor],
        [_hourStack.bottomAnchor constraintEqualToAnchor:hourScroll.contentLayoutGuide.bottomAnchor],
        [_hourStack.leadingAnchor constraintEqualToAnchor:hourScroll.contentLayoutGuide.leadingAnchor],
        [_hourStack.trailingAnchor constraintEqualToAnchor:hourScroll.contentLayoutGuide.trailingAnchor],
        [_hourStack.heightAnchor constraintEqualToAnchor:hourScroll.frameLayoutGuide.heightAnchor],
    ]];
}

#pragma mark Showing

// Converts a loaded temperature when the unit was switched after loading.
- (double)temperature:(double)value {
    if (_forecastFahrenheit == _fahrenheit) return value;
    return _fahrenheit ? value * 9 / 5 + 32 : (value - 32) * 5 / 9;
}

- (NSString *)degrees:(NSNumber *)value {
    return value ? [NSString stringWithFormat:@"%ld°", lround([self temperature:value.doubleValue])] : @"–";
}

- (UIView *)hourCellWithTime:(NSString *)time image:(UIImage *)image temperature:(NSString *)temperature {
    UILabel *timeLabel = WLabel(13, UIFontWeightSemibold, 0.8);
    timeLabel.text = time;
    UIImageView *icon = [[UIImageView alloc] initWithImage:image];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = [UIColor whiteColor];
    UILabel *tempLabel = WLabel(17, UIFontWeightSemibold, 1);
    tempLabel.text = temperature;
    UIStackView *cell = [[UIStackView alloc] initWithArrangedSubviews:@[timeLabel, icon, tempLabel]];
    cell.axis = UILayoutConstraintAxisVertical;
    cell.alignment = UIStackViewAlignmentCenter;
    cell.spacing = 8;
    [cell.widthAnchor constraintGreaterThanOrEqualToConstant:50].active = YES;
    [icon.heightAnchor constraintEqualToConstant:28].active = YES;
    return cell;
}

- (UIView *)dayRowWithName:(NSString *)name image:(UIImage *)image low:(NSNumber *)low high:(NSNumber *)high
                   weekLow:(double)weekLow weekHigh:(double)weekHigh {
    UILabel *nameLabel = WLabel(17, UIFontWeightMedium, 1);
    nameLabel.text = name;
    UIImageView *icon = [[UIImageView alloc] initWithImage:image];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = [UIColor whiteColor];
    UILabel *lowLabel = WLabel(17, UIFontWeightMedium, 0.65), *highLabel = WLabel(17, UIFontWeightMedium, 1);
    lowLabel.text = [self degrees:low];
    highLabel.text = [self degrees:high];
    lowLabel.textAlignment = highLabel.textAlignment = NSTextAlignmentRight;
    WeatherRangeBar *bar = [[WeatherRangeBar alloc] init];
    double span = weekHigh - weekLow;
    if (low && high && span > 0) {
        bar.start = (low.doubleValue - weekLow) / span;
        bar.end = (high.doubleValue - weekLow) / span;
    } else {
        bar.end = 1;
    }
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[nameLabel, icon, lowLabel, bar, highLabel]];
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 10;
    row.isAccessibilityElement = YES;
    row.accessibilityLabel = [NSString stringWithFormat:@"%@, low %@, high %@", name, lowLabel.text, highLabel.text];
    [NSLayoutConstraint activateConstraints:@[
        [nameLabel.widthAnchor constraintEqualToConstant:62],
        [icon.widthAnchor constraintEqualToConstant:32],
        [icon.heightAnchor constraintEqualToConstant:26],
        [lowLabel.widthAnchor constraintEqualToConstant:42],
        [highLabel.widthAnchor constraintEqualToConstant:42],
    ]];
    return row;
}

// Puts everything known on screen. Safe to call in any state.
- (void)render {
    [self setTitle:_city ?: @"Choose a City" ofButton:_cityButton];
    [self setTitle:_fahrenheit ? @"°F" : @"°C" ofButton:_unitButton];
    _refreshButton.enabled = _city && !_loading;

    NSDictionary *current = WDict(_forecast[@"current"]);
    NSNumber *temp = WNum(current[@"temperature_2m"]);
    BOOL hasData = temp != nil;
    NSNumber *codeNumber = WNum(current[@"weather_code"]);
    NSInteger code = codeNumber ? codeNumber.integerValue : -1;
    NSNumber *dayNumber = WNum(current[@"is_day"]);
    BOOL day = dayNumber ? dayNumber.boolValue : YES;

    ((CAGradientLayer *)_sky.layer).colors = WSkyColors(hasData ? code : 0, day);

    // The message: no city yet, or the last load failed. Old numbers stay visible below an error.
    BOOL showMessage = !_city || _failed;
    if (showMessage) {
        _messageLabel.text = _city ? @"Couldn't load the weather. Check your connection." : @"Pick a city to see its weather.";
        [self setTitle:_city ? @"Try Again" : @"Search for a City" ofButton:_messageButton];
    }
    BOOL spin = _loading && !hasData;
    if (spin) [_spinner startAnimating]; else [_spinner stopAnimating];
    if (hasData) [self renderForecastWithCurrent:current code:code day:day];

    // Sections that do not apply are taken out of the stack, so they leave no gap.
    NSMutableArray *sections = [NSMutableArray array];
    if (showMessage) [sections addObject:_message];
    if (spin) [sections addObject:_spinner];
    if (hasData) {
        [sections addObject:_hero];
        if (_hourStack.arrangedSubviews.count) [sections addObject:_hourCard];
        if (_dayStack.arrangedSubviews.count) [sections addObject:_dayCard];
        [sections addObject:_footer];
    }
    for (UIView *view in _content.arrangedSubviews) [view removeFromSuperview];
    for (UIView *view in sections) [_content addArrangedSubview:view];
}

- (void)renderForecastWithCurrent:(NSDictionary *)current code:(NSInteger)code day:(BOOL)day {
    NSNumber *temp = WNum(current[@"temperature_2m"]);

    NSDictionary *daily = WDict(_forecast[@"daily"]);
    NSArray *dayTimes = WArr(daily[@"time"]), *dayCodes = WArr(daily[@"weather_code"]);
    NSArray *highs = WArr(daily[@"temperature_2m_max"]), *lows = WArr(daily[@"temperature_2m_min"]);

    _icon.image = WSymbol(code, day, 64);
    _tempLabel.text = [self degrees:temp];
    _conditionLabel.text = code >= 0 ? WConditionText(code) : @"";
    NSNumber *todayHigh = WNum(WAt(highs, 0)), *todayLow = WNum(WAt(lows, 0));
    _rangeLabel.text = (todayHigh && todayLow) ? [NSString stringWithFormat:@"H: %@   L: %@", [self degrees:todayHigh], [self degrees:todayLow]] : @"";
    _feelsLabel.text = [self degrees:WNum(current[@"apparent_temperature"])];
    NSNumber *wind = WNum(current[@"wind_speed_10m"]), *humidity = WNum(current[@"relative_humidity_2m"]);
    double speed = wind.doubleValue;
    if (_forecastFahrenheit != _fahrenheit) speed = _fahrenheit ? speed / 1.609344 : speed * 1.609344;
    _windLabel.text = wind ? [NSString stringWithFormat:@"%ld %@", lround(speed), _fahrenheit ? @"mph" : @"km/h"] : @"–";
    _humidityLabel.text = humidity ? [NSString stringWithFormat:@"%ld%%", lround(humidity.doubleValue)] : @"–";

    // Hours, starting at the current one. Times sort as text, e.g. "2026-10-02T14:00".
    NSDictionary *hourly = WDict(_forecast[@"hourly"]);
    NSArray *hourTimes = WArr(hourly[@"time"]), *hourTemps = WArr(hourly[@"temperature_2m"]), *hourCodes = WArr(hourly[@"weather_code"]);
    NSString *now = WStr(current[@"time"]);
    NSString *thisHour = now.length >= 13 ? [now substringToIndex:13] : nil;
    NSUInteger first = 0;
    for (NSUInteger i = 0; thisHour && i < hourTimes.count; i++) {
        NSString *time = WStr(hourTimes[i]);
        if (time && [time compare:thisHour] != NSOrderedAscending) { first = i; break; }
    }
    NSDateFormatter *hourParser = WFormatter(@"yyyy-MM-dd'T'HH:mm", nil), *hourPrinter = WFormatter(nil, @"j");
    for (UIView *view in _hourStack.arrangedSubviews) [view removeFromSuperview];
    for (NSUInteger i = first, shown = 0; i < hourTimes.count && shown < 24; i++) {
        NSString *time = WStr(hourTimes[i]);
        NSNumber *hourTemp = WNum(WAt(hourTemps, i)), *hourCode = WNum(WAt(hourCodes, i));
        NSDate *date = time ? [hourParser dateFromString:time] : nil;
        if (!date || !hourTemp) continue;
        // The hourly feed has no day/night flag, so later hours go by the clock: 6 to 19 is day.
        NSInteger hour = time.length >= 13 ? [[time substringWithRange:NSMakeRange(11, 2)] integerValue] : 12;
        BOOL hourIsDay = shown == 0 ? day : (hour >= 6 && hour < 19);
        [_hourStack addArrangedSubview:[self hourCellWithTime:shown == 0 ? @"Now" : [hourPrinter stringFromDate:date]
                                                        image:WSymbol(hourCode ? hourCode.integerValue : -1, hourIsDay, 22)
                                                  temperature:[self degrees:hourTemp]]];
        shown++;
    }

    // Days. The bars are scaled to the coldest and warmest readings of the week.
    NSUInteger dayCount = MIN((NSUInteger)7, dayTimes.count);
    double weekLow = DBL_MAX, weekHigh = -DBL_MAX;
    for (NSUInteger i = 0; i < dayCount; i++) {
        NSNumber *low = WNum(WAt(lows, i)), *high = WNum(WAt(highs, i));
        if (low) weekLow = MIN(weekLow, low.doubleValue);
        if (high) weekHigh = MAX(weekHigh, high.doubleValue);
    }
    NSDateFormatter *dayParser = WFormatter(@"yyyy-MM-dd", nil), *dayPrinter = WFormatter(nil, @"EEE");
    for (UIView *view in _dayStack.arrangedSubviews) [view removeFromSuperview];
    for (NSUInteger i = 0; i < dayCount; i++) {
        NSString *time = WStr(dayTimes[i]);
        NSDate *date = time ? [dayParser dateFromString:time] : nil;
        if (!date) continue;
        NSNumber *dayCode = WNum(WAt(dayCodes, i));
        BOOL today = now.length >= 10 && [time isEqualToString:[now substringToIndex:10]];
        [_dayStack addArrangedSubview:[self dayRowWithName:today ? @"Today" : [dayPrinter stringFromDate:date]
                                                     image:WSymbol(dayCode ? dayCode.integerValue : -1, YES, 20)
                                                       low:WNum(WAt(lows, i)) high:WNum(WAt(highs, i))
                                                   weekLow:weekLow weekHigh:weekHigh]];
    }

    NSString *when = _loadedAt ? [NSDateFormatter localizedStringFromDate:_loadedAt dateStyle:NSDateFormatterNoStyle
                                                                 timeStyle:NSDateFormatterShortStyle] : nil;
    _footer.text = [NSString stringWithFormat:@"%@Weather data by Open-Meteo.com", when ? [NSString stringWithFormat:@"Updated %@ · ", when] : @""];
}

#pragma mark Actions and loading

- (void)messageButtonTapped {
    if (_city) [self refresh]; else [self changeCity];
}

- (void)changeCity {
    if (self.presentedViewController) return;
    WeatherSearchController *search = [[WeatherSearchController alloc] init];
    __weak typeof(self) weakSelf = self;
    search.onPick = ^(NSString *name, double latitude, double longitude) {
        [weakSelf useCity:name latitude:latitude longitude:longitude];
    };
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:search];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)useCity:(NSString *)name latitude:(double)latitude longitude:(double)longitude {
    _city = [name copy];
    _latitude = latitude;
    _longitude = longitude;
    // The old city's numbers must not be shown, or shared, under the new name.
    _forecast = nil;
    _loadedAt = nil;
    _sharedTemp = _sharedCode = nil;
    _sharedUpdated = nil;
    [self saveSettings];
    [self writeShared];
    [self refresh];
}

- (void)toggleUnit {
    _fahrenheit = !_fahrenheit;
    if (_sharedTemp) _sharedTemp = @(_fahrenheit ? _sharedTemp.doubleValue * 9 / 5 + 32 : (_sharedTemp.doubleValue - 32) * 5 / 9);
    [self saveSettings];
    [self writeShared];
    [self render];   // shows converted numbers at once; the reload below replaces them
    if (_city) [self refresh];
}

- (void)saveSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:_fahrenheit forKey:@"fahrenheit"];
    if (_city) {
        [defaults setObject:_city forKey:@"city"];
        [defaults setDouble:_latitude forKey:@"latitude"];
        [defaults setDouble:_longitude forKey:@"longitude"];
    }
}

// The file the Lock Screen reads. Failures are ignored: the app works without it.
- (void)writeShared {
    if (!_city) return;
    NSMutableDictionary *shared = [NSMutableDictionary dictionary];
    shared[@"city"] = _city;
    shared[@"latitude"] = @(_latitude);
    shared[@"longitude"] = @(_longitude);
    shared[@"fahrenheit"] = @(_fahrenheit);
    shared[@"updated"] = _sharedUpdated ?: [NSDate dateWithTimeIntervalSince1970:0];
    // Right after a city change there is no reading yet; these two appear once the forecast loads.
    if (_sharedTemp) {
        shared[@"temp"] = _sharedTemp;
        shared[@"code"] = _sharedCode ?: @0;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:shared format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    if (!data) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:[kSharedPath stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    [data writeToFile:kSharedPath options:NSDataWritingAtomic error:NULL];
}

- (void)refresh {
    if (!_city) {
        [_scroll.refreshControl endRefreshing];
        return;
    }
    BOOL fahrenheit = _fahrenheit;
    NSUInteger generation = ++_generation;   // a newer request makes older answers irrelevant
    NSString *address = [NSString stringWithFormat:@"https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f"
        @"&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m,relative_humidity_2m,is_day"
        @"&hourly=temperature_2m,weather_code&daily=weather_code,temperature_2m_max,temperature_2m_min"
        @"&temperature_unit=%@&wind_speed_unit=%@&timezone=auto&forecast_days=7",
        _latitude, _longitude, fahrenheit ? @"fahrenheit" : @"celsius", fahrenheit ? @"mph" : @"kmh"];
    _loading = YES;
    _failed = NO;
    [self render];
    __weak typeof(self) weakSelf = self;
    WFetch(address, ^(NSDictionary *json) {
        WeatherViewController *me = weakSelf;
        if (!me || generation != me->_generation) return;
        me->_loading = NO;
        [me->_scroll.refreshControl endRefreshing];
        NSDictionary *current = WDict(json[@"current"]);
        NSNumber *temp = WNum(current[@"temperature_2m"]);
        if (temp) {
            me->_forecast = json;
            me->_forecastFahrenheit = fahrenheit;
            me->_loadedAt = [NSDate date];
            me->_sharedTemp = @([me temperature:temp.doubleValue]);
            me->_sharedCode = WNum(current[@"weather_code"]) ?: @0;
            me->_sharedUpdated = me->_loadedAt;
            [me writeShared];
        } else {
            me->_failed = YES;   // offline, a server error, or an answer without a temperature
        }
        [me render];
    });
}

@end

#pragma mark - App

@interface WeatherAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation WeatherAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[WeatherViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([WeatherAppDelegate class]));
    }
}
