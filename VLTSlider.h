//
//  VLTSlider.h
//  The "slide to unlock" control. Shared by the SpringBoard tweak (the real
//  one on the Lock Screen) and the Settings pane (a working preview).
//

#import <UIKit/UIKit.h>

@interface VLTSlideToUnlock : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSString *text;          // nil or empty = "slide to unlock"
@property (nonatomic, strong) UIColor *knobColor;    // nil = white
@property (nonatomic, copy) void (^onUnlock)(void);  // called once the knob reaches the end
- (void)reset;                                       // knob back to the start
+ (CGSize)preferredSizeForWidth:(CGFloat)available;
@end

// "Swipe up to unlock": a home bar and a hint along the bottom edge.
@interface VLTSwipeUpToUnlock : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, copy) void (^onUnlock)(void);
// On the real Lock Screen the whole screen follows the finger, driven from
// outside; then this view only draws the bar and the hint (passive = YES).
@property (nonatomic) BOOL passive;
// Distance from this view's bottom edge to the middle of the hint text.
@property (nonatomic) CGFloat hintInset;
- (void)reset;
+ (CGFloat)preferredHeight;
@end
