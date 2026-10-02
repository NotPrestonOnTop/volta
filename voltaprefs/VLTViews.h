#import <UIKit/UIKit.h>
#import <Preferences/PSTableCell.h>

#define VLT_ACCENT [UIColor colorWithRed:0.357 green:0.357 blue:0.941 alpha:1.0]   // #5B5BF0
#define VLT_TEAL   [UIColor colorWithRed:0.098 green:0.784 blue:0.725 alpha:1.0]   // #19C8B9

// Gradient banner shown at the top of the main page.
@interface VLTHeaderView : UIView
@end

// Live mock-up of the status bar battery, drawn from the saved settings.
@interface VLTBatteryPreview : UIView
@property (nonatomic, copy) NSDictionary *prefs;
@end

// Table row with a color swatch (or "Default") on the right.
@interface VLTColorCell : PSTableCell
@end

// Table row with a thumbnail of the user's own battery picture.
@interface VLTPictureCell : PSTableCell
@end
