//
//  Wallet for iPad (part of Volta). A card holder for looks: it keeps a
//  nickname, a colour and at most the last four digits. It cannot pay.
//

#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>

#define HEX(v) [UIColor colorWithRed:(((v) >> 16) & 0xFF) / 255.0 green:(((v) >> 8) & 0xFF) / 255.0 blue:((v) & 0xFF) / 255.0 alpha:1]

static NSString *const kItemsKey = @"items";
static const NSUInteger kMaxItems = 24, kMaxText = 60, kMaxPayload = 300;
static NSString *const kFooter = @"Volta Wallet is a card holder for looks. It can't pay, and it never asks for a full card number.";
static NSString *const kNoPay = @"Apple Pay isn't available on this iPad. This card is just for show.";

#pragma mark - Model

// Each theme: name, top-left colour, bottom-right colour.
static NSArray<NSArray *> *Themes(void) {
    static NSArray *themes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        themes = @[@[@"Midnight", @0x1B1F3B, @0x3A3F78], @[@"Sunset", @0xF0642D, @0xC42E63], @[@"Mint", @0x0FA38C, @0x0B6B74],
                   @[@"Ocean", @0x2A7BE4, @0x1A3FA8], @[@"Grape", @0x8E54E9, @0x4B2A99], @[@"Ember", @0xE0483E, @0x8E1F2F],
                   @[@"Forest", @0x2E8B57, @0x14532D], @[@"Graphite", @0x5A6070, @0x2A2D36]];
    });
    return themes;
}

// Trimmed text no longer than max; anything that is not a string becomes empty.
static NSString *CleanText(id value, NSUInteger max) {
    if (![value isKindOfClass:[NSString class]]) return @"";
    NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length > max) text = [text substringToIndex:[text rangeOfComposedCharacterSequenceAtIndex:max].location];
    return text;
}

static NSUInteger DigitCount(NSString *text) {
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c >= '0' && c <= '9') count++;
    }
    return count;
}

static BOOL IsFourDigits(NSString *text) { return text.length == 4 && DigitCount(text) == 4; }

// One stored item, checked field by field. Returns nil when it cannot be used.
static NSDictionary *CleanItem(id raw) {
    if (![raw isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = raw;
    id kind = dict[@"kind"], theme = dict[@"theme"];
    if (![kind isKindOfClass:[NSString class]]) return nil;
    BOOL pass = [kind isEqualToString:@"pass"];
    if (!pass && ![kind isEqualToString:@"card"]) return nil;
    NSString *title = CleanText(dict[@"title"], kMaxText), *payload = CleanText(dict[@"payload"], kMaxPayload);
    NSString *last4 = CleanText(dict[@"last4"], kMaxText);
    if (!title.length || (pass && !payload.length)) return nil;
    NSInteger index = [theme isKindOfClass:[NSNumber class]] ? [theme integerValue] : 0;
    if (index < 0 || index >= (NSInteger)Themes().count) index = 0;
    return @{@"kind": pass ? @"pass" : @"card", @"title": title, @"subtitle": CleanText(dict[@"subtitle"], kMaxText),
             @"last4": (!pass && IsFourDigits(last4)) ? last4 : @"", @"theme": @(index), @"payload": pass ? payload : @""};
}

static NSMutableArray<NSDictionary *> *LoadItems(void) {
    NSMutableArray *items = [NSMutableArray array];
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kItemsKey];
    if (![stored isKindOfClass:[NSArray class]]) return items;
    for (id raw in (NSArray *)stored) {
        NSDictionary *item = CleanItem(raw);
        if (item) [items addObject:item];
        if (items.count >= kMaxItems) break;
    }
    return items;
}

#pragma mark - Small helpers

static UILabel *Label(CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    return label;
}

static UIButton *PillButton(NSString *title, UIColor *fill, UIColor *text) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:text forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    button.backgroundColor = fill;
    button.layer.cornerRadius = 14;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.pointerInteractionEnabled = YES;
    return button;
}

static void ShowAlert(UIViewController *host, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

static UINavigationController *WalletNav(UIViewController *root) {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    UINavigationBarAppearance *look = [[UINavigationBarAppearance alloc] init];
    [look configureWithOpaqueBackground];
    look.backgroundColor = HEX(0x0F1020);
    look.shadowColor = [UIColor clearColor];
    look.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor whiteColor]};
    nav.navigationBar.standardAppearance = look;
    nav.navigationBar.scrollEdgeAppearance = look;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.view.tintColor = HEX(0x19C8B9);
    return nav;
}

// One module per pixel; the image view scales it up with nearest-neighbour.
static UIImage *QRImage(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    if (!data.length || !filter) return nil;
    [filter setValue:data forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *output = filter.outputImage;
    if (!output || CGRectIsEmpty(output.extent) || CGRectIsInfinite(output.extent)) return nil;
    CGImageRef cg = [[CIContext context] createCGImage:output fromRect:output.extent];
    if (!cg) return nil;
    UIImage *image = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return image;
}

#pragma mark - Card view

@interface WalletGradientView : UIView
@property (nonatomic, assign) NSInteger theme;
@end

@implementation WalletGradientView
+ (Class)layerClass { return [CAGradientLayer class]; }
- (void)setTheme:(NSInteger)theme {
    _theme = MAX(0, MIN(theme, (NSInteger)Themes().count - 1));
    NSArray *entry = Themes()[(NSUInteger)_theme];
    CAGradientLayer *layer = (CAGradientLayer *)self.layer;
    layer.colors = @[(id)HEX([entry[1] integerValue]).CGColor, (id)HEX([entry[2] integerValue]).CGColor];
    layer.startPoint = CGPointMake(0, 0);
    layer.endPoint = CGPointMake(1, 1);
}
@end

@interface WalletCardView : UIView
- (void)setItem:(NSDictionary *)item;
- (void)pulse;
@end

@implementation WalletCardView {
    WalletGradientView *_face;
    UILabel *_title, *_subtitle, *_bottom;
    UIView *_chip;
    UIImageView *_glyph;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.35;
        self.layer.shadowRadius = 10;
        self.layer.shadowOffset = CGSizeMake(0, -3);
        _face = [[WalletGradientView alloc] init];
        _face.clipsToBounds = YES;
        _face.layer.cornerCurve = kCACornerCurveContinuous;
        [self addSubview:_face];
        _title = Label(20, UIFontWeightSemibold, [UIColor whiteColor]);
        _subtitle = Label(14, UIFontWeightRegular, [UIColor colorWithWhite:1 alpha:0.8]);
        _bottom = Label(18, UIFontWeightMedium, [UIColor colorWithWhite:1 alpha:0.92]);
        _bottom.font = [UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightMedium];
        _chip = [[UIView alloc] init];
        _chip.backgroundColor = [UIColor colorWithWhite:1 alpha:0.28];
        _chip.layer.cornerRadius = 6;
        _glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"qrcode"]];
        _glyph.tintColor = [UIColor colorWithWhite:1 alpha:0.85];
        _glyph.contentMode = UIViewContentModeScaleAspectFit;
        for (UIView *view in @[_title, _subtitle, _bottom, _chip, _glyph]) [_face addSubview:view];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return self;
}

- (void)setItem:(NSDictionary *)item {
    BOOL pass = [item[@"kind"] isEqual:@"pass"];
    NSString *last4 = CleanText(item[@"last4"], 4);
    _face.theme = [item[@"theme"] isKindOfClass:[NSNumber class]] ? [item[@"theme"] integerValue] : 0;
    _title.text = CleanText(item[@"title"], kMaxText);
    _subtitle.text = CleanText(item[@"subtitle"], kMaxText);
    _bottom.text = pass ? @"PASS" : (IsFourDigits(last4) ? [@"•••• " stringByAppendingString:last4] : @"");
    _chip.hidden = pass;
    _glyph.hidden = !pass;
    NSMutableArray *spoken = [NSMutableArray arrayWithObject:_title.text.length ? _title.text : (pass ? @"Pass" : @"Card")];
    if (_subtitle.text.length) [spoken addObject:_subtitle.text];
    if (!pass && IsFourDigits(last4)) [spoken addObject:[@"ending in " stringByAppendingString:last4]];
    self.accessibilityLabel = [spoken componentsJoinedByString:@", "];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    _face.frame = self.bounds;
    _face.layer.cornerRadius = w * 0.055;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:w * 0.055].CGPath;
    _title.frame = CGRectMake(20, 16, w - 98, 26);
    _subtitle.frame = CGRectMake(20, 43, w - 98, 20);
    _chip.frame = CGRectMake(w - 58, 18, 38, 28);
    _glyph.frame = CGRectMake(w - 52, 16, 32, 32);
    _bottom.frame = CGRectMake(20, h - 44, w - 40, 24);
}

// A ring that grows out from the middle of the card and fades, twice.
- (void)pulse {
    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.frame = CGRectMake(CGRectGetMidX(self.bounds) - 34, CGRectGetMidY(self.bounds) - 34, 68, 68);
    ring.path = [UIBezierPath bezierPathWithOvalInRect:ring.bounds].CGPath;
    ring.fillColor = [UIColor clearColor].CGColor;
    ring.strokeColor = [UIColor whiteColor].CGColor;
    ring.lineWidth = 3;
    ring.opacity = 0;
    [_face.layer addSublayer:ring];
    CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    grow.fromValue = @0.3;
    grow.toValue = @3.6;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.9;
    fade.toValue = @0;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[grow, fade];
    group.duration = 0.6;
    group.repeatCount = 2;
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [ring addAnimation:group forKey:@"pulse"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [ring removeFromSuperlayer];
    });
}

@end

#pragma mark - Add / edit form

@interface WalletFormController : UIViewController <UITextFieldDelegate>
@property (nonatomic, copy) NSDictionary *item;   // nil when adding
@property (nonatomic, assign) BOOL isPass;
@property (nonatomic, copy) void (^onSave)(NSDictionary *item);
@end

@implementation WalletFormController {
    UIScrollView *_scroll;
    WalletCardView *_preview;
    UITextField *_titleField, *_subtitleField, *_extraField;   // extra: last four (card) or QR text (pass)
    UILabel *_hint, *_themeLabel, *_footer;
    NSMutableArray<WalletGradientView *> *_swatches;
    NSInteger _theme;
}

- (UITextField *)fieldWithPlaceholder:(NSString *)placeholder text:(NSString *)text {
    UITextField *field = [[UITextField alloc] init];
    field.backgroundColor = HEX(0x262842);
    field.textColor = [UIColor whiteColor];
    field.font = [UIFont systemFontOfSize:17];
    field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder
                                    attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.4]}];
    field.text = text;
    field.layer.cornerRadius = 12;
    field.layer.cornerCurve = kCACornerCurveContinuous;
    field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 10)];
    field.leftViewMode = UITextFieldViewModeAlways;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.returnKeyType = UIReturnKeyNext;
    field.delegate = self;
    [field addTarget:self action:@selector(refreshPreview) forControlEvents:UIControlEventEditingChanged];
    [_scroll addSubview:field];
    return field;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = HEX(0x0F1020);
    self.title = [NSString stringWithFormat:@"%@ %@", self.item ? @"Edit" : @"New", self.isPass ? @"Pass" : @"Card"];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                          target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                                                           target:self action:@selector(save)];
    _scroll = [[UIScrollView alloc] init];
    _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    _preview = [[WalletCardView alloc] init];
    _preview.isAccessibilityElement = NO;
    [_scroll addSubview:_preview];
    _titleField = [self fieldWithPlaceholder:self.isPass ? @"Title (e.g. Library)" : @"Nickname (e.g. Everyday)" text:self.item[@"title"]];
    _subtitleField = [self fieldWithPlaceholder:self.isPass ? @"Subtitle (optional)" : @"Subtitle (optional, e.g. Debit)"
                                           text:self.item[@"subtitle"]];
    if (self.isPass) {
        _extraField = [self fieldWithPlaceholder:@"Text or number for the QR code" text:self.item[@"payload"]];
        _extraField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    } else {
        _extraField = [self fieldWithPlaceholder:@"Last four digits (optional)" text:self.item[@"last4"]];
        _extraField.keyboardType = UIKeyboardTypeNumberPad;
    }
    _extraField.returnKeyType = UIReturnKeyDone;

    _hint = Label(13, UIFontWeightRegular, [UIColor colorWithWhite:1 alpha:0.55]);
    _hint.text = self.isPass ? @"Shown as a QR code, for example a loyalty or library number."
                             : @"Only the last four digits, never the whole number.";
    _themeLabel = Label(15, UIFontWeightSemibold, [UIColor whiteColor]);
    _footer = Label(13, UIFontWeightRegular, [UIColor colorWithWhite:1 alpha:0.5]);
    _footer.text = kFooter;
    _footer.textAlignment = NSTextAlignmentCenter;
    for (UILabel *label in @[_hint, _themeLabel, _footer]) {
        label.numberOfLines = 0;
        [_scroll addSubview:label];
    }

    _swatches = [NSMutableArray array];
    for (NSUInteger i = 0; i < Themes().count; i++) {
        WalletGradientView *swatch = [[WalletGradientView alloc] init];
        swatch.theme = (NSInteger)i;
        swatch.layer.borderColor = [UIColor whiteColor].CGColor;
        swatch.isAccessibilityElement = YES;
        swatch.accessibilityLabel = Themes()[i][0];
        [swatch addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(swatchTapped:)]];
        [_scroll addSubview:swatch];
        [_swatches addObject:swatch];
    }
    _theme = [self.item[@"theme"] integerValue];
    [self refreshPreview];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:)
                                                 name:UIKeyboardWillChangeFrameNotification object:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets safe = self.view.safeAreaInsets;
    _scroll.frame = self.view.bounds;
    CGFloat width = self.view.bounds.size.width - safe.left - safe.right;
    CGFloat w = floor(MIN(width - 32, 420)), x = safe.left + floor((width - w) / 2), y = safe.top + 16;
    CGFloat previewW = MIN(w, 260), previewH = floor(previewW / 1.586);
    _preview.frame = CGRectMake(x + floor((w - previewW) / 2), y, previewW, previewH);
    y += previewH + 20;
    for (UITextField *field in @[_titleField, _subtitleField, _extraField]) {
        field.frame = CGRectMake(x, y, w, 50);
        y += 60;
    }
    CGFloat hintH = ceil([_hint sizeThatFits:CGSizeMake(w - 8, CGFLOAT_MAX)].height);
    _hint.frame = CGRectMake(x + 4, y - 4, w - 8, hintH);
    y += hintH + 16;
    _themeLabel.frame = CGRectMake(x + 4, y, w - 8, 20);
    y += 30;
    // Eight in a row when there is room, otherwise two rows of four.
    NSInteger columns = w >= 400 ? 8 : 4;
    CGFloat gap = 10, size = MIN(46, floor((w - gap * (columns - 1)) / columns));
    CGFloat pitch = (w - size) / (columns - 1);
    for (NSInteger i = 0; i < (NSInteger)_swatches.count; i++) {
        _swatches[i].frame = CGRectMake(x + (i % columns) * pitch, y + (i / columns) * (size + gap), size, size);
        _swatches[i].layer.cornerRadius = size / 2;
    }
    y += ((NSInteger)_swatches.count + columns - 1) / columns * (size + gap) + 14;
    CGFloat footerH = ceil([_footer sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)].height);
    _footer.frame = CGRectMake(x, y, w, footerH);
    _scroll.contentSize = CGSizeMake(self.view.bounds.size.width, y + footerH + 20 + safe.bottom);
}

- (NSDictionary *)draft {
    return @{@"kind": self.isPass ? @"pass" : @"card", @"title": _titleField.text ?: @"", @"subtitle": _subtitleField.text ?: @"",
             @"last4": self.isPass ? @"" : (_extraField.text ?: @""), @"payload": self.isPass ? (_extraField.text ?: @"") : @"",
             @"theme": @(_theme)};
}

- (void)refreshPreview {
    if (_theme < 0 || _theme >= (NSInteger)Themes().count) _theme = 0;
    [_preview setItem:[self draft]];
    _themeLabel.text = [@"Theme: " stringByAppendingString:Themes()[(NSUInteger)_theme][0]];
    for (NSInteger i = 0; i < (NSInteger)_swatches.count; i++) {
        _swatches[i].layer.borderWidth = i == _theme ? 3 : 0;
        _swatches[i].accessibilityTraits = UIAccessibilityTraitButton | (i == _theme ? UIAccessibilityTraitSelected : 0);
    }
}

- (void)swatchTapped:(UITapGestureRecognizer *)tap {
    _theme = ((WalletGradientView *)tap.view).theme;
    [self refreshPreview];
}

// Keeps every field short; the last-four field takes digits only.
- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    NSString *current = field.text ?: @"";
    if (NSMaxRange(range) > current.length) return NO;
    BOOL lastFour = field == _extraField && !self.isPass;
    if (lastFour && DigitCount(string) != string.length) return NO;
    NSUInteger limit = lastFour ? 4 : (field == _extraField ? kMaxPayload : kMaxText);
    return current.length - range.length + string.length <= limit;
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    if (field == _titleField) [_subtitleField becomeFirstResponder];
    else if (field == _subtitleField) [_extraField becomeFirstResponder];
    else [field resignFirstResponder];
    return NO;
}

- (void)textFieldDidBeginEditing:(UITextField *)field {
    [_scroll scrollRectToVisible:CGRectInset(field.frame, 0, -12) animated:YES];
}

- (void)keyboardChanged:(NSNotification *)note {
    CGRect end = [self.view convertRect:[note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];
    CGFloat overlap = CGRectIntersection(self.view.bounds, end).size.height;
    _scroll.contentInset = UIEdgeInsetsMake(0, 0, overlap, 0);
    _scroll.verticalScrollIndicatorInsets = UIEdgeInsetsMake(0, 0, overlap, 0);
}

- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)save {
    NSString *title = CleanText(_titleField.text, kMaxText), *subtitle = CleanText(_subtitleField.text, kMaxText);
    NSString *extra = CleanText(_extraField.text, kMaxPayload), *problem = nil;
    if (!title.length) problem = @"Give it a name first.";
    else if (self.isPass && !extra.length) problem = @"Add the text or number for the QR code.";
    else if (!self.isPass && extra.length && !IsFourDigits(extra)) problem = @"Use exactly the last four digits, or leave that field empty.";
    else if (DigitCount(title) >= 12 || DigitCount(subtitle) >= 12)
        problem = @"That looks like a full card number. Volta Wallet only keeps a nickname and the last four digits.";
    NSDictionary *item = problem ? nil : CleanItem([self draft]);
    if (!item) {
        ShowAlert(self, @"Check the details", problem ?: @"Something in this form can't be saved.");
        return;
    }
    if (self.onSave) self.onSave(item);
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - The stack

@interface WalletViewController : UIViewController
@end

@implementation WalletViewController {
    NSMutableArray<NSDictionary *> *_items;
    NSMutableArray<WalletCardView *> *_cards;
    UIScrollView *_scroll;
    NSInteger _selected;   // -1 when the stack is closed
    BOOL _paying;
    UIView *_detail, *_qrPanel, *_empty;
    UIImageView *_qrView;
    UILabel *_qrText, *_info, *_footer, *_emptyText;
    UIButton *_payButton, *_editButton, *_deleteButton, *_emptyButton;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Wallet";
    self.view.backgroundColor = HEX(0x0F1020);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self action:@selector(addTapped:)];
    _items = LoadItems();
    _cards = [NSMutableArray array];
    _selected = -1;

    _scroll = [[UIScrollView alloc] init];
    _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scroll.alwaysBounceVertical = YES;
    [_scroll addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(stackTapped:)]];
    [self.view addSubview:_scroll];

    _footer = Label(13, UIFontWeightRegular, [UIColor colorWithWhite:1 alpha:0.5]);
    _footer.text = kFooter;
    _footer.numberOfLines = 0;
    _footer.textAlignment = NSTextAlignmentCenter;
    [_scroll addSubview:_footer];

    // Empty state: an outlined card-shaped slot and one button.
    _empty = [[UIView alloc] init];
    _empty.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    _empty.layer.borderWidth = 2;
    _empty.layer.cornerCurve = kCACornerCurveContinuous;
    _emptyText = Label(17, UIFontWeightMedium, [UIColor colorWithWhite:1 alpha:0.7]);
    _emptyText.text = @"Your wallet is empty.\nAdd a card or a pass to start the stack.";
    _emptyText.numberOfLines = 0;
    _emptyText.textAlignment = NSTextAlignmentCenter;
    [_empty addSubview:_emptyText];
    _emptyButton = PillButton(@"Add Your First Card", HEX(0x19C8B9), HEX(0x06282A));
    [_emptyButton addTarget:self action:@selector(addTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:_empty];
    [_scroll addSubview:_emptyButton];

    // Details under the selected card: QR panel (passes), a line of text, the buttons.
    _detail = [[UIView alloc] init];
    _detail.alpha = 0;
    _qrPanel = [[UIView alloc] init];
    _qrPanel.backgroundColor = [UIColor whiteColor];
    _qrPanel.layer.cornerRadius = 18;
    _qrPanel.layer.cornerCurve = kCACornerCurveContinuous;
    _qrView = [[UIImageView alloc] init];
    _qrView.contentMode = UIViewContentModeScaleAspectFit;
    _qrView.layer.magnificationFilter = kCAFilterNearest;   // keeps the squares sharp
    _qrView.isAccessibilityElement = YES;
    _qrView.accessibilityLabel = @"QR code";
    _qrText = Label(13, UIFontWeightRegular, HEX(0x333645));
    _qrText.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    _qrText.numberOfLines = 2;
    _qrText.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _qrText.textAlignment = NSTextAlignmentCenter;
    [_qrPanel addSubview:_qrView];
    [_qrPanel addSubview:_qrText];
    _info = Label(15, UIFontWeightRegular, [UIColor colorWithWhite:1 alpha:0.75]);
    _info.numberOfLines = 0;
    _info.textAlignment = NSTextAlignmentCenter;
    _payButton = PillButton(@"Pay", HEX(0x19C8B9), HEX(0x06282A));
    _editButton = PillButton(@"Edit", HEX(0x262842), [UIColor whiteColor]);
    _deleteButton = PillButton(@"Delete", HEX(0x262842), HEX(0xFF6B6B));
    [_payButton addTarget:self action:@selector(payTapped) forControlEvents:UIControlEventTouchUpInside];
    [_editButton addTarget:self action:@selector(editTapped) forControlEvents:UIControlEventTouchUpInside];
    [_deleteButton addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *view in @[_qrPanel, _info, _payButton, _editButton, _deleteButton]) [_detail addSubview:view];
    [_scroll addSubview:_detail];
    [self reload];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutStack];
}

- (BOOL)hasSelection { return _selected >= 0 && _selected < (NSInteger)_cards.count; }

// Card slot for the current width: centred, at most 420 wide, placed at the given y.
- (CGRect)slotAtY:(CGFloat)y {
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat width = self.view.bounds.size.width - safe.left - safe.right;
    CGFloat w = floor(MIN(width - 32, 420));
    return CGRectMake(safe.left + floor((width - w) / 2), y, w, floor(w / 1.586));
}

- (void)place:(UIView *)view in:(CGRect)frame {   // bounds + centre, so a lifted card keeps its transform
    view.bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
    view.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
}

// Lays out the detail panel below the top slot and returns its bottom edge.
- (CGFloat)placeDetail {
    CGRect slot = [self slotAtY:self.view.safeAreaInsets.top + 16];
    CGFloat w = slot.size.width, y = 0;
    if (!_qrPanel.hidden) {
        CGFloat side = MIN(w, 250), textH = ceil([_qrText sizeThatFits:CGSizeMake(side - 28, CGFLOAT_MAX)].height);
        _qrPanel.frame = CGRectMake(floor((w - side) / 2), 0, side, side + textH + 6);
        _qrView.frame = CGRectMake(14, 14, side - 28, side - 28);
        _qrText.frame = CGRectMake(14, side - 8, side - 28, textH);
        y = CGRectGetMaxY(_qrPanel.frame) + 14;
    }
    CGFloat infoH = ceil([_info sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)].height);
    _info.frame = CGRectMake(0, y, w, infoH);
    y += infoH + 14;
    NSArray<UIButton *> *buttons = _payButton.hidden ? @[_editButton, _deleteButton] : @[_payButton, _editButton, _deleteButton];
    CGFloat gap = 10, buttonW = floor((w - gap * (buttons.count - 1)) / buttons.count);
    for (NSUInteger i = 0; i < buttons.count; i++) buttons[i].frame = CGRectMake(i * (buttonW + gap), y, buttonW, 48);
    _detail.frame = CGRectMake(slot.origin.x, CGRectGetMaxY(slot) + 16, w, y + 48);
    return CGRectGetMaxY(_detail.frame);
}

- (void)layoutStack {
    UIEdgeInsets safe = self.view.safeAreaInsets;
    _scroll.frame = self.view.bounds;
    BOOL picked = [self hasSelection];
    CGRect slot = [self slotAtY:safe.top + 16];
    CGFloat bottom = slot.origin.y;
    if (picked) {
        [self place:_cards[_selected] in:slot];
        slot.origin.y = [self placeDetail] + 24;
        bottom = slot.origin.y - 24;
    }
    _detail.alpha = picked ? 1 : 0;
    _detail.userInteractionEnabled = picked;
    // The rest of the stack; cards sit closer together while one is pulled out.
    CGFloat peek = picked ? 46 : 68;
    for (NSInteger i = 0; i < (NSInteger)_cards.count; i++) {
        if (picked && i == _selected) continue;
        [self place:_cards[i] in:slot];
        [_scroll bringSubviewToFront:_cards[i]];
        bottom = CGRectGetMaxY(slot);
        slot.origin.y += peek;
    }
    if (picked) [_scroll bringSubviewToFront:_cards[_selected]];
    if (!_items.count) {
        _empty.frame = slot;
        _empty.layer.cornerRadius = slot.size.width * 0.055;
        _emptyText.frame = CGRectInset(_empty.bounds, 20, 16);
        _emptyButton.frame = CGRectMake(slot.origin.x, CGRectGetMaxY(slot) + 16, slot.size.width, 50);
        bottom = CGRectGetMaxY(_emptyButton.frame);
    }
    CGFloat footerH = ceil([_footer sizeThatFits:CGSizeMake(slot.size.width, CGFLOAT_MAX)].height);
    _footer.frame = CGRectMake(slot.origin.x, bottom + 22, slot.size.width, footerH);
    CGFloat height = CGRectGetMaxY(_footer.frame) + 20 + safe.bottom;
    _scroll.contentSize = CGSizeMake(self.view.bounds.size.width, height);
    CGFloat maxOffset = MAX(0, height - self.view.bounds.size.height);
    if (_scroll.contentOffset.y > maxOffset) _scroll.contentOffset = CGPointMake(0, maxOffset);
}

// Rebuilds the card views from the items.
- (void)reload {
    for (WalletCardView *card in _cards) [card removeFromSuperview];
    [_cards removeAllObjects];
    for (NSDictionary *item in _items) {
        WalletCardView *card = [[WalletCardView alloc] init];
        [card setItem:item];
        [_scroll addSubview:card];
        [_cards addObject:card];
    }
    if (![self hasSelection]) _selected = -1;
    _empty.hidden = _emptyButton.hidden = _items.count > 0;
    [self fillDetail];
    [self layoutStack];
}

- (void)saveAndReload {
    [[NSUserDefaults standardUserDefaults] setObject:[_items copy] forKey:kItemsKey];
    [UIView transitionWithView:_scroll duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        [self reload];
    } completion:nil];
}

- (void)fillDetail {
    if (![self hasSelection]) return;
    NSDictionary *item = _items[_selected];
    BOOL pass = [item[@"kind"] isEqual:@"pass"];
    NSString *subtitle = item[@"subtitle"], *last4 = item[@"last4"];
    NSMutableArray *parts = [NSMutableArray array];
    if (subtitle.length) [parts addObject:subtitle];
    if (pass) [parts addObject:@"Show this code to be scanned"];
    else [parts addObject:last4.length ? [@"Ending in " stringByAppendingString:last4] : @"No digits saved"];
    [parts addObject:[Themes()[[item[@"theme"] unsignedIntegerValue]][0] stringByAppendingString:@" theme"]];
    _info.text = [parts componentsJoinedByString:@"  ·  "];
    _qrPanel.hidden = !pass;
    _payButton.hidden = pass;
    if (pass) {
        UIImage *code = QRImage(item[@"payload"]);
        _qrView.image = code;
        _qrText.text = code ? item[@"payload"] : @"This text can't be shown as a QR code.";
    }
}

- (void)openCard:(NSInteger)index {
    _selected = index;
    if ([self hasSelection]) {   // put the panel in place first so it only fades in
        [self fillDetail];
        [self placeDetail];
        _detail.alpha = 0;
    }
    [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState animations:^{
        [self layoutStack];
        if (index >= 0) [self scrollToTop];
    } completion:nil];
}

- (void)scrollToTop { _scroll.contentOffset = CGPointZero; }

// One tap handler for the whole stack: open a card, or put the open one back.
- (void)stackTapped:(UITapGestureRecognizer *)tap {
    if (_paying) return;
    UIView *hit = [_scroll hitTest:[tap locationInView:_scroll] withEvent:nil];
    if (hit && [hit isDescendantOfView:_detail]) return;
    if ([self hasSelection]) {
        [self openCard:-1];
        return;
    }
    while (hit && ![hit isKindOfClass:[WalletCardView class]]) hit = hit.superview;
    NSUInteger index = hit ? [_cards indexOfObject:(WalletCardView *)hit] : NSNotFound;
    if (index != NSNotFound) [self openCard:(NSInteger)index];
}

#pragma mark Actions

- (void)addTapped:(id)sender {
    if (_items.count >= kMaxItems) {
        ShowAlert(self, @"Wallet is full", @"You can keep up to 24 items. Delete one to add another.");
        return;
    }
    __weak typeof(self) weakSelf = self;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Add to Wallet" message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Card" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf showFormForIndex:-1 pass:NO];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Pass (QR code)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf showFormForIndex:-1 pass:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if ([sender isKindOfClass:[UIBarButtonItem class]]) sheet.popoverPresentationController.barButtonItem = sender;
    else [self anchor:sheet to:sender];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)anchor:(UIAlertController *)sheet to:(UIView *)view {   // iPad shows action sheets as popovers
    sheet.popoverPresentationController.sourceView = view;
    sheet.popoverPresentationController.sourceRect = view.bounds;
}

- (void)showFormForIndex:(NSInteger)index pass:(BOOL)pass {
    WalletFormController *form = [[WalletFormController alloc] init];
    form.item = (index >= 0 && index < (NSInteger)_items.count) ? _items[index] : nil;
    form.isPass = pass;
    __weak typeof(self) weakSelf = self;
    form.onSave = ^(NSDictionary *item) { [weakSelf storeItem:item atIndex:index]; };
    UINavigationController *nav = WalletNav(form);
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)storeItem:(NSDictionary *)item atIndex:(NSInteger)index {
    if (index >= 0 && index < (NSInteger)_items.count) _items[index] = item;
    else if (index < 0 && _items.count < kMaxItems) [_items addObject:item];
    [self saveAndReload];
}

- (void)editTapped {
    if (_paying || ![self hasSelection]) return;
    [self showFormForIndex:_selected pass:[_items[_selected][@"kind"] isEqual:@"pass"]];
}

- (void)deleteTapped {
    if (_paying || ![self hasSelection]) return;
    NSDictionary *item = _items[_selected];
    __weak typeof(self) weakSelf = self;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Delete “%@”?", item[@"title"]]
                                                                   message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf removeItem:item];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self anchor:sheet to:_deleteButton];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)removeItem:(NSDictionary *)item {
    NSUInteger index = [_items indexOfObjectIdenticalTo:item];
    if (index == NSNotFound) return;
    [_items removeObjectAtIndex:index];
    _selected = -1;
    [self saveAndReload];
}

// The card lifts, a ring pulses, it settles, and then the honest answer.
- (void)payTapped {
    if (_paying || ![self hasSelection]) return;
    _paying = YES;
    WalletCardView *card = _cards[_selected];
    __weak typeof(self) weakSelf = self;
    __weak WalletCardView *weakCard = card;
    [card pulse];
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.6 options:0 animations:^{
        card.transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(0, -6), 1.04, 1.04);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.35 delay:0.75 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            weakCard.transform = CGAffineTransformIdentity;
        } completion:^(BOOL done) {
            [weakSelf finishPay];
        }];
    }];
}

- (void)finishPay {
    _paying = NO;
    if (self.presentedViewController || !self.view.window) return;
    ShowAlert(self, @"Not today", kNoPay);
}

@end

#pragma mark - App

@interface WalletAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation WalletAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = WalletNav([[WalletViewController alloc] init]);
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([WalletAppDelegate class]));
    }
}
