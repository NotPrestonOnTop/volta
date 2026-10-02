//
//  Calculator for iPad (part of Volta). A plain four-function calculator;
//  the arithmetic lives in CalcCore.h.
//

#import <UIKit/UIKit.h>
#import "CalcCore.h"

#define HEX(v) [UIColor colorWithRed:(((v) >> 16) & 0xFF) / 255.0 green:(((v) >> 8) & 0xFF) / 255.0 blue:((v) & 0xFF) / 255.0 alpha:1]

@interface CalcKey : UIButton
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) UIColor *restColor;
@end

@implementation CalcKey
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:highlighted ? 0.03 : 0.25 animations:^{ self.alpha = highlighted ? 0.6 : 1; }];
}
@end

@interface CalcViewController : UIViewController
@end

@implementation CalcViewController {
    Calc _calc;
    UILabel *_display;
    NSMutableArray<CalcKey *> *_keys;
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

- (void)viewDidLoad {
    [super viewDidLoad];
    calc_reset(&_calc);
    self.view.backgroundColor = HEX(0x0F1020);

    _display = [[UILabel alloc] init];
    _display.textColor = [UIColor whiteColor];
    _display.textAlignment = NSTextAlignmentRight;
    _display.adjustsFontSizeToFitWidth = YES;
    _display.minimumScaleFactor = 0.3;
    _display.isAccessibilityElement = YES;
    _display.accessibilityLabel = @"Result";
    [self.view addSubview:_display];

    // Row by row. Tags: C clear, n negate, % percent, operators, digits, dot, equals.
    NSArray *rows = @[@[@"C", @"n", @"%", @"/"], @[@"7", @"8", @"9", @"*"], @[@"4", @"5", @"6", @"-"],
                      @[@"1", @"2", @"3", @"+"], @[@"0", @".", @"="]];
    NSDictionary *titles = @{@"C": @"AC", @"n": @"+/−", @"/": @"÷", @"*": @"×", @"-": @"−"};
    NSDictionary *spoken = @{@"C": @"Clear", @"n": @"Plus minus", @"%": @"Percent", @"/": @"Divide", @"*": @"Multiply",
                             @"-": @"Subtract", @"+": @"Add", @"=": @"Equals", @".": @"Decimal point"};
    _keys = [NSMutableArray array];
    for (NSArray *row in rows) {
        for (NSString *key in row) {
            CalcKey *button = [CalcKey buttonWithType:UIButtonTypeCustom];
            button.key = key;
            BOOL operator = [@"/*-+=" containsString:key], function = [@"Cn%" containsString:key];
            button.restColor = operator ? HEX(0x19C8B9) : (function ? HEX(0x3D4066) : HEX(0x262842));
            button.backgroundColor = button.restColor;
            [button setTitle:titles[key] ?: key forState:UIControlStateNormal];
            [button setTitleColor:operator ? HEX(0x06282A) : [UIColor whiteColor] forState:UIControlStateNormal];
            button.accessibilityLabel = spoken[key] ?: key;
            [button addTarget:self action:@selector(pressed:) forControlEvents:UIControlEventTouchUpInside];
            [self.view addSubview:button];
            [_keys addObject:button];
        }
    }
    [self refresh];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat width = self.view.bounds.size.width - safe.left - safe.right;
    CGFloat height = self.view.bounds.size.height - safe.top - safe.bottom;
    // Five rows of keys plus a display about one and a half keys tall.
    CGFloat gap = 14;
    CGFloat size = floor(MIN((MIN(width, 560) - gap * 5) / 4, (height - gap * 7) / 6.6));
    size = MIN(size, 118);
    CGFloat gridWidth = size * 4 + gap * 3, gridHeight = size * 5 + gap * 4;
    CGFloat x0 = safe.left + (width - gridWidth) / 2;
    CGFloat displayHeight = size * 1.4;
    CGFloat y0 = safe.top + (height - (gridHeight + gap + displayHeight)) / 2 + displayHeight + gap;

    _display.frame = CGRectMake(x0 + 8, y0 - gap - displayHeight, gridWidth - 16, displayHeight);
    _display.font = [UIFont systemFontOfSize:size * 0.95 weight:UIFontWeightLight];

    NSInteger index = 0;
    NSArray *counts = @[@4, @4, @4, @4, @3];
    for (NSInteger row = 0; row < 5; row++) {
        CGFloat x = x0;
        for (NSInteger column = 0; column < [counts[row] integerValue]; column++) {
            CalcKey *button = _keys[index++];
            CGFloat w = (row == 4 && column == 0) ? size * 2 + gap : size;   // wide zero
            button.frame = CGRectMake(x, y0 + row * (size + gap), w, size);
            button.layer.cornerRadius = size * 0.3;
            button.layer.cornerCurve = kCACornerCurveContinuous;
            button.titleLabel.font = [UIFont systemFontOfSize:size * 0.42 weight:UIFontWeightMedium];
            x += w + gap;
        }
    }
}

- (void)refresh {
    char text[40];
    calc_display(&_calc, text, sizeof(text));
    NSString *plain = [NSString stringWithUTF8String:text];

    // Group the whole-number part in threes for reading: 1234567.5 -> 1,234,567.5
    NSString *shown = plain;
    if (![plain containsString:@"e"] && ![plain isEqualToString:@"Error"]) {
        NSArray *parts = [plain componentsSeparatedByString:@"."];
        NSString *whole = parts[0];
        BOOL negative = [whole hasPrefix:@"-"];
        if (negative) whole = [whole substringFromIndex:1];
        NSMutableString *grouped = [NSMutableString string];
        for (NSInteger i = 0; i < (NSInteger)whole.length; i++) {
            if (i > 0 && (whole.length - i) % 3 == 0) [grouped appendString:@","];
            [grouped appendFormat:@"%C", [whole characterAtIndex:i]];
        }
        shown = [NSString stringWithFormat:@"%@%@%@", negative ? @"−" : @"", grouped,
                 parts.count > 1 ? [@"." stringByAppendingString:parts[1]] : @""];
    }
    _display.text = shown;
    _display.accessibilityValue = plain;

    // The pending operator stays lit until the next number starts.
    char pending = _calc.lastWasOp ? (_calc.highOp ? _calc.highOp : _calc.lowOp) : 0;
    for (CalcKey *button in _keys) {
        BOOL lit = pending && button.key.length == 1 && [button.key characterAtIndex:0] == (unichar)pending;
        button.backgroundColor = lit ? [UIColor whiteColor] : button.restColor;
    }
    // "AC" clears everything; while typing it becomes "C" and clears the entry.
    [_keys.firstObject setTitle:(_calc.entry[0] ? @"C" : @"AC") forState:UIControlStateNormal];
}

- (void)pressed:(CalcKey *)button {
    unichar key = [button.key characterAtIndex:0];
    if (key >= '0' && key <= '9') calc_digit(&_calc, (char)key);
    else if (key == '.') calc_dot(&_calc);
    else if (key == '=') calc_equals(&_calc);
    else if (key == '%') calc_percent(&_calc);
    else if (key == 'n') calc_negate(&_calc);
    else if (key == 'C') {
        if (_calc.entry[0] && !_calc.error) _calc.entry[0] = '\0';   // clear what is being typed
        else calc_reset(&_calc);
    } else calc_operator(&_calc, (char)key);
    [self refresh];
}

@end

@interface CalcAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation CalcAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[CalcViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([CalcAppDelegate class]));
    }
}
