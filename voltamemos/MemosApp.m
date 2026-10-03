//
//  Voice Memos (part of Volta). Records .m4a files with AVAudioRecorder,
//  lists them newest first, and plays them back with AVAudioPlayer.
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

static const CGFloat kRowHeight = 64, kOpenRowHeight = 172;

static NSString *MemoTime(NSTimeInterval t) {
    if (!isfinite(t) || t < 0) t = 0;
    long seconds = (long)t;
    return [NSString stringWithFormat:@"%ld:%02ld", seconds / 60, seconds % 60];
}

static BOOL MemoCanWrite(NSString *folder) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL]) return NO;
    NSString *probe = [folder stringByAppendingPathComponent:@".volta-probe"];
    if (![[NSData data] writeToFile:probe atomically:NO]) return NO;
    [fm removeItemAtPath:probe error:NULL];
    return YES;
}

// Where recordings live: the shared folder if we can write there, else the app's own folders.
static NSURL *MemoFolder(void) {
    static NSURL *folder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *choices = [NSMutableArray arrayWithObject:@"/var/mobile/Documents/Volta Memos"];
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (documents) [choices addObject:documents];
        NSString *chosen = NSTemporaryDirectory();
        for (NSString *path in choices) {
            if (MemoCanWrite(path)) { chosen = path; break; }
        }
        folder = [NSURL fileURLWithPath:chosen isDirectory:YES];
    });
    return folder;
}

@interface Memo : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSDate *date;
@property (nonatomic) NSTimeInterval duration;
@end

@implementation Memo
- (NSString *)fileName { return self.url.lastPathComponent; }
- (NSString *)title { return [self.url.lastPathComponent stringByDeletingPathExtension]; }
@end

// Round record button: a ring with a red dot that becomes a rounded square while recording.
@interface MemoRecordButton : UIControl
@property (nonatomic) BOOL recording;
@end

@implementation MemoRecordButton {
    UIView *_dot;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
        _dot = [[UIView alloc] init];
        _dot.backgroundColor = [UIColor systemRedColor];
        _dot.layer.cornerCurve = kCACornerCurveContinuous;
        _dot.userInteractionEnabled = NO;
        [self addSubview:_dot];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.accessibilityLabel = @"Record";
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat size = MIN(self.bounds.size.width, self.bounds.size.height);
    CGFloat dot = self.recording ? size * 0.40 : size - 14;
    _dot.bounds = CGRectMake(0, 0, dot, dot);
    _dot.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    _dot.layer.cornerRadius = self.recording ? size * 0.08 : dot / 2;
}

- (void)drawRect:(CGRect)rect {
    CGFloat size = MIN(self.bounds.size.width, self.bounds.size.height);
    CGRect ring = CGRectMake((self.bounds.size.width - size) / 2 + 1.5, (self.bounds.size.height - size) / 2 + 1.5, size - 3, size - 3);
    UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:ring];
    path.lineWidth = 3;
    [[UIColor labelColor] setStroke];
    [path stroke];
}

- (void)setRecording:(BOOL)recording {
    if (_recording == recording) return;
    _recording = recording;
    self.accessibilityLabel = recording ? @"Stop" : @"Record";
    [self setNeedsLayout];
    [UIView animateWithDuration:0.2 animations:^{ [self layoutIfNeeded]; }];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    _dot.alpha = highlighted ? 0.6 : 1;
}
@end

// Scrolling level meter: one rounded bar per sample, newest on the right.
@interface MemoWaveView : UIView
- (void)push:(CGFloat)level;
- (void)reset;
@end

@implementation MemoWaveView {
    NSMutableArray<NSNumber *> *_levels;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _levels = [NSMutableArray array];
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
        self.isAccessibilityElement = NO;
    }
    return self;
}

- (void)push:(CGFloat)level {
    [_levels addObject:@(MAX(0, MIN(1, level)))];
    if (_levels.count > 400) [_levels removeObjectsInRange:NSMakeRange(0, _levels.count - 400)];
    [self setNeedsDisplay];
}

- (void)reset {
    [_levels removeAllObjects];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    const CGFloat bar = 3, step = 6;
    CGFloat height = self.bounds.size.height;
    NSInteger slots = (NSInteger)floor((self.bounds.size.width + (step - bar)) / step);
    CGFloat x0 = self.bounds.size.width - slots * step + (step - bar);
    for (NSInteger slot = 0; slot < slots; slot++) {
        // Slots with no sample yet are drawn as quiet dots.
        NSInteger index = (NSInteger)_levels.count - slots + slot;
        BOOL live = index >= 0;
        CGFloat h = live ? MAX(bar, _levels[index].doubleValue * height) : bar;
        [(live ? [UIColor systemRedColor] : [UIColor tertiaryLabelColor]) setFill];
        CGRect frame = CGRectMake(x0 + slot * step, (height - h) / 2, bar, h);
        [[UIBezierPath bezierPathWithRoundedRect:frame cornerRadius:bar / 2] fill];
    }
}
@end

// A recording row. The playback controls sit below the text and show when the row is open.
@interface MemoCell : UITableViewCell
@property (nonatomic, readonly) UILabel *nameLabel, *detailLabel, *elapsedLabel, *remainingLabel;
@property (nonatomic, readonly) UISlider *slider;
@property (nonatomic, readonly) UIButton *backButton, *playButton, *forwardButton;
@property (nonatomic) BOOL open;
@end

@implementation MemoCell

- (UILabel *)labelWithFont:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.font = font;
    label.textColor = color;
    [self.contentView addSubview:label];
    return label;
}

- (UIButton *)buttonWithSymbol:(NSString *)symbol size:(CGFloat)size label:(NSString *)label {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightMedium];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
    button.tintColor = [UIColor labelColor];
    button.accessibilityLabel = label;
    [self.contentView addSubview:button];
    return button;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if ((self = [super initWithStyle:style reuseIdentifier:identifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.contentView.clipsToBounds = YES;
        UIFont *small = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
        _nameLabel = [self labelWithFont:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold] color:[UIColor labelColor]];
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _detailLabel = [self labelWithFont:[UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular]
                                     color:[UIColor secondaryLabelColor]];
        _elapsedLabel = [self labelWithFont:small color:[UIColor secondaryLabelColor]];
        _remainingLabel = [self labelWithFont:small color:[UIColor secondaryLabelColor]];
        _remainingLabel.textAlignment = NSTextAlignmentRight;
        _slider = [[UISlider alloc] init];
        _slider.minimumTrackTintColor = [UIColor systemRedColor];
        _slider.accessibilityLabel = @"Position";
        [self.contentView addSubview:_slider];
        _backButton = [self buttonWithSymbol:@"gobackward.15" size:22 label:@"Back 15 seconds"];
        _playButton = [self buttonWithSymbol:@"play.fill" size:28 label:@"Play"];
        _forwardButton = [self buttonWithSymbol:@"goforward.15" size:22 label:@"Forward 15 seconds"];
    }
    return self;
}

- (void)setOpen:(BOOL)open {
    _open = open;
    for (UIView *view in @[_slider, _elapsedLabel, _remainingLabel, _backButton, _playButton, _forwardButton]) view.hidden = !open;
}

- (void)setPlaying:(BOOL)playing {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightMedium];
    [_playButton setImage:[UIImage systemImageNamed:playing ? @"pause.fill" : @"play.fill" withConfiguration:config]
                 forState:UIControlStateNormal];
    _playButton.accessibilityLabel = playing ? @"Pause" : @"Play";
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIEdgeInsets margins = self.contentView.layoutMargins;
    CGFloat x = margins.left, width = self.contentView.bounds.size.width - margins.left - margins.right;
    _nameLabel.frame = CGRectMake(x, 11, width, 22);
    _detailLabel.frame = CGRectMake(x, 35, width, 18);
    _slider.frame = CGRectMake(x, kRowHeight + 2, width, 30);
    _elapsedLabel.frame = CGRectMake(x, kRowHeight + 32, width / 2, 16);
    _remainingLabel.frame = CGRectMake(x + width / 2, kRowHeight + 32, width / 2, 16);
    CGFloat middle = x + width / 2, y = kRowHeight + 52;
    _playButton.frame = CGRectMake(middle - 30, y, 60, 48);
    _backButton.frame = CGRectMake(middle - 30 - 76, y, 60, 48);
    _forwardButton.frame = CGRectMake(middle + 30 + 16, y, 60, 48);
}
@end

@interface MemosViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, AVAudioRecorderDelegate, AVAudioPlayerDelegate>
@end

@implementation MemosViewController {
    UITableView *_table;
    UILabel *_emptyLabel, *_timeLabel, *_messageLabel;
    UIVisualEffectView *_panel;
    UIView *_panelLine;
    MemoWaveView *_wave;
    MemoRecordButton *_recordButton;
    NSMutableArray<Memo *> *_memos;
    NSString *_openName;          // file name of the open row, if any
    AVAudioPlayer *_player;
    AVAudioRecorder *_recorder;
    NSTimer *_playTimer, *_meterTimer;
    NSDateFormatter *_dateFormatter;
    BOOL _micDenied;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Voice Memos";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    _memos = [NSMutableArray array];
    _dateFormatter = [[NSDateFormatter alloc] init];
    _dateFormatter.dateStyle = NSDateFormatterMediumStyle;
    _dateFormatter.timeStyle = NSDateFormatterShortStyle;
    _dateFormatter.doesRelativeDateFormatting = YES;

    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _table.dataSource = self;
    _table.delegate = self;
    [_table registerClass:[MemoCell class] forCellReuseIdentifier:@"memo"];
    [self.view addSubview:_table];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.text = @"No Recordings\n\nTap the red button to record your first voice memo.";
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.textColor = [UIColor secondaryLabelColor];
    _emptyLabel.font = [UIFont systemFontOfSize:17];
    [self.view addSubview:_emptyLabel];

    _panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    [self.view addSubview:_panel];
    _panelLine = [[UIView alloc] init];
    _panelLine.backgroundColor = [UIColor separatorColor];
    _wave = [[MemoWaveView alloc] init];
    _timeLabel = [[UILabel alloc] init];
    _timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:22 weight:UIFontWeightMedium];
    _timeLabel.textColor = [UIColor labelColor];
    _timeLabel.text = @"0:00.0";
    _messageLabel = [[UILabel alloc] init];
    _messageLabel.text = @"Voice Memos needs the microphone. Allow it in Settings > Privacy > Microphone.";
    _messageLabel.numberOfLines = 0;
    _messageLabel.textAlignment = NSTextAlignmentCenter;
    _messageLabel.textColor = [UIColor secondaryLabelColor];
    _messageLabel.font = [UIFont systemFontOfSize:15];
    _messageLabel.adjustsFontSizeToFitWidth = YES;
    _messageLabel.minimumScaleFactor = 0.7;
    _recordButton = [[MemoRecordButton alloc] init];
    [_recordButton addTarget:self action:@selector(recordTapped) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *view in @[_panelLine, _wave, _timeLabel, _messageLabel, _recordButton]) [_panel.contentView addSubview:view];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(wentToBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(cameToForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    [center addObserver:self selector:@selector(interrupted:) name:AVAudioSessionInterruptionNotification object:nil];

    _micDenied = [AVAudioSession sharedInstance].recordPermission == AVAudioSessionRecordPermissionDenied;
    [self updatePanel];
    [self reloadMemos];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_playTimer invalidate];
    [_meterTimer invalidate];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGRect bounds = self.view.bounds;
    // Short screens (a phone on its side) get a one-line panel.
    BOOL compact = bounds.size.height < 500;
    CGFloat panelHeight = compact ? 88 : 200;
    CGFloat width = MIN(bounds.size.width - safe.left - safe.right - 32, 640);
    CGFloat x = safe.left + (bounds.size.width - safe.left - safe.right - width) / 2;

    _table.frame = bounds;
    if (_table.contentInset.bottom != panelHeight) {
        _table.contentInset = _table.verticalScrollIndicatorInsets = UIEdgeInsetsMake(0, 0, panelHeight, 0);
    }
    _panel.frame = CGRectMake(0, bounds.size.height - panelHeight - safe.bottom, bounds.size.width, panelHeight + safe.bottom);
    _panelLine.frame = CGRectMake(0, 0, bounds.size.width, 1 / MAX(1, self.traitCollection.displayScale));
    if (compact) {
        _timeLabel.textAlignment = NSTextAlignmentLeft;
        _timeLabel.frame = CGRectMake(x, 12, 96, 64);
        _wave.frame = CGRectMake(x + 104, 20, MAX(0, width - 104 - 80), 48);
        _recordButton.frame = CGRectMake(x + width - 64, 12, 64, 64);
        _messageLabel.frame = CGRectMake(x, 8, MAX(0, width - 80), 72);
    } else {
        _timeLabel.textAlignment = NSTextAlignmentCenter;
        _wave.frame = CGRectMake(x, 16, width, 56);
        _timeLabel.frame = CGRectMake(x, 78, width, 28);
        _recordButton.frame = CGRectMake(x + (width - 72) / 2, 116, 72, 72);
        _messageLabel.frame = CGRectMake(x, 12, width, 96);
    }
    _emptyLabel.frame = CGRectMake(x, safe.top, width, MAX(0, CGRectGetMinY(_panel.frame) - safe.top));
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *top = self;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    [top presentViewController:alert animated:YES completion:nil];
}

- (NSTimer *)timerEvery:(NSTimeInterval)interval action:(SEL)action {
    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:interval repeats:YES block:^(NSTimer *t) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) { [t invalidate]; return; }
        ((void (*)(id, SEL))[strongSelf methodForSelector:action])(strongSelf, action);
    }];
    // Common modes keep it ticking while the list scrolls.
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    return timer;
}

#pragma mark Recordings on disk

- (void)reloadMemos {
    NSArray<NSURL *> *urls = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:MemoFolder()
                                                           includingPropertiesForKeys:@[NSURLCreationDateKey]
                                                                              options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL];
    NSString *recordingName = _recorder.url.lastPathComponent;
    [_memos removeAllObjects];
    for (NSURL *url in urls) {
        if ([url.pathExtension caseInsensitiveCompare:@"m4a"] != NSOrderedSame) continue;
        if ([url.lastPathComponent isEqualToString:recordingName]) continue;   // still being written
        Memo *memo = [[Memo alloc] init];
        memo.url = url;
        NSDate *date = nil;
        [url getResourceValue:&date forKey:NSURLCreationDateKey error:NULL];
        memo.date = date ?: [NSDate distantPast];
        // A file that cannot be opened just shows 0:00.
        AVAudioPlayer *probe = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:NULL];
        memo.duration = probe ? MAX(0, probe.duration) : 0;
        [_memos addObject:memo];
    }
    [_memos sortUsingComparator:^NSComparisonResult(Memo *a, Memo *b) {
        NSComparisonResult order = [b.date compare:a.date];
        return order != NSOrderedSame ? order : [b.fileName localizedStandardCompare:a.fileName];
    }];
    if (_openName && ![self openMemo]) [self closePlayer];
    [_table reloadData];
    _emptyLabel.hidden = _memos.count > 0;
}

// "Recording N.m4a" with N one above the highest number in use.
- (NSURL *)nextRecordingURL {
    NSInteger highest = 0;
    NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:MemoFolder().path error:NULL];
    for (NSString *name in names) {
        NSString *title = [name stringByDeletingPathExtension];
        if ([title hasPrefix:@"Recording "]) highest = MAX(highest, [[title substringFromIndex:10] integerValue]);
    }
    NSString *name = [NSString stringWithFormat:@"Recording %ld.m4a", (long)highest + 1];
    return [MemoFolder() URLByAppendingPathComponent:name isDirectory:NO];
}

- (NSUInteger)rowOf:(Memo *)memo {
    return [_memos indexOfObjectPassingTest:^BOOL(Memo *other, NSUInteger index, BOOL *stop) {
        return [other.fileName isEqualToString:memo.fileName];
    }];
}

- (Memo *)openMemo {
    for (Memo *memo in _memos) {
        if ([memo.fileName isEqualToString:_openName]) return memo;
    }
    return nil;
}

- (MemoCell *)openCell {
    Memo *memo = [self openMemo];
    if (!memo) return nil;
    NSIndexPath *path = [NSIndexPath indexPathForRow:[self rowOf:memo] inSection:0];
    return (MemoCell *)[_table cellForRowAtIndexPath:path];
}

#pragma mark Recording

- (void)updatePanel {
    BOOL recording = _recorder != nil;
    _recordButton.recording = recording;
    _messageLabel.hidden = !_micDenied || recording;
    _wave.hidden = _timeLabel.hidden = !_messageLabel.hidden;
    if (!recording) {
        _timeLabel.text = @"0:00.0";
        [_wave reset];
    }
}

- (void)recordTapped {
    if (_recorder) { [self stopRecording]; return; }
    __weak typeof(self) weakSelf = self;
    [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_micDenied = !granted;
            [strongSelf updatePanel];
            if (granted) [strongSelf startRecording];
        });
    }];
}

- (void)startRecording {
    if (_recorder || [UIApplication sharedApplication].applicationState == UIApplicationStateBackground) return;
    [self openRowNamed:nil];   // also stops playback

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault
                      options:AVAudioSessionCategoryOptionDefaultToSpeaker error:&error] ||
        ![session setActive:YES error:&error]) {
        [self alert:@"Can't Record" message:error.localizedDescription ?: @"The microphone is not available right now."];
        return;
    }
    NSDictionary *settings = @{AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @44100.0,
                               AVNumberOfChannelsKey: @1, AVEncoderAudioQualityKey: @(AVAudioQualityHigh)};
    NSURL *url = [self nextRecordingURL];
    AVAudioRecorder *recorder = [[AVAudioRecorder alloc] initWithURL:url settings:settings error:&error];
    recorder.delegate = self;
    recorder.meteringEnabled = YES;
    if (!recorder || ![recorder prepareToRecord] || ![recorder record]) {
        [recorder stop];
        [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
        [session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:NULL];
        [self alert:@"Can't Record" message:error.localizedDescription ?: @"The recording could not be started."];
        return;
    }
    _recorder = recorder;
    [self updatePanel];
    _meterTimer = [self timerEvery:0.05 action:@selector(meterTick)];
}

- (void)meterTick {
    if (!_recorder) return;
    [_recorder updateMeters];
    // -50 dB and below is silence, 0 dB is full height.
    [_wave push:([_recorder averagePowerForChannel:0] + 50) / 50];
    NSTimeInterval t = MAX(0, _recorder.currentTime);
    _timeLabel.text = [NSString stringWithFormat:@"%@.%d", MemoTime(t), (int)(fmod(t, 1) * 10)];
}

- (void)stopRecording {
    if (!_recorder) return;
    AVAudioRecorder *recorder = _recorder;
    _recorder = nil;
    [_meterTimer invalidate];
    _meterTimer = nil;
    [recorder stop];
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:NULL];
    // Nothing captured: do not leave an empty file behind.
    NSNumber *size = [[NSFileManager defaultManager] attributesOfItemAtPath:recorder.url.path error:NULL][NSFileSize];
    if (size.unsignedLongLongValue == 0) [[NSFileManager defaultManager] removeItemAtURL:recorder.url error:NULL];
    [self updatePanel];
    [self reloadMemos];
}

// Only reached when the recorder stops by itself; our own stop clears _recorder first.
- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)flag {
    if (recorder != _recorder) return;
    [self stopRecording];
    if (!flag) [self alert:@"Recording Stopped" message:@"The recording ended early and may be incomplete."];
}

- (void)audioRecorderEncodeErrorDidOccur:(AVAudioRecorder *)recorder error:(NSError *)error {
    if (recorder != _recorder) return;
    [self stopRecording];
    [self alert:@"Recording Stopped" message:error.localizedDescription ?: @"The audio could not be saved."];
}

- (void)wentToBackground {
    [self stopRecording];
    [self pausePlayer];
}

- (void)cameToForeground {
    _micDenied = [AVAudioSession sharedInstance].recordPermission == AVAudioSessionRecordPermissionDenied;
    [self updatePanel];
    [self reloadMemos];
    [self refreshPlayback];
}

- (void)interrupted:(NSNotification *)note {
    if ([note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] != AVAudioSessionInterruptionTypeBegan) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf stopRecording];
        [weakSelf pausePlayer];
    });
}

#pragma mark Playback

- (void)pausePlayer {
    [_playTimer invalidate];
    _playTimer = nil;
    if (_player.playing) [_player pause];
    [self refreshPlayback];
}

- (void)closePlayer {
    [self pausePlayer];
    _player.delegate = nil;
    _player = nil;
    _openName = nil;
}

// Opens one row (nil closes them all) and loads its file, paused at the start.
- (void)openRowNamed:(NSString *)name {
    [self closePlayer];
    _openName = [name copy];
    Memo *memo = [self openMemo];
    if (memo) {
        _player = [[AVAudioPlayer alloc] initWithContentsOfURL:memo.url error:NULL];   // nil if unreadable
        _player.delegate = self;
        [_player prepareToPlay];
    }
    for (MemoCell *cell in _table.visibleCells) {
        NSIndexPath *path = [_table indexPathForCell:cell];
        if (path && path.row < (NSInteger)_memos.count) cell.open = [_memos[path.row].fileName isEqualToString:_openName];
    }
    [self refreshPlayback];
    [_table performBatchUpdates:nil completion:nil];   // animate the row heights
}

- (void)refreshPlayback { [self fillControls:[self openCell]]; }

- (void)fillControls:(MemoCell *)cell {
    if (!cell) return;
    NSTimeInterval duration = _player ? _player.duration : 0, now = _player ? _player.currentTime : 0;
    if (!cell.slider.isTracking) cell.slider.value = duration > 0 ? (float)(now / duration) : 0;
    cell.elapsedLabel.text = MemoTime(now);
    cell.remainingLabel.text = [@"-" stringByAppendingString:MemoTime(duration - now)];
    [cell setPlaying:_player.playing];
}

- (void)playTapped {
    if (_recorder) return;
    if (!_player) { [self alert:@"Can't Play" message:@"This recording could not be opened."]; return; }
    if (_player.playing) { [self pausePlayer]; return; }
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&error] || ![session setActive:YES error:&error] || ![_player play]) {
        [self alert:@"Can't Play" message:error.localizedDescription ?: @"This recording could not be played."];
        return;
    }
    [_playTimer invalidate];
    _playTimer = [self timerEvery:1.0 / 30 action:@selector(refreshPlayback)];
    [self refreshPlayback];
}

- (void)seekTo:(NSTimeInterval)time {
    if (!_player) return;
    // Stay just short of the end so a seek never restarts the file.
    _player.currentTime = MAX(0, MIN(time, _player.duration - 0.05));
    [self refreshPlayback];
}

- (void)sliderMoved:(UISlider *)slider { [self seekTo:slider.value * _player.duration]; }
- (void)backTapped { [self seekTo:_player.currentTime - 15]; }
- (void)forwardTapped { [self seekTo:_player.currentTime + 15]; }

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (player != _player) return;
    player.currentTime = 0;
    [self pausePlayer];
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    if (player != _player) return;
    [self pausePlayer];
    [self alert:@"Can't Play" message:error.localizedDescription ?: @"This recording is damaged."];
}

#pragma mark Rename, share, delete

- (void)deleteMemo:(Memo *)memo {
    NSUInteger row = [self rowOf:memo];
    if (row == NSNotFound) return;
    memo = _memos[row];
    if ([memo.fileName isEqualToString:_openName]) [self closePlayer];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    if (![fm removeItemAtURL:memo.url error:&error] && [fm fileExistsAtPath:memo.url.path]) {
        [self alert:@"Can't Delete" message:error.localizedDescription];
        return;
    }
    [_memos removeObjectAtIndex:row];
    [_table deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:0]] withRowAnimation:UITableViewRowAnimationAutomatic];
    _emptyLabel.hidden = _memos.count > 0;
}

- (void)askToRename:(Memo *)memo {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Recording" message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = memo.title;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    }];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf rename:memo to:weakAlert.textFields.firstObject.text];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)rename:(Memo *)memo to:(NSString *)typed {
    NSUInteger row = [self rowOf:memo];
    if (row == NSNotFound) return;
    memo = _memos[row];
    NSString *name = [typed ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([name.lowercaseString hasSuffix:@".m4a"]) name = [name substringToIndex:name.length - 4];
    if ([name isEqualToString:memo.title]) return;
    NSString *problem = nil;
    NSURL *target = [MemoFolder() URLByAppendingPathComponent:[name stringByAppendingString:@".m4a"] isDirectory:NO];
    if (name.length == 0) problem = @"The name can't be empty.";
    else if ([name containsString:@"/"] || [name hasPrefix:@"."]) problem = @"The name can't contain \"/\" or start with a dot.";
    else if ([[NSFileManager defaultManager] fileExistsAtPath:target.path]) problem = @"A recording with that name already exists.";
    NSError *error = nil;
    BOOL wasOpen = [memo.fileName isEqualToString:_openName];
    if (!problem) {
        if (wasOpen) [self pausePlayer];
        if (![[NSFileManager defaultManager] moveItemAtURL:memo.url toURL:target error:&error]) {
            problem = error.localizedDescription ?: @"The file could not be renamed.";
        }
    }
    if (problem) { [self alert:@"Can't Rename" message:problem]; return; }
    memo.url = target;
    if (wasOpen) _openName = memo.fileName;   // the player keeps its open file
    [_table reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)shareMemo:(Memo *)memo {
    NSUInteger row = [self rowOf:memo];
    if (row == NSNotFound) return;
    memo = _memos[row];
    if (![[NSFileManager defaultManager] fileExistsAtPath:memo.url.path]) {
        [self alert:@"Can't Share" message:@"The file for this recording is missing."];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[memo.url] applicationActivities:nil];
    // iPad shows this as a popover and needs something to point at.
    UITableViewCell *cell = [_table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    share.popoverPresentationController.sourceView = cell ?: _recordButton;
    share.popoverPresentationController.sourceRect = cell ? cell.bounds : _recordButton.bounds;
    [self presentViewController:share animated:YES completion:nil];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _memos.count; }

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [_memos[indexPath.row].fileName isEqualToString:_openName] ? kOpenRowHeight : kRowHeight;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MemoCell *cell = [tableView dequeueReusableCellWithIdentifier:@"memo" forIndexPath:indexPath];
    Memo *memo = _memos[indexPath.row];
    BOOL open = [memo.fileName isEqualToString:_openName];
    cell.nameLabel.text = memo.title;
    cell.detailLabel.text = [NSString stringWithFormat:@"%@  ·  %@", [_dateFormatter stringFromDate:memo.date], MemoTime(memo.duration)];
    cell.open = open;
    cell.accessibilityHint = open ? nil : @"Opens the playback controls";
    // Adding the same target twice is a no-op, so reused cells are fine.
    [cell.slider addTarget:self action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
    [cell.playButton addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
    [cell.backButton addTarget:self action:@selector(backTapped) forControlEvents:UIControlEventTouchUpInside];
    [cell.forwardButton addTarget:self action:@selector(forwardTapped) forControlEvents:UIControlEventTouchUpInside];
    if (open) [self fillControls:cell];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_recorder) return;   // playing would break the recording
    NSString *name = _memos[indexPath.row].fileName;
    [self openRowNamed:[name isEqualToString:_openName] ? nil : name];
    if (_openName) [tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionNone animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    Memo *memo = _memos[indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
        handler:^(UIContextualAction *action, UIView *source, void (^done)(BOOL)) {
            [weakSelf deleteMemo:memo];
            done(YES);
        }];
    delete.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                    point:(CGPoint)point {
    Memo *memo = _memos[indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
            UIAction *rename = [UIAction actionWithTitle:@"Rename" image:[UIImage systemImageNamed:@"pencil"] identifier:nil
                                                 handler:^(UIAction *action) { [weakSelf askToRename:memo]; }];
            UIAction *share = [UIAction actionWithTitle:@"Share" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil
                                                handler:^(UIAction *action) { [weakSelf shareMemo:memo]; }];
            UIAction *delete = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"] identifier:nil
                                                 handler:^(UIAction *action) { [weakSelf deleteMemo:memo]; }];
            delete.attributes = UIMenuElementAttributesDestructive;
            return [UIMenu menuWithTitle:@"" children:@[rename, share, delete]];
        }];
}

@end

@interface MemosAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation MemosAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.tintColor = [UIColor systemRedColor];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[[MemosViewController alloc] init]];
    navigation.navigationBar.prefersLargeTitles = YES;
    self.window.rootViewController = navigation;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([MemosAppDelegate class]));
    }
}
