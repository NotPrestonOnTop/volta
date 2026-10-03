// Volta - Lock Screen look: the clock's typeface, color, size and position,
// a message under it, and hiding the smaller bits. SpringBoard only.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import "VLTShared.h"
#import "VLTLook.h"

@interface _UILegibilitySettings : NSObject
- (id)initWithStyle:(NSInteger)style primaryColor:(UIColor *)primary secondaryColor:(UIColor *)secondary shadowColor:(UIColor *)shadow;
- (NSInteger)style;
- (UIColor *)shadowColor;
@end

@interface SBFLockScreenDateView : UIView
+ (UIFont *)timeFont;
- (void)setLegibilitySettings:(_UILegibilitySettings *)settings;
- (void)setSubtitleHidden:(BOOL)hidden;
- (id)_timeLabel;
@end

#pragma mark - Settings

static BOOL gLookOn;
static NSInteger gFont;             // 0 system, 1 rounded, 2 serif, 3 mono, 4 heavy, 5 ultra light
static UIColor *gClockColor;
static CGFloat gClockScale = 1, gClockX, gClockY;
static BOOL gHideDate;
static NSString *gMessage;
static BOOL gHideHint, gHideDots, gHideQuick, gHideLockIcon;
// Widgets under the clock
static BOOL gWidgetWeather, gWidgetBattery, gWidgetCountdown, gWidgetGreeting, gWidgetDay, gWidgetPlain;
static NSString *gCountdownDate, *gCountdownLabel;
static NSInteger gWidgetGen;     // bumped whenever the chips need rebuilding

static void VLTLoadLookPrefs(void) {
    NSDictionary *p = VLTCopyPrefs();
    gLookOn = VLTBool(p, @"enabled", YES) && VLTBool(p, @"lockLookOn", NO);
    gFont = gLookOn ? (NSInteger)VLTNum(p, @"lockClockFont", 0) : 0;
    if (gFont < 0 || gFont > 5) gFont = 0;
    gClockColor = gLookOn ? VLTColorFromHex(p[@"lockClockColor"]) : nil;
    gClockScale = gLookOn ? fmin(fmax(VLTNum(p, @"lockClockScale", 100) / 100.0, 0.5), 2.0) : 1;
    gClockX = gLookOn ? fmin(fmax(VLTNum(p, @"lockClockX", 0), -400), 400) : 0;
    gClockY = gLookOn ? fmin(fmax(VLTNum(p, @"lockClockY", 0), -200), 600) : 0;
    gHideDate = gLookOn && VLTBool(p, @"lockHideDate", NO);
    NSString *message = [VLTStr(p, @"lockMessage") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    gMessage = (gLookOn && message.length) ? (message.length > 120 ? [message substringToIndex:120] : message) : nil;
    gHideHint = gLookOn && VLTBool(p, @"lockHideHint", NO);
    gHideDots = gLookOn && VLTBool(p, @"lockHideDots", NO);
    gHideQuick = gLookOn && VLTBool(p, @"lockHideQuick", NO);
    gHideLockIcon = gLookOn && VLTBool(p, @"lockHideLockIcon", NO);
    gWidgetWeather = VLTBool(p, @"lwWeather", NO);
    gWidgetBattery = VLTBool(p, @"lwBattery", NO);
    gWidgetCountdown = VLTBool(p, @"lwCountdown", NO);
    gWidgetGreeting = VLTBool(p, @"lwGreeting", NO);
    gWidgetDay = VLTBool(p, @"lwDay", NO);
    gWidgetPlain = VLTBool(p, @"lwPlain", NO);
    gCountdownDate = [VLTStr(p, @"lwCountdownDate") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *countdownLabel = [VLTStr(p, @"lwCountdownLabel") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    gCountdownLabel = countdownLabel.length > 30 ? [countdownLabel substringToIndex:30] : countdownLabel;
    gWidgetGen++;
}

static NSHashTable *VLTLookTable(int which) {
    static NSHashTable *tables[5];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ for (int i = 0; i < 5; i++) tables[i] = [NSHashTable weakObjectsHashTable]; });
    return tables[which];
}
#define VLTDateViews() VLTLookTable(0)

#pragma mark - Widgets under the clock

// Small facts shown as a row of chips: weather, battery, a countdown, a
// greeting, the day of the year. Texts are worked out at most every 20 seconds.

static BOOL VLTWidgetsOn(void) {
    return gLookOn && (gWidgetWeather || gWidgetBattery || gWidgetCountdown || gWidgetGreeting || gWidgetDay);
}

static NSString *VLTWeatherWord(NSInteger code) {
    if (code == 0) return @"Clear";
    if (code <= 2) return @"Partly cloudy";
    if (code == 3) return @"Cloudy";
    if (code == 45 || code == 48) return @"Fog";
    if (code >= 51 && code <= 57) return @"Drizzle";
    if (code >= 61 && code <= 67) return @"Rain";
    if (code >= 71 && code <= 77) return @"Snow";
    if (code >= 80 && code <= 82) return @"Showers";
    if (code == 85 || code == 86) return @"Snow showers";
    if (code >= 95) return @"Thunderstorm";
    return @"Weather";
}

static NSString *VLTWeatherSymbol(NSInteger code) {
    if (code == 0) return @"sun.max.fill";
    if (code <= 2) return @"cloud.sun.fill";
    if (code == 3) return @"cloud.fill";
    if (code == 45 || code == 48) return @"cloud.fog.fill";
    if (code >= 51 && code <= 67) return @"cloud.rain.fill";
    if ((code >= 71 && code <= 77) || code == 85 || code == 86) return @"cloud.snow.fill";
    if (code >= 80 && code <= 82) return @"cloud.heavyrain.fill";
    if (code >= 95) return @"cloud.bolt.rain.fill";
    return @"cloud.fill";
}

// The latest reading: fetched here at most every 30 minutes for the city
// chosen in the Weather app (which writes weather.plist), and kept in memory.
static NSNumber *gWeatherTemp, *gWeatherCode;
static NSString *gWeatherFor;       // "lat,lon,unit" the reading belongs to
static NSDate *gWeatherAt, *gWeatherTried;

static void VLTRefreshClocks(void);

static void VLTFetchWeather(double latitude, double longitude, BOOL fahrenheit, NSString *key) {
    // One try per quarter of an hour for a place, so being offline costs next to nothing.
    static NSString *triedKey;
    if (gWeatherTried && [triedKey isEqualToString:key] && [gWeatherTried timeIntervalSinceNow] > -900) return;
    gWeatherTried = [NSDate date];
    triedKey = [key copy];
    NSString *address = [NSString stringWithFormat:@"https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current=temperature_2m,weather_code&temperature_unit=%@",
                         latitude, longitude, fahrenheit ? @"fahrenheit" : @"celsius"];
    NSURL *url = [NSURL URLWithString:address];
    if (!url) return;
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 12;
    configuration.timeoutIntervalForResource = 20;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        [session finishTasksAndInvalidate];
        if (!data || data.length > 64 * 1024) return;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        NSDictionary *current = [json isKindOfClass:[NSDictionary class]] ? json[@"current"] : nil;
        if (![current isKindOfClass:[NSDictionary class]]) return;
        NSNumber *temp = current[@"temperature_2m"], *code = current[@"weather_code"];
        if (![temp isKindOfClass:[NSNumber class]] || ![code isKindOfClass:[NSNumber class]]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            gWeatherTemp = temp;
            gWeatherCode = code;
            gWeatherFor = key;
            gWeatherAt = [NSDate date];
            gWidgetGen++;
            VLTRefreshClocks();
        });
    }] resume];
}

// @[symbol, text] or nil.
static NSArray *VLTWeatherChip(void) {
    NSDictionary *saved = nil;
    for (NSString *path in @[VLT_IMAGE_DIR @"/weather.plist"]) {
        NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([file isKindOfClass:[NSDictionary class]]) saved = file;
    }
    NSNumber *latitude = saved[@"latitude"], *longitude = saved[@"longitude"];
    if (![latitude isKindOfClass:[NSNumber class]] || ![longitude isKindOfClass:[NSNumber class]] ||
        fabs(latitude.doubleValue) > 90 || fabs(longitude.doubleValue) > 180) return @[@"cloud.fill", @"Pick a city in Weather"];
    BOOL fahrenheit = VLTBool(saved, @"fahrenheit", YES);
    NSString *key = [NSString stringWithFormat:@"%.3f,%.3f,%d", latitude.doubleValue, longitude.doubleValue, fahrenheit];

    BOOL ours = [gWeatherFor isEqualToString:key] && gWeatherAt;
    if (!ours || [gWeatherAt timeIntervalSinceNow] < -1800) VLTFetchWeather(latitude.doubleValue, longitude.doubleValue, fahrenheit, key);
    NSNumber *temp = nil, *code = nil;
    if (ours && [gWeatherAt timeIntervalSinceNow] > -3 * 3600) {
        temp = gWeatherTemp;
        code = gWeatherCode;
    } else if ([saved[@"updated"] isKindOfClass:[NSDate class]] && [(NSDate *)saved[@"updated"] timeIntervalSinceNow] > -3 * 3600 &&
               [saved[@"temp"] isKindOfClass:[NSNumber class]] && [saved[@"code"] isKindOfClass:[NSNumber class]]) {
        temp = saved[@"temp"];   // what the Weather app last saw
        code = saved[@"code"];
    }
    if (!temp || !code) return @[@"cloud.fill", @"Weather unavailable"];
    return @[VLTWeatherSymbol(code.integerValue), [NSString stringWithFormat:@"%ld° %@", lround(temp.doubleValue), VLTWeatherWord(code.integerValue)]];
}

static NSArray *VLTCountdownChip(void) {
    static NSDateFormatter *parser;
    if (!parser) {
        parser = [[NSDateFormatter alloc] init];
        parser.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        parser.dateFormat = @"yyyy-MM-dd";
    }
    parser.timeZone = [NSTimeZone localTimeZone];
    NSDate *target = gCountdownDate.length ? [parser dateFromString:gCountdownDate] : nil;
    if (!target) return @[@"calendar", @"Set a date (2026-12-25)"];
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSInteger days = [calendar components:NSCalendarUnitDay fromDate:[calendar startOfDayForDate:[NSDate date]]
                                   toDate:[calendar startOfDayForDate:target] options:0].day;
    NSString *what = gCountdownLabel.length ? gCountdownLabel : @"the big day";
    NSString *text;
    if (days == 0) text = [NSString stringWithFormat:@"Today: %@", what];
    else if (days > 0) text = [NSString stringWithFormat:@"%ld day%@ to %@", (long)days, days == 1 ? @"" : @"s", what];
    else text = [NSString stringWithFormat:@"%ld day%@ since %@", (long)-days, days == -1 ? @"" : @"s", what];
    return @[@"calendar", text];
}

// Every chip to show, in order: @[@[symbol, text], ...]
static NSArray<NSArray *> *VLTWidgetChips(void) {
    static NSArray *cached;
    static CFTimeInterval cachedAt;
    static NSInteger cachedGen = -1;
    CFTimeInterval now = CACurrentMediaTime();
    if (cached && cachedGen == gWidgetGen && now - cachedAt < 20) return cached;

    NSMutableArray *chips = [NSMutableArray array];
    if (gWidgetWeather) {
        NSArray *chip = VLTWeatherChip();
        if (chip) [chips addObject:chip];
    }
    if (gWidgetBattery) {
        UIDevice *device = [UIDevice currentDevice];
        if (!device.batteryMonitoringEnabled) device.batteryMonitoringEnabled = YES;
        float level = device.batteryLevel;
        BOOL charging = device.batteryState == UIDeviceBatteryStateCharging || device.batteryState == UIDeviceBatteryStateFull;
        if (level >= 0) {
            NSString *symbol = charging ? @"battery.100.bolt" : (level > 0.5 ? @"battery.100" : @"battery.25");
            [chips addObject:@[symbol, [NSString stringWithFormat:@"%ld%%", lround(level * 100)]]];
        }
    }
    if (gWidgetCountdown) [chips addObject:VLTCountdownChip()];
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *today = [NSDate date];
    if (gWidgetGreeting) {
        NSInteger hour = [calendar component:NSCalendarUnitHour fromDate:today];
        NSString *text = hour < 5 ? @"Good night" : (hour < 12 ? @"Good morning" : (hour < 18 ? @"Good afternoon" : (hour < 22 ? @"Good evening" : @"Good night")));
        [chips addObject:@[(hour >= 6 && hour < 18) ? @"sun.max.fill" : @"moon.stars.fill", text]];
    }
    if (gWidgetDay) {
        NSInteger week = [calendar component:NSCalendarUnitWeekOfYear fromDate:today];
        NSInteger day = [calendar ordinalityOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitYear forDate:today];
        [chips addObject:@[@"number", [NSString stringWithFormat:@"Week %ld · Day %ld", (long)week, (long)day]]];
    }
    cached = chips;
    cachedAt = now;
    cachedGen = gWidgetGen;
    return chips;
}

@interface VLTWidgetRow : UIView
- (CGFloat)setChips:(NSArray<NSArray *> *)chips color:(UIColor *)color plain:(BOOL)plain width:(CGFloat)width;   // returns its height
@end

@implementation VLTWidgetRow {
    NSArray *_chips;
    UIColor *_color;
    BOOL _plain;
    CGFloat _width, _height;
}

- (CGFloat)setChips:(NSArray<NSArray *> *)chips color:(UIColor *)color plain:(BOOL)plain width:(CGFloat)width {
    if ([chips isEqual:_chips] && [color isEqual:_color] && plain == _plain && fabs(width - _width) < 0.5) return _height;
    _chips = [chips copy];
    _color = color;
    _plain = plain;
    _width = width;
    for (UIView *old in [self.subviews copy]) [old removeFromSuperview];

    // Build the chips, then lay them out in centred lines.
    UIFont *font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    for (NSArray *chip in chips) {
        if (chip.count != 2) continue;
        UIView *view = [[UIView alloc] init];
        view.userInteractionEnabled = NO;
        UIImage *image = [UIImage systemImageNamed:chip[0] withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]];
        UIImageView *icon = [[UIImageView alloc] initWithImage:image];
        icon.tintColor = color;
        icon.contentMode = UIViewContentModeCenter;
        UILabel *label = [[UILabel alloc] init];
        label.text = chip[1];
        label.font = font;
        label.textColor = color;
        CGFloat textWidth = MIN(ceil([label.text sizeWithAttributes:@{NSFontAttributeName: font}].width), width - 60);
        CGFloat padding = plain ? 2 : 11, height = 28;
        icon.frame = CGRectMake(padding, 0, 20, height);
        label.frame = CGRectMake(padding + 24, 0, textWidth, height);
        view.frame = CGRectMake(0, 0, padding * 2 + 24 + textWidth, height);
        if (!plain) {
            view.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
            view.layer.cornerRadius = height / 2;
        } else {
            view.layer.shadowColor = [UIColor blackColor].CGColor;
            view.layer.shadowOpacity = 0.35;
            view.layer.shadowRadius = 3;
            view.layer.shadowOffset = CGSizeZero;
        }
        [view addSubview:icon];
        [view addSubview:label];
        [self addSubview:view];
        [views addObject:view];
    }
    CGFloat gap = 8, y = 0;
    NSUInteger index = 0;
    while (index < views.count) {
        CGFloat lineWidth = 0;
        NSUInteger end = index;
        while (end < views.count) {
            CGFloat next = lineWidth + (end > index ? gap : 0) + views[end].frame.size.width;
            if (end > index && next > width) break;
            lineWidth = next;
            end++;
        }
        CGFloat x = (width - lineWidth) / 2;
        for (NSUInteger i = index; i < end; i++) {
            CGRect frame = views[i].frame;
            frame.origin = CGPointMake(round(x), y);
            views[i].frame = frame;
            x += frame.size.width + gap;
        }
        y += 28 + gap;
        index = end;
    }
    _height = views.count ? y - gap : 0;
    return _height;
}

@end

static const void *kWidgetRow = &kWidgetRow;

// below: where the row starts, in the date view's coordinates.
static void VLTApplyWidgets(UIView *view, CGFloat below) {
    VLTWidgetRow *row = objc_getAssociatedObject(view, kWidgetRow);
    if (!VLTWidgetsOn()) {
        if (row) {
            [row removeFromSuperview];
            objc_setAssociatedObject(view, kWidgetRow, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (!row) {
        row = [[VLTWidgetRow alloc] initWithFrame:CGRectZero];
        row.userInteractionEnabled = NO;
        objc_setAssociatedObject(view, kWidgetRow, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (row.superview != view) [view addSubview:row];
    CGFloat width = MAX(view.bounds.size.width, 320);
    CGFloat height = [row setChips:VLTWidgetChips() color:gClockColor ?: [UIColor whiteColor] plain:gWidgetPlain width:width];
    CGRect frame = CGRectMake((view.bounds.size.width - width) / 2, below, width, height);
    if (!CGRectEqualToRect(row.frame, frame)) row.frame = frame;
}

// Keeps the chips fresh while a Lock Screen clock is on screen.
static NSTimer *gWidgetTimer;

static void VLTSyncWidgetTimer(void) {
    BOOL needed = NO;
    if (VLTWidgetsOn()) {
        for (UIView *view in VLTDateViews().allObjects) if (view.window) { needed = YES; break; }
    }
    if (needed && !gWidgetTimer) {
        gWidgetTimer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) {
            // Nothing to refresh while the screen is off.
            static int blankToken = -1;
            if (blankToken == -1 && notify_register_check("com.apple.springboard.hasBlankedScreen", &blankToken) != NOTIFY_STATUS_OK) blankToken = -2;
            uint64_t blanked = 0;
            if (blankToken >= 0 && notify_get_state(blankToken, &blanked) == NOTIFY_STATUS_OK && blanked) return;
            BOOL any = NO;
            for (UIView *view in VLTDateViews().allObjects) {
                if (!view.window) continue;
                any = YES;
                [view setNeedsLayout];
            }
            if (!any || !VLTWidgetsOn()) {
                [gWidgetTimer invalidate];
                gWidgetTimer = nil;
            }
        }];
        gWidgetTimer.tolerance = 5;
    } else if (!needed && gWidgetTimer) {
        [gWidgetTimer invalidate];
        gWidgetTimer = nil;
    }
}

#pragma mark - Clock

static UIFont *VLTClockFont(UIFont *system) {
    if (![system isKindOfClass:[UIFont class]] || gFont == 0) return system;
    CGFloat size = system.pointSize;
    UIFont *font = nil;
    UIFontDescriptorSystemDesign design = nil;
    switch (gFont) {
        case 1: design = UIFontDescriptorSystemDesignRounded; break;
        case 2: design = UIFontDescriptorSystemDesignSerif; break;
        case 3: design = UIFontDescriptorSystemDesignMonospaced; break;
        case 4: font = [UIFont systemFontOfSize:size weight:UIFontWeightHeavy]; break;
        case 5: font = [UIFont systemFontOfSize:size weight:UIFontWeightUltraLight]; break;
        default: break;
    }
    if (design) {
        UIFont *base = [UIFont systemFontOfSize:size weight:UIFontWeightMedium];
        UIFontDescriptor *descriptor = [base.fontDescriptor fontDescriptorWithDesign:design];
        if (descriptor) font = [UIFont fontWithDescriptor:descriptor size:size];
    }
    return font ?: system;
}

static const void *kRealSettings = &kRealSettings;
static const void *kRealSubtitleHidden = &kRealSubtitleHidden;
static const void *kMessageLabel = &kMessageLabel;
static const void *kLookTouched = &kLookTouched;
static BOOL gLookReplaying;

static id VLTClockSettings(_UILegibilitySettings *real) {
    if (!gClockColor) return real;
    Class cls = NSClassFromString(@"_UILegibilitySettings");
    if (!cls || ![cls instancesRespondToSelector:@selector(initWithStyle:primaryColor:secondaryColor:shadowColor:)]) return real;
    NSInteger style = [real respondsToSelector:@selector(style)] ? [real style] : 1;
    UIColor *shadow = [real respondsToSelector:@selector(shadowColor)] ? [real shadowColor] : nil;
    return [[cls alloc] initWithStyle:style primaryColor:gClockColor
                       secondaryColor:[gClockColor colorWithAlphaComponent:0.7 * CGColorGetAlpha(gClockColor.CGColor)]
                          shadowColor:shadow ?: [UIColor colorWithWhite:0 alpha:0.3]];
}

static void VLTApplyClock(SBFLockScreenDateView *view) {
    CALayer *layer = view.layer;
    VLTPinOffset(layer, @"vltClockScale", @"transform.scale", gLookOn, gClockScale - 1);
    VLTPinOffset(layer, @"vltClockX", @"transform.translation.x", gLookOn, gClockX);
    VLTPinOffset(layer, @"vltClockY", @"transform.translation.y", gLookOn, gClockY);

    // Typeface. The label keeps whatever font it was given, so set it when the choice changes.
    // Compared as a plain stamp of what we last set, so layout can never chase itself.
    NSString *lastSet = objc_getAssociatedObject(view, kLookTouched);
    if ((gFont != 0 || lastSet) && [view respondsToSelector:@selector(_timeLabel)] && [[view class] respondsToSelector:@selector(timeFont)]) {
        id label = [view _timeLabel];
        UIFont *wanted = [[view class] timeFont];   // goes through the hook below
        NSString *stamp = [wanted isKindOfClass:[UIFont class]] ? [NSString stringWithFormat:@"%ld-%.1f", (long)gFont, wanted.pointSize] : nil;
        if (stamp && [label respondsToSelector:@selector(setFont:)] && ![lastSet isEqualToString:stamp]) {
            [label setFont:wanted];
            objc_setAssociatedObject(view, kLookTouched, stamp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [view setNeedsLayout];
        }
    }

    // The message, centred under the clock and date.
    UILabel *message = objc_getAssociatedObject(view, kMessageLabel);
    if (gMessage) {
        if (!message) {
            message = [[UILabel alloc] initWithFrame:CGRectZero];
            message.userInteractionEnabled = NO;
            message.textAlignment = NSTextAlignmentCenter;
            message.numberOfLines = 2;
            message.adjustsFontSizeToFitWidth = YES;
            message.minimumScaleFactor = 0.6;
            message.layer.shadowColor = [UIColor blackColor].CGColor;
            message.layer.shadowOpacity = 0.35;
            message.layer.shadowRadius = 3;
            message.layer.shadowOffset = CGSizeZero;
            objc_setAssociatedObject(view, kMessageLabel, message, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (message.superview != view) [view addSubview:message];
        UIFont *font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
        if (gFont == 1 || gFont == 2 || gFont == 3) {
            UIFontDescriptorSystemDesign design = gFont == 1 ? UIFontDescriptorSystemDesignRounded
                                                : (gFont == 2 ? UIFontDescriptorSystemDesignSerif : UIFontDescriptorSystemDesignMonospaced);
            UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorWithDesign:design];
            if (descriptor) font = [UIFont fontWithDescriptor:descriptor size:20];
        }
        if (![message.text isEqualToString:gMessage]) message.text = gMessage;
        if (![message.font isEqual:font]) message.font = font;
        UIColor *color = gClockColor ?: [UIColor whiteColor];
        if (![message.textColor isEqual:color]) message.textColor = color;
        CGFloat width = MAX(view.bounds.size.width, 280);
        CGRect frame = CGRectMake((view.bounds.size.width - width) / 2, view.bounds.size.height + 8, width, 54);
        if (!CGRectEqualToRect(message.frame, frame)) message.frame = frame;
    } else if (message) {
        [message removeFromSuperview];
        objc_setAssociatedObject(view, kMessageLabel, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        message = nil;
    }

    // Widgets go under the message, or straight under the clock when there is none.
    CGFloat below = view.bounds.size.height + 10;
    if (message) below = CGRectGetMinY(message.frame) + ceil([message sizeThatFits:CGSizeMake(message.bounds.size.width, 54)].height) + 10;
    VLTApplyWidgets(view, below);
}

// Pushes the real values back through the hooks so they pick up new settings.
static void VLTRefreshClocks(void) {
    for (SBFLockScreenDateView *view in VLTDateViews().allObjects) {
        gLookReplaying = YES;
        _UILegibilitySettings *settings = objc_getAssociatedObject(view, kRealSettings);
        if (settings && [view respondsToSelector:@selector(setLegibilitySettings:)]) [view setLegibilitySettings:settings];
        NSNumber *hidden = objc_getAssociatedObject(view, kRealSubtitleHidden);
        if ([view respondsToSelector:@selector(setSubtitleHidden:)]) [view setSubtitleHidden:hidden.boolValue];
        gLookReplaying = NO;
        VLTApplyClock(view);
        [view setNeedsLayout];
    }
}

#pragma mark - Small bits

static const void *kBitMask = &kBitMask;

static BOOL VLTBitHidden(int which) {
    switch (which) {
        case 1: return gHideHint;
        case 2: return gHideDots;
        case 3: return gHideQuick;
        case 4: return gHideLockIcon;
        default: return NO;
    }
}

static void VLTTrackBit(UIView *view, int which) {
    if (!view.window) return;
    [VLTLookTable(which) addObject:view];
    VLTSetMasked(view, VLTBitHidden(which), kBitMask);
}

static void VLTRefreshBits(void) {
    for (int which = 1; which <= 4; which++) {
        for (UIView *view in VLTLookTable(which).allObjects) VLTSetMasked(view, VLTBitHidden(which), kBitMask);
    }
}

#pragma mark - Hooks

%group LockLook

%hook SBFLockScreenDateView

+ (id)timeFont {
    UIFont *font = %orig;
    return VLTClockFont(font);
}

- (void)setLegibilitySettings:(id)settings {
    if (!gLookReplaying) objc_setAssociatedObject(self, kRealSettings, settings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(settings ? VLTClockSettings(settings) : settings);
}

- (void)setSubtitleHidden:(BOOL)hidden {
    if (!gLookReplaying) objc_setAssociatedObject(self, kRealSubtitleHidden, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(gHideDate ? YES : hidden);
}

- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window) {
        VLTSyncWidgetTimer();
        return;
    }
    [VLTDateViews() addObject:self];
    VLTSyncWidgetTimer();
    if (gHideDate && [self respondsToSelector:@selector(setSubtitleHidden:)]) {
        gLookReplaying = YES;
        NSNumber *hidden = objc_getAssociatedObject(self, kRealSubtitleHidden);
        [self setSubtitleHidden:hidden.boolValue];
        gLookReplaying = NO;
    }
    VLTApplyClock(self);
}

- (void)layoutSubviews {
    %orig;
    VLTApplyClock(self);
}

%end

%hook SBUICallToActionLabel
- (void)didMoveToWindow {
    %orig;
    VLTTrackBit((UIView *)self, 1);
}
%end

%hook CSPageControl
- (void)didMoveToWindow {
    %orig;
    VLTTrackBit((UIView *)self, 2);
}
%end

%hook CSQuickActionsView
- (void)didMoveToWindow {
    %orig;
    VLTTrackBit((UIView *)self, 3);
}
%end

%hook SBUIProudLockIconView
- (void)didMoveToWindow {
    %orig;
    VLTTrackBit((UIView *)self, 4);
}
%end

%end // group LockLook

static void VLTLookPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VLTLoadLookPrefs();
        VLTRefreshClocks();
        VLTRefreshBits();
        VLTSyncWidgetTimer();
    });
}

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        VLTLoadLookPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, VLTLookPrefsChanged,
                                        CFSTR(VLT_NOTIFY_PREFS), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        %init(LockLook);
    }
}
