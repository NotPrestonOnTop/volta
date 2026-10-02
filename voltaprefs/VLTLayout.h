#import <UIKit/UIKit.h>
#import <Preferences/PSTableCell.h>
#import "VLTControllers.h"

// Control Center > Layout & Custom Controls
@interface VLTCCLayoutController : VLTBaseController
@end

// A normal-looking row with a chevron, for rows that open another screen.
@interface VLTNavCell : PSTableCell
@end

// Reorder, resize and hide Control Center modules.
@interface VLTModuleEditorController : UITableViewController
@end

// The list of custom buttons.
@interface VLTButtonListController : UITableViewController
@end
