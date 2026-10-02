//
//  Phone for iPad (part of Volta).
//
//  An iPad cannot place cellular calls, so this is a look-alike that is honest
//  about it: the keypad, tones, favorites and recents all work, and "calling"
//  ends by offering FaceTime Audio, which is real.
//

#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>

#define HEX(v) [UIColor colorWithRed:(((v) >> 16) & 0xFF) / 255.0 green:(((v) >> 8) & 0xFF) / 255.0 blue:((v) & 0xFF) / 255.0 alpha:1]
#define TEAL HEX(0x19C8B9)

#pragma mark - Storage

static NSString * const kRecents = @"recents";      // [{number, name?, date}]
static NSString * const kFavorites = @"favorites";  // [{name, number}]

static NSArray<NSDictionary *> *PHList(NSString *key) {
    NSArray *list = [[NSUserDefaults standardUserDefaults] arrayForKey:key];
    return [list isKindOfClass:[NSArray class]] ? list : @[];
}

static void PHSetList(NSString *key, NSArray *list) {
    [[NSUserDefaults standardUserDefaults] setObject:list forKey:key];
}

static NSString *PHNameForNumber(NSString *number) {
    for (NSDictionary *favorite in PHList(kFavorites)) {
        if ([favorite[@"number"] isEqual:number]) return favorite[@"name"];
    }
    return nil;
}

static void PHAddRecent(NSString *number) {
    NSMutableArray *recents = [PHList(kRecents) mutableCopy];
    [recents insertObject:@{@"number": number, @"date": [NSDate date]} atIndex:0];
    while (recents.count > 60) [recents removeLastObject];
    PHSetList(kRecents, recents);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"PHRecentsChanged" object:nil];
}

#pragma mark - Call screen

@interface PHCallController : UIViewController
@property (nonatomic, copy) NSString *number;
@end

@implementation PHCallController {
    CAGradientLayer *_background;
    UILabel *_name, *_status;
    UIButton *_end, *_faceTime;
    NSTimer *_timer;
    NSInteger _ticks;
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

- (UIButton *)pillWithTitle:(NSString *)title symbol:(NSString *)symbol color:(UIColor *)color action:(SEL)action {
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = title;
    config.image = [UIImage systemImageNamed:symbol];
    config.imagePadding = 8;
    config.baseBackgroundColor = color;
    config.baseForegroundColor = [UIColor whiteColor];
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.contentInsets = NSDirectionalEdgeInsetsMake(14, 22, 14, 22);
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _background = [CAGradientLayer layer];
    _background.colors = @[(id)HEX(0x15143A).CGColor, (id)HEX(0x1B4B5A).CGColor];
    [self.view.layer addSublayer:_background];

    _name = [[UILabel alloc] init];
    _name.text = PHNameForNumber(self.number) ?: self.number;
    _name.font = [UIFont systemFontOfSize:38 weight:UIFontWeightRegular];
    _name.textColor = [UIColor whiteColor];
    _name.textAlignment = NSTextAlignmentCenter;
    _name.adjustsFontSizeToFitWidth = YES;
    _name.minimumScaleFactor = 0.5;
    [self.view addSubview:_name];

    _status = [[UILabel alloc] init];
    _status.text = @"calling…";
    _status.font = [UIFont systemFontOfSize:19 weight:UIFontWeightRegular];
    _status.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 0;
    [self.view addSubview:_status];

    _faceTime = [self pillWithTitle:@"Try FaceTime Audio" symbol:@"phone.arrow.up.right.fill" color:TEAL action:@selector(faceTime)];
    _faceTime.alpha = 0;
    _end = [self pillWithTitle:@"End" symbol:@"phone.down.fill" color:[UIColor systemRedColor] action:@selector(end)];

    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:YES block:^(NSTimer *timer) { [weakSelf tick]; }];
}

// A few seconds of "calling", then the truth.
- (void)tick {
    _ticks++;
    if (_ticks < 5) {
        _status.text = [NSString stringWithFormat:@"calling%@", [@"..." substringToIndex:(_ticks % 3) + 1]];
        return;
    }
    [_timer invalidate];
    _timer = nil;
    _status.text = @"Can't connect.\nThis iPad has no cellular calling.";
    [UIView animateWithDuration:0.3 animations:^{ self->_faceTime.alpha = 1; }];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, _status.text);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _background.frame = self.view.bounds;
    [CATransaction commit];
    _name.frame = CGRectMake(24, h * 0.16, w - 48, 48);
    _status.frame = CGRectMake(24, CGRectGetMaxY(_name.frame) + 8, w - 48, 56);
    CGSize endSize = [_end sizeThatFits:CGSizeMake(w, 60)], faceSize = [_faceTime sizeThatFits:CGSizeMake(w, 60)];
    _end.frame = CGRectMake((w - MAX(endSize.width, 150)) / 2, h * 0.80 - 28, MAX(endSize.width, 150), 56);
    _faceTime.frame = CGRectMake((w - faceSize.width) / 2, CGRectGetMinY(_end.frame) - 74, faceSize.width, 56);
}

- (void)faceTime {
    NSString *digits = [[self.number componentsSeparatedByCharactersInSet:
                         [[NSCharacterSet characterSetWithCharactersInString:@"0123456789+"] invertedSet]] componentsJoinedByString:@""];
    NSURL *url = [NSURL URLWithString:[@"facetime-audio://" stringByAppendingString:digits]];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    [self end];
}

- (void)end {
    [_timer invalidate];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

static void PHStartCall(UIViewController *from, NSString *number) {
    if (!number.length) return;
    PHAddRecent(number);
    PHCallController *call = [[PHCallController alloc] init];
    call.number = number;
    call.modalPresentationStyle = UIModalPresentationFullScreen;
    [from presentViewController:call animated:YES completion:nil];
}

#pragma mark - Keypad

@interface PHKeyButton : UIButton
@property (nonatomic, copy) NSString *digit;
@end

@implementation PHKeyButton
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:highlighted ? 0.03 : 0.3 animations:^{
        self.backgroundColor = highlighted ? [UIColor tertiaryLabelColor] : [UIColor secondarySystemFillColor];
    }];
}
@end

@interface PHKeypadController : UIViewController
@end

@implementation PHKeypadController {
    NSMutableString *_number;
    UILabel *_display;
    NSMutableArray<PHKeyButton *> *_keys;
    UIButton *_call, *_delete;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    _number = [NSMutableString string];

    _display = [[UILabel alloc] init];
    _display.font = [UIFont systemFontOfSize:40 weight:UIFontWeightRegular];
    _display.textAlignment = NSTextAlignmentCenter;
    _display.adjustsFontSizeToFitWidth = YES;
    _display.minimumScaleFactor = 0.4;
    _display.accessibilityLabel = @"Number";
    [self.view addSubview:_display];

    NSArray *digits = @[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"*", @"0", @"#"];
    NSArray *letters = @[@" ", @"ABC", @"DEF", @"GHI", @"JKL", @"MNO", @"PQRS", @"TUV", @"WXYZ", @"", @"+", @""];
    _keys = [NSMutableArray array];
    for (NSInteger i = 0; i < 12; i++) {
        PHKeyButton *key = [PHKeyButton buttonWithType:UIButtonTypeCustom];
        key.digit = digits[i];
        key.backgroundColor = [UIColor secondarySystemFillColor];
        NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:digits[i] attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:34 weight:UIFontWeightRegular], NSForegroundColorAttributeName: [UIColor labelColor]}];
        if ([letters[i] length]) {
            [title appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:letters[i]] attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightBold], NSForegroundColorAttributeName: [UIColor labelColor],
                NSKernAttributeName: @1.5}]];
        }
        key.titleLabel.numberOfLines = 2;
        key.titleLabel.textAlignment = NSTextAlignmentCenter;
        [key setAttributedTitle:title forState:UIControlStateNormal];
        key.accessibilityLabel = [digits[i] isEqualToString:@"*"] ? @"Star" : ([digits[i] isEqualToString:@"#"] ? @"Pound" : digits[i]);
        [key addTarget:self action:@selector(keyDown:) forControlEvents:UIControlEventTouchDown];
        if ([digits[i] isEqualToString:@"0"]) {   // hold 0 for "+"
            [key addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(zeroHeld:)]];
        }
        [self.view addSubview:key];
        [_keys addObject:key];
    }

    _call = [UIButton buttonWithType:UIButtonTypeCustom];
    _call.backgroundColor = TEAL;
    _call.tintColor = [UIColor whiteColor];
    [_call setImage:[UIImage systemImageNamed:@"phone.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightMedium]]
           forState:UIControlStateNormal];
    _call.accessibilityLabel = @"Call";
    [_call addTarget:self action:@selector(call) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_call];

    _delete = [UIButton buttonWithType:UIButtonTypeSystem];
    _delete.tintColor = [UIColor secondaryLabelColor];
    [_delete setImage:[UIImage systemImageNamed:@"delete.left.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular]]
             forState:UIControlStateNormal];
    _delete.accessibilityLabel = @"Delete";
    [_delete addTarget:self action:@selector(deleteDigit) forControlEvents:UIControlEventTouchUpInside];
    [_delete addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(clearHeld:)]];
    [self.view addSubview:_delete];
    [self refresh];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat width = self.view.bounds.size.width, height = self.view.bounds.size.height - safe.top - safe.bottom;
    // Number, four rows of keys, then the call row.
    CGFloat size = floor(MIN(MIN((width - 80) / 3.6, (height - 110) / 6.2), 84));
    CGFloat gapX = size * 0.34, gapY = size * 0.2;
    CGFloat gridWidth = size * 3 + gapX * 2, gridHeight = size * 5 + gapY * 4;
    CGFloat x0 = (width - gridWidth) / 2, y0 = safe.top + (height - gridHeight - 70) / 2 + 70;
    _display.frame = CGRectMake(24, y0 - 70, width - 48, 50);
    for (NSInteger i = 0; i < 12; i++) {
        _keys[i].frame = CGRectMake(x0 + (i % 3) * (size + gapX), y0 + (i / 3) * (size + gapY), size, size);
        _keys[i].layer.cornerRadius = size / 2;
    }
    CGFloat rowY = y0 + 4 * (size + gapY);
    _call.frame = CGRectMake(x0 + size + gapX, rowY, size, size);
    _call.layer.cornerRadius = size / 2;
    _delete.frame = CGRectMake(x0 + 2 * (size + gapX), rowY, size, size);
}

- (void)refresh {
    _display.text = _number;
    _delete.hidden = _number.length == 0;
}

- (void)keyDown:(PHKeyButton *)key {
    if (_number.length >= 24) return;
    // Touch tones: system sounds 1200 - 1209 are 0 - 9, then * and #.
    NSInteger index = [@"0123456789*#" rangeOfString:key.digit].location;
    if (index != NSNotFound) AudioServicesPlaySystemSound((SystemSoundID)(1200 + index));
    [_number appendString:key.digit];
    [self refresh];
}

- (void)zeroHeld:(UILongPressGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan || !_number.length) return;
    [_number replaceCharactersInRange:NSMakeRange(_number.length - 1, 1) withString:@"+"];
    [self refresh];
}

- (void)deleteDigit {
    if (_number.length) [_number deleteCharactersInRange:NSMakeRange(_number.length - 1, 1)];
    [self refresh];
}

- (void)clearHeld:(UILongPressGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan) return;
    [_number setString:@""];
    [self refresh];
}

- (void)call {
    if (!_number.length) {   // like a real phone: with nothing typed, bring back the last number
        NSString *last = PHList(kRecents).firstObject[@"number"];
        if (last) { [_number setString:last]; [self refresh]; }
        return;
    }
    PHStartCall(self, [_number copy]);
    [_number setString:@""];
    [self refresh];
}

@end

#pragma mark - Lists

@interface PHRecentsController : UITableViewController
@end

@implementation PHRecentsController

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Recents";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStylePlain target:self action:@selector(clear)];
    [[NSNotificationCenter defaultCenter] addObserver:self.tableView selector:@selector(reloadData) name:@"PHRecentsChanged" object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)clear {
    PHSetList(kRecents, @[]);
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return PHList(kRecents).count; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return PHList(kRecents).count ? nil : @"Numbers you dial show up here.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"recent"]
                         ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"recent"];
    NSDictionary *recent = PHList(kRecents)[indexPath.row];
    cell.textLabel.text = PHNameForNumber(recent[@"number"]) ?: recent[@"number"];
    cell.detailTextLabel.text = [NSDateFormatter localizedStringFromDate:recent[@"date"] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
    cell.imageView.image = [UIImage systemImageNamed:@"phone.arrow.up.right"];
    cell.imageView.tintColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PHStartCall(self, PHList(kRecents)[indexPath.row][@"number"]);
}

@end

@interface PHFavoritesController : UITableViewController
@end

@implementation PHFavoritesController

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Favorites";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(add)];
}

- (void)add {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"New Favorite" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Name";
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Number";
        field.keyboardType = UIKeyboardTypePhonePad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *name = [weakAlert.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *number = [weakAlert.textFields[1].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!number.length) return;
        NSMutableArray *favorites = [PHList(kFavorites) mutableCopy];
        [favorites addObject:@{@"name": name.length ? name : number, @"number": number}];
        PHSetList(kFavorites, favorites);
        [weakSelf.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return PHList(kFavorites).count; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return PHList(kFavorites).count ? @"Swipe left on a favorite to remove it." : @"Tap + to add a name and number.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"favorite"]
                         ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"favorite"];
    NSDictionary *favorite = PHList(kFavorites)[indexPath.row];
    cell.textLabel.text = favorite[@"name"];
    cell.detailTextLabel.text = favorite[@"number"];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.image = [UIImage systemImageNamed:@"star.fill"];
    cell.imageView.tintColor = [UIColor systemYellowColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PHStartCall(self, PHList(kFavorites)[indexPath.row][@"number"]);
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    NSMutableArray *favorites = [PHList(kFavorites) mutableCopy];
    [favorites removeObjectAtIndex:indexPath.row];
    PHSetList(kFavorites, favorites);
    [tableView reloadData];
}

@end

@interface PHVoicemailController : UIViewController
@end

@implementation PHVoicemailController {
    UIImageView *_icon;
    UILabel *_text;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Voicemail";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    _icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"recordingtape" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:54 weight:UIImageSymbolWeightLight]]];
    _icon.tintColor = [UIColor tertiaryLabelColor];
    _icon.contentMode = UIViewContentModeCenter;
    [self.view addSubview:_icon];
    _text = [[UILabel alloc] init];
    _text.text = @"No Voicemail\nVoicemail needs a cellular plan, which this iPad does not have.";
    _text.numberOfLines = 0;
    _text.textAlignment = NSTextAlignmentCenter;
    _text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _text.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:_text];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    _icon.frame = CGRectMake(0, h * 0.36 - 40, w, 80);
    _text.frame = CGRectMake(40, CGRectGetMaxY(_icon.frame) + 8, w - 80, 90);
}

@end

#pragma mark - App

@interface PHAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation PHAppDelegate

- (UIViewController *)tab:(UIViewController *)controller title:(NSString *)title symbol:(NSString *)symbol wrap:(BOOL)wrap {
    UIViewController *root = wrap ? [[UINavigationController alloc] initWithRootViewController:controller] : controller;
    root.tabBarItem = [[UITabBarItem alloc] initWithTitle:title image:[UIImage systemImageNamed:symbol] tag:0];
    return root;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    UITabBarController *tabs = [[UITabBarController alloc] init];
    tabs.viewControllers = @[
        [self tab:[[PHFavoritesController alloc] init] title:@"Favorites" symbol:@"star.fill" wrap:YES],
        [self tab:[[PHRecentsController alloc] init] title:@"Recents" symbol:@"clock.fill" wrap:YES],
        [self tab:[[PHKeypadController alloc] init] title:@"Keypad" symbol:@"circle.grid.3x3.fill" wrap:NO],
        [self tab:[[PHVoicemailController alloc] init] title:@"Voicemail" symbol:@"recordingtape" wrap:YES],
    ];
    tabs.selectedIndex = 2;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.tintColor = TEAL;
    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([PHAppDelegate class]));
    }
}
