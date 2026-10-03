//
//  Saved (part of Volta) - a watch-later list for YouTube videos that needs no
//  account. It keeps links, not the videos themselves: tapping one opens it
//  in the YouTube app (or the browser).
//
//  Videos arrive three ways: the "Save to Volta" button Volta adds to share
//  sheets (it opens voltasaved://add?v=<id>), pasting a link, or typing one.
//

#import <UIKit/UIKit.h>
#import "SavedCore.h"

#define HEX(v) [UIColor colorWithRed:(((v) >> 16) & 0xFF) / 255.0 green:(((v) >> 8) & 0xFF) / 255.0 blue:((v) & 0xFF) / 255.0 alpha:1]
#define VS_ACCENT HEX(0x5B5BF0)

static NSString *const kStoreKey = @"videos";
static const NSUInteger kMaxVideos = 500;

// The id inside a link or any text containing one; nil if there is none.
static NSString *VSVideoID(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return nil;
    char out[VLT_VIDEO_ID_MAX + 1];
    return vlt_video_id(text.UTF8String, out) ? @(out) : nil;
}

// A bare id, as passed by the share button.
static BOOL VSIsID(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length < 6 || text.length > VLT_VIDEO_ID_MAX) return NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c > 127 || !vlt_id_char((char)c)) return NO;
    }
    return YES;
}

static NSString *VSWatchLink(NSString *videoID) {
    return [@"https://www.youtube.com/watch?v=" stringByAppendingString:videoID];
}

#pragma mark - Store

// Each video is a dictionary of plain values: id, title, author, thumb (JPEG
// data), added (date), watched (bool). Everything read back is checked.
@interface VSStore : NSObject
@property (nonatomic, readonly) NSArray<NSDictionary *> *videos;   // newest first
+ (instancetype)shared;
- (BOOL)contains:(NSString *)videoID;
- (BOOL)add:(NSString *)videoID;
- (void)remove:(NSString *)videoID;
- (void)update:(NSString *)videoID with:(NSDictionary *)changes;
@end

@implementation VSStore {
    NSMutableArray<NSDictionary *> *_videos;
}

+ (instancetype)shared {
    static VSStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [[VSStore alloc] init]; });
    return store;
}

- (instancetype)init {
    if ((self = [super init])) {
        _videos = [NSMutableArray array];
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kStoreKey];
        for (id item in saved) {
            if (![item isKindOfClass:[NSDictionary class]] || !VSIsID(item[@"id"]) || [self contains:item[@"id"]]) continue;
            NSMutableDictionary *video = [NSMutableDictionary dictionaryWithObject:item[@"id"] forKey:@"id"];
            if ([item[@"title"] isKindOfClass:[NSString class]] && [item[@"title"] length] <= 300) video[@"title"] = item[@"title"];
            if ([item[@"author"] isKindOfClass:[NSString class]] && [item[@"author"] length] <= 200) video[@"author"] = item[@"author"];
            if ([item[@"thumb"] isKindOfClass:[NSData class]] && [item[@"thumb"] length] <= 200 * 1024) video[@"thumb"] = item[@"thumb"];
            video[@"added"] = [item[@"added"] isKindOfClass:[NSDate class]] ? item[@"added"] : [NSDate date];
            video[@"watched"] = @([item[@"watched"] isKindOfClass:[NSNumber class]] && [item[@"watched"] boolValue]);
            [_videos addObject:video];
            if (_videos.count >= kMaxVideos) break;
        }
    }
    return self;
}

- (NSArray<NSDictionary *> *)videos { return [_videos copy]; }

- (void)save {
    [[NSUserDefaults standardUserDefaults] setObject:_videos forKey:kStoreKey];
}

- (NSUInteger)indexOf:(NSString *)videoID {
    return [_videos indexOfObjectPassingTest:^BOOL(NSDictionary *video, NSUInteger index, BOOL *stop) { return [video[@"id"] isEqualToString:videoID]; }];
}

- (BOOL)contains:(NSString *)videoID { return [self indexOf:videoID] != NSNotFound; }

- (BOOL)add:(NSString *)videoID {
    if (!VSIsID(videoID) || [self contains:videoID] || _videos.count >= kMaxVideos) return NO;
    [_videos insertObject:@{@"id": videoID, @"added": [NSDate date], @"watched": @NO} atIndex:0];
    [self save];
    return YES;
}

- (void)remove:(NSString *)videoID {
    NSUInteger index = [self indexOf:videoID];
    if (index == NSNotFound) return;
    [_videos removeObjectAtIndex:index];
    [self save];
}

- (void)update:(NSString *)videoID with:(NSDictionary *)changes {
    NSUInteger index = [self indexOf:videoID];
    if (index == NSNotFound) return;
    NSMutableDictionary *video = [_videos[index] mutableCopy];
    [video addEntriesFromDictionary:changes];
    _videos[index] = video;
    [self save];
}

@end

#pragma mark - Looking a video up

// Title and channel come from YouTube's public "oEmbed" address, the picture
// from its thumbnail server. Both are fetched by id only; nothing is sent
// about the person using the app.
static NSURLSession *VSSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 15;
        configuration.timeoutIntervalForResource = 30;
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

static void VSFetchDetails(NSString *videoID, void (^done)(void)) {
    if (!VSIsID(videoID)) return;
    NSString *link = [VSWatchLink(videoID) stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet alphanumericCharacterSet]];
    NSURL *info = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.youtube.com/oembed?format=json&url=%@", link]];
    NSURL *picture = [NSURL URLWithString:[NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/mqdefault.jpg", videoID]];
    if (info) {
        [[VSSession() dataTaskWithURL:info completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!data || data.length > 64 * 1024) return;
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if (![json isKindOfClass:[NSDictionary class]]) return;
            NSMutableDictionary *changes = [NSMutableDictionary dictionary];
            NSString *title = json[@"title"], *author = json[@"author_name"];
            if ([title isKindOfClass:[NSString class]] && title.length) changes[@"title"] = title.length > 300 ? [title substringToIndex:300] : title;
            if ([author isKindOfClass:[NSString class]] && author.length) changes[@"author"] = author.length > 200 ? [author substringToIndex:200] : author;
            if (changes.count == 0) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [[VSStore shared] update:videoID with:changes];
                if (done) done();
            });
        }] resume];
    }
    if (picture) {
        [[VSSession() dataTaskWithURL:picture completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!data || data.length > 2 * 1024 * 1024) return;
            UIImage *image = [UIImage imageWithData:data];
            if (!image || image.size.width < 8 || image.size.height < 8 || image.size.width > 4096 || image.size.height > 4096) return;
            // Keep a small copy: 240 x 135 is plenty for a list row.
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
            format.scale = 1;
            format.opaque = YES;
            NSData *small = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(240, 135) format:format] JPEGDataWithCompressionQuality:0.8 actions:^(UIGraphicsImageRendererContext *context) {
                [image drawInRect:CGRectMake(0, 0, 240, 135)];
            }];
            if (!small) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [[VSStore shared] update:videoID with:@{@"thumb": small}];
                if (done) done();
            });
        }] resume];
    }
}

#pragma mark - Row

@interface VSCell : UITableViewCell
- (void)show:(NSDictionary *)video;
@end

@implementation VSCell {
    UIImageView *_thumb;
    UILabel *_title, *_detail;
    UIImageView *_play;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        _thumb = [[UIImageView alloc] init];
        _thumb.contentMode = UIViewContentModeScaleAspectFill;
        _thumb.clipsToBounds = YES;
        _thumb.layer.cornerRadius = 8;
        _thumb.layer.cornerCurve = kCACornerCurveContinuous;
        _thumb.backgroundColor = [UIColor tertiarySystemFillColor];
        [self.contentView addSubview:_thumb];
        _play = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"play.rectangle.fill"]];
        _play.tintColor = [UIColor tertiaryLabelColor];
        _play.contentMode = UIViewContentModeCenter;
        [_thumb addSubview:_play];
        _title = [[UILabel alloc] init];
        _title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        _title.numberOfLines = 2;
        [self.contentView addSubview:_title];
        _detail = [[UILabel alloc] init];
        _detail.font = [UIFont systemFontOfSize:13];
        _detail.textColor = [UIColor secondaryLabelColor];
        [self.contentView addSubview:_detail];
    }
    return self;
}

- (void)show:(NSDictionary *)video {
    BOOL watched = [video[@"watched"] boolValue];
    NSData *thumb = video[@"thumb"];
    _thumb.image = thumb ? [UIImage imageWithData:thumb] : nil;
    _play.hidden = _thumb.image != nil;
    _thumb.alpha = watched ? 0.45 : 1;
    _title.text = video[@"title"] ?: @"YouTube video";
    _title.textColor = watched ? [UIColor secondaryLabelColor] : [UIColor labelColor];
    NSString *author = video[@"author"] ?: [@"youtu.be/" stringByAppendingString:video[@"id"]];
    _detail.text = watched ? [@"Watched · " stringByAppendingString:author] : author;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", _title.text, _detail.text];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat inset = self.contentView.layoutMargins.left, width = self.contentView.bounds.size.width;
    _thumb.frame = CGRectMake(inset, 10, 124, 70);
    _play.frame = _thumb.bounds;
    CGFloat x = CGRectGetMaxX(_thumb.frame) + 12, textWidth = MAX(width - x - inset, 40);
    CGSize fit = [_title sizeThatFits:CGSizeMake(textWidth, 44)];
    _title.frame = CGRectMake(x, 12, textWidth, MIN(ceil(fit.height), 44));
    _detail.frame = CGRectMake(x, CGRectGetMaxY(_title.frame) + 4, textWidth, 18);
}

@end

#pragma mark - List

@interface VSListController : UITableViewController <UISearchResultsUpdating>
- (void)addVideoID:(NSString *)videoID announce:(BOOL)announce;
@end

@implementation VSListController {
    NSArray<NSDictionary *> *_shown;
    NSString *_query;
    UILabel *_empty;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Saved";
    self.view.tintColor = VS_ACCENT;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.rowHeight = 90;
    [self.tableView registerClass:[VSCell class] forCellReuseIdentifier:@"video"];

    __weak typeof(self) weakSelf = self;
    UIAction *paste = [UIAction actionWithTitle:@"Paste Link" image:[UIImage systemImageNamed:@"doc.on.clipboard"] identifier:nil
                                        handler:^(UIAction *action) { [weakSelf pasteLink]; }];
    UIAction *type = [UIAction actionWithTitle:@"Type a Link" image:[UIImage systemImageNamed:@"keyboard"] identifier:nil
                                       handler:^(UIAction *action) { [weakSelf typeLink]; }];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"]
                                                                               menu:[UIMenu menuWithTitle:@"" children:@[paste, type]]];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Search saved videos";
    self.navigationItem.searchController = search;

    _empty = [[UILabel alloc] init];
    _empty.numberOfLines = 0;
    _empty.textAlignment = NSTextAlignmentCenter;
    _empty.textColor = [UIColor secondaryLabelColor];
    _empty.font = [UIFont systemFontOfSize:16];
    _empty.text = @"Nothing saved yet.\n\nIn YouTube, tap Share on a video, then More, then Save to Volta.\nOr copy a video's link and tap + here.";
    [self rebuild];

    // Fill in anything that was saved while offline.
    for (NSDictionary *video in [VSStore shared].videos) {
        if (!video[@"title"] || !video[@"thumb"]) VSFetchDetails(video[@"id"], ^{ [weakSelf rebuild]; });
    }
}

- (void)rebuild {
    NSArray *all = [VSStore shared].videos;
    if (_query.length) {
        NSString *query = _query;
        all = [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *video, NSDictionary *bindings) {
            return [video[@"title"] localizedCaseInsensitiveContainsString:query] || [video[@"author"] localizedCaseInsensitiveContainsString:query];
        }]];
    }
    _shown = all;
    BOOL nothing = [VSStore shared].videos.count == 0;
    self.tableView.backgroundView = nothing ? _empty : nil;
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    _query = [searchController.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    [self rebuild];
}

- (void)say:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [(self.presentedViewController ?: self) presentViewController:alert animated:YES completion:nil];
}

#pragma mark Adding

- (void)addVideoID:(NSString *)videoID announce:(BOOL)announce {
    if (!VSIsID(videoID)) {
        [self say:@"Not a YouTube Link" message:@"Saved keeps links to YouTube videos, like youtu.be/… or youtube.com/watch?v=…"];
        return;
    }
    VSStore *store = [VSStore shared];
    if ([store contains:videoID]) {
        if (announce) [self say:@"Already Saved" message:@"That video is in your list."];
        return;
    }
    if (![store add:videoID]) {
        [self say:@"List Is Full" message:[NSString stringWithFormat:@"Saved keeps up to %lu videos. Remove some to make room.", (unsigned long)kMaxVideos]];
        return;
    }
    [self rebuild];
    __weak typeof(self) weakSelf = self;
    VSFetchDetails(videoID, ^{ [weakSelf rebuild]; });
    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
}

- (void)pasteLink {
    NSString *text = [UIPasteboard generalPasteboard].string;
    NSString *videoID = VSVideoID(text);
    if (!videoID) {
        [self say:@"No YouTube Link Copied" message:@"Copy a video's link first (Share, then Copy Link in YouTube), then choose Paste Link."];
        return;
    }
    [self addVideoID:videoID announce:YES];
}

- (void)typeLink {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add a Video" message:@"Paste or type a YouTube link." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"https://youtu.be/…";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = weakAlert.textFields.firstObject.text;
        NSString *videoID = VSVideoID(text) ?: (VSIsID(text) ? text : nil);
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf addVideoID:videoID announce:YES]; });   // after the alert has closed
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _shown.count; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (_shown.count == 0) return ([VSStore shared].videos.count && _query.length) ? @"No saved videos match your search." : nil;
    return @"Saved keeps links on this iPad only. Tap a video to open it in YouTube; swipe a row to mark it watched or remove it.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    VSCell *cell = [tableView dequeueReusableCellWithIdentifier:@"video" forIndexPath:indexPath];
    [cell show:_shown[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *videoID = _shown[indexPath.row][@"id"];
    // The YouTube app if it is installed, otherwise the browser.
    NSURL *app = [NSURL URLWithString:[@"youtube://www.youtube.com/watch?v=" stringByAppendingString:videoID]];
    NSURL *web = [NSURL URLWithString:VSWatchLink(videoID)];
    UIApplication *application = [UIApplication sharedApplication];
    [application openURL:[application canOpenURL:app] ? app : web options:@{} completionHandler:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *video = _shown[indexPath.row];
    NSString *videoID = video[@"id"];
    BOOL watched = [video[@"watched"] boolValue];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Remove"
                                                                       handler:^(UIContextualAction *action, UIView *source, void (^completion)(BOOL)) {
        [[VSStore shared] remove:videoID];
        [weakSelf rebuild];
        completion(YES);
    }];
    UIContextualAction *mark = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:watched ? @"Unwatched" : @"Watched"
                                                                     handler:^(UIContextualAction *action, UIView *source, void (^completion)(BOOL)) {
        [[VSStore shared] update:videoID with:@{@"watched": @(!watched)}];
        [weakSelf rebuild];
        completion(YES);
    }];
    mark.backgroundColor = VS_ACCENT;
    return [UISwipeActionsConfiguration configurationWithActions:@[remove, mark]];
}

@end

#pragma mark - App

@interface VSAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation VSAppDelegate {
    VSListController *_list;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.tintColor = VS_ACCENT;
    _list = [[VSListController alloc] init];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:_list];
    [self.window makeKeyAndVisible];
    return YES;
}

// voltasaved://add?v=<video id>   (from the Save to Volta share button)
// voltasaved://add?url=<link>
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    if (![url.scheme.lowercaseString isEqualToString:@"voltasaved"] || ![url.host.lowercaseString isEqualToString:@"add"]) return NO;
    NSString *videoID = nil;
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
        if ([item.name isEqualToString:@"v"] && VSIsID(item.value)) videoID = item.value;
        else if ([item.name isEqualToString:@"url"] && !videoID) videoID = VSVideoID(item.value);
    }
    [_list loadViewIfNeeded];
    [_list addVideoID:videoID announce:YES];
    return videoID != nil;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([VSAppDelegate class]));
    }
}
