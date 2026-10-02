#import "VLTLayout.h"
#import "VLTViews.h"
#import "VLTShared.h"
#import "VLTActions.h"
#import <objc/message.h>

static void VLTSave(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR(VLT_DOMAIN));
}

static void VLTCommit(void) {
    CFPreferencesAppSynchronize(CFSTR(VLT_DOMAIN));
    notify_post(VLT_NOTIFY_PREFS);
}

static UITableViewController *VLTPrepare(UITableViewController *controller) {
    controller.view.tintColor = VLT_ACCENT;
    return controller;
}

#pragma mark - Generic picker

// A list to choose one thing from. Each item: @{@"title", @"value", optional @"subtitle", optional @"symbol"}.
@interface VLTChoiceController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, copy) NSArray<NSDictionary *> *items;
@property (nonatomic, strong) id selectedValue;
@property (nonatomic, copy) void (^onPick)(NSDictionary *item);
@property (nonatomic) BOOL searchable;
@property (nonatomic, copy) NSString *emptyText;
@end

@implementation VLTChoiceController {
    NSArray<NSDictionary *> *_shown;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.tintColor = VLT_ACCENT;
    _shown = self.items ?: @[];
    if (self.searchable) {
        UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
        search.searchResultsUpdater = self;
        search.obscuresBackgroundDuringPresentation = NO;
        self.navigationItem.searchController = search;
        self.navigationItem.hidesSearchBarWhenScrolling = NO;
        self.definesPresentationContext = YES;
    }
}

- (void)setItems:(NSArray<NSDictionary *> *)items {
    _items = [items copy];
    _shown = _items ?: @[];
    if (self.isViewLoaded) [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!query.length) {
        _shown = self.items ?: @[];
    } else {
        _shown = [self.items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item, NSDictionary *bindings) {
            return [item[@"title"] rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
                   [item[@"subtitle"] rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
        }]];
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _shown.count; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return _shown.count ? nil : self.emptyText;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"choice"]
                         ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"choice"];
    NSDictionary *item = _shown[indexPath.row];
    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"subtitle"];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.image = item[@"symbol"] ? [UIImage systemImageNamed:item[@"symbol"]] : nil;
    cell.accessoryType = [item[@"value"] isEqual:self.selectedValue] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = _shown[indexPath.row];
    if (self.onPick) self.onPick(item);
    self.navigationItem.searchController.active = NO;
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - Installed apps

static NSArray<NSDictionary *> *VLTInstalledApps(void) {
    NSMutableArray *apps = [NSMutableArray array];
    @try {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        SEL shared = NSSelectorFromString(@"defaultWorkspace");
        SEL all = NSSelectorFromString(@"allInstalledApplications");
        if (![workspaceClass respondsToSelector:shared]) return apps;
        id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, shared);
        if (![workspace respondsToSelector:all]) return apps;
        for (id proxy in ((NSArray *(*)(id, SEL))objc_msgSend)(workspace, all)) {
            NSString *identifier = [proxy valueForKey:@"applicationIdentifier"];
            NSString *name = [proxy valueForKey:@"localizedName"];
            NSArray *tags = [proxy valueForKey:@"appTags"];
            if (![identifier isKindOfClass:[NSString class]] || ![name isKindOfClass:[NSString class]] || !name.length) continue;
            if ([tags isKindOfClass:[NSArray class]] && [tags containsObject:@"hidden"]) continue;   // internal system apps
            [apps addObject:@{@"title": name, @"subtitle": identifier, @"value": identifier}];
        }
    } @catch (__unused NSException *e) {}
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
    }];
    return apps;
}

static NSArray<NSString *> *VLTSymbolChoices(void) {
    return @[@"app.fill", @"star.fill", @"heart.fill", @"bolt.fill", @"flame.fill", @"moon.fill", @"sun.max.fill", @"sparkles",
             @"house.fill", @"gearshape.fill", @"slider.horizontal.3", @"wrench.and.screwdriver.fill", @"terminal.fill",
             @"music.note", @"play.fill", @"headphones", @"gamecontroller.fill", @"tv.fill", @"camera.fill", @"photo.fill",
             @"message.fill", @"envelope.fill", @"phone.fill", @"safari.fill", @"globe", @"link", @"map.fill", @"cart.fill",
             @"book.fill", @"pencil", @"doc.fill", @"folder.fill", @"calendar", @"clock.fill", @"alarm.fill", @"timer",
             @"lock.fill", @"lock.rotation", @"key.fill", @"battery.25", @"battery.100", @"wifi", @"antenna.radiowaves.left.and.right",
             @"airplane", @"car.fill", @"figure.walk", @"leaf.fill", @"cloud.fill", @"snowflake", @"ladybug.fill", @"pawprint.fill",
             @"arrow.clockwise", @"power", @"trash.fill", @"bell.fill", @"magnifyingglass", @"qrcode", @"dollarsign.circle.fill"];
}

#pragma mark - One button

@interface VLTButtonDetailController : UITableViewController <UITextFieldDelegate>
@property (nonatomic, strong) NSMutableDictionary *button;
@property (nonatomic, copy) void (^onChange)(NSDictionary *button);
@end

@implementation VLTButtonDetailController

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.tintColor = VLT_ACCENT;
    self.title = @"Button";
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)action { return [self.button[@"a"] integerValue]; }

- (void)changed {
    if (self.onChange) self.onChange([self.button copy]);
}

// Sections: 0 title, 1 symbol, 2 action (+ target)
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (section == 2 && VLTActionNeedsTarget([self action])) ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Title", @"Icon", @"When Tapped"][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Shown under the icon. Leave empty for an icon-only button.";
    if (section == 2 && [self action] == VLTActionShortcut) return @"Type the shortcut's name exactly as it appears in the Shortcuts app.";
    if (section == 2 && [self action] == VLTActionOpenURL) return @"A web address, or any app link such as music:// or prefs:root=WIFI.";
    return nil;
}

- (UITableViewCell *)textCellWithTag:(NSInteger)tag text:(NSString *)text placeholder:(NSString *)placeholder {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectInset(cell.contentView.bounds, 18, 0)];
    field.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    field.tag = tag;
    field.text = text;
    field.placeholder = placeholder;
    field.delegate = self;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.returnKeyType = UIReturnKeyDone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    if (tag == 2) {
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        if ([self action] == VLTActionOpenURL) field.keyboardType = UIKeyboardTypeURL;
    }
    [field addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingChanged];
    [cell.contentView addSubview:field];
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger action = [self action];
    if (indexPath.section == 0) return [self textCellWithTag:1 text:self.button[@"t"] placeholder:@"Optional"];
    if (indexPath.section == 2 && indexPath.row == 1 && action != VLTActionOpenApp) {
        return [self textCellWithTag:2 text:self.button[@"v"] placeholder:(action == VLTActionShortcut ? @"Shortcut name" : @"https://example.com")];
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (indexPath.section == 1) {
        NSString *symbol = [self.button[@"s"] length] ? self.button[@"s"] : VLTActionDefaultSymbol(action);
        cell.textLabel.text = @"Icon";
        cell.imageView.image = [UIImage systemImageNamed:symbol];
        cell.detailTextLabel.text = symbol;
    } else if (indexPath.row == 0) {
        cell.textLabel.text = @"Action";
        cell.detailTextLabel.text = VLTActionName(action);
    } else {
        cell.textLabel.text = @"App";
        cell.detailTextLabel.text = [self.button[@"n"] length] ? self.button[@"n"] : ([self.button[@"v"] length] ? self.button[@"v"] : @"Choose");
    }
    return cell;
}

- (void)fieldChanged:(UITextField *)field {
    self.button[field.tag == 1 ? @"t" : @"v"] = field.text ?: @"";
    [self changed];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    __weak typeof(self) weakSelf = self;
    VLTChoiceController *picker = [[VLTChoiceController alloc] init];

    if (indexPath.section == 1) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *symbol in VLTSymbolChoices()) {
            if ([UIImage systemImageNamed:symbol]) [items addObject:@{@"title": symbol, @"value": symbol, @"symbol": symbol}];
        }
        picker.title = @"Icon";
        picker.items = items;
        picker.selectedValue = self.button[@"s"];
        picker.onPick = ^(NSDictionary *item) {
            weakSelf.button[@"s"] = item[@"value"];
            [weakSelf changed];
        };
    } else if (indexPath.section == 2 && indexPath.row == 0) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSNumber *action in VLTAllActions()) {
            [items addObject:@{@"title": VLTActionName(action.integerValue), @"value": action, @"symbol": VLTActionDefaultSymbol(action.integerValue)}];
        }
        picker.title = @"Action";
        picker.items = items;
        picker.selectedValue = self.button[@"a"];
        picker.onPick = ^(NSDictionary *item) {
            NSInteger old = [weakSelf action];
            NSString *currentSymbol = weakSelf.button[@"s"];
            // Follow the new action's icon unless the user picked their own.
            if (!currentSymbol.length || [currentSymbol isEqualToString:VLTActionDefaultSymbol(old)])
                weakSelf.button[@"s"] = VLTActionDefaultSymbol([item[@"value"] integerValue]);
            weakSelf.button[@"a"] = item[@"value"];
            weakSelf.button[@"v"] = @"";
            [weakSelf.button removeObjectForKey:@"n"];
            [weakSelf changed];
        };
    } else if (indexPath.section == 2 && [self action] == VLTActionOpenApp) {
        picker.title = @"App";
        picker.searchable = YES;
        picker.emptyText = @"Loading apps…";
        picker.selectedValue = self.button[@"v"];
        picker.onPick = ^(NSDictionary *item) {
            weakSelf.button[@"v"] = item[@"value"];
            weakSelf.button[@"n"] = item[@"title"];
            if (![weakSelf.button[@"t"] length]) weakSelf.button[@"t"] = item[@"title"];
            [weakSelf changed];
        };
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray *apps = VLTInstalledApps();
            dispatch_async(dispatch_get_main_queue(), ^{
                picker.emptyText = @"No apps found.";
                picker.items = apps;
            });
        });
    } else {
        return;
    }
    [self.navigationController pushViewController:picker animated:YES];
}

@end

#pragma mark - Button list

@implementation VLTButtonListController {
    NSMutableArray<NSDictionary *> *_buttons;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.tintColor = VLT_ACCENT;
    self.title = @"Buttons";
    self.tableView.allowsSelectionDuringEditing = YES;
    self.tableView.editing = YES;
    _buttons = [NSMutableArray array];
    NSArray *saved = VLTCopyPrefs()[@"ccCustomButtons"];
    if ([saved isKindOfClass:[NSArray class]]) {
        for (id button in saved) if ([button isKindOfClass:[NSDictionary class]]) [_buttons addObject:button];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)save {
    VLTSave(@"ccCustomButtons", [_buttons copy]);
    VLTCommit();
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? _buttons.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return _buttons.count ? @"Drag to reorder. They appear four to a row under your modules." : @"No buttons yet.";
    return [NSString stringWithFormat:@"Up to %d buttons. Turn on Show Custom Controls on the previous screen to see them.", VLT_MAX_BUTTONS];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (indexPath.section == 1) {
        BOOL full = _buttons.count >= VLT_MAX_BUTTONS;
        cell.textLabel.text = @"Add Button";
        cell.textLabel.textColor = full ? [UIColor tertiaryLabelColor] : VLT_ACCENT;
        cell.imageView.image = [UIImage systemImageNamed:@"plus.circle.fill"];
        cell.imageView.tintColor = full ? [UIColor tertiaryLabelColor] : VLT_ACCENT;
        return cell;
    }
    NSDictionary *button = _buttons[indexPath.row];
    NSInteger action = [button[@"a"] integerValue];
    NSString *symbol = [button[@"s"] length] ? button[@"s"] : VLTActionDefaultSymbol(action);
    NSString *title = [button[@"t"] length] ? button[@"t"] : VLTActionName(action);
    NSString *detail = VLTActionName(action);
    NSString *target = [button[@"n"] length] ? button[@"n"] : button[@"v"];
    if (VLTActionNeedsTarget(action)) detail = [target length] ? [NSString stringWithFormat:@"%@: %@", detail, target] : [detail stringByAppendingString:@" (not set)"];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.image = [UIImage systemImageNamed:symbol] ?: [UIImage systemImageNamed:@"circle"];
    cell.editingAccessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return indexPath.section == 0; }
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath { return indexPath.section == 0; }

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0 ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)source toProposedIndexPath:(NSIndexPath *)proposed {
    return proposed.section == 0 ? proposed : [NSIndexPath indexPathForRow:MAX((NSInteger)_buttons.count - 1, 0) inSection:0];
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination {
    NSDictionary *button = _buttons[source.row];
    [_buttons removeObjectAtIndex:source.row];
    [_buttons insertObject:button atIndex:destination.row];
    [self save];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete || indexPath.section != 0) return;
    [_buttons removeObjectAtIndex:indexPath.row];
    [self save];
    [tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger index = indexPath.row;
    if (indexPath.section == 1) {
        if (_buttons.count >= VLT_MAX_BUTTONS) return;
        [_buttons addObject:@{@"t": @"", @"s": VLTActionDefaultSymbol(VLTActionOpenApp), @"a": @(VLTActionOpenApp), @"v": @""}];
        index = _buttons.count - 1;
        [self save];
    }
    VLTButtonDetailController *detail = [[VLTButtonDetailController alloc] init];
    detail.button = [_buttons[index] mutableCopy];
    __weak typeof(self) weakSelf = self;
    detail.onChange = ^(NSDictionary *button) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || index >= (NSInteger)strongSelf->_buttons.count) return;
        strongSelf->_buttons[index] = button;
        [strongSelf save];
    };
    [self.navigationController pushViewController:detail animated:YES];
}

@end

#pragma mark - Module editor

@implementation VLTModuleEditorController {
    NSMutableArray<NSDictionary *> *_modules;       // {id, name, size} in the user's order
    NSMutableSet<NSString *> *_hidden;
    NSMutableDictionary<NSString *, NSString *> *_sizes;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.tintColor = VLT_ACCENT;
    self.title = @"Modules";
    self.tableView.allowsSelectionDuringEditing = YES;
    self.tableView.editing = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Reset" style:UIBarButtonItemStylePlain
                                                                             target:self action:@selector(resetLayout)];
    [self load];
}

- (void)load {
    NSDictionary *prefs = VLTCopyPrefs();
    NSArray *info = [prefs[@"ccModuleInfo"] isKindOfClass:[NSArray class]] ? prefs[@"ccModuleInfo"] : @[];
    NSArray *order = [prefs[@"ccOrder"] isKindOfClass:[NSArray class]] ? prefs[@"ccOrder"] : @[];
    NSArray *hidden = [prefs[@"ccHidden"] isKindOfClass:[NSArray class]] ? prefs[@"ccHidden"] : @[];
    NSDictionary *sizes = [prefs[@"ccSizes"] isKindOfClass:[NSDictionary class]] ? prefs[@"ccSizes"] : @{};

    NSMutableDictionary *byIdentifier = [NSMutableDictionary dictionary];
    for (NSDictionary *module in info) {
        if ([module isKindOfClass:[NSDictionary class]] && [module[@"id"] isKindOfClass:[NSString class]]) byIdentifier[module[@"id"]] = module;
    }
    _modules = [NSMutableArray array];
    for (NSString *identifier in order) {            // saved order first
        if (byIdentifier[identifier] && ![_modules containsObject:byIdentifier[identifier]]) [_modules addObject:byIdentifier[identifier]];
    }
    for (NSDictionary *module in info) {             // then anything new, in system order
        if (byIdentifier[module[@"id"]] && ![_modules containsObject:module]) [_modules addObject:module];
    }
    _hidden = [NSMutableSet setWithArray:hidden];
    _sizes = [sizes mutableCopy];
    [self.tableView reloadData];
}

- (void)save {
    NSMutableArray *order = [NSMutableArray array];
    for (NSDictionary *module in _modules) [order addObject:module[@"id"]];
    VLTSave(@"ccOrder", order);
    VLTSave(@"ccHidden", _hidden.allObjects);
    VLTSave(@"ccSizes", [_sizes copy]);
    VLTCommit();
}

- (void)resetLayout {
    VLTSave(@"ccOrder", nil);
    VLTSave(@"ccHidden", nil);
    VLTSave(@"ccSizes", nil);
    VLTCommit();
    [self load];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _modules.count; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!_modules.count) return @"Volta hasn't seen your modules yet. Respring once, open Control Center, then come back here.";
    return @"Drag to reorder; modules fill the grid left to right, top to bottom. Tap a module to change its size or hide it. Not every module looks right at every size. Changes apply after a respring, with Custom Layout turned on.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"module"]
                         ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"module"];
    NSDictionary *module = _modules[indexPath.row];
    NSString *identifier = module[@"id"];
    BOOL hidden = [_hidden containsObject:identifier];
    NSString *normal = [[module[@"size"] description] stringByReplacingOccurrencesOfString:@"x" withString:@" × "];
    NSString *custom = [_sizes[identifier] stringByReplacingOccurrencesOfString:@"x" withString:@" × "];
    NSString *size = custom.length ? custom : (normal.length ? [NSString stringWithFormat:@"Default (%@)", normal] : @"Default");
    cell.textLabel.text = module[@"name"];
    cell.textLabel.textColor = hidden ? [UIColor tertiaryLabelColor] : [UIColor labelColor];
    cell.detailTextLabel.text = hidden ? @"Hidden" : size;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.image = [UIImage systemImageNamed:hidden ? @"eye.slash" : @"square.grid.2x2"];
    cell.imageView.tintColor = hidden ? [UIColor tertiaryLabelColor] : VLT_ACCENT;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }
- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath { return NO; }

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination {
    NSDictionary *module = _modules[source.row];
    [_modules removeObjectAtIndex:source.row];
    [_modules insertObject:module atIndex:destination.row];
    [self save];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *module = _modules[indexPath.row];
    NSString *identifier = module[@"id"];
    BOOL hidden = [_hidden containsObject:identifier];
    __weak typeof(self) weakSelf = self;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:module[@"name"] message:@"Size is width × height in grid tiles."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    void (^setSize)(NSString *) = ^(NSString *size) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (size) strongSelf->_sizes[identifier] = size;
        else [strongSelf->_sizes removeObjectForKey:identifier];
        [strongSelf save];
        [strongSelf.tableView reloadData];
    };
    [sheet addAction:[UIAlertAction actionWithTitle:@"Default Size" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { setSize(nil); }]];
    for (NSString *size in @[@"1x1", @"2x1", @"1x2", @"2x2", @"4x1", @"4x2"]) {
        NSString *title = [size stringByReplacingOccurrencesOfString:@"x" withString:@" × "];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { setSize(size); }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:(hidden ? @"Show Module" : @"Hide Module")
                                              style:(hidden ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive)
                                            handler:^(UIAlertAction *a) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (hidden) [strongSelf->_hidden removeObject:identifier];
        else [strongSelf->_hidden addObject:identifier];
        [strongSelf save];
        [strongSelf.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

@end

#pragma mark - Nav cell

@implementation VLTNavCell

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.textColor = [UIColor labelColor];
    self.textLabel.textAlignment = NSTextAlignmentNatural;
}

@end

#pragma mark - Layout & Custom Controls page

@implementation VLTCCLayoutController

- (NSString *)plistName { return @"ControlCenterLayout"; }

- (void)openModules:(PSSpecifier *)specifier {
    [self.navigationController pushViewController:VLTPrepare([[VLTModuleEditorController alloc] init]) animated:YES];
}

- (void)openButtons:(PSSpecifier *)specifier {
    [self.navigationController pushViewController:VLTPrepare([[VLTButtonListController alloc] init]) animated:YES];
}

- (void)respring:(PSSpecifier *)specifier {
    notify_post(VLT_NOTIFY_RESPRING);
}

// Each preset is a full set of the style keys from the main Control Center
// page; a missing key means "back to default".
- (void)applyPreset:(PSSpecifier *)specifier {
    NSString *name = [specifier propertyForKey:@"preset"];
    NSDictionary *presets = @{
        @"glass":    @{@"ccBlur": @60, @"ccRadiusOn": @YES, @"ccRadius": @26, @"ccPlatter": @55,
                       @"ccModTint": @"#FFFFFFFF", @"ccModTintStrength": @10, @"ccBorderColor": @"#FFFFFF66", @"ccBorderWidth": @1},
        @"neon":     @{@"ccTint": @"#12002EFF", @"ccTintStrength": @55, @"ccRadiusOn": @YES, @"ccRadius": @14, @"ccPlatter": @70,
                       @"ccModTint": @"#7A00FFFF", @"ccModTintStrength": @20, @"ccBorderColor": @"#00F0FFFF", @"ccBorderWidth": @1.5,
                       @"ccToggleColor": @"#FF2BD6FF", @"ccToggleShape": @40},
        @"midnight": @{@"ccTint": @"#000000FF", @"ccTintStrength": @60, @"ccPlatter": @80,
                       @"ccModTint": @"#0A1A3AFF", @"ccModTintStrength": @45, @"ccToggleColor": @"#4F7CFFFF"},
        @"sunset":   @{@"ccTint": @"#3A0D2EFF", @"ccTintStrength": @45, @"ccRadiusOn": @YES, @"ccRadius": @30, @"ccPlatter": @75,
                       @"ccModTint": @"#FF7A3DFF", @"ccModTintStrength": @22, @"ccBorderColor": @"#FFD0A0AA", @"ccBorderWidth": @1,
                       @"ccToggleColor": @"#FF5E62FF"},
        @"reset":    @{},
    };
    NSDictionary *preset = presets[name];
    if (!preset) return;
    for (NSString *key in @[@"ccBlur", @"ccTint", @"ccTintStrength", @"ccRadiusOn", @"ccRadius", @"ccPlatter", @"ccModTint",
                            @"ccModTintStrength", @"ccBorderColor", @"ccBorderWidth", @"ccToggleColor", @"ccToggleShape"]) {
        VLTSave(key, preset[key]);
    }
    if (preset.count) VLTSave(@"ccEnabled", @YES);
    VLTCommit();

    UIAlertController *done = [UIAlertController alertControllerWithTitle:(preset.count ? [NSString stringWithFormat:@"%@ Applied", specifier.name] : @"Style Reset")
                                                                  message:@"Open Control Center to see it. You can fine-tune everything on the previous page."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:done animated:YES completion:nil];
}

@end
