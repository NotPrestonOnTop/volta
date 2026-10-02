#import <UIKit/UIKit.h>

// Credits and the update checker.
@interface VLTAboutController : UIViewController
@end

// Looks for a newer version at the feed link the user has set.
@interface VLTUpdater : NSObject
+ (NSString *)feedURLString;                       // nil when not set up
+ (BOOL)updateAvailable;                           // from the last check
+ (NSString *)latestVersion;                       // from the last check, may be nil
+ (void)checkWithCompletion:(void (^)(BOOL ok, NSString *message))completion;
+ (void)checkIfDueWithCompletion:(void (^)(void))completion;   // at most once a day
@end
