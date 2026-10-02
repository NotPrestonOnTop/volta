// Volta - icon themes: shape, tint and icon-pack artwork.
// Used by the tweak (real icons) and by the Settings preview.
#import <UIKit/UIKit.h>
#import "VLTShared.h"

enum { VLTTintOff = 0, VLTTintColorize, VLTTintWash, VLTTintGray, VLTTintInvert, VLTTintCount };
enum {
    VLTShapeDefault = 0, VLTShapeCircle, VLTShapeHexagon, VLTShapeOctagon, VLTShapeLeaf,
    VLTShapeStar, VLTShapeHeart, VLTShapeDiamond, VLTShapeCount
};

typedef struct {
    int      tintMode;   // VLTTint...
    uint32_t tint;       // 0xRRGGBBAA
    CGFloat  strength;   // 0 ... 1
    int      shape;      // VLTShape...
} VLTIconStyle;

static inline VLTIconStyle VLTIconStyleFromPrefs(NSDictionary *p) {
    VLTIconStyle style = {0};
    if (!VLTBool(p, @"enabled", YES) || !VLTBool(p, @"iconOn", NO)) return style;
    int mode = (int)VLTNum(p, @"iconTintMode", 0);
    style.tintMode = (mode > 0 && mode < VLTTintCount) ? mode : VLTTintOff;
    if (!VLTParseHex(p[@"iconTint"], &style.tint)) style.tint = 0x5B5BF0FF;
    style.strength = fmin(fmax(VLTNum(p, @"iconTintStrength", 70) / 100.0, 0), 1);
    int shape = (int)VLTNum(p, @"iconShape", 0);
    style.shape = (shape > 0 && shape < VLTShapeCount) ? shape : VLTShapeDefault;
    return style;
}

static inline BOOL VLTIconStyleIsPlain(VLTIconStyle style) {
    return style.shape == VLTShapeDefault && (style.tintMode == VLTTintOff || style.strength < 0.005);
}

// A regular polygon or star inscribed in the rect. inner < 1 makes a star.
static inline UIBezierPath *VLTIconPolygon(CGRect rect, int points, CGFloat rotation, CGFloat inner) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGPoint center = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    CGFloat radius = MIN(rect.size.width, rect.size.height) / 2;
    int count = inner < 0.999 ? points * 2 : points;
    for (int i = 0; i < count; i++) {
        CGFloat r = (inner < 0.999 && (i % 2)) ? radius * inner : radius;
        CGFloat angle = rotation + (CGFloat)i * 2 * M_PI / count;
        CGPoint point = CGPointMake(center.x + r * cos(angle), center.y + r * sin(angle));
        if (i == 0) [path moveToPoint:point];
        else [path addLineToPoint:point];
    }
    [path closePath];
    return path;
}

// nil means "leave the icon's own outline alone".
static inline UIBezierPath *VLTIconShapePath(int shape, CGRect rect) {
    CGFloat w = rect.size.width, h = rect.size.height, x = rect.origin.x, y = rect.origin.y;
    switch (shape) {
        case VLTShapeCircle:  return [UIBezierPath bezierPathWithOvalInRect:rect];
        case VLTShapeHexagon: return VLTIconPolygon(rect, 6, -M_PI_2, 1);
        case VLTShapeOctagon: return VLTIconPolygon(rect, 8, M_PI / 8, 1);
        case VLTShapeLeaf:
            return [UIBezierPath bezierPathWithRoundedRect:rect byRoundingCorners:UIRectCornerTopLeft | UIRectCornerBottomRight
                                               cornerRadii:CGSizeMake(w / 2, h / 2)];
        case VLTShapeStar:    return VLTIconPolygon(rect, 5, -M_PI_2, 0.55);
        case VLTShapeDiamond: return VLTIconPolygon(rect, 4, -M_PI_2, 1);
        case VLTShapeHeart: {
            UIBezierPath *path = [UIBezierPath bezierPath];
            [path moveToPoint:CGPointMake(x + w * 0.5, y + h * 0.95)];
            [path addCurveToPoint:CGPointMake(x, y + h * 0.33)
                    controlPoint1:CGPointMake(x + w * 0.20, y + h * 0.78) controlPoint2:CGPointMake(x, y + h * 0.56)];
            [path addCurveToPoint:CGPointMake(x + w * 0.5, y + h * 0.22)
                    controlPoint1:CGPointMake(x, y + h * 0.02) controlPoint2:CGPointMake(x + w * 0.40, y + h * 0.02)];
            [path addCurveToPoint:CGPointMake(x + w, y + h * 0.33)
                    controlPoint1:CGPointMake(x + w * 0.60, y + h * 0.02) controlPoint2:CGPointMake(x + w, y + h * 0.02)];
            [path addCurveToPoint:CGPointMake(x + w * 0.5, y + h * 0.95)
                    controlPoint1:CGPointMake(x + w, y + h * 0.56) controlPoint2:CGPointMake(x + w * 0.80, y + h * 0.78)];
            [path closePath];
            return path;
        }
        default: return nil;
    }
}

// base: the icon as the system drew it (already has its rounded outline).
// artwork: optional replacement picture from the icon pack (a plain square).
// Returns nil when there is nothing to change.
static inline UIImage *VLTIconRender(UIImage *base, UIImage *artwork, VLTIconStyle style) {
    CGSize size = base.size;
    if (size.width < 2 || size.height < 2 || size.width > 1024 || size.height > 1024) return nil;
    if (!artwork && VLTIconStyleIsPlain(style)) return nil;
    CGRect rect = CGRectMake(0, 0, size.width, size.height);

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = base.scale > 0 ? base.scale : 2;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];

    UIBezierPath *outline = VLTIconShapePath(style.shape, rect);
    if (!outline && artwork) outline = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:size.width * 0.225];
    UIImage *shaped = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        if (outline) [outline addClip];
        if (artwork) {   // aspect fill
            CGSize a = artwork.size;
            CGFloat scale = (a.width > 0 && a.height > 0) ? MAX(size.width / a.width, size.height / a.height) : 1;
            CGSize drawn = CGSizeMake(a.width * scale, a.height * scale);
            [artwork drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height)];
        } else {
            [base drawInRect:rect];
        }
    }];
    if (style.tintMode == VLTTintOff || style.strength < 0.005) return shaped;

    UIColor *color = VLTColorFromRGBA(style.tint);
    CGBlendMode blend = kCGBlendModeNormal;
    switch (style.tintMode) {
        case VLTTintColorize: blend = kCGBlendModeColor; break;
        case VLTTintWash:     blend = kCGBlendModeNormal; break;
        case VLTTintGray:     blend = kCGBlendModeSaturation; color = [UIColor grayColor]; break;
        case VLTTintInvert:   blend = kCGBlendModeDifference; color = [UIColor whiteColor]; break;
        default: break;
    }
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [shaped drawInRect:rect];
        [[color colorWithAlphaComponent:style.strength] setFill];
        UIRectFillUsingBlendMode(rect, blend);
        [shaped drawInRect:rect blendMode:kCGBlendModeDestinationIn alpha:1];   // keep the icon's own outline
    }];
}
