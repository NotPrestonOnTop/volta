#import <UIKit/UIKit.h>
#import <Preferences/PSTableCell.h>

// The cards on the main page, in order.
typedef NS_ENUM(NSInteger, VLTPage) {
    VLTPageBattery = 0, VLTPageStatus, VLTPageCC, VLTPageHome, VLTPageIcons, VLTPageDock,
    VLTPageWallpaper, VLTPageLock, VLTPageNotif, VLTPageFun, VLTPageProfiles, VLTPageAbout,
};

// Main page: banner plus one card per section.
@interface VLTDashboardView : UIView
@property (nonatomic, copy) void (^onSelect)(NSInteger index);   // a VLTPage
- (void)setStatus:(NSString *)status atIndex:(NSInteger)index;
- (CGFloat)heightForWidth:(CGFloat)width;
@end

// Mock-ups drawn from the saved settings.
@interface VLTCCPreview : UIView
@property (nonatomic, copy) NSDictionary *prefs;
@end

@interface VLTDockPreview : UIView
@property (nonatomic, copy) NSDictionary *prefs;
@end

// A small screen running the real animated scene.
@interface VLTWallpaperPreview : UIView
@property (nonatomic, copy) NSDictionary *prefs;
@property (nonatomic) BOOL paused;
@end

// A working slide-to-unlock control on a wallpaper card.
@interface VLTLockPreview : UIView
@property (nonatomic, copy) NSDictionary *prefs;
@end

// Confetti falling on a card; the header of the Fun page.
@interface VLTFunHeader : UIView
@end

// Table row showing whether a video (or .tendies file) has been chosen.
@interface VLTVideoCell : PSTableCell
@end
