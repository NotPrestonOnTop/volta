//
//  VLTScene.h
//  The animated wallpaper view. Shared by the SpringBoard tweak (the real
//  wallpaper) and the Settings pane (the live preview).
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, VLTSceneKind) {
    VLTSceneNone      = 0,
    VLTSceneAurora    = 1,
    VLTSceneFireflies = 2,
    VLTSceneStarfield = 3,
    VLTSceneSnow      = 4,
    VLTSceneEmbers    = 5,
    VLTSceneBubbles   = 6,
    VLTSceneVideo     = 100,
    VLTSceneTendies   = 101,   // Core Animation packages from an imported .tendies file
};

#define VLT_MAX_WALLPAPER_VOLUME 0.40   // hard ceiling for wallpaper sound

@interface VLTSceneView : UIView
@property (nonatomic) NSInteger kind;
@property (nonatomic) BOOL keepsWallpaper;          // YES: no backdrop, particles float over what is behind
@property (nonatomic) CGFloat speed;                // 0.5 - 2.0
@property (nonatomic) CGFloat dim;                  // 0 - 0.8
@property (nonatomic, copy) NSString *videoPath;    // VLTSceneVideo: the file. VLTSceneTendies: the unpacked folder.
@property (nonatomic) CGFloat volume;               // sound, 0 (silent) ... VLT_MAX_WALLPAPER_VOLUME
@property (nonatomic, copy) NSString *audioPath;    // optional sound file; replaces a video's own sound and works with any scene
// How My Video and My Tendies are sized to the screen.
// 0 automatic (fill, unless that would crop away most of the picture; then fit),
// 1 fill (crop the overflow), 2 fit (show everything), 3 stretch.
@property (nonatomic) NSInteger fitMode;
@property (nonatomic) CGFloat zoom;                 // 0.5 - 2.0, on top of fitMode
@property (nonatomic) BOOL paused;
// Applies every setting at once and rebuilds only if something changed.
- (void)configureWithKind:(NSInteger)kind keepsWallpaper:(BOOL)keeps speed:(CGFloat)speed dim:(CGFloat)dim videoPath:(NSString *)path generation:(NSInteger)generation;
+ (NSString *)nameForKind:(NSInteger)kind;

// .tendies wallpapers define named states: "Locked", "Unlock" and "Sleep".
// Moving between them plays the wallpaper's own transition.
- (void)setWallpaperState:(NSString *)name;
// The ".ca" packages of the first wallpaper found under folder, back to front.
+ (NSArray<NSString *> *)packagePathsInFolder:(NSString *)folder;
// The first video file found under folder (video-based .tendies), or nil.
+ (NSString *)videoPathInFolder:(NSString *)folder;
@end
