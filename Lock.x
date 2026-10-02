//
//  Volta - Lock.x  (SpringBoard only, part of VoltaHome)
//
//  Slide to unlock and swipe up to unlock. Either one asks SpringBoard for a
//  normal unlock, exactly as a Home button press does: with a passcode set
//  you still get the passcode screen (or Touch ID / Face ID). Nothing about
//  device security is bypassed.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "VLTShared.h"
#import "VLTSlider.h"

static BOOL      gSlideOn;
static NSString *gSlideText;
static UIColor  *gSlideColor;
static CGFloat   gSlideOffset = 120;     // distance from the bottom edge
static NSInteger gSlideStyle;            // 0 slider, 1 swipe up, 2 both
static __weak UIViewController *gCoverSheet;
static const void *kSliderKey  = &kSliderKey;
static const void *kSwipeKey   = &kSwipeKey;
static const void *kPanKey     = &kPanKey;
static const void *kHintMask   = &kHintMask;

static void VLTLoadLockPrefs(void) {
    NSDictionary *p = VLTCopyPrefs();
    gSlideOn     = VLTBool(p, @"enabled", YES) && VLTBool(p, @"slideOn", NO);
    gSlideText   = VLTStr(p, @"slideText");
    gSlideColor  = VLTColorFromHex(p[@"slideColor"]);
    gSlideOffset = fmin(fmax(VLTNum(p, @"slideOffset", 120), 40), 400);
    gSlideStyle  = (NSInteger)VLTNum(p, @"slideStyle", 0);
    if (gSlideStyle < 0 || gSlideStyle > 2) gSlideStyle = 0;
}

static inline BOOL VLTWantsSwipe(void)  { return gSlideOn && gSlideStyle != 0; }
static inline BOOL VLTWantsSlider(void) { return gSlideOn && gSlideStyle != 1; }

#pragma mark - Unlocking

static id VLTLockManager(void) {
    Class cls = NSClassFromString(@"SBLockScreenManager");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    return [cls respondsToSelector:shared] ? ((id (*)(id, SEL))objc_msgSend)(cls, shared) : nil;
}

static BOOL VLTIsUILocked(void) {
    id manager = VLTLockManager();
    SEL locked = NSSelectorFromString(@"isUILocked");
    return [manager respondsToSelector:locked] ? ((BOOL (*)(id, SEL))objc_msgSend)(manager, locked) : YES;
}

// Three ways to ask, newest first. Each is SpringBoard's own "please unlock":
// it opens straight away when no passcode is needed, and otherwise brings up
// the passcode screen.
static void VLTRequestUnlock(void) {
    id manager = VLTLockManager();
    @try {
        Class requestClass = NSClassFromString(@"SBLockScreenUnlockRequest");
        SEL withRequest = NSSelectorFromString(@"unlockWithRequest:completion:");
        if (requestClass && [manager respondsToSelector:withRequest]) {
            id request = [[requestClass alloc] init];
            [request setValue:@"Volta" forKey:@"name"];
            [request setValue:@17 forKey:@"source"];
            [request setValue:@3 forKey:@"intent"];    // dismiss the Lock Screen, authenticating first if needed
            ((BOOL (*)(id, SEL, id, id))objc_msgSend)(manager, withRequest, request, nil);
            return;
        }
        SEL fromSource = NSSelectorFromString(@"unlockUIFromSource:withOptions:");
        if ([manager respondsToSelector:fromSource]) {
            ((BOOL (*)(id, SEL, int, id))objc_msgSend)(manager, fromSource, 17, nil);
            return;
        }
        SEL request = NSSelectorFromString(@"lockScreenViewControllerRequestsUnlock");
        if ([manager respondsToSelector:request]) ((void (*)(id, SEL))objc_msgSend)(manager, request);
    } @catch (NSException *e) {
        NSLog(@"[Volta] unlock request failed: %@", e);
    }
}

#pragma mark - Swipe up, iPhone style

// The pan lives on the Lock Screen's root view, so it works no matter what is
// layered at the bottom edge. The whole Lock Screen follows the finger; let go
// far enough up (or flick) and it unlocks, otherwise it settles back.
@interface VLTSwipeHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handlePan:(UIPanGestureRecognizer *)pan;
@end

@implementation VLTSwipeHandler

+ (instancetype)shared {
    static VLTSwipeHandler *handler;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handler = [[VLTSwipeHandler alloc] init]; });
    return handler;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    if (!VLTWantsSwipe() || !VLTIsUILocked()) return NO;
    UIView *view = recognizer.view;
    UIView *slider = objc_getAssociatedObject(gCoverSheet, kSliderKey);
    if (slider && [touch.view isDescendantOfView:slider]) return NO;   // the slider keeps its own drag
    // Must start near the bottom edge, like the Home bar gesture.
    CGFloat zone = MAX(120, view.bounds.size.height * 0.14);
    return [touch locationInView:view].y >= view.bounds.size.height - zone;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    CGPoint velocity = [(UIPanGestureRecognizer *)recognizer velocityInView:recognizer.view];
    return velocity.y < 0 && fabs(velocity.y) > fabs(velocity.x);
}

// Scrolling and paging on the Lock Screen wait for this gesture to give up.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)settle:(UIView *)view {
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ view.transform = CGAffineTransformIdentity; } completion:nil];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *view = pan.view;
    CGFloat height = MAX(view.bounds.size.height, 1);
    CGFloat y = MIN([pan translationInView:view.superview ?: view].y, 0);   // upward only
    switch (pan.state) {
        case UIGestureRecognizerStateChanged:
            view.transform = CGAffineTransformMakeTranslation(0, y);
            break;
        case UIGestureRecognizerStateEnded: {
            CGFloat velocity = [pan velocityInView:view.superview ?: view].y;
            BOOL far = y < -height * 0.22;
            BOOL flung = velocity < -900 && y < -40;
            if (far || flung) {
                [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
                // Carry on up and out, ask for the unlock, then put the view back
                // underneath: if a passcode is needed its screen shows in this view.
                [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                                 animations:^{ view.transform = CGAffineTransformMakeTranslation(0, -height); }
                                 completion:^(BOOL finished) {
                    VLTRequestUnlock();
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if (VLTIsUILocked()) [self settle:view];
                        else view.transform = CGAffineTransformIdentity;
                    });
                }];
            } else {
                [self settle:view];
            }
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self settle:view];
            break;
        default: break;
    }
}

@end

#pragma mark - Lock Screen views

static UIView *VLTFindView(UIView *root, Class cls, int depth) {
    if (!cls || depth > 8) return nil;
    for (UIView *subview in root.subviews) {
        if ([subview isKindOfClass:cls]) return subview;
        UIView *found = VLTFindView(subview, cls, depth + 1);
        if (found) return found;
    }
    return nil;
}

// The system's "Press home to open" text.
static UIView *VLTSystemHint(UIViewController *coverSheet) {
    UIView *container = VLTFindView(coverSheet.view, NSClassFromString(@"CSTeachableMomentsContainerView"), 0);
    UIView *label = nil;
    @try {
        id value = [container valueForKey:@"callToActionLabel"];
        if ([value isKindOfClass:[UIView class]]) label = value;
    } @catch (__unused NSException *e) {}
    return label ?: VLTFindView(coverSheet.view, NSClassFromString(@"SBUICallToActionLabel"), 0);
}

// Adds, updates or removes the slider, the swipe-up bar and the gesture.
static void VLTApplyLockControls(UIViewController *coverSheet) {
    if (!coverSheet.isViewLoaded) return;
    gCoverSheet = coverSheet;
    UIView *root = coverSheet.view;
    VLTSlideToUnlock *slider = objc_getAssociatedObject(coverSheet, kSliderKey);
    VLTSwipeUpToUnlock *swipe = objc_getAssociatedObject(coverSheet, kSwipeKey);
    BOOL wantsSlider = VLTWantsSlider(), wantsSwipe = VLTWantsSwipe();

    if (!wantsSlider && slider) {
        [slider removeFromSuperview];
        objc_setAssociatedObject(coverSheet, kSliderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        slider = nil;
    }
    if (!wantsSwipe && swipe) {
        [swipe removeFromSuperview];
        objc_setAssociatedObject(coverSheet, kSwipeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        swipe = nil;
    }

    // One pan on the root view, installed once; its delegate decides when it applies.
    if (wantsSwipe && !objc_getAssociatedObject(root, kPanKey)) {
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[VLTSwipeHandler shared] action:@selector(handlePan:)];
        pan.delegate = [VLTSwipeHandler shared];
        pan.maximumNumberOfTouches = 1;
        [root addGestureRecognizer:pan];
        objc_setAssociatedObject(root, kPanKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // The same screen doubles as Notification Center when you are already
    // unlocked; none of this has a job there.
    BOOL locked = VLTIsUILocked();

    // Our hint takes the place of "Press home to open", so hide that one.
    UIView *systemHint = VLTSystemHint(coverSheet);
    if (systemHint) {
        CALayer *ours = objc_getAssociatedObject(systemHint, kHintMask);
        if (wantsSwipe && locked) {
            if (!systemHint.layer.mask) {
                CALayer *mask = [CALayer layer];   // empty mask = nothing drawn
                systemHint.layer.mask = mask;
                objc_setAssociatedObject(systemHint, kHintMask, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } else if (ours) {
            if (systemHint.layer.mask == ours) systemHint.layer.mask = nil;
            objc_setAssociatedObject(systemHint, kHintMask, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    // Don't re-lay-out while the screen is being dragged.
    if (!CGAffineTransformIsIdentity(root.transform)) return;
    if (!gSlideOn) return;

    if (wantsSwipe) {
        if (!swipe) {
            swipe = [[VLTSwipeUpToUnlock alloc] initWithFrame:CGRectZero];
            swipe.passive = YES;
            objc_setAssociatedObject(coverSheet, kSwipeKey, swipe, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (swipe.superview != root) [root addSubview:swipe];
        // Bar on the bottom edge; hint exactly where the system's text was
        // (above the page dots), or a sensible spot if that text is not found.
        CGFloat hintInset = 62;
        if (systemHint && systemHint.window) {
            CGRect hintFrame = [root convertRect:systemHint.bounds fromView:systemHint];
            CGFloat fromBottom = root.bounds.size.height - CGRectGetMidY(hintFrame);
            if (fromBottom > 30 && fromBottom < 220) hintInset = fromBottom;
        }
        CGFloat height = MAX([VLTSwipeUpToUnlock preferredHeight], hintInset + 24);
        CGRect frame = CGRectMake(0, root.bounds.size.height - height, root.bounds.size.width, height);
        if (!CGRectEqualToRect(swipe.frame, frame)) swipe.frame = frame;
        swipe.hintInset = hintInset;
        swipe.hidden = !locked;
    }

    if (wantsSlider) {
        // Prefer the main page, so the slider moves away with it when you
        // swipe to the camera or widgets.
        UIView *host = root;
        @try {
            id page = [root valueForKey:@"mainPageView"];
            if ([page isKindOfClass:[UIView class]] && [(UIView *)page isDescendantOfView:root]) host = page;
        } @catch (__unused NSException *e) {}

        if (!slider) {
            slider = [[VLTSlideToUnlock alloc] initWithFrame:CGRectZero];
            slider.onUnlock = ^{ VLTRequestUnlock(); };
            objc_setAssociatedObject(coverSheet, kSliderKey, slider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (slider.superview != host) [host addSubview:slider];
        else if (host.subviews.lastObject != slider) [host bringSubviewToFront:slider];

        slider.text = gSlideText;
        slider.knobColor = gSlideColor;
        CGSize size = [VLTSlideToUnlock preferredSizeForWidth:host.bounds.size.width];
        CGRect frame = CGRectMake(round((host.bounds.size.width - size.width) / 2),
                                  round(host.bounds.size.height - gSlideOffset - size.height), size.width, size.height);
        if (!CGRectEqualToRect(slider.frame, frame)) slider.frame = frame;
        slider.hidden = !locked;
    }
}

static void VLTResetLockControls(UIViewController *coverSheet) {
    [(VLTSlideToUnlock *)objc_getAssociatedObject(coverSheet, kSliderKey) reset];
    if (coverSheet.isViewLoaded) coverSheet.view.transform = CGAffineTransformIdentity;
}

%group LockControls

%hook CSCoverSheetViewController

- (void)viewDidLoad {
    %orig;
    VLTApplyLockControls((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    VLTResetLockControls((UIViewController *)self);
    VLTApplyLockControls((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    VLTApplyLockControls((UIViewController *)self);
}

%end

%end // group LockControls

static void VLTLockPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        VLTLoadLockPrefs();
        UIViewController *coverSheet = gCoverSheet;
        if (coverSheet) VLTApplyLockControls(coverSheet);
    });
}

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        VLTLoadLockPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, VLTLockPrefsChanged,
                                        CFSTR(VLT_NOTIFY_PREFS), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // Locked <-> unlocked: show or hide the controls and put everything back in place.
        static int lockToken;
        notify_register_dispatch("com.apple.springboard.lockstate", &lockToken, dispatch_get_main_queue(), ^(int token) {
            UIViewController *coverSheet = gCoverSheet;
            if (!coverSheet) return;
            VLTResetLockControls(coverSheet);
            VLTApplyLockControls(coverSheet);
        });

        %init(LockControls);
    }
}
