// Volta - small helpers shared by the SpringBoard look-and-feel hooks.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

@interface UIView (VLTLookPrivate)
- (CGFloat)_continuousCornerRadius;
- (void)_setContinuousCornerRadius:(CGFloat)radius;
@end

// A fixed, additive offset on one key path ("transform.scale", ...). It adds
// to whatever the system sets, so layout carries on underneath. Passing
// on = NO removes it; a changed value replaces it.
static inline void VLTPinOffset(CALayer *layer, NSString *key, NSString *keyPath, BOOL on, CGFloat value) {
    CABasicAnimation *existing = (CABasicAnimation *)[layer animationForKey:key];
    if (!on || fabs(value) < 0.0005) {
        if (existing) [layer removeAnimationForKey:key];
        return;
    }
    if ([existing isKindOfClass:[CABasicAnimation class]] && [existing.toValue respondsToSelector:@selector(doubleValue)] &&
        fabs([existing.toValue doubleValue] - value) < 0.0005) return;
    if (existing) [layer removeAnimationForKey:key];
    CABasicAnimation *hold = [CABasicAnimation animationWithKeyPath:keyPath];
    hold.fromValue = hold.toValue = @(value);
    hold.additive = YES;
    hold.duration = 3600;
    hold.repeatCount = HUGE_VALF;
    hold.removedOnCompletion = NO;
    [layer addAnimation:hold forKey:key];
}

// Hides a view with an empty layer mask: the system keeps laying it out and
// never touches masks, so nothing fights back. Only ever removes its own mask.
static inline void VLTSetMasked(UIView *view, BOOL hide, const void *key) {
    CALayer *ours = objc_getAssociatedObject(view, key);
    if (hide) {
        if (!view.layer.mask) {
            CALayer *mask = [CALayer layer];
            view.layer.mask = mask;
            objc_setAssociatedObject(view, key, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else if (ours) {
        if (view.layer.mask == ours) view.layer.mask = nil;
        objc_setAssociatedObject(view, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static inline void VLTLookSetRadius(UIView *view, CGFloat radius) {
    if ([view respondsToSelector:@selector(_setContinuousCornerRadius:)]) {
        [view _setContinuousCornerRadius:radius];
    } else {
        view.layer.cornerRadius = radius;
        view.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

static inline CGFloat VLTLookRadius(UIView *view) {
    if ([view respondsToSelector:@selector(_continuousCornerRadius)] && [view _continuousCornerRadius] > 0)
        return [view _continuousCornerRadius];
    return view.layer.cornerRadius;
}

static inline id VLTLookValue(id object, NSString *key) {
    id value = nil;
    @try { value = [object valueForKey:key]; } @catch (__unused NSException *e) {}
    return value;
}
