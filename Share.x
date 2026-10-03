// Volta - adds "Save to Volta" to share sheets when a YouTube link is being
// shared. It hands the video's id to Volta's Saved app, which keeps a
// watch-later list that needs no account. Loaded into every app.
#import <UIKit/UIKit.h>
#import <notify.h>
#import "VLTShared.h"
#import "voltasaved/SavedCore.h"

static BOOL gIsSpringBoard;
static BOOL gShareOn = YES;

static void VLTLoadShare(void) {
    NSDictionary *s = gIsSpringBoard ? VLTStatusDict(VLTCopyPrefs()) : [NSDictionary dictionaryWithContentsOfFile:VLT_STATUS_PATH];
    if (![s isKindOfClass:[NSDictionary class]]) s = @{};
    // Off with Volta, with its own switch, or when the Saved app is hidden.
    gShareOn = VLTBool(s, @"enabled", YES) && VLTBool(s, @"shareSave", YES) && VLTBool(s, @"appSaved", YES);
}

static NSString *VLTSharedVideoID(NSArray *items) {
    char out[VLT_VIDEO_ID_MAX + 1];
    for (id item in items) {
        NSString *text = nil;
        if ([item isKindOfClass:[NSURL class]]) text = [(NSURL *)item absoluteString];
        else if ([item isKindOfClass:[NSString class]]) text = item;
        if (text.length && text.length < 2048 && vlt_video_id(text.UTF8String, out)) return @(out);
    }
    return nil;
}

@interface VLTSaveActivity : UIActivity
@end

@implementation VLTSaveActivity {
    NSString *_videoID;
}

+ (UIActivityCategory)activityCategory { return UIActivityCategoryAction; }
- (UIActivityType)activityType { return @"com.notpreston.volta.save"; }
- (NSString *)activityTitle { return @"Save to Volta"; }
- (UIImage *)activityImage { return [UIImage systemImageNamed:@"bookmark.fill"]; }
- (BOOL)canPerformWithActivityItems:(NSArray *)activityItems { return VLTSharedVideoID(activityItems) != nil; }
- (void)prepareWithActivityItems:(NSArray *)activityItems { _videoID = VLTSharedVideoID(activityItems); }

- (void)performActivity {
    NSURL *url = _videoID ? [NSURL URLWithString:[@"voltasaved://add?v=" stringByAppendingString:_videoID]] : nil;
    if (!url) {
        [self activityDidFinish:NO];
        return;
    }
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL opened) {
        [self activityDidFinish:opened];
    }];
}

@end

%group ShareSave

%hook UIActivityViewController

- (id)initWithActivityItems:(NSArray *)activityItems applicationActivities:(NSArray *)applicationActivities {
    if (gShareOn && [activityItems isKindOfClass:[NSArray class]] && VLTSharedVideoID(activityItems)) {
        NSMutableArray *activities = [NSMutableArray arrayWithObject:[[VLTSaveActivity alloc] init]];
        if ([applicationActivities isKindOfClass:[NSArray class]]) [activities addObjectsFromArray:applicationActivities];
        applicationActivities = activities;
    }
    return %orig(activityItems, applicationActivities);
}

%end

%end // group ShareSave

static void VLTShareChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ VLTLoadShare(); });
}

%ctor {
    @autoreleasepool {
        NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
        NSString *executable = [NSBundle mainBundle].executablePath ?: @"";
        gIsSpringBoard = [bundleID isEqualToString:@"com.apple.springboard"];
        if (!gIsSpringBoard) {   // same rule as the battery hooks: real apps only
            if (!bundleID) return;
            if (![executable containsString:@"/Application"]) return;
            if ([executable containsString:@".appex/"]) return;
        }
        if ([bundleID isEqualToString:@"com.notpreston.volta.saved"]) return;   // no need inside the Saved app itself
        VLTLoadShare();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, VLTShareChanged,
                                        gIsSpringBoard ? CFSTR(VLT_NOTIFY_PREFS) : CFSTR(VLT_NOTIFY_APPLY), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        %init(ShareSave);
    }
}
