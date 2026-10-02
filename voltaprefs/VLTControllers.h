#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

// Shared behaviour: loads a plist, stores values, handles color rows.
@interface VLTBaseController : PSListController <UIColorPickerViewControllerDelegate>
- (NSString *)plistName;      // override
- (UIView *)makeHeaderView;   // override, optional
- (CGFloat)headerHeightForWidth:(CGFloat)width;   // override, optional
- (void)prefsDidChange;       // override, optional
@end

@interface VLTRootListController : VLTBaseController
@end

@interface VLTBatteryController : VLTBaseController <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@end

@interface VLTCCController : VLTBaseController
@end

@interface VLTDockController : VLTBaseController
@end

@interface VLTWallpaperController : VLTBaseController <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@end

@interface VLTLockController : VLTBaseController
@end

@interface VLTFunController : VLTBaseController
@end
