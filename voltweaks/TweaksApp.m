//
//  Voltweaks (part of Volta) - a tweak manager.
//
//  Lists every tweak the jailbreak loads, says which package it came from and
//  which apps it loads into, and switches tweaks on and off. "Off" renames
//  <Name>.dylib to <Name>.disabled (the convention iCleaner uses), which the
//  loader skips; a respring makes it take effect.
//
//  The tweak folder belongs to root, so the rename is done by a small helper
//  tool, voltweaks-helper (see ../voltweakshelper/main.c).
//

#import <UIKit/UIKit.h>
#import <spawn.h>
#import <dlfcn.h>
#import <notify.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <errno.h>

extern char **environ;

#define HEX(v) [UIColor colorWithRed:(((v) >> 16) & 0xFF) / 255.0 green:(((v) >> 8) & 0xFF) / 255.0 blue:((v) & 0xFF) / 255.0 alpha:1]
#define VT_ACCENT HEX(0x5B5BF0)
#define VT_TEAL   HEX(0x19C8B9)

static NSString *const kHelperPath = @"/var/jb/usr/libexec/voltweaks-helper";
static NSString *const kRespringNotification = @"com.notpreston.volta/respring";

#pragma mark - Model

@interface VTTweak : NSObject
@property (nonatomic, copy) NSString *name;          // file name without extension
@property (nonatomic, copy) NSString *folder;
@property (nonatomic) BOOL enabled;
@property (nonatomic) BOOL wasEnabledAtLaunch;       // what SpringBoard is running with, as far as we know
@property (nonatomic) unsigned long long bytes;
@property (nonatomic, copy) NSArray<NSString *> *targets;   // bundle ids / executables it loads into
@property (nonatomic, copy) NSString *packageID, *packageName, *version, *author, *summary;
@end

@implementation VTTweak

- (NSString *)title { return self.packageName.length ? self.packageName : self.name; }

- (BOOL)isVolta { return [self.name isEqualToString:@"Volta"] || [self.name isEqualToString:@"VoltaHome"]; }

// "SpringBoard", "All apps", "Safari + 2 more"
- (NSString *)targetSummary {
    if (self.targets.count == 0) return @"No filter";
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *target in self.targets) {
        if ([target isEqualToString:@"com.apple.springboard"]) [names addObject:@"SpringBoard"];
        else if ([target isEqualToString:@"com.apple.UIKit"]) [names addObject:@"All apps"];
        else if ([target isEqualToString:@"com.apple.Preferences"]) [names addObject:@"Settings"];
        else [names addObject:target.pathExtension.length ? target.pathExtension : target];
    }
    if (names.count <= 2) return [names componentsJoinedByString:@", "];
    return [NSString stringWithFormat:@"%@, %@ + %lu more", names[0], names[1], (unsigned long)names.count - 2];
}

@end

#pragma mark - Reading the device

static NSArray<NSString *> *VTTweakFolders(void) {
    NSMutableArray *folders = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *folder in @[@"/var/jb/Library/MobileSubstrate/DynamicLibraries", @"/var/jb/usr/lib/TweakInject"]) {
        NSString *real = [folder stringByResolvingSymlinksInPath];   // usually one folder under two names
        BOOL isDirectory = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:real isDirectory:&isDirectory] || !isDirectory) continue;
        if ([seen containsObject:real]) continue;
        [seen addObject:real];
        [folders addObject:folder];
    }
    return folders;
}

// Same rule as the helper: a plain file name.
static BOOL VTNameOK(NSString *name) {
    if (name.length == 0 || name.length > 120 || [name hasPrefix:@"."] || [name hasPrefix:@"-"]) return NO;
    static NSCharacterSet *bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+ "] invertedSet];
    });
    return [name rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static NSArray<NSString *> *VTStrings(id value) {
    NSMutableArray *out = [NSMutableArray array];
    if ([value isKindOfClass:[NSArray class]]) {
        for (id item in value) if ([item isKindOfClass:[NSString class]] && [item length] && [item length] < 200) [out addObject:item];
    }
    return out;
}

// What a tweak's filter file says it loads into.
static NSArray<NSString *> *VTTargets(NSString *plistPath) {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSDictionary *filter = [plist isKindOfClass:[NSDictionary class]] ? plist[@"Filter"] : nil;
    if (![filter isKindOfClass:[NSDictionary class]]) return @[];
    NSMutableArray *targets = [NSMutableArray array];
    [targets addObjectsFromArray:VTStrings(filter[@"Bundles"])];
    [targets addObjectsFromArray:VTStrings(filter[@"Executables"])];
    if (targets.count > 60) [targets removeObjectsInRange:NSMakeRange(60, targets.count - 60)];
    return targets;
}

// Which package installed each tweak: look the file up in dpkg's file lists,
// then read that package's entry in dpkg's status file.
static void VTAttachPackages(NSArray<VTTweak *> *tweaks) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *dpkg = nil;
    for (NSString *candidate in @[@"/var/jb/var/lib/dpkg", @"/var/jb/Library/dpkg"]) {
        if ([files fileExistsAtPath:[candidate stringByAppendingPathComponent:@"status"]]) { dpkg = candidate; break; }
    }
    if (!dpkg || tweaks.count == 0) return;

    NSString *info = [dpkg stringByAppendingPathComponent:@"info"];
    NSMutableArray<VTTweak *> *unmatched = [tweaks mutableCopy];
    NSInteger looked = 0;
    for (NSString *file in [files contentsOfDirectoryAtPath:info error:NULL]) {
        if (unmatched.count == 0 || ++looked > 6000) break;
        if (![file.pathExtension isEqualToString:@"list"]) continue;
        @autoreleasepool {
            NSString *path = [info stringByAppendingPathComponent:file];
            if ([[files attributesOfItemAtPath:path error:NULL] fileSize] > 4 * 1024 * 1024) continue;
            NSString *list = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
            if (!list || ([list rangeOfString:@"DynamicLibraries/"].location == NSNotFound && [list rangeOfString:@"TweakInject/"].location == NSNotFound)) continue;
            list = [list stringByAppendingString:@"\n"];
            NSString *package = [file stringByDeletingPathExtension];
            NSRange arch = [package rangeOfString:@":"];   // "name:arch.list"
            if (arch.location != NSNotFound) package = [package substringToIndex:arch.location];
            for (VTTweak *tweak in [unmatched copy]) {
                NSString *a = [NSString stringWithFormat:@"DynamicLibraries/%@.dylib\n", tweak.name];
                NSString *b = [NSString stringWithFormat:@"TweakInject/%@.dylib\n", tweak.name];
                if ([list rangeOfString:a].location != NSNotFound || [list rangeOfString:b].location != NSNotFound) {
                    tweak.packageID = package;
                    [unmatched removeObject:tweak];
                }
            }
        }
    }

    NSMutableDictionary<NSString *, NSMutableArray<VTTweak *> *> *byPackage = [NSMutableDictionary dictionary];
    for (VTTweak *tweak in tweaks) {
        if (!tweak.packageID) continue;
        if (!byPackage[tweak.packageID]) byPackage[tweak.packageID] = [NSMutableArray array];
        [byPackage[tweak.packageID] addObject:tweak];
    }
    if (byPackage.count == 0) return;
    NSString *statusPath = [dpkg stringByAppendingPathComponent:@"status"];
    if ([[files attributesOfItemAtPath:statusPath error:NULL] fileSize] > 32 * 1024 * 1024) return;
    NSString *status = [NSString stringWithContentsOfFile:statusPath encoding:NSUTF8StringEncoding error:NULL]
                    ?: [NSString stringWithContentsOfFile:statusPath encoding:NSISOLatin1StringEncoding error:NULL];
    for (NSString *block in [status componentsSeparatedByString:@"\n\n"]) {
        NSMutableDictionary<NSString *, NSString *> *fields = [NSMutableDictionary dictionary];
        for (NSString *line in [block componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@" "] || [line hasPrefix:@"\t"]) continue;   // continuation of a long description
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location == NSNotFound || colon.location == 0) continue;
            NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            fields[[line substringToIndex:colon.location]] = value.length > 300 ? [value substringToIndex:300] : value;
        }
        NSArray<VTTweak *> *owned = fields[@"Package"] ? byPackage[fields[@"Package"]] : nil;
        if (!owned) continue;
        NSString *author = fields[@"Author"] ?: fields[@"Maintainer"];
        NSRange email = [author rangeOfString:@"<"];   // "Name <mail>" -> "Name"
        if (email.location != NSNotFound && email.location > 0) author = [[author substringToIndex:email.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        for (VTTweak *tweak in owned) {
            tweak.packageName = fields[@"Name"];
            tweak.version = fields[@"Version"];
            tweak.author = author;
            tweak.summary = fields[@"Description"];
        }
    }
}

static NSArray<VTTweak *> *VTScan(void) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSMutableDictionary<NSString *, VTTweak *> *found = [NSMutableDictionary dictionary];
    for (NSString *folder in VTTweakFolders()) {
        for (NSString *file in [files contentsOfDirectoryAtPath:folder error:NULL]) {
            NSString *extension = file.pathExtension;
            BOOL on = [extension isEqualToString:@"dylib"], off = [extension isEqualToString:@"disabled"];
            if (!on && !off) continue;
            NSString *name = [file stringByDeletingPathExtension];
            if (!VTNameOK(name)) continue;
            VTTweak *existing = found[name];
            if (existing && (existing.enabled || !on)) continue;   // a loadable copy wins over a switched-off one
            VTTweak *tweak = [[VTTweak alloc] init];
            tweak.name = name;
            tweak.folder = folder;
            tweak.enabled = on;
            tweak.wasEnabledAtLaunch = on;
            NSString *path = [folder stringByAppendingPathComponent:file];
            tweak.bytes = [[files attributesOfItemAtPath:[path stringByResolvingSymlinksInPath] error:NULL] fileSize];
            tweak.targets = VTTargets([[folder stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"plist"]);
            found[name] = tweak;
            if (found.count >= 1000) break;
        }
    }
    NSArray *tweaks = found.allValues;
    VTAttachPackages(tweaks);
    return [tweaks sortedArrayUsingComparator:^NSComparisonResult(VTTweak *a, VTTweak *b) { return [[a title] localizedCaseInsensitiveCompare:[b title]]; }];
}

#pragma mark - Switching a tweak

// Runs the helper and returns its exit code, or -1 if it could not be started.
// asRoot asks the system to start it as root directly (needs an entitlement
// the jailbreak honours); otherwise the helper's set-uid bit has to do it.
static int VTRunHelper(NSArray<NSString *> *arguments, BOOL asRoot) {
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:kHelperPath]) return -1;
    posix_spawnattr_t attributes;
    if (posix_spawnattr_init(&attributes) != 0) return -1;
    if (asRoot) {
        // Private calls, looked up by name so a missing one is a clean "no".
        int (*setPersona)(const posix_spawnattr_t *, uid_t, uint32_t) = dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
        int (*setUID)(const posix_spawnattr_t *, uid_t) = dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
        int (*setGID)(const posix_spawnattr_t *, gid_t) = dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
        if (!setPersona || !setUID || !setGID ||
            setPersona(&attributes, 99, 1 /* override */) != 0 || setUID(&attributes, 0) != 0 || setGID(&attributes, 0) != 0) {
            posix_spawnattr_destroy(&attributes);
            return -1;
        }
    }
    NSUInteger count = arguments.count;
    const char **argv = calloc(count + 2, sizeof(char *));
    if (!argv) { posix_spawnattr_destroy(&attributes); return -1; }
    argv[0] = kHelperPath.fileSystemRepresentation;
    for (NSUInteger i = 0; i < count; i++) argv[i + 1] = arguments[i].UTF8String;
    pid_t pid = 0;
    int spawned = posix_spawn(&pid, argv[0], NULL, &attributes, (char *const *)argv, environ);
    free(argv);
    posix_spawnattr_destroy(&attributes);
    if (spawned != 0) return -1;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

// nil on success, otherwise a sentence for the user.
static NSString *VTSetEnabled(VTTweak *tweak, BOOL enabled) {
    if (!VTNameOK(tweak.name)) return @"That tweak has an unusual file name.";
    NSString *base = [tweak.folder stringByAppendingPathComponent:tweak.name];
    NSString *from = [base stringByAppendingPathExtension:enabled ? @"disabled" : @"dylib"];
    NSString *to = [base stringByAppendingPathExtension:enabled ? @"dylib" : @"disabled"];
    NSFileManager *files = [NSFileManager defaultManager];

    // 1. Directly, in case this folder happens to be writable.
    if (![files fileExistsAtPath:to] && [files moveItemAtPath:from toPath:to error:NULL]) return nil;

    // 2. The helper, started as root; 3. the helper relying on its set-uid bit.
    NSArray *arguments = @[enabled ? @"enable" : @"disable", tweak.name];
    int code = VTRunHelper(arguments, YES);
    if (code != 0) code = VTRunHelper(arguments, NO);
    switch (code) {
        case 0:  return nil;
        case 3:  return @"Voltweaks was not given root access on this jailbreak, so it cannot change tweaks here. Reinstalling Volta sometimes fixes this.";
        case 4:  return @"That tweak's file is gone. Pull down to refresh the list.";
        case 5:  return @"The file could not be renamed. A tweak with the same name may already be there.";
        case -1: return @"Voltweaks's helper tool is missing or could not be started. Reinstalling Volta puts it back.";
        default: return @"The change could not be made.";
    }
}

static void VTRespring(void) {
    notify_post(kRespringNotification.UTF8String);   // handled by Volta, if it is loaded
    // And the jailbreak's own tool, in case Volta itself is switched off.
    const char *tool = "/var/jb/usr/bin/sbreload";
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:@(tool)]) {
        char *const arguments[] = {(char *)tool, NULL};
        pid_t pid = 0;
        posix_spawn(&pid, tool, NULL, NULL, arguments, environ);
    }
}

#pragma mark - Views

// A rounded tile with the tweak's initial; its color comes from the name so it
// is the same every time.
static UIImage *VTTile(NSString *title, CGFloat side, BOOL dimmed) {
    NSArray *palette = @[@[HEX(0x5B5BF0), HEX(0x8E6BF5)], @[HEX(0x19C8B9), HEX(0x0E8F8A)], @[HEX(0xFF9F0A), HEX(0xFF5E3A)],
                         @[HEX(0xFF6482), HEX(0xD9304F)], @[HEX(0x4FC3FF), HEX(0x0A6CFF)], @[HEX(0x5FE36B), HEX(0x1FB141)],
                         @[HEX(0xBF5AF2), HEX(0x7D3BD6)]];
    NSUInteger hash = 5381;
    for (NSUInteger i = 0; i < title.length; i++) hash = hash * 33 + [title characterAtIndex:i];
    NSArray *colors = dimmed ? @[HEX(0x8E8E93), HEX(0x636366)] : palette[hash % palette.count];
    NSString *letter = title.length ? [[title substringWithRange:[title rangeOfComposedCharacterSequenceAtIndex:0]] uppercaseString] : @"?";
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side) cornerRadius:side * 0.24] addClip];
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)@[(id)[colors[0] CGColor], (id)[colors[1] CGColor]], NULL);
        CGContextDrawLinearGradient(context.CGContext, gradient, CGPointZero, CGPointMake(side, side), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
        NSDictionary *attributes = @{NSFontAttributeName: [UIFont systemFontOfSize:side * 0.5 weight:UIFontWeightBold],
                                     NSForegroundColorAttributeName: [UIColor whiteColor]};
        CGSize size = [letter sizeWithAttributes:attributes];
        [letter drawAtPoint:CGPointMake((side - size.width) / 2, (side - size.height) / 2) withAttributes:attributes];
    }];
}

// The card at the top of the list: counts and the Respring button.
@interface VTSummaryView : UIView
@property (nonatomic, strong) UIButton *respringButton;
- (void)setTotal:(NSInteger)total off:(NSInteger)off pending:(NSInteger)pending;
@end

@implementation VTSummaryView {
    CAGradientLayer *_gradient;
    UILabel *_count, *_detail;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _gradient = [CAGradientLayer layer];
        _gradient.colors = @[(id)VT_ACCENT.CGColor, (id)VT_TEAL.CGColor];
        _gradient.startPoint = CGPointMake(0, 0);
        _gradient.endPoint = CGPointMake(1, 1);
        _gradient.cornerRadius = 22;
        _gradient.cornerCurve = kCACornerCurveContinuous;
        [self.layer addSublayer:_gradient];

        _count = [[UILabel alloc] init];
        _count.textColor = [UIColor whiteColor];
        _count.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
        _count.adjustsFontSizeToFitWidth = YES;
        _count.minimumScaleFactor = 0.6;
        [self addSubview:_count];

        _detail = [[UILabel alloc] init];
        _detail.textColor = [UIColor colorWithWhite:1 alpha:0.85];
        _detail.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        _detail.numberOfLines = 2;
        [self addSubview:_detail];

        _respringButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _respringButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _respringButton.layer.cornerRadius = 17;
        [self addSubview:_respringButton];
        [self setTotal:0 off:0 pending:0];
    }
    return self;
}

- (void)setTotal:(NSInteger)total off:(NSInteger)off pending:(NSInteger)pending {
    _count.text = [NSString stringWithFormat:@"%ld tweak%@", (long)total, total == 1 ? @"" : @"s"];
    if (pending > 0) {
        _detail.text = [NSString stringWithFormat:@"%ld change%@ waiting for a respring", (long)pending, pending == 1 ? @"" : @"s"];
    } else {
        _detail.text = off ? [NSString stringWithFormat:@"%ld on · %ld off", (long)(total - off), (long)off] : @"All switched on";
    }
    // The button stands out once there is something to apply.
    [_respringButton setTitle:pending > 0 ? @"Respring to Apply" : @"Respring" forState:UIControlStateNormal];
    _respringButton.backgroundColor = pending > 0 ? [UIColor whiteColor] : [UIColor colorWithWhite:1 alpha:0.22];
    [_respringButton setTitleColor:pending > 0 ? VT_ACCENT : [UIColor whiteColor] forState:UIControlStateNormal];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat inset = MAX(16, self.layoutMargins.left);
    CGRect card = CGRectMake(inset, 8, self.bounds.size.width - inset * 2, self.bounds.size.height - 16);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _gradient.frame = card;
    [CATransaction commit];
    CGSize button = [_respringButton sizeThatFits:CGSizeMake(CGFLOAT_MAX, 34)];
    button.width = MIN(button.width + 32, card.size.width / 2);   // room either side of the title
    _respringButton.frame = CGRectMake(CGRectGetMaxX(card) - button.width - 16, CGRectGetMidY(card) - 17, button.width, 34);
    CGFloat textWidth = CGRectGetMinX(_respringButton.frame) - card.origin.x - 28;
    _count.frame = CGRectMake(card.origin.x + 18, card.origin.y + 16, textWidth, 36);
    _detail.frame = CGRectMake(card.origin.x + 18, card.origin.y + 54, textWidth, 40);
    [_detail sizeToFit];
    _detail.frame = CGRectMake(card.origin.x + 18, card.origin.y + 54, textWidth, MIN(_detail.frame.size.height, 40));
}

@end

#pragma mark - Detail

@interface VTDetailController : UITableViewController
@property (nonatomic, strong) VTTweak *tweak;
@property (nonatomic, copy) void (^onToggle)(VTTweak *tweak, BOOL enabled, UISwitch *toggle);
@end

@implementation VTDetailController {
    NSArray<NSArray<NSString *> *> *_facts;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self.tweak title];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.tintColor = VT_ACCENT;
    VTTweak *tweak = self.tweak;
    NSMutableArray *facts = [NSMutableArray array];
    if (tweak.packageID) [facts addObject:@[@"Package", tweak.packageID]];
    if (tweak.version.length) [facts addObject:@[@"Version", tweak.version]];
    if (tweak.author.length) [facts addObject:@[@"Author", tweak.author]];
    [facts addObject:@[@"File", [tweak.name stringByAppendingString:@".dylib"]]];
    [facts addObject:@[@"Size", [NSByteCountFormatter stringFromByteCount:(long long)tweak.bytes countStyle:NSByteCountFormatterCountStyleFile]]];
    _facts = facts;
}

- (BOOL)canOpenPackage {
    return self.tweak.packageID.length && [[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"sileo://"]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return [self canOpenPackage] ? 4 : 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0:  return 1;
        case 1:  return _facts.count;
        case 2:  return MAX((NSInteger)self.tweak.targets.count, 1);
        default: return 1;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 1 ? @"About" : (section == 2 ? @"Loads Into" : nil);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        NSString *what = self.tweak.summary.length ? [self.tweak.summary stringByAppendingString:@"\n\n"] : @"";
        NSString *volta = [self.tweak isVolta] ? @" This is part of Volta itself; Voltweaks keeps working without it." : @"";
        return [NSString stringWithFormat:@"%@Switching a tweak off stops it loading after the next respring. Nothing is deleted.%@", what, volta];
    }
    if (section == 1) return @"Switch a tweak back on before uninstalling its package, so no switched-off copy is left behind.";
    if (section == 2 && self.tweak.targets.count == 0) return @"This tweak has no filter file, so the loader does not load it into anything.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (indexPath.section == 0) {
        cell.textLabel.text = @"Enabled";
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.onTintColor = VT_ACCENT;
        toggle.on = self.tweak.enabled;
        [toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else if (indexPath.section == 1) {
        cell.textLabel.text = _facts[indexPath.row][0];
        cell.detailTextLabel.text = _facts[indexPath.row][1];
        cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
        cell.detailTextLabel.minimumScaleFactor = 0.6;
    } else if (indexPath.section == 2) {
        NSString *target = self.tweak.targets.count ? self.tweak.targets[indexPath.row] : @"Nothing";
        NSDictionary *friendly = @{@"com.apple.springboard": @"SpringBoard (Home Screen)", @"com.apple.UIKit": @"Every app", @"com.apple.Preferences": @"Settings"};
        cell.textLabel.text = friendly[target] ?: target;
        cell.textLabel.adjustsFontSizeToFitWidth = YES;
        cell.textLabel.minimumScaleFactor = 0.6;
    } else {
        cell.textLabel.text = @"Show in Sileo";
        cell.textLabel.textColor = VT_ACCENT;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 3 || !self.tweak.packageID.length) return;
    NSString *escaped = [self.tweak.packageID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[@"sileo://package/" stringByAppendingString:escaped ?: @""]];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)toggled:(UISwitch *)toggle {
    if (self.onToggle) self.onToggle(self.tweak, toggle.on, toggle);
}

@end

#pragma mark - List

@interface VTListController : UITableViewController <UISearchResultsUpdating>
@end

@implementation VTListController {
    NSArray<VTTweak *> *_all, *_on, *_off;
    NSString *_query;
    VTSummaryView *_summary;
    BOOL _loaded, _busy;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Voltweaks";
    self.view.tintColor = VT_ACCENT;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.rowHeight = 62;

    _summary = [[VTSummaryView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 124)];
    [_summary.respringButton addTarget:self action:@selector(respring) forControlEvents:UIControlEventTouchUpInside];
    self.tableView.tableHeaderView = _summary;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Search tweaks";
    self.navigationItem.searchController = search;

    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];

    __weak typeof(self) weakSelf = self;
    UIAction *allOff = [UIAction actionWithTitle:@"Turn All Off (Keep Volta)" image:[UIImage systemImageNamed:@"moon.zzz.fill"] identifier:nil
                                         handler:^(UIAction *action) { [weakSelf confirmAll:NO]; }];
    UIAction *allOn = [UIAction actionWithTitle:@"Turn All On" image:[UIImage systemImageNamed:@"bolt.fill"] identifier:nil
                                        handler:^(UIAction *action) { [weakSelf confirmAll:YES]; }];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                                                                               menu:[UIMenu menuWithTitle:@"" children:@[allOff, allOn]]];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_loaded) [self rebuild];   // coming back from a detail page
}

// Reads the device off the main thread; the list is rebuilt when it is done.
- (void)reload {
    if (_busy) return;
    _busy = YES;
    NSDictionary<NSString *, NSNumber *> *launchStates = [self launchStates];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<VTTweak *> *tweaks = VTScan();
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            // Keep what each tweak's state was when the app opened, so "changes waiting" stays right.
            for (VTTweak *tweak in tweaks) {
                NSNumber *before = launchStates[tweak.name];
                if (before) tweak.wasEnabledAtLaunch = before.boolValue;
            }
            strongSelf->_all = tweaks;
            strongSelf->_loaded = YES;
            strongSelf->_busy = NO;
            [strongSelf.refreshControl endRefreshing];
            [strongSelf rebuild];
        });
    });
}

- (NSDictionary<NSString *, NSNumber *> *)launchStates {
    NSMutableDictionary *states = [NSMutableDictionary dictionary];
    for (VTTweak *tweak in _all) states[tweak.name] = @(tweak.wasEnabledAtLaunch);
    return states;
}

- (void)rebuild {
    NSMutableArray *on = [NSMutableArray array], *off = [NSMutableArray array];
    NSInteger offCount = 0, pending = 0;
    for (VTTweak *tweak in _all) {
        if (!tweak.enabled) offCount++;
        if (tweak.enabled != tweak.wasEnabledAtLaunch) pending++;
        if (_query.length && ![[tweak title] localizedCaseInsensitiveContainsString:_query] && ![tweak.name localizedCaseInsensitiveContainsString:_query] &&
            !(tweak.packageID && [tweak.packageID localizedCaseInsensitiveContainsString:_query])) continue;
        [tweak.enabled ? on : off addObject:tweak];
    }
    _on = on;
    _off = off;
    [_summary setTotal:_all.count off:offCount pending:pending];
    [self.tableView reloadData];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.tableView.bounds.size.width;
    if (fabs(_summary.frame.size.width - width) > 0.5) {
        _summary.frame = CGRectMake(0, 0, width, 124);
        self.tableView.tableHeaderView = _summary;
    }
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    _query = [searchController.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (_loaded) [self rebuild];
}

#pragma mark Table

- (NSArray<VTTweak *> *)tweaksInSection:(NSInteger)section { return section == 0 ? _on : _off; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [self tweaksInSection:section].count; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if ([self tweaksInSection:section].count == 0) return nil;
    return section == 0 ? @"On" : @"Off";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 1) return nil;
    if (!_loaded) return @"Looking for tweaks…";
    if (_all.count == 0) return @"No tweaks were found. Voltweaks looks in the jailbreak's tweak folder (/var/jb/usr/lib/TweakInject).";
    if (_on.count + _off.count == 0) return @"No tweaks match your search.";
    return @"Switch a tweak off and respring to stop it loading. Nothing is deleted, and switching it back on brings it back.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"tweak"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"tweak"];
    VTTweak *tweak = [self tweaksInSection:indexPath.section][indexPath.row];
    cell.textLabel.text = [tweak title];
    cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    NSString *changed = tweak.enabled != tweak.wasEnabledAtLaunch ? @"Respring to apply · " : @"";
    cell.detailTextLabel.text = [changed stringByAppendingString:[tweak targetSummary]];
    cell.detailTextLabel.textColor = changed.length ? VT_ACCENT : [UIColor secondaryLabelColor];
    cell.imageView.image = VTTile([tweak title], 40, !tweak.enabled);
    UISwitch *toggle = [cell.accessoryView isKindOfClass:[UISwitch class]] ? (UISwitch *)cell.accessoryView : nil;
    if (!toggle) {
        toggle = [[UISwitch alloc] init];
        toggle.onTintColor = VT_ACCENT;
        [toggle addTarget:self action:@selector(rowToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }
    toggle.on = tweak.enabled;
    toggle.accessibilityLabel = [tweak title];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    VTDetailController *detail = [[VTDetailController alloc] init];
    detail.tweak = [self tweaksInSection:indexPath.section][indexPath.row];
    __weak typeof(self) weakSelf = self;
    detail.onToggle = ^(VTTweak *tweak, BOOL enabled, UISwitch *toggle) { [weakSelf setTweak:tweak enabled:enabled toggle:toggle]; };
    [self.navigationController pushViewController:detail animated:YES];
}

#pragma mark Actions

- (void)rowToggled:(UISwitch *)toggle {
    // Find the row from the switch's place in the table, so reused cells can never point at the wrong tweak.
    CGPoint point = [toggle convertPoint:CGPointMake(CGRectGetMidX(toggle.bounds), CGRectGetMidY(toggle.bounds)) toView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
    NSArray<VTTweak *> *tweaks = indexPath ? [self tweaksInSection:indexPath.section] : nil;
    if (!indexPath || indexPath.row >= (NSInteger)tweaks.count) {
        [self rebuild];
        return;
    }
    [self setTweak:tweaks[indexPath.row] enabled:toggle.on toggle:toggle];
}

- (void)setTweak:(VTTweak *)tweak enabled:(BOOL)enabled toggle:(UISwitch *)toggle {
    if (tweak.enabled == enabled) return;
    NSString *problem = VTSetEnabled(tweak, enabled);
    if (problem) {
        [toggle setOn:tweak.enabled animated:YES];
        [self say:@"Couldn't Change Tweak" message:problem];
        return;
    }
    tweak.enabled = enabled;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    // Let the switch finish sliding before its row moves to the other section.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf rebuild]; });
}

- (void)say:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [(self.presentedViewController ?: self.navigationController.topViewController ?: self) presentViewController:alert animated:YES completion:nil];
}

- (void)confirmAll:(BOOL)enable {
    NSString *title = enable ? @"Turn All Tweaks On?" : @"Turn All Tweaks Off?";
    NSString *message = enable ? @"Every tweak that is switched off will load again after a respring."
                               : @"Every tweak except Volta stops loading after a respring. Handy for finding which tweak is causing a problem.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:enable ? @"Turn On" : @"Turn Off" style:enable ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) { [weakSelf setAll:enable]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)setAll:(BOOL)enable {
    NSInteger failed = 0;
    NSString *firstProblem = nil;
    for (VTTweak *tweak in _all) {
        if (tweak.enabled == enable || (!enable && [tweak isVolta])) continue;
        NSString *problem = VTSetEnabled(tweak, enable);
        if (problem) {
            failed++;
            if (!firstProblem) firstProblem = problem;
            if ([problem containsString:@"root access"] || [problem containsString:@"helper tool"]) break;   // the rest would fail the same way
        } else {
            tweak.enabled = enable;
        }
    }
    [self rebuild];
    if (failed) [self say:@"Some Tweaks Were Not Changed" message:firstProblem];
}

- (void)respring {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring Now?" message:@"The Home Screen restarts and your tweak changes take effect."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { VTRespring(); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - App

@interface VTAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation VTAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.tintColor = VT_ACCENT;
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[[VTListController alloc] init]];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([VTAppDelegate class]));
    }
}
