#import "VLTScene.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

// Private Core Animation API for loading .ca packages (the same one Control
// Center uses for its animated glyphs).
@interface CAPackage : NSObject
+ (instancetype)packageWithContentsOfURL:(NSURL *)url type:(NSString *)type options:(NSDictionary *)options error:(NSError **)error;
@property (readonly) CALayer *rootLayer;
@property (readonly, getter=isGeometryFlipped) BOOL geometryFlipped;
@end
extern NSString * const kCAPackageTypeCAMLBundle;

@interface CAStateController : NSObject
- (instancetype)initWithLayer:(CALayer *)layer;
- (void)setInitialStatesOfLayer:(CALayer *)layer;
- (void)setState:(id)state ofLayer:(CALayer *)layer transitionSpeed:(float)speed;
@end

@interface CALayer (VLTStates)
- (id)stateWithName:(NSString *)name;
@end

#define RGB(r, g, b) [UIColor colorWithRed:(r) / 255.0 green:(g) / 255.0 blue:(b) / 255.0 alpha:1]

@implementation VLTSceneView {
    CAGradientLayer *_backdrop;
    CALayer *_content;        // emitters, glow blobs or the video layer
    CALayer *_dimLayer;
    AVQueuePlayer *_player;
    AVPlayerLooper *_looper;
    AVPlayerLayer *_playerLayer;
    AVQueuePlayer *_audioPlayer;      // the user's own sound file, looping on its own clock
    AVPlayerLooper *_audioLooper;
    NSString *_audioPlayerPath;
    CGSize _builtSize;
    NSInteger _generation;
    BOOL _needsBuild;
    NSMutableArray<CALayer *> *_packageRoots;                 // .tendies layers
    NSMutableArray<CAStateController *> *_stateControllers;   // one per root, same order
    NSString *_wallpaperState;
}

+ (NSString *)nameForKind:(NSInteger)kind {
    switch (kind) {
        case VLTSceneAurora:    return @"Aurora";
        case VLTSceneFireflies: return @"Fireflies";
        case VLTSceneStarfield: return @"Starfield";
        case VLTSceneSnow:      return @"Snow";
        case VLTSceneEmbers:    return @"Embers";
        case VLTSceneBubbles:   return @"Bubbles";
        case VLTSceneVideo:     return @"My Video";
        case VLTSceneTendies:   return @"My Tendies";
        default:                return @"Off";
    }
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        _speed = 1;
        _zoom = 1;
        _backdrop = [CAGradientLayer layer];
        _content = [CALayer layer];
        _dimLayer = [CALayer layer];
        _dimLayer.backgroundColor = [UIColor blackColor].CGColor;
        _dimLayer.opacity = 0;
        [self.layer addSublayer:_backdrop];
        [self.layer addSublayer:_content];
        [self.layer addSublayer:_dimLayer];
        _needsBuild = YES;
    }
    return self;
}

- (void)dealloc {
    [_player pause];
    [_audioPlayer pause];
}

- (BOOL)hasOwnSound {
    return _audioPath.length && [[NSFileManager defaultManager] isReadableFileAtPath:_audioPath];
}

static void VLTUseAmbientAudio(void) {
    // "Ambient" plays alongside music instead of stopping it, and obeys the silent switch.
    @try {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient
                                         withOptions:AVAudioSessionCategoryOptionMixWithOthers error:NULL];
    } @catch (__unused NSException *e) {}
}

// Starts, swaps or stops the separate sound-file player.
- (void)updateAudio {
    BOOL wanted = _volume > 0.001 && _kind != VLTSceneNone && [self hasOwnSound];
    if (!wanted) {
        [_audioPlayer pause];
        _audioPlayer = nil;
        _audioLooper = nil;
        _audioPlayerPath = nil;
        return;
    }
    if (_audioPlayer && [_audioPlayerPath isEqualToString:_audioPath]) return;
    VLTUseAmbientAudio();
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:_audioPath]];
    _audioPlayer = [AVQueuePlayer queuePlayerWithItems:@[]];
    _audioPlayer.allowsExternalPlayback = NO;
    _audioLooper = [AVPlayerLooper playerLooperWithPlayer:_audioPlayer templateItem:item];
    _audioPlayerPath = [_audioPath copy];
}

- (void)setAudioPath:(NSString *)path {
    if ((path ?: @"").length == (_audioPath ?: @"").length && [(path ?: @"") isEqualToString:(_audioPath ?: @"")]) return;
    BOOL hadOwn = [self hasOwnSound];
    _audioPath = [path copy];
    // A video drops its own sound track when a sound file takes over, and gets it back afterwards.
    if (_kind == VLTSceneVideo && hadOwn != [self hasOwnSound]) {
        _needsBuild = YES;
        [self setNeedsLayout];
    }
    [self applyLiveSettings];
}

- (void)configureWithKind:(NSInteger)kind keepsWallpaper:(BOOL)keeps speed:(CGFloat)speed dim:(CGFloat)dim videoPath:(NSString *)path generation:(NSInteger)generation {
    BOOL usesFile = (kind == VLTSceneVideo || kind == VLTSceneTendies);
    BOOL structural = kind != _kind || keeps != _keepsWallpaper || generation != _generation ||
                      (usesFile && ![(path ?: @"") isEqualToString:(_videoPath ?: @"")]);
    _kind = kind;
    _keepsWallpaper = keeps;
    _videoPath = [path copy];
    _generation = generation;
    _speed = fmin(fmax(speed, 0.25), 3);
    _dim = fmin(fmax(dim, 0), 0.9);
    if (structural) _needsBuild = YES;
    [self applyLiveSettings];
    [self setNeedsLayout];
}

- (void)setFitMode:(NSInteger)mode {
    if (mode < 0 || mode > 3) mode = 0;
    if (mode == _fitMode) return;
    _fitMode = mode;
    _needsBuild = YES;
    [self setNeedsLayout];
}

- (void)setZoom:(CGFloat)zoom {
    CGFloat clamped = fmin(fmax(zoom, 0.5), 2.0);
    if (fabs(clamped - _zoom) < 0.001) return;
    _zoom = clamped;
    _needsBuild = YES;
    [self setNeedsLayout];
}

// Horizontal and vertical scale that places a picture of `design` size in
// this view, according to fitMode and zoom.
- (CGSize)scaleForDesignSize:(CGSize)design {
    CGSize size = _content.bounds.size;
    CGFloat sx = size.width / design.width, sy = size.height / design.height;
    CGFloat fill = MAX(sx, sy), fit = MIN(sx, sy);
    NSInteger mode = _fitMode;
    if (mode == 0) {
        // Filling keeps (fit / fill) of the picture on screen. A phone wallpaper
        // on a sideways iPad would keep about a third, so fit it instead.
        mode = (fit / fill < 0.6) ? 2 : 1;
    }
    if (mode == 3) return CGSizeMake(sx * _zoom, sy * _zoom);
    CGFloat scale = (mode == 2 ? fit : fill) * _zoom;
    return CGSizeMake(scale, scale);
}

// Sound needs an audio track in the player, so crossing zero rebuilds it.
- (void)setVolume:(CGFloat)volume {
    CGFloat clamped = fmin(fmax(volume, 0), VLT_MAX_WALLPAPER_VOLUME);
    BOOL hadSound = _volume > 0.001, hasSound = clamped > 0.001;
    _volume = clamped;
    if (hadSound != hasSound && _kind == VLTSceneVideo) {
        _needsBuild = YES;
        [self setNeedsLayout];
    }
    [self applyLiveSettings];
}

- (void)setPaused:(BOOL)paused {
    if (_paused == paused) return;
    _paused = paused;
    // Standard Core Animation pause: freeze this layer's clock in place.
    CALayer *layer = self.layer;
    if (paused) {
        CFTimeInterval now = [layer convertTime:CACurrentMediaTime() fromLayer:nil];
        layer.speed = 0;
        layer.timeOffset = now;
    } else {
        CFTimeInterval pausedAt = layer.timeOffset;
        layer.speed = 1;
        layer.timeOffset = 0;
        layer.beginTime = 0;
        layer.beginTime = [layer convertTime:CACurrentMediaTime() fromLayer:nil] - pausedAt;
    }
    [self applyLiveSettings];
}

// Speed, dim and play/pause: cheap, no rebuild.
- (void)applyLiveSettings {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _content.speed = _speed;
    _dimLayer.opacity = _dim;
    [CATransaction commit];
    if (_player) {
        _player.volume = _volume;
        _player.muted = _volume <= 0.001;
        if (_paused) [_player pause];
        else _player.rate = _speed;
    }
    [self updateAudio];
    if (_audioPlayer) {
        _audioPlayer.volume = _volume;
        if (_paused) [_audioPlayer pause];
        else if (_audioPlayer.rate == 0) [_audioPlayer play];   // always at normal speed, whatever the scene speed
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    if (size.width < 1 || size.height < 1) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _backdrop.frame = self.bounds;
    _content.frame = self.bounds;
    _dimLayer.frame = self.bounds;
    [CATransaction commit];
    if (_needsBuild || fabs(size.width - _builtSize.width) > 1 || fabs(size.height - _builtSize.height) > 1) {
        _needsBuild = NO;
        _builtSize = size;
        [self build];
    }
}

#pragma mark - Building

- (void)build {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *layer in [_content.sublayers copy]) [layer removeFromSuperlayer];
    [_player pause];
    _player = nil;
    _looper = nil;
    _playerLayer = nil;
    _packageRoots = nil;
    _stateControllers = nil;
    _backdrop.colors = nil;
    _backdrop.hidden = YES;

    switch (_kind) {
        case VLTSceneAurora:    [self buildAurora]; break;
        case VLTSceneFireflies: [self buildFireflies]; break;
        case VLTSceneStarfield: [self buildStarfield]; break;
        case VLTSceneSnow:      [self buildSnow]; break;
        case VLTSceneEmbers:    [self buildEmbers]; break;
        case VLTSceneBubbles:   [self buildBubbles]; break;
        case VLTSceneVideo:     [self buildVideo]; break;
        case VLTSceneTendies:   [self buildTendies]; break;
        default: break;
    }
    [CATransaction commit];
    [self applyLiveSettings];
}

- (void)setBackdropColors:(NSArray<UIColor *> *)colors {
    if (_keepsWallpaper) return;
    NSMutableArray *cg = [NSMutableArray array];
    for (UIColor *color in colors) [cg addObject:(id)color.CGColor];
    _backdrop.colors = cg;
    _backdrop.startPoint = CGPointMake(0.5, 0);
    _backdrop.endPoint = CGPointMake(0.5, 1);
    _backdrop.hidden = NO;
}

// How much bigger than a phone screen this view is; particle counts scale with it.
- (CGFloat)areaFactor {
    return (self.bounds.size.width * self.bounds.size.height) / (390.0 * 844.0);
}

- (CGFloat)widthFactor {
    return self.bounds.size.width / 390.0;
}

+ (UIImage *)glowImage {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ image = [self radialImageWithColor:[UIColor whiteColor] size:64 solidCore:0.12]; });
    return image;
}

// Soft round dot: opaque up to `core` of the radius, then fading to clear.
+ (UIImage *)radialImageWithColor:(UIColor *)color size:(CGFloat)size solidCore:(CGFloat)core {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(id)color.CGColor, (id)color.CGColor, (id)[color colorWithAlphaComponent:0].CGColor];
        CGFloat locations[] = {0, core, 1};
        CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, locations);
        CGPoint center = CGPointMake(size / 2, size / 2);
        CGContextDrawRadialGradient(context.CGContext, gradient, center, 0, center, size / 2, 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
    }];
}

+ (UIImage *)bubbleImage {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = 1;
        format.opaque = NO;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(64, 64) format:format];
        image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [[UIColor colorWithWhite:1 alpha:0.10] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(3, 3, 58, 58)] fill];
            UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(3, 3, 58, 58)];
            ring.lineWidth = 2.5;
            [[UIColor colorWithWhite:1 alpha:0.75] setStroke];
            [ring stroke];
            [[UIColor colorWithWhite:1 alpha:0.8] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(17, 14, 11, 8)] fill];
        }];
    });
    return image;
}

- (CAEmitterLayer *)emitterWithCells:(NSArray<CAEmitterCell *> *)cells additive:(BOOL)additive prewarm:(CFTimeInterval)seconds {
    CAEmitterLayer *emitter = [CAEmitterLayer layer];
    emitter.frame = _content.bounds;
    emitter.emitterCells = cells;
    if (additive) emitter.renderMode = kCAEmitterLayerAdditive;
    emitter.seed = arc4random();
    [_content addSublayer:emitter];
    // Start "in the past" so the screen is already populated on first show.
    emitter.beginTime = [emitter convertTime:CACurrentMediaTime() fromLayer:nil] - seconds;
    return emitter;
}

// A particle that fades in, then shrinks away to nothing at the end of its life.
- (CAEmitterCell *)glowCellWithColor:(UIColor *)color rate:(float)rate life:(float)life scale:(CGFloat)scale {
    CAEmitterCell *cell = [CAEmitterCell emitterCell];
    cell.contents = (id)[VLTSceneView glowImage].CGImage;
    cell.birthRate = rate;
    cell.lifetime = life;
    cell.lifetimeRange = life * 0.3;
    cell.color = [color colorWithAlphaComponent:0].CGColor;
    cell.alphaSpeed = 2.5 / life;                 // full strength after ~40 % of its life
    cell.scale = scale;
    cell.scaleRange = scale * 0.3;
    cell.scaleSpeed = -scale / (life * 1.3);
    return cell;
}

- (void)fillRectEmitter:(CAEmitterLayer *)emitter {
    emitter.emitterShape = kCAEmitterLayerRectangle;
    emitter.emitterMode = kCAEmitterLayerSurface;
    emitter.emitterPosition = CGPointMake(CGRectGetMidX(_content.bounds), CGRectGetMidY(_content.bounds));
    emitter.emitterSize = _content.bounds.size;
}

- (void)lineEmitter:(CAEmitterLayer *)emitter atY:(CGFloat)y {
    emitter.emitterShape = kCAEmitterLayerLine;
    emitter.emitterPosition = CGPointMake(CGRectGetMidX(_content.bounds), y);
    emitter.emitterSize = CGSizeMake(_content.bounds.size.width * 1.1, 1);
}

#pragma mark Scenes

- (void)buildAurora {
    [self setBackdropColors:@[RGB(4, 9, 28), RGB(9, 28, 58), RGB(5, 16, 30)]];
    CGSize size = _content.bounds.size;
    CGFloat span = MAX(size.width, size.height);
    NSArray *colors = @[RGB(60, 255, 176), RGB(51, 200, 255), RGB(155, 93, 229), RGB(40, 230, 200)];
    // Slow, wide glows drifting across the upper two thirds of the screen.
    CGFloat paths[4][8] = {
        {0.15, 0.20, 0.70, 0.30, 0.45, 0.50, 0.10, 0.35},
        {0.85, 0.35, 0.30, 0.15, 0.60, 0.45, 0.90, 0.25},
        {0.50, 0.60, 0.80, 0.50, 0.20, 0.65, 0.55, 0.40},
        {0.30, 0.10, 0.75, 0.20, 0.50, 0.30, 0.15, 0.15},
    };
    for (int i = 0; i < 4; i++) {
        CALayer *blob = [CALayer layer];
        CGFloat diameter = span * (0.85 + 0.12 * i);
        blob.bounds = CGRectMake(0, 0, diameter, diameter * 0.75);
        blob.contents = (id)[VLTSceneView radialImageWithColor:colors[i] size:160 solidCore:0.05].CGImage;
        blob.opacity = 0.55;
        blob.position = CGPointMake(paths[i][0] * size.width, paths[i][1] * size.height);
        [_content addSublayer:blob];

        NSMutableArray *points = [NSMutableArray array];
        for (int p = 0; p < 4; p++)
            [points addObject:[NSValue valueWithCGPoint:CGPointMake(paths[i][p * 2] * size.width, paths[i][p * 2 + 1] * size.height)]];
        [points addObject:points.firstObject];
        CAKeyframeAnimation *drift = [CAKeyframeAnimation animationWithKeyPath:@"position"];
        drift.values = points;
        drift.calculationMode = kCAAnimationCubicPaced;
        drift.duration = 22 + i * 5;
        drift.repeatCount = HUGE_VALF;
        drift.removedOnCompletion = NO;
        [blob addAnimation:drift forKey:@"drift"];

        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
        pulse.fromValue = @0.30;
        pulse.toValue = @0.70;
        pulse.duration = 6 + i * 1.7;
        pulse.autoreverses = YES;
        pulse.repeatCount = HUGE_VALF;
        pulse.removedOnCompletion = NO;
        pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [blob addAnimation:pulse forKey:@"pulse"];
    }
    // A few faint stars so the sky does not look empty.
    CAEmitterCell *star = [self glowCellWithColor:[UIColor whiteColor] rate:2.5 * [self areaFactor] life:6 scale:0.07];
    [self fillRectEmitter:[self emitterWithCells:@[star] additive:YES prewarm:6]];
}

- (void)buildFireflies {
    [self setBackdropColors:@[RGB(4, 12, 28), RGB(8, 34, 38), RGB(14, 44, 30)]];
    CAEmitterCell *fly = [self glowCellWithColor:RGB(214, 255, 102) rate:3.2 * [self areaFactor] life:8 scale:0.34];
    fly.velocity = 14;
    fly.velocityRange = 12;
    fly.emissionRange = 2 * M_PI;
    fly.yAcceleration = -1.5;
    CAEmitterCell *warm = [self glowCellWithColor:RGB(255, 214, 92) rate:1.2 * [self areaFactor] life:9 scale:0.24];
    warm.velocity = 10;
    warm.velocityRange = 10;
    warm.emissionRange = 2 * M_PI;
    [self fillRectEmitter:[self emitterWithCells:@[fly, warm] additive:YES prewarm:9]];
}

- (void)buildStarfield {
    [self setBackdropColors:@[RGB(2, 1, 17), RGB(11, 16, 38), RGB(27, 31, 75)]];
    CAEmitterCell *small = [self glowCellWithColor:[UIColor whiteColor] rate:14 * [self areaFactor] life:5 scale:0.07];
    CAEmitterCell *blue = [self glowCellWithColor:RGB(170, 205, 255) rate:3 * [self areaFactor] life:7 scale:0.14];
    CAEmitterCell *gold = [self glowCellWithColor:RGB(255, 225, 170) rate:1.5 * [self areaFactor] life:7 scale:0.17];
    for (CAEmitterCell *cell in @[small, blue, gold]) {
        cell.velocity = 2;
        cell.emissionRange = 2 * M_PI;
    }
    [self fillRectEmitter:[self emitterWithCells:@[small, blue, gold] additive:YES prewarm:7]];
}

- (void)buildSnow {
    [self setBackdropColors:@[RGB(22, 34, 62), RGB(58, 86, 128), RGB(132, 160, 196)]];
    CGFloat height = _content.bounds.size.height;
    NSMutableArray *cells = [NSMutableArray array];
    // Three depths: far flakes are small and slow, near ones large and fast.
    CGFloat specs[3][4] = {{0.10, 38, 0.55, 7}, {0.18, 62, 0.80, 5}, {0.30, 95, 0.95, 2.5}};   // scale, speed, alpha, rate
    for (int i = 0; i < 3; i++) {
        CAEmitterCell *flake = [CAEmitterCell emitterCell];
        flake.contents = (id)[VLTSceneView glowImage].CGImage;
        flake.birthRate = specs[i][3] * [self widthFactor];
        flake.velocity = specs[i][1];
        flake.velocityRange = specs[i][1] * 0.25;
        flake.lifetime = height / (specs[i][1] * 0.75) + 1;
        flake.emissionLongitude = M_PI_2;          // straight down
        flake.emissionRange = M_PI / 9;
        flake.xAcceleration = 2.5;
        flake.scale = specs[i][0];
        flake.scaleRange = specs[i][0] * 0.4;
        flake.color = [UIColor colorWithWhite:1 alpha:specs[i][2]].CGColor;
        [cells addObject:flake];
    }
    CAEmitterLayer *emitter = [self emitterWithCells:cells additive:NO prewarm:height / 40 + 2];
    [self lineEmitter:emitter atY:-12];
}

- (void)buildEmbers {
    [self setBackdropColors:@[RGB(9, 4, 10), RGB(40, 12, 22), RGB(104, 34, 10)]];
    CGFloat height = _content.bounds.size.height;
    NSMutableArray *cells = [NSMutableArray array];
    NSArray *colors = @[RGB(255, 140, 40), RGB(255, 90, 30), RGB(255, 200, 90)];
    for (int i = 0; i < 3; i++) {
        CAEmitterCell *ember = [CAEmitterCell emitterCell];
        ember.contents = (id)[VLTSceneView glowImage].CGImage;
        ember.birthRate = (i == 2 ? 2.0 : 4.5) * [self widthFactor];
        ember.velocity = 60 + i * 18;
        ember.velocityRange = 30;
        ember.lifetime = MIN(11, height / 75.0);
        ember.lifetimeRange = 2.5;
        ember.emissionLongitude = -M_PI_2;         // straight up
        ember.emissionRange = M_PI / 5;
        ember.yAcceleration = -6;
        ember.xAcceleration = (i - 1) * 5;
        ember.scale = 0.16 + 0.05 * i;
        ember.scaleRange = 0.08;
        ember.scaleSpeed = -0.018;
        ember.color = ((UIColor *)colors[i]).CGColor;
        ember.alphaSpeed = -0.11;
        [cells addObject:ember];
    }
    CAEmitterLayer *emitter = [self emitterWithCells:cells additive:YES prewarm:10];
    [self lineEmitter:emitter atY:height + 12];
}

- (void)buildBubbles {
    [self setBackdropColors:@[RGB(6, 36, 62), RGB(14, 92, 136), RGB(46, 166, 202)]];
    CGFloat height = _content.bounds.size.height;
    CAEmitterCell *bubble = [CAEmitterCell emitterCell];
    bubble.contents = (id)[VLTSceneView bubbleImage].CGImage;
    bubble.birthRate = 2.6 * [self widthFactor];
    bubble.velocity = 55;
    bubble.velocityRange = 25;
    bubble.lifetime = height / 40.0 + 1;
    bubble.emissionLongitude = -M_PI_2;
    bubble.emissionRange = M_PI / 14;
    bubble.yAcceleration = -3;
    bubble.scale = 0.45;
    bubble.scaleRange = 0.35;
    bubble.scaleSpeed = 0.02;
    bubble.color = [UIColor colorWithWhite:1 alpha:0.8].CGColor;
    bubble.alphaRange = 0.3;
    CAEmitterLayer *emitter = [self emitterWithCells:@[bubble] additive:NO prewarm:height / 40.0];
    [self lineEmitter:emitter atY:height + 30];
}

- (void)buildVideo {
    if (!_videoPath.length || ![[NSFileManager defaultManager] isReadableFileAtPath:_videoPath]) return;
    _backdrop.colors = @[(id)[UIColor blackColor].CGColor, (id)[UIColor blackColor].CGColor];
    _backdrop.hidden = NO;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:_videoPath] options:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) return;

    // Silent by default: with no audio track the player never touches the
    // audio session, so music and calls are left alone. The sound track is
    // only added when the user asked for wallpaper sound.
    AVMutableComposition *composition = [AVMutableComposition composition];
    AVMutableCompositionTrack *video = [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                                                                preferredTrackID:kCMPersistentTrackID_Invalid];
    NSError *error = nil;
    if (![video insertTimeRange:track.timeRange ofTrack:track atTime:kCMTimeZero error:&error]) return;
    video.preferredTransform = track.preferredTransform;   // keeps portrait videos upright

    BOOL useVideoSound = _volume > 0.001 && ![self hasOwnSound];
    AVAssetTrack *soundTrack = useVideoSound ? [asset tracksWithMediaType:AVMediaTypeAudio].firstObject : nil;
    if (soundTrack) {
        AVMutableCompositionTrack *sound = [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                    preferredTrackID:kCMPersistentTrackID_Invalid];
        [sound insertTimeRange:track.timeRange ofTrack:soundTrack atTime:kCMTimeZero error:NULL];
        VLTUseAmbientAudio();
    }

    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:composition];
    _player = [AVQueuePlayer queuePlayerWithItems:@[]];
    _player.muted = (soundTrack == nil);
    _player.volume = soundTrack ? _volume : 0;
    _player.allowsExternalPlayback = NO;
    _player.preventsDisplaySleepDuringVideoPlayback = NO;   // let the device auto-lock as usual
    _player.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;
    _looper = [AVPlayerLooper playerLooperWithPlayer:_player templateItem:item];

    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
    // Size the layer to the video's own shape, then scale it like any picture.
    CGSize natural = CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform);
    natural = CGSizeMake(fabs(natural.width), fabs(natural.height));
    if (natural.width < 1 || natural.height < 1) natural = _content.bounds.size;
    CGSize videoScale = [self scaleForDesignSize:natural];
    _playerLayer.videoGravity = AVLayerVideoGravityResize;
    _playerLayer.bounds = CGRectMake(0, 0, natural.width * videoScale.width, natural.height * videoScale.height);
    _playerLayer.position = CGPointMake(CGRectGetMidX(_content.bounds), CGRectGetMidY(_content.bounds));
    [_content addSublayer:_playerLayer];
    if (!_paused) [_player play];
}

#pragma mark .tendies

static BOOL VLTIsDirectory(NSString *path) {
    BOOL directory = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&directory] && directory;
}

+ (NSArray<NSString *> *)packagePathsInFolder:(NSString *)folder {
    if (!folder.length || !VLTIsDirectory(folder)) return @[];
    NSFileManager *files = [NSFileManager defaultManager];
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *byParent = [NSMutableDictionary dictionary];
    NSDirectoryEnumerator *walker = [files enumeratorAtPath:folder];
    for (NSString *relative in walker) {
        if (![relative.pathExtension.lowercaseString isEqualToString:@"ca"]) continue;
        NSString *path = [folder stringByAppendingPathComponent:relative];
        if (!VLTIsDirectory(path) || ![files fileExistsAtPath:[path stringByAppendingPathComponent:@"main.caml"]]) continue;
        [walker skipDescendants];
        NSString *parent = path.stringByDeletingLastPathComponent;
        if (!byParent[parent]) byParent[parent] = [NSMutableArray array];
        [byParent[parent] addObject:path];
    }
    if (!byParent.count) return @[];
    // A file can hold several wallpapers; use the first one.
    NSString *first = [byParent.allKeys sortedArrayUsingSelector:@selector(compare:)].firstObject;
    NSInteger (^depth)(NSString *) = ^NSInteger(NSString *path) {
        NSString *name = path.lastPathComponent.lowercaseString;
        if ([name containsString:@"back"] || [name hasPrefix:@"bg"]) return 0;
        if ([name containsString:@"float"] || [name containsString:@"fore"] || [name hasPrefix:@"fg"]) return 2;
        return 1;
    };
    return [byParent[first] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger da = depth(a), db = depth(b);
        if (da != db) return da < db ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];
}

+ (NSString *)videoPathInFolder:(NSString *)folder {
    if (!folder.length || !VLTIsDirectory(folder)) return nil;
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *relative in [[NSFileManager defaultManager] enumeratorAtPath:folder]) {
        if ([@[@"mp4", @"mov", @"m4v"] containsObject:relative.pathExtension.lowercaseString])
            [found addObject:[folder stringByAppendingPathComponent:relative]];
    }
    return [found sortedArrayUsingSelector:@selector(compare:)].firstObject;
}

- (void)buildTendies {
    Class packageClass = NSClassFromString(@"CAPackage");
    if (!packageClass) return;
    _packageRoots = [NSMutableArray array];
    _stateControllers = [NSMutableArray array];
    CGSize size = _content.bounds.size;
    UIColor *edgeColor = nil;

    for (NSString *path in [VLTSceneView packagePathsInFolder:_videoPath]) {
        CALayer *root = nil;
        BOOL flipped = NO;
        @try {
            NSError *error = nil;
            CAPackage *package = [packageClass packageWithContentsOfURL:[NSURL fileURLWithPath:path isDirectory:YES]
                                                                   type:kCAPackageTypeCAMLBundle options:nil error:&error];
            root = package.rootLayer;
            flipped = package.isGeometryFlipped;
            if (!root) NSLog(@"[Volta] could not load %@: %@", path.lastPathComponent, error);
        } @catch (NSException *e) {
            NSLog(@"[Volta] could not load %@: %@", path.lastPathComponent, e);
        }
        if (!root) continue;

        // Wallpapers are authored for one screen size; scale to cover ours.
        CGSize design = root.bounds.size;
        if (design.width < 1 || design.height < 1) design = CGSizeMake(390, 844);
        CALayer *holder = [CALayer layer];
        holder.bounds = CGRectMake(0, 0, design.width, design.height);
        holder.geometryFlipped = flipped;
        root.anchorPoint = CGPointMake(0.5, 0.5);
        root.position = CGPointMake(design.width / 2, design.height / 2);
        [holder addSublayer:root];
        CGSize scale = [self scaleForDesignSize:design];
        holder.position = CGPointMake(size.width / 2, size.height / 2);
        holder.transform = CATransform3DMakeScale(scale.width, scale.height, 1);
        holder.masksToBounds = YES;   // nothing the designer parked off-canvas leaks into view
        [_content addSublayer:holder];
        // When the wallpaper does not cover the screen, continue its own background color.
        if (!edgeColor && root.backgroundColor && CGColorGetAlpha(root.backgroundColor) > 0.5)
            edgeColor = [UIColor colorWithCGColor:root.backgroundColor];

        CAStateController *controller = [[NSClassFromString(@"CAStateController") alloc] initWithLayer:root];
        if (controller) {
            @try { [controller setInitialStatesOfLayer:root]; } @catch (__unused NSException *e) {}
            [_packageRoots addObject:root];
            [_stateControllers addObject:controller];
        }
    }
    if (_content.sublayers.count && !_keepsWallpaper) {
        UIColor *fill = edgeColor ?: [UIColor blackColor];
        _backdrop.colors = @[(id)fill.CGColor, (id)fill.CGColor];
        _backdrop.hidden = NO;
    }
    NSString *state = _wallpaperState;
    _wallpaperState = nil;
    if (state) [self setWallpaperState:state];
}

static void VLTApplyState(CAStateController *controller, CALayer *layer, NSString *name) {
    if ([layer respondsToSelector:@selector(stateWithName:)]) {
        id state = [layer stateWithName:name];
        if (state) [controller setState:state ofLayer:layer transitionSpeed:1.0];
    }
    for (CALayer *child in layer.sublayers) VLTApplyState(controller, child, name);
}

- (void)setWallpaperState:(NSString *)name {
    if (!name.length || [name isEqualToString:_wallpaperState]) return;
    _wallpaperState = [name copy];
    for (NSUInteger i = 0; i < _stateControllers.count; i++) {
        @try { VLTApplyState(_stateControllers[i], _packageRoots[i], name); } @catch (__unused NSException *e) {}
    }
}

@end
