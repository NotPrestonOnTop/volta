#import "VLTControllers.h"

// Pages added in 2.0.
@interface VLTHomeController : VLTBaseController
@end

@interface VLTIconsController : VLTBaseController <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@end

@interface VLTStatusController : VLTBaseController
@end

@interface VLTNotifController : VLTBaseController
@end

// Pages added in 2.2.
@interface VLTSwitcherController : VLTBaseController
@end

@interface VLTKeyboardController : VLTBaseController
@end

@interface VLTPopupsController : VLTBaseController
@end

@interface VLTSoundsController : VLTBaseController
@end

@interface VLTSafetyController : VLTBaseController
@end

// One line for the Safety card and list row.
NSString *VLTSafetySummary(NSDictionary *prefs, BOOL *inUse);

// Saved setups: not a settings list, a plain table.
@interface VLTProfilesController : UITableViewController <UIDocumentPickerDelegate>
@end

// How many profiles are saved (for the dashboard card).
NSInteger VLTProfileCount(void);
