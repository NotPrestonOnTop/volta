#import "VLTCreator.h"
#import "VLTViews.h"
#import "VLTShared.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>

#define GRID 16                 // the pixel editor's canvas is GRID x GRID
#define FRAME_EXPORT 96         // drawn frames are saved at this size (GRID x 6)
#define FRAME_MAX_SIDE 144      // imported frames are scaled down to this

static void VLTCreatorSave(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR(VLT_DOMAIN));
}

// PNG data for an image, no larger than FRAME_MAX_SIDE on its longest side.
static NSData *VLTFrameData(UIImage *image) {
    if (!image || image.size.width < 1 || image.size.height < 1) return nil;
    CGFloat longest = MAX(image.size.width, image.size.height) * image.scale;
    CGFloat k = MIN(1.0, FRAME_MAX_SIDE / longest);
    CGSize size = CGSizeMake(MAX(1, round(image.size.width * image.scale * k)), MAX(1, round(image.size.height * image.scale * k)));
    UIImage *small = [VLTRenderer(size, 1) imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
    return UIImagePNGRepresentation(small);
}

#pragma mark - Pixel editor

@interface VLTPixelCanvas : UIView
@property (nonatomic) uint32_t *pixels;          // GRID * GRID, 0xRRGGBBAA, owned by the controller
@property (nonatomic) const uint32_t *ghost;     // previous frame, shown faintly; may be NULL
@property (nonatomic) uint32_t color;            // 0 = eraser
@property (nonatomic, copy) void (^onChange)(void);
@end

@implementation VLTPixelCanvas

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
        self.layer.cornerRadius = 12;
        self.clipsToBounds = YES;
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = @"Drawing canvas";
        self.accessibilityTraits = UIAccessibilityTraitAllowsDirectInteraction;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGFloat cell = self.bounds.size.width / GRID;
    for (int y = 0; y < GRID; y++) {
        for (int x = 0; x < GRID; x++) {
            CGRect r = CGRectMake(x * cell, y * cell, cell, cell);
            // Checkerboard = transparent
            [((x + y) % 2 ? [UIColor colorWithWhite:0.22 alpha:1] : [UIColor colorWithWhite:0.28 alpha:1]) setFill];
            UIRectFill(r);
            uint32_t pixel = self.pixels ? self.pixels[y * GRID + x] : 0;
            if (pixel & 0xFF) {
                [VLTColorFromRGBA(pixel) setFill];
                UIRectFillUsingBlendMode(r, kCGBlendModeNormal);
            } else if (self.ghost && (self.ghost[y * GRID + x] & 0xFF)) {
                [[VLTColorFromRGBA(self.ghost[y * GRID + x]) colorWithAlphaComponent:0.22] setFill];
                UIRectFillUsingBlendMode(r, kCGBlendModeNormal);
            }
        }
    }
    [[UIColor colorWithWhite:1 alpha:0.08] setStroke];
    UIBezierPath *lines = [UIBezierPath bezierPath];
    for (int i = 1; i < GRID; i++) {
        [lines moveToPoint:CGPointMake(i * cell, 0)];
        [lines addLineToPoint:CGPointMake(i * cell, self.bounds.size.height)];
        [lines moveToPoint:CGPointMake(0, i * cell)];
        [lines addLineToPoint:CGPointMake(self.bounds.size.width, i * cell)];
    }
    lines.lineWidth = 1;
    [lines stroke];
}

- (void)paintAt:(CGPoint)point {
    if (!self.pixels) return;
    CGFloat cell = self.bounds.size.width / GRID;
    int x = (int)floor(point.x / cell), y = (int)floor(point.y / cell);
    if (x < 0 || y < 0 || x >= GRID || y >= GRID) return;
    if (self.pixels[y * GRID + x] == self.color) return;
    self.pixels[y * GRID + x] = self.color;
    [self setNeedsDisplay];
    if (self.onChange) self.onChange();
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self paintAt:[touches.anyObject locationInView:self]]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // Include the in-between points so fast strokes leave no gaps.
    UITouch *touch = touches.anyObject;
    for (UITouch *step in [event coalescedTouchesForTouch:touch] ?: @[touch]) [self paintAt:[step locationInView:self]];
}

@end

@interface VLTPixelEditorController : UIViewController <UIColorPickerViewControllerDelegate>
@property (nonatomic, strong) UIImage *startImage;          // frame being edited, or nil for a blank one
@property (nonatomic, strong) UIImage *previousImage;       // shown faintly behind, for lining frames up
@property (nonatomic, copy) void (^onDone)(UIImage *image);
@end

@implementation VLTPixelEditorController {
    uint32_t _pixels[GRID * GRID];
    uint32_t _ghost[GRID * GRID];
    BOOL _hasGhost;
    VLTPixelCanvas *_canvas;
    UIStackView *_palette;
    NSMutableArray<UIButton *> *_swatches;
    NSMutableArray<NSNumber *> *_colors;
    NSInteger _selected;
}

// Reads any image down to the GRID x GRID canvas.
static void VLTReadPixels(UIImage *image, uint32_t *out) {
    memset(out, 0, sizeof(uint32_t) * GRID * GRID);
    if (!image.CGImage) return;
    uint8_t buffer[GRID * GRID * 4];
    memset(buffer, 0, sizeof(buffer));
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buffer, GRID, GRID, 8, GRID * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) return;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    CGContextDrawImage(ctx, CGRectMake(0, 0, GRID, GRID), image.CGImage);
    CGContextRelease(ctx);
    for (int i = 0; i < GRID * GRID; i++) {
        uint32_t r = buffer[i * 4], g = buffer[i * 4 + 1], b = buffer[i * 4 + 2], a = buffer[i * 4 + 3];
        if (a < 40) continue;                                   // treat faint edges as empty
        r = MIN(255u, r * 255 / a); g = MIN(255u, g * 255 / a); b = MIN(255u, b * 255 / a);   // undo premultiplication
        out[i] = (r << 24) | (g << 16) | (b << 8) | 0xFF;
    }
}

- (UIImage *)renderedImage {
    CGFloat cell = (CGFloat)FRAME_EXPORT / GRID;
    const uint32_t *pixels = _pixels;
    return [VLTRenderer(CGSizeMake(FRAME_EXPORT, FRAME_EXPORT), 1) imageWithActions:^(UIGraphicsImageRendererContext *context) {
        for (int y = 0; y < GRID; y++) {
            for (int x = 0; x < GRID; x++) {
                uint32_t pixel = pixels[y * GRID + x];
                if (!(pixel & 0xFF)) continue;
                [VLTColorFromRGBA(pixel) setFill];
                UIRectFill(CGRectMake(x * cell, y * cell, cell, cell));
            }
        }
    }];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Draw Frame";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.view.tintColor = VLT_ACCENT;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];

    VLTReadPixels(self.startImage, _pixels);
    _hasGhost = self.previousImage != nil;
    if (_hasGhost) VLTReadPixels(self.previousImage, _ghost);

    _canvas = [[VLTPixelCanvas alloc] initWithFrame:CGRectZero];
    _canvas.pixels = _pixels;
    _canvas.ghost = _hasGhost ? _ghost : NULL;
    [self.view addSubview:_canvas];

    // Palette: a spread of colors, the last slot is your own pick, plus an eraser.
    _colors = [@[@0xFFFFFFFF, @0x1C1C1EFF, @0xFF3B30FF, @0xFF9500FF, @0xFFCC00FF, @0x34C759FF, @0x00C7BEFF,
                 @0x0A84FFFF, @0x5E5CE6FF, @0xBF5AF2FF, @0xFF6482FF, @0x8E5A2BFF] mutableCopy];
    _swatches = [NSMutableArray array];
    _palette = [[UIStackView alloc] init];
    _palette.axis = UILayoutConstraintAxisHorizontal;
    _palette.distribution = UIStackViewDistributionFillEqually;
    _palette.spacing = 6;
    for (NSInteger i = 0; i < (NSInteger)_colors.count + 2; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tag = i;
        button.layer.cornerRadius = 8;
        button.layer.borderColor = VLT_ACCENT.CGColor;
        if (i < (NSInteger)_colors.count) {
            button.backgroundColor = VLTColorFromRGBA(_colors[i].unsignedIntValue);
            button.accessibilityLabel = [NSString stringWithFormat:@"Color %ld", (long)i + 1];
        } else {
            BOOL eraser = (i == (NSInteger)_colors.count + 1);
            [button setImage:[UIImage systemImageNamed:eraser ? @"eraser.fill" : @"eyedropper.halffull"] forState:UIControlStateNormal];
            button.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
            button.accessibilityLabel = eraser ? @"Eraser" : @"Choose a color";
        }
        [button addTarget:self action:@selector(swatchTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_palette addArrangedSubview:button];
        [_swatches addObject:button];
    }
    [self.view addSubview:_palette];
    self.toolbarItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStylePlain target:self action:@selector(clearAll)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
        [[UIBarButtonItem alloc] initWithTitle:@"Fill Empty" style:UIBarButtonItemStylePlain target:self action:@selector(fillEmpty)],
    ];
    [self selectSwatch:0];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat width = self.view.bounds.size.width - 32, available = self.view.bounds.size.height - safe.top - safe.bottom - 32 - 60;
    CGFloat side = floor(MIN(MIN(width, available), 520) / GRID) * GRID;
    _canvas.frame = CGRectMake(round((self.view.bounds.size.width - side) / 2), safe.top + 16, side, side);
    CGFloat paletteWidth = MIN(width, 620);
    _palette.frame = CGRectMake(round((self.view.bounds.size.width - paletteWidth) / 2), CGRectGetMaxY(_canvas.frame) + 16, paletteWidth, 40);
}

- (void)selectSwatch:(NSInteger)index {
    _selected = index;
    for (UIButton *button in _swatches) button.layer.borderWidth = (button.tag == index) ? 3 : 0;
    BOOL eraser = index == (NSInteger)_colors.count + 1;
    if (eraser) _canvas.color = 0;
    else if (index < (NSInteger)_colors.count) _canvas.color = _colors[index].unsignedIntValue;
}

- (void)swatchTapped:(UIButton *)button {
    if (button.tag == (NSInteger)_colors.count) {   // own color
        UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
        picker.delegate = self;
        picker.supportsAlpha = NO;
        [self presentViewController:picker animated:YES completion:nil];
        return;
    }
    [self selectSwatch:button.tag];
}

- (void)useOwnColor:(UIColor *)color {
    uint32_t rgba = 0xFFFFFFFF;
    VLTParseHex(VLTHexFromColor(color), &rgba);
    rgba |= 0xFF;
    UIButton *button = _swatches[_colors.count];
    button.backgroundColor = VLTColorFromRGBA(rgba);
    [button setImage:nil forState:UIControlStateNormal];
    _selected = _colors.count;
    for (UIButton *swatch in _swatches) swatch.layer.borderWidth = (swatch == button) ? 3 : 0;
    _canvas.color = rgba;
}

- (void)colorPickerViewController:(UIColorPickerViewController *)picker didSelectColor:(UIColor *)color continuously:(BOOL)continuously {
    if (!continuously) [self useOwnColor:color];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)picker {
    [self useOwnColor:picker.selectedColor];
}

- (void)clearAll {
    memset(_pixels, 0, sizeof(_pixels));
    [_canvas setNeedsDisplay];
}

- (void)fillEmpty {
    if (!_canvas.color) return;
    for (int i = 0; i < GRID * GRID; i++) if (!(_pixels[i] & 0xFF)) _pixels[i] = _canvas.color;
    [_canvas setNeedsDisplay];
}

- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)done {
    UIImage *image = [self renderedImage];
    void (^handler)(UIImage *) = self.onDone;
    [self dismissViewControllerAnimated:YES completion:^{ if (handler) handler(image); }];
}

@end

#pragma mark - Save slots

// Saved animations live in their own preferences file, away from the settings
// the tweak reads, so a full set of slots never slows anything down.
#define VLT_SLOT_DOMAIN CFSTR("com.notpreston.volta.slots")
#define VLT_MAX_SLOTS 12

static NSArray<NSDictionary *> *VLTSlots(void) {
    CFPreferencesAppSynchronize(VLT_SLOT_DOMAIN);
    NSArray *slots = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("slots"), VLT_SLOT_DOMAIN));
    NSMutableArray *valid = [NSMutableArray array];
    for (id slot in ([slots isKindOfClass:[NSArray class]] ? slots : @[])) {
        if ([slot isKindOfClass:[NSDictionary class]] && [slot[@"frames"] isKindOfClass:[NSArray class]]) [valid addObject:slot];
    }
    return valid;
}

static void VLTSetSlots(NSArray *slots) {
    CFPreferencesSetAppValue(CFSTR("slots"), (__bridge CFPropertyListRef)slots, VLT_SLOT_DOMAIN);
    CFPreferencesAppSynchronize(VLT_SLOT_DOMAIN);
}

@interface VLTSlotListController : UITableViewController
@property (nonatomic, copy) NSArray<NSData *> *(^currentFrames)(void);
@property (nonatomic, copy) NSInteger (^currentFps)(void);
@property (nonatomic, copy) void (^onLoad)(NSArray<NSData *> *frames, NSInteger fps);
@end

@implementation VLTSlotListController {
    NSMutableArray<NSDictionary *> *_slots;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Saved Animations";
    self.view.tintColor = VLT_ACCENT;
    _slots = [VLTSlots() mutableCopy];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 1 : _slots.count; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return (section == 1 && _slots.count) ? @"Saved" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return [NSString stringWithFormat:@"Keeps a copy of the animation you are working on. Up to %d slots.", VLT_MAX_SLOTS];
    return _slots.count ? @"Tap a slot to load it, replace it, rename it or delete it. Saved animations stay put when Volta is updated or its settings are reset."
                        : @"Nothing saved yet.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (indexPath.section == 0) {
        BOOL canSave = self.currentFrames().count > 0 && _slots.count < VLT_MAX_SLOTS;
        cell.textLabel.text = @"Save Current Animation…";
        cell.textLabel.textColor = canSave ? VLT_ACCENT : [UIColor tertiaryLabelColor];
        cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.down.fill"];
        cell.imageView.tintColor = canSave ? VLT_ACCENT : [UIColor tertiaryLabelColor];
        return cell;
    }
    NSDictionary *slot = _slots[indexPath.row];
    NSArray *frames = slot[@"frames"];
    cell.textLabel.text = [slot[@"name"] length] ? slot[@"name"] : @"Untitled";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu frame%@ · %ld per second", (unsigned long)frames.count, frames.count == 1 ? @"" : @"s", (long)[slot[@"fps"] integerValue]];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    UIImage *thumb = [frames.firstObject isKindOfClass:[NSData class]] ? [UIImage imageWithData:frames.firstObject] : nil;
    if (thumb) {
        // A fixed-size tile so every row lines up, whatever the frame's shape.
        cell.imageView.image = [VLTRenderer(CGSizeMake(44, 44), 0) imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [[UIColor colorWithRed:0.12 green:0.11 blue:0.26 alpha:1] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 44, 44) cornerRadius:9] fill];
            CGContextSetInterpolationQuality(context.CGContext, kCGInterpolationNone);
            CGFloat k = MIN(34 / thumb.size.width, 34 / thumb.size.height);
            CGSize fitted = CGSizeMake(thumb.size.width * k, thumb.size.height * k);
            [thumb drawInRect:CGRectMake((44 - fitted.width) / 2, (44 - fitted.height) / 2, fitted.width, fitted.height)];
        }];
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)askForName:(NSString *)title initial:(NSString *)initial then:(void (^)(NSString *name))then {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = initial;
        field.placeholder = @"Name";
        field.autocapitalizationType = UITextAutocapitalizationTypeSentences;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *name = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        then(name.length ? name : @"Untitled");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSDictionary *)slotNamed:(NSString *)name {
    return @{@"name": name, @"fps": @(self.currentFps()), @"frames": self.currentFrames() ?: @[], @"date": [NSDate date]};
}

- (void)commit {
    VLTSetSlots(_slots);
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    __weak typeof(self) weakSelf = self;
    if (indexPath.section == 0) {
        if (!self.currentFrames().count || _slots.count >= VLT_MAX_SLOTS) return;
        [self askForName:@"Save Animation" initial:[NSString stringWithFormat:@"Animation %lu", (unsigned long)_slots.count + 1] then:^(NSString *name) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf->_slots addObject:[strongSelf slotNamed:name]];
            [strongSelf commit];
        }];
        return;
    }

    NSInteger index = indexPath.row;
    NSDictionary *slot = _slots[index];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:slot[@"name"] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Load" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        void (^load)(void) = ^{
            if (strongSelf.onLoad) strongSelf.onLoad(slot[@"frames"], [slot[@"fps"] integerValue]);
            [strongSelf.navigationController popViewControllerAnimated:YES];
        };
        if (!strongSelf.currentFrames().count) { load(); return; }
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Replace Current Animation?"
                                                                         message:@"The frames you are working on will be replaced. Save them to a slot first if you want to keep them."
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Replace" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { load(); }]];
        [strongSelf presentViewController:confirm animated:YES completion:nil];
    }]];
    if (self.currentFrames().count) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Replace With Current Animation" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || index >= (NSInteger)strongSelf->_slots.count) return;
            strongSelf->_slots[index] = [strongSelf slotNamed:slot[@"name"]];
            [strongSelf commit];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf askForName:@"Rename" initial:slot[@"name"] then:^(NSString *name) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || index >= (NSInteger)strongSelf->_slots.count) return;
            NSMutableDictionary *renamed = [slot mutableCopy];
            renamed[@"name"] = name;
            strongSelf->_slots[index] = renamed;
            [strongSelf commit];
        }];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || index >= (NSInteger)strongSelf->_slots.count) return;
        [strongSelf->_slots removeObjectAtIndex:index];
        [strongSelf commit];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

@end

#pragma mark - Frame cell

@interface VLTFrameCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *numberLabel;
@end

@implementation VLTFrameCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.contentView.backgroundColor = [UIColor colorWithRed:0.12 green:0.11 blue:0.26 alpha:1];
        self.contentView.layer.cornerRadius = 12;
        self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
        self.contentView.layer.borderColor = VLT_ACCENT.CGColor;
        self.contentView.clipsToBounds = YES;
        _imageView = [[UIImageView alloc] initWithFrame:CGRectInset(self.contentView.bounds, 8, 8)];
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.layer.magnificationFilter = kCAFilterNearest;   // keep pixel art crisp
        [self.contentView addSubview:_imageView];
        _numberLabel = [[UILabel alloc] initWithFrame:CGRectMake(5, 3, 30, 14)];
        _numberLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightSemibold];
        _numberLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
        [self.contentView addSubview:_numberLabel];
    }
    return self;
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    self.contentView.layer.borderWidth = selected ? 3 : 0;
}

@end

#pragma mark - Creator

@interface VLTAnimCreatorController () <UICollectionViewDataSource, UICollectionViewDelegate, PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@end

@implementation VLTAnimCreatorController {
    NSMutableArray<NSData *> *_frames;
    NSMutableArray<UIImage *> *_images;
    NSInteger _selected;
    NSInteger _fps;

    UIScrollView *_scroll;
    UIView *_previewCard;
    CAGradientLayer *_previewGradient;
    UIImageView *_preview;
    UILabel *_emptyLabel;
    UICollectionView *_strip;
    UIStackView *_buttons;
    UILabel *_speedLabel;
    UISlider *_speedSlider;
    UILabel *_footer;
    NSMutableDictionary<NSString *, UIButton *> *_buttonsByName;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Animation Creator";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.view.tintColor = VLT_ACCENT;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Slots" style:UIBarButtonItemStylePlain target:self action:@selector(openSlots)];

    NSDictionary *prefs = VLTCopyPrefs();
    _frames = [NSMutableArray array];
    _images = [NSMutableArray array];
    for (id item in ([prefs[@"batFrames"] isKindOfClass:[NSArray class]] ? prefs[@"batFrames"] : @[])) {
        UIImage *image = [item isKindOfClass:[NSData class]] ? [UIImage imageWithData:item] : nil;
        if (image && _frames.count < VLT_MAX_FRAMES) { [_frames addObject:item]; [_images addObject:image]; }
    }
    _fps = (NSInteger)lround(fmin(fmax(VLTNum(prefs, @"batFps", 8), 1), 24));

    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    _previewCard = [[UIView alloc] init];
    _previewCard.layer.cornerRadius = 22;
    _previewCard.layer.cornerCurve = kCACornerCurveContinuous;
    _previewCard.clipsToBounds = YES;
    _previewGradient = [CAGradientLayer layer];
    _previewGradient.colors = @[(id)[UIColor colorWithRed:0.11 green:0.09 blue:0.27 alpha:1].CGColor,
                                (id)[UIColor colorWithRed:0.29 green:0.18 blue:0.51 alpha:1].CGColor,
                                (id)[UIColor colorWithRed:0.12 green:0.44 blue:0.55 alpha:1].CGColor];
    _previewGradient.startPoint = CGPointMake(0, 0);
    _previewGradient.endPoint = CGPointMake(1, 1);
    [_previewCard.layer addSublayer:_previewGradient];
    [_scroll addSubview:_previewCard];

    _preview = [[UIImageView alloc] init];
    _preview.contentMode = UIViewContentModeScaleAspectFit;
    _preview.layer.magnificationFilter = kCAFilterNearest;
    [_previewCard addSubview:_preview];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.text = @"No frames yet.\nDraw one, or add photos or a GIF.";
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _emptyLabel.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    [_previewCard addSubview:_emptyLabel];

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.itemSize = CGSizeMake(72, 72);
    layout.minimumLineSpacing = 10;
    layout.sectionInset = UIEdgeInsetsMake(0, 16, 0, 16);
    _strip = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    _strip.backgroundColor = [UIColor clearColor];
    _strip.showsHorizontalScrollIndicator = NO;
    _strip.dataSource = self;
    _strip.delegate = self;
    [_strip registerClass:[VLTFrameCell class] forCellWithReuseIdentifier:@"frame"];
    [_scroll addSubview:_strip];

    _buttonsByName = [NSMutableDictionary dictionary];
    NSArray *rows = @[
        @[@[@"Draw", @"pencil.tip", @"drawFrame"], @[@"Photos", @"photo.on.rectangle", @"addPhotos"], @[@"GIF File", @"square.stack.3d.forward.dottedline", @"importGIF"]],
        @[@[@"Edit", @"square.and.pencil", @"editFrame"], @[@"Duplicate", @"plus.square.on.square", @"duplicateFrame"], @[@"Delete", @"trash", @"deleteFrame"]],
        @[@[@"Move Left", @"arrow.left", @"moveLeft"], @[@"Move Right", @"arrow.right", @"moveRight"], @[@"Delete All", @"trash.slash", @"deleteAll"]],
    ];
    _buttons = [[UIStackView alloc] init];
    _buttons.axis = UILayoutConstraintAxisVertical;
    _buttons.spacing = 10;
    _buttons.distribution = UIStackViewDistributionFillEqually;
    for (NSArray *row in rows) {
        UIStackView *line = [[UIStackView alloc] init];
        line.axis = UILayoutConstraintAxisHorizontal;
        line.spacing = 10;
        line.distribution = UIStackViewDistributionFillEqually;
        for (NSArray *spec in row) {
            UIButtonConfiguration *config = [UIButtonConfiguration tintedButtonConfiguration];
            config.title = spec[0];
            config.image = [UIImage systemImageNamed:spec[1]] ?: [UIImage systemImageNamed:@"square"];
            config.imagePlacement = NSDirectionalRectEdgeTop;
            config.imagePadding = 4;
            config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
            config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
                NSMutableDictionary *updated = [attributes mutableCopy];
                updated[NSFontAttributeName] = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
                return updated;
            };
            if ([spec[0] hasPrefix:@"Delete"]) config.baseForegroundColor = config.baseBackgroundColor = [UIColor systemRedColor];
            UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
            [button addTarget:self action:NSSelectorFromString(spec[2]) forControlEvents:UIControlEventTouchUpInside];
            [line addArrangedSubview:button];
            _buttonsByName[spec[2]] = button;
        }
        [_buttons addArrangedSubview:line];
    }
    [_scroll addSubview:_buttons];

    _speedLabel = [[UILabel alloc] init];
    _speedLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [_scroll addSubview:_speedLabel];
    _speedSlider = [[UISlider alloc] init];
    _speedSlider.minimumValue = 1;
    _speedSlider.maximumValue = 24;
    _speedSlider.value = _fps;
    [_speedSlider addTarget:self action:@selector(speedChanged) forControlEvents:UIControlEventValueChanged];
    [_speedSlider addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [_scroll addSubview:_speedSlider];

    _footer = [[UILabel alloc] init];
    _footer.numberOfLines = 0;
    _footer.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _footer.textColor = [UIColor secondaryLabelColor];
    _footer.text = [NSString stringWithFormat:@"Up to %d frames. Your animation becomes the battery picture as soon as it has a frame; you can switch back under Picture on the Battery page. Drawn frames are %d × %d pixels, and the faint shapes while drawing are the frame before, to help you line things up. Use Slots (top right) to keep animations and switch between them.", VLT_MAX_FRAMES, GRID, GRID];
    [_scroll addSubview:_footer];

    _selected = _frames.count ? 0 : -1;
    [self refresh];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width, inset = MAX(16, self.view.layoutMargins.left), inner = MIN(width - inset * 2, 640);
    CGFloat x = round((width - inner) / 2), y = 14;
    _previewCard.frame = CGRectMake(x, y, inner, 180);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _previewGradient.frame = _previewCard.bounds;
    [CATransaction commit];
    _preview.frame = CGRectMake((inner - 120) / 2, 30, 120, 120);
    _emptyLabel.frame = CGRectInset(_previewCard.bounds, 20, 20);
    y = CGRectGetMaxY(_previewCard.frame) + 14;
    _strip.frame = CGRectMake(0, y, width, 76);
    y += 76 + 14;
    _buttons.frame = CGRectMake(x, y, inner, 3 * 62 + 20);
    y = CGRectGetMaxY(_buttons.frame) + 20;
    _speedLabel.frame = CGRectMake(x + 4, y, inner - 8, 20);
    _speedSlider.frame = CGRectMake(x + 4, y + 26, inner - 8, 30);
    y += 70;
    CGSize footerSize = [_footer sizeThatFits:CGSizeMake(inner - 8, CGFLOAT_MAX)];
    _footer.frame = CGRectMake(x + 4, y, inner - 8, footerSize.height);
    _scroll.contentSize = CGSizeMake(width, CGRectGetMaxY(_footer.frame) + 30);
}

#pragma mark State

- (void)refresh {
    BOOL has = _frames.count > 0, hasSelection = _selected >= 0 && _selected < (NSInteger)_frames.count;
    BOOL full = _frames.count >= VLT_MAX_FRAMES;
    _emptyLabel.hidden = has;
    [_preview stopAnimating];
    _preview.animationImages = nil;
    _preview.image = _images.firstObject;
    if (_images.count > 1) {
        _preview.animationImages = _images;
        _preview.animationDuration = (double)_images.count / MAX(_fps, 1);
        [_preview startAnimating];
    }
    _speedLabel.text = [NSString stringWithFormat:@"Speed: %ld frames per second", (long)_fps];
    for (NSString *name in @[@"editFrame", @"duplicateFrame", @"deleteFrame"]) _buttonsByName[name].enabled = hasSelection;
    _buttonsByName[@"duplicateFrame"].enabled = hasSelection && !full;
    _buttonsByName[@"moveLeft"].enabled = hasSelection && _selected > 0;
    _buttonsByName[@"moveRight"].enabled = hasSelection && _selected < (NSInteger)_frames.count - 1;
    _buttonsByName[@"deleteAll"].enabled = has;
    for (NSString *name in @[@"drawFrame", @"addPhotos", @"importGIF"]) _buttonsByName[name].enabled = !full;
    [_strip reloadData];
    if (hasSelection) {
        [_strip selectItemAtIndexPath:[NSIndexPath indexPathForItem:_selected inSection:0] animated:NO
                       scrollPosition:UICollectionViewScrollPositionCenteredHorizontally];
    }
}

- (void)save {
    NSDictionary *prefs = VLTCopyPrefs();
    VLTCreatorSave(@"batFrames", _frames.count ? [_frames copy] : nil);
    VLTCreatorSave(@"batFps", @(_fps));
    VLTCreatorSave(@"batImageGen", @(((long)VLTNum(prefs, @"batImageGen", 0) + 1) % 256));
    int kind = (int)VLTNum(prefs, @"batImage", VLT_IMAGE_NONE);
    if (_frames.count && kind != VLT_IMAGE_ANIMATED) VLTCreatorSave(@"batImage", @(VLT_IMAGE_ANIMATED));
    if (!_frames.count && kind == VLT_IMAGE_ANIMATED) VLTCreatorSave(@"batImage", @(VLT_IMAGE_NONE));
    CFPreferencesAppSynchronize(CFSTR(VLT_DOMAIN));
    notify_post(VLT_NOTIFY_PREFS);
}

- (void)changed {
    [self save];
    [self refresh];
}

- (void)speedChanged {
    NSInteger fps = (NSInteger)lroundf(_speedSlider.value);
    if (fps == _fps) return;
    _fps = fps;
    _speedLabel.text = [NSString stringWithFormat:@"Speed: %ld frames per second", (long)_fps];
    if (_images.count > 1) {
        _preview.animationDuration = (double)_images.count / MAX(_fps, 1);
        [_preview startAnimating];
    }
}

- (void)insertImage:(UIImage *)image at:(NSInteger)index {
    if (_frames.count >= VLT_MAX_FRAMES) return;
    NSData *data = VLTFrameData(image);
    UIImage *stored = data ? [UIImage imageWithData:data] : nil;
    if (!stored) return;
    index = MIN(MAX(index, 0), (NSInteger)_frames.count);
    [_frames insertObject:data atIndex:index];
    [_images insertObject:stored atIndex:index];
    _selected = index;
}

#pragma mark Actions

- (void)openSlots {
    VLTSlotListController *slots = [[VLTSlotListController alloc] init];
    __weak typeof(self) weakSelf = self;
    slots.currentFrames = ^NSArray<NSData *> *{
        typeof(self) strongSelf = weakSelf;
        return strongSelf ? [strongSelf->_frames copy] : @[];
    };
    slots.currentFps = ^NSInteger{
        typeof(self) strongSelf = weakSelf;
        return strongSelf ? strongSelf->_fps : 8;
    };
    slots.onLoad = ^(NSArray<NSData *> *frames, NSInteger fps) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf->_frames removeAllObjects];
        [strongSelf->_images removeAllObjects];
        for (id item in frames) {
            UIImage *image = [item isKindOfClass:[NSData class]] ? [UIImage imageWithData:item] : nil;
            if (image && strongSelf->_frames.count < VLT_MAX_FRAMES) { [strongSelf->_frames addObject:item]; [strongSelf->_images addObject:image]; }
        }
        strongSelf->_fps = MIN(MAX(fps, 1), 24);
        strongSelf->_speedSlider.value = strongSelf->_fps;
        strongSelf->_selected = strongSelf->_frames.count ? 0 : -1;
        [strongSelf changed];
    };
    [self.navigationController pushViewController:slots animated:YES];
}

- (void)openEditorWithImage:(UIImage *)image previous:(UIImage *)previous replacing:(BOOL)replace {
    VLTPixelEditorController *editor = [[VLTPixelEditorController alloc] init];
    editor.startImage = image;
    editor.previousImage = previous;
    NSInteger target = _selected;
    __weak typeof(self) weakSelf = self;
    editor.onDone = ^(UIImage *result) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !result) return;
        if (replace && target >= 0 && target < (NSInteger)strongSelf->_frames.count) {
            [strongSelf->_frames removeObjectAtIndex:target];
            [strongSelf->_images removeObjectAtIndex:target];
            [strongSelf insertImage:result at:target];
        } else {
            [strongSelf insertImage:result at:target + 1];
        }
        [strongSelf changed];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)drawFrame {
    UIImage *previous = (_selected >= 0 && _selected < (NSInteger)_images.count) ? _images[_selected] : nil;
    [self openEditorWithImage:nil previous:previous replacing:NO];
}

- (void)editFrame {
    if (_selected < 0 || _selected >= (NSInteger)_images.count) return;
    UIImage *previous = _selected > 0 ? _images[_selected - 1] : nil;
    [self openEditorWithImage:_images[_selected] previous:previous replacing:YES];
}

- (void)duplicateFrame {
    if (_selected < 0 || _selected >= (NSInteger)_images.count) return;
    [self insertImage:_images[_selected] at:_selected + 1];
    [self changed];
}

- (void)deleteFrame {
    if (_selected < 0 || _selected >= (NSInteger)_frames.count) return;
    [_frames removeObjectAtIndex:_selected];
    [_images removeObjectAtIndex:_selected];
    _selected = MIN(_selected, (NSInteger)_frames.count - 1);
    [self changed];
}

- (void)deleteAll {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete All Frames?" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete All" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf->_frames removeAllObjects];
        [strongSelf->_images removeAllObjects];
        strongSelf->_selected = -1;
        [strongSelf changed];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)moveBy:(NSInteger)delta {
    NSInteger to = _selected + delta;
    if (_selected < 0 || to < 0 || to >= (NSInteger)_frames.count) return;
    [_frames exchangeObjectAtIndex:_selected withObjectAtIndex:to];
    [_images exchangeObjectAtIndex:_selected withObjectAtIndex:to];
    _selected = to;
    [self changed];
}

- (void)moveLeft { [self moveBy:-1]; }
- (void)moveRight { [self moveBy:1]; }

- (void)addPhotos {
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = [PHPickerFilter imagesFilter];
    config.selectionLimit = MAX(1, VLT_MAX_FRAMES - (NSInteger)_frames.count);
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)importGIF {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeGIF] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

// Every frame of a GIF (evenly thinned if it has more than there is room for).
- (NSArray<UIImage *> *)imagesFromGIFData:(NSData *)data fps:(NSInteger *)fps room:(NSInteger)room {
    CGImageSourceRef source = data ? CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL) : NULL;
    if (!source) return @[];
    size_t count = CGImageSourceGetCount(source);
    NSMutableArray *images = [NSMutableArray array];
    size_t step = (count > (size_t)room && room > 0) ? (count + room - 1) / room : 1;
    for (size_t i = 0; i < count && (NSInteger)images.count < room; i += step) {
        CGImageRef frame = CGImageSourceCreateImageAtIndex(source, i, NULL);
        if (frame) {
            [images addObject:[UIImage imageWithCGImage:frame]];
            CGImageRelease(frame);
        }
    }
    if (fps && count > 1) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        NSDictionary *gif = properties[(__bridge NSString *)kCGImagePropertyGIFDictionary];
        double delay = [gif[(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime] doubleValue];
        if (delay <= 0) delay = [gif[(__bridge NSString *)kCGImagePropertyGIFDelayTime] doubleValue];
        if (delay > 0) *fps = (NSInteger)lround(fmin(fmax(1.0 / (delay * step), 1), 24));
    }
    CFRelease(source);
    return images;
}

- (void)appendImages:(NSArray<UIImage *> *)images fps:(NSInteger)fps {
    if (!images.count) return;
    BOOL wasEmpty = _frames.count == 0;
    for (UIImage *image in images) [self insertImage:image at:_frames.count];
    if (wasEmpty && fps > 0) {
        _fps = fps;
        _speedSlider.value = fps;
    }
    [self changed];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (scoped) [url stopAccessingSecurityScopedResource];
    NSInteger fps = 0;
    [self appendImages:[self imagesFromGIFData:data fps:&fps room:VLT_MAX_FRAMES - (NSInteger)_frames.count] fps:fps];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    // Load everything first, keeping the order the photos were picked in.
    NSMutableArray *slots = [NSMutableArray array];
    for (NSUInteger i = 0; i < results.count; i++) [slots addObject:[NSNull null]];
    dispatch_group_t group = dispatch_group_create();
    __block NSInteger gifFps = 0;
    NSInteger room = VLT_MAX_FRAMES - (NSInteger)_frames.count;
    __weak typeof(self) weakSelf = self;
    [results enumerateObjectsUsingBlock:^(PHPickerResult *result, NSUInteger index, BOOL *stop) {
        NSItemProvider *provider = result.itemProvider;
        dispatch_group_enter(group);
        if ([provider hasItemConformingToTypeIdentifier:UTTypeGIF.identifier]) {
            [provider loadDataRepresentationForTypeIdentifier:UTTypeGIF.identifier completionHandler:^(NSData *data, NSError *error) {
                NSInteger fps = 0;
                NSArray *images = [weakSelf imagesFromGIFData:data fps:&fps room:room] ?: @[];
                @synchronized (slots) { slots[index] = images; if (fps > 0) gifFps = fps; }
                dispatch_group_leave(group);
            }];
        } else if ([provider canLoadObjectOfClass:[UIImage class]]) {
            [provider loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
                if ([(id)object isKindOfClass:[UIImage class]]) { @synchronized (slots) { slots[index] = @[(UIImage *)object]; } }
                dispatch_group_leave(group);
            }];
        } else {
            dispatch_group_leave(group);
        }
    }];
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSMutableArray *images = [NSMutableArray array];
        for (id slot in slots) if ([slot isKindOfClass:[NSArray class]]) [images addObjectsFromArray:slot];
        [weakSelf appendImages:images fps:gifFps];
    });
}

#pragma mark Strip

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section { return _images.count; }

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    VLTFrameCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"frame" forIndexPath:indexPath];
    cell.imageView.image = _images[indexPath.item];
    cell.numberLabel.text = [NSString stringWithFormat:@"%ld", (long)indexPath.item + 1];
    cell.accessibilityLabel = [NSString stringWithFormat:@"Frame %ld", (long)indexPath.item + 1];
    cell.isAccessibilityElement = YES;
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    _selected = indexPath.item;
    [self refresh];
}

@end
