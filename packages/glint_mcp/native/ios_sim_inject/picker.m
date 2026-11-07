#import "camera_feed.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

static NSString *const GPImageType = @"public.image";
static NSString *const GPMovieType = @"public.movie";
static NSString *const GPDeviceName = @"glint simulator camera";
static const NSTimeInterval GPUnsetMaxRecording = 600;
static const NSTimeInterval GPDefaultMaxRecording = 10;
static const int GPMissedFramesBeforeLabel = 8;
static const void *kTakeoverKey = &kTakeoverKey;
static const void *kRequestedTypesKey = &kRequestedTypesKey;
static const void *kRequestedControlsKey = &kRequestedControlsKey;
static const void *kRequestedOverlayKey = &kRequestedOverlayKey;

typedef NS_ENUM(NSInteger, GPMode) { GPModePhoto, GPModeVideo };

static NSInteger GPShownLens(UIImagePickerController *picker) {
  NSInteger wanted = picker.cameraDevice == UIImagePickerControllerCameraDeviceFront ? 1 : 0;
  return GCFeedHasLens(wanted) ? wanted : 1 - wanted;
}

static BOOL GPAnyConforms(NSArray *identifiers, UTType *base) {
  for (NSString *identifier in identifiers) {
    UTType *type = [UTType typeWithIdentifier:identifier];
    if (type && [type conformsToType:base]) return YES;
  }
  return NO;
}

/// UIKit resets `mediaTypes` to images when the source becomes the camera, so the app's own request is kept.
static NSArray *GPMediaTypes(UIImagePickerController *picker) {
  return objc_getAssociatedObject(picker, kRequestedTypesKey) ?: picker.mediaTypes;
}

/// Once the picker has a camera of its own UIKit answers these getters from it, so the app's own settings are kept.
static BOOL GPShowsControls(UIImagePickerController *picker) {
  NSNumber *requested = objc_getAssociatedObject(picker, kRequestedControlsKey);
  return requested ? requested.boolValue : picker.showsCameraControls;
}

static UIView *GPOverlay(UIImagePickerController *picker) {
  id requested = objc_getAssociatedObject(picker, kRequestedOverlayKey);
  if (requested) return [requested isKindOfClass:UIView.class] ? requested : nil;
  return picker.cameraOverlayView;
}

static BOOL GPWantsPhotos(NSArray *types) { return types.count == 0 || GPAnyConforms(types, UTTypeImage); }

static BOOL GPWantsVideo(NSArray *types) { return GPAnyConforms(types, UTTypeMovie); }

static void GPRemoveFile(NSURL *url) { [NSFileManager.defaultManager removeItemAtURL:url error:nil]; }

static NSDictionary *GPPhotoMetadata(UIImage *photo) {
  NSDateFormatter *format = [NSDateFormatter new];
  format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  format.dateFormat = @"yyyy:MM:dd HH:mm:ss";
  NSString *now = [format stringFromDate:NSDate.date];
  NSInteger width = (NSInteger)(photo.size.width * photo.scale), height = (NSInteger)(photo.size.height * photo.scale);
  return @{
    (id)kCGImagePropertyOrientation : @1,
    (id)kCGImagePropertyPixelWidth : @(width),
    (id)kCGImagePropertyPixelHeight : @(height),
    (id)kCGImagePropertyExifDictionary : @{
      (id)kCGImagePropertyExifPixelXDimension : @(width),
      (id)kCGImagePropertyExifPixelYDimension : @(height),
      (id)kCGImagePropertyExifDateTimeOriginal : now,
      (id)kCGImagePropertyExifDateTimeDigitized : now,
    },
    (id)kCGImagePropertyTIFFDictionary : @{
      (id)kCGImagePropertyTIFFOrientation : @1,
      (id)kCGImagePropertyTIFFMake : GPDeviceName,
      (id)kCGImagePropertyTIFFModel : GPDeviceName,
      (id)kCGImagePropertyTIFFDateTime : now,
    },
  };
}

/// What the render queue needs and nothing UIKit owns, so its blocks never hold the controller.
@interface GPPreviewState : NSObject
@property(atomic) uint32_t width;
@property(atomic) uint32_t height;
@property(atomic) NSInteger lens;
@property(nonatomic) int missed;
@property(nonatomic) BOOL labelShown;
@end

@implementation GPPreviewState
@end

static void GPSetLabel(GPPreviewState *state, __weak UILabel *label, BOOL visible) {
  state.labelShown = visible;
  dispatch_async(dispatch_get_main_queue(), ^{ label.hidden = !visible; });
}

static void GPRenderPreview(GPPreviewState *state, __weak UIImageView *view, __weak UILabel *label) {
  CGSize size = CGSizeMake(state.width, state.height);
  if (size.width < 1 || size.height < 1) return;
  NSInteger lens = state.lens;
  UIImage *image = nil;
  CIImage *fit = GCFeedFit(lens, size, lens == 1);
  CGImageRef cg = fit ? [GCFeedContext() createCGImage:fit fromRect:CGRectMake(0, 0, size.width, size.height)] : NULL;
  if (cg) {
    image = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
  }
  if (!image) {
    if (++state.missed >= GPMissedFramesBeforeLabel && !state.labelShown) GPSetLabel(state, label, YES);
    return;
  }
  state.missed = 0;
  if (state.labelShown) GPSetLabel(state, label, NO);
  dispatch_async(dispatch_get_main_queue(), ^{ view.image = image; });
}

@interface GPRecording : NSObject
@property(nonatomic) AVAssetWriter *writer;
@property(nonatomic) AVAssetWriterInput *input;
@property(nonatomic) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property(nonatomic) NSURL *url;
@property(nonatomic) CFAbsoluteTime start;
@property(nonatomic) NSTimeInterval cap;
@property(nonatomic) NSInteger lens;
@property(nonatomic) NSUInteger frames;
@property(nonatomic) NSUInteger token;
@property(atomic) BOOL active;
@end

@implementation GPRecording
@end

/// Appends one feed frame to the recording; true once the time cap is reached.
static BOOL GPAppendFrame(GPRecording *rec) {
  if (!rec.active || !rec.input.readyForMoreMediaData || !rec.adaptor.pixelBufferPool) return NO;
  NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - rec.start;
  if (elapsed >= rec.cap) return YES;
  CVPixelBufferRef buffer = NULL;
  CVPixelBufferPoolCreatePixelBuffer(NULL, rec.adaptor.pixelBufferPool, &buffer);
  if (!buffer) return NO;
  if (GCFeedRenderInto(rec.lens, buffer, NO) && [rec.adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMakeWithSeconds(elapsed, 600)]) {
    rec.frames++;
  }
  CVPixelBufferRelease(buffer);
  return NO;
}

@class GPCaptureController;
static void GPFinishRecording(GPCaptureController *controller, GPRecording *rec);

@interface GPRootView : UIView
@property(nonatomic, copy) void (^onWindowChange)(BOOL attached);
@end

@implementation GPRootView
- (void)didMoveToWindow {
  [super didMoveToWindow];
  if (self.onWindowChange) self.onWindowChange(self.window != nil);
}
@end

@interface GPCaptureController : UIViewController
- (instancetype)initWithPicker:(UIImagePickerController *)picker savedStack:(NSArray *)stack barHidden:(BOOL)barHidden;
- (void)applyConfiguration;
- (void)capturePhoto;
- (BOOL)startRecording;
- (void)stopRecording;
- (void)cancel;
- (void)tearDown;
- (void)recordingFinished:(GPRecording *)rec;
@end

@implementation GPCaptureController {
  __weak UIImagePickerController *_picker;
  NSArray *_savedStack;
  BOOL _savedBarHidden;
  GPRootView *_root;
  UIImageView *_preview;
  UILabel *_noFrame;
  UIView *_placedOverlay;
  UIToolbar *_bar;
  UIButton *_shutter;
  UIView *_disc;
  UISegmentedControl *_modeSwitch;
  NSLayoutConstraint *_previewBottom;
  GPMode _mode;
  BOOL _delivering;
  BOOL _cancelled;
  BOOL _tornDown;
  NSUInteger _captureToken;

  GPPreviewState *_state;
  dispatch_queue_t _renderQueue;
  dispatch_source_t _previewTimer;

  dispatch_queue_t _recordQueue;
  dispatch_source_t _recordTimer;
  GPRecording *_recording;
}

- (instancetype)initWithPicker:(UIImagePickerController *)picker savedStack:(NSArray *)stack barHidden:(BOOL)barHidden {
  if ((self = [super initWithNibName:nil bundle:nil])) {
    _picker = picker;
    _savedStack = stack;
    _savedBarHidden = barHidden;
    _state = [GPPreviewState new];
    _renderQueue = dispatch_queue_create("glint.picker.preview", DISPATCH_QUEUE_SERIAL);
    _recordQueue = dispatch_queue_create("glint.picker.record", DISPATCH_QUEUE_SERIAL);
    _mode = [self initialMode];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(feedChanged) name:GCFeedChangedNotification object:nil];
  }
  return self;
}

- (BOOL)allowsPhoto { return GPWantsPhotos(GPMediaTypes(_picker)); }

- (BOOL)allowsVideo { return GPWantsVideo(GPMediaTypes(_picker)); }

- (GPMode)initialMode {
  if (![self allowsPhoto]) return GPModeVideo;
  return [self allowsVideo] && _picker.cameraCaptureMode == UIImagePickerControllerCameraCaptureModeVideo ? GPModeVideo : GPModePhoto;
}

- (void)loadView {
  _root = [GPRootView new];
  _root.backgroundColor = UIColor.blackColor;
  __weak GPCaptureController *weakSelf = self;
  _root.onWindowChange = ^(BOOL attached) {
    if (attached) {
      [weakSelf startPreview];
    } else {
      [weakSelf stopPreview];
    }
  };
  _preview = [UIImageView new];
  _preview.translatesAutoresizingMaskIntoConstraints = NO;
  _preview.contentMode = UIViewContentModeScaleAspectFit;
  _preview.isAccessibilityElement = NO;
  [_root addSubview:_preview];
  _noFrame = [self noFrameLabel];
  [_root addSubview:_noFrame];
  _previewBottom = [_preview.bottomAnchor constraintEqualToAnchor:_root.bottomAnchor];
  [NSLayoutConstraint activateConstraints:@[
    [_preview.leadingAnchor constraintEqualToAnchor:_root.leadingAnchor],
    [_preview.trailingAnchor constraintEqualToAnchor:_root.trailingAnchor],
    [_preview.topAnchor constraintEqualToAnchor:_root.topAnchor],
    _previewBottom,
    [_noFrame.centerXAnchor constraintEqualToAnchor:_root.centerXAnchor],
    [_noFrame.centerYAnchor constraintEqualToAnchor:_root.centerYAnchor],
  ]];
  self.view = _root;
  [self applyConfiguration];
}

- (UILabel *)noFrameLabel {
  UILabel *label = [UILabel new];
  label.translatesAutoresizingMaskIntoConstraints = NO;
  label.text = @"  No camera frame  ";
  label.accessibilityLabel = @"No camera frame";
  label.textColor = UIColor.whiteColor;
  label.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.9];
  label.font = [UIFont systemFontOfSize:17];
  label.layer.cornerRadius = 8;
  label.clipsToBounds = YES;
  label.hidden = YES;
  return label;
}

/// The render queue owns the label state, so every show request goes through it.
- (void)requestNoFrameLabel {
  GPPreviewState *state = _state;
  __weak UILabel *label = _noFrame;
  dispatch_async(_renderQueue, ^{ GPSetLabel(state, label, YES); });
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGSize bounds = _preview.bounds.size;
  if (bounds.width < 1 || bounds.height < 1) return;
  CGFloat scale = 720.0 / MIN(bounds.width, bounds.height);
  _state.width = (uint32_t)floor(bounds.width * scale);
  _state.height = (uint32_t)floor(bounds.height * scale);
  [self placeOverlay];
}

- (void)applyConfiguration {
  UIImagePickerController *picker = _picker;
  if (!picker || _tornDown || !_root) return;
  if (![self allowsPhoto] && _mode == GPModePhoto) _mode = GPModeVideo;
  if (![self allowsVideo] && _mode == GPModeVideo) _mode = GPModePhoto;
  BOOL controls = GPShowsControls(picker);
  if (controls && !_bar) [self installBar];
  if (!controls && _bar) [self removeBar];
  [self placeOverlay];
  _state.lens = GPShownLens(picker);
  [self updateShutterLook];
  _modeSwitch.selectedSegmentIndex = _mode;
}

- (void)feedChanged {
  if (!GCFeedActive()) {
    [self cancel];
    return;
  }
  [self applyConfiguration];
}

- (void)removePlacedOverlay {
  if (_placedOverlay.superview == _root) [_placedOverlay removeFromSuperview];
  _placedOverlay = nil;
}

- (void)placeOverlay {
  UIView *overlay = GPShowsControls(_picker) ? nil : GPOverlay(_picker);
  if (_placedOverlay && _placedOverlay != overlay) [self removePlacedOverlay];
  if (!overlay || _placedOverlay == overlay || CGRectIsEmpty(_root.bounds)) return;
  [_root addSubview:overlay];
  _placedOverlay = overlay;
  [_root bringSubviewToFront:_noFrame];
}

- (void)installBar {
  _bar = [self controlBar];
  [_root addSubview:_bar];
  [_root bringSubviewToFront:_noFrame];
  _previewBottom.active = NO;
  _previewBottom = [_preview.bottomAnchor constraintEqualToAnchor:_bar.topAnchor];
  [NSLayoutConstraint activateConstraints:@[
    _previewBottom,
    [_bar.leadingAnchor constraintEqualToAnchor:_root.leadingAnchor],
    [_bar.trailingAnchor constraintEqualToAnchor:_root.trailingAnchor],
    [_bar.bottomAnchor constraintEqualToAnchor:_root.safeAreaLayoutGuide.bottomAnchor],
    [_bar.heightAnchor constraintEqualToConstant:110],
  ]];
}

- (void)removeBar {
  [_bar removeFromSuperview];
  _bar = nil;
  _shutter = nil;
  _disc = nil;
  _modeSwitch = nil;
  _previewBottom.active = NO;
  _previewBottom = [_preview.bottomAnchor constraintEqualToAnchor:_root.bottomAnchor];
  _previewBottom.active = YES;
}

- (UIToolbar *)controlBar {
  UIToolbar *bar = [UIToolbar new];
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  UIToolbarAppearance *look = [UIToolbarAppearance new];
  [look configureWithOpaqueBackground];
  look.backgroundColor = UIColor.blackColor;
  bar.standardAppearance = look;
  bar.scrollEdgeAppearance = look;
  bar.accessibilityIdentifier = @"Camera";
  UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithTitle:@"Cancel" style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
  cancel.tintColor = UIColor.whiteColor;
  cancel.accessibilityLabel = @"Cancel";
  UIBarButtonItem *shutter = [[UIBarButtonItem alloc] initWithCustomView:[self shutterButton]];
  UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
  bar.items = @[ cancel, flex, shutter, flex, [self trailingItem] ];
  return bar;
}

- (UIBarButtonItem *)trailingItem {
  if ([self allowsPhoto] && [self allowsVideo]) {
    _modeSwitch = [[UISegmentedControl alloc] initWithItems:@[ @"Photo", @"Video" ]];
    _modeSwitch.selectedSegmentIndex = _mode;
    _modeSwitch.accessibilityLabel = @"Capture mode";
    [_modeSwitch addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    return [[UIBarButtonItem alloc] initWithCustomView:_modeSwitch];
  }
  UIBarButtonItem *balance = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
  balance.width = 60;
  return balance;
}

- (UIView *)shutterButton {
  _shutter = [UIButton buttonWithType:UIButtonTypeCustom];
  _shutter.translatesAutoresizingMaskIntoConstraints = NO;
  _shutter.layer.cornerRadius = 39;
  _shutter.layer.borderWidth = 4;
  _shutter.layer.borderColor = UIColor.whiteColor.CGColor;
  _disc = [UIView new];
  _disc.translatesAutoresizingMaskIntoConstraints = NO;
  _disc.userInteractionEnabled = NO;
  _disc.layer.cornerRadius = 31;
  [_shutter addSubview:_disc];
  [NSLayoutConstraint activateConstraints:@[
    [_shutter.widthAnchor constraintEqualToConstant:78],
    [_shutter.heightAnchor constraintEqualToConstant:78],
    [_disc.centerXAnchor constraintEqualToAnchor:_shutter.centerXAnchor],
    [_disc.centerYAnchor constraintEqualToAnchor:_shutter.centerYAnchor],
    [_disc.widthAnchor constraintEqualToConstant:62],
    [_disc.heightAnchor constraintEqualToConstant:62],
  ]];
  [_shutter addTarget:self action:@selector(shutterTapped) forControlEvents:UIControlEventTouchUpInside];
  return _shutter;
}

- (BOOL)isRecording { return _recording.active; }

- (void)updateShutterLook {
  BOOL recording = [self isRecording];
  _disc.backgroundColor = _mode == GPModeVideo ? UIColor.redColor : UIColor.whiteColor;
  _disc.layer.cornerRadius = recording ? 8 : 31;
  _shutter.accessibilityLabel = _mode == GPModePhoto ? @"Take Photo" : (recording ? @"Stop Recording" : @"Record Video");
}

- (void)modeChanged:(UISegmentedControl *)control {
  if ([self isRecording]) {
    control.selectedSegmentIndex = _mode;
    return;
  }
  _mode = control.selectedSegmentIndex == 1 ? GPModeVideo : GPModePhoto;
  [self updateShutterLook];
}

- (void)shutterTapped {
  if (_mode == GPModePhoto) {
    [self capturePhoto];
  } else if ([self isRecording]) {
    [self stopRecording];
  } else {
    [self startRecording];
  }
}

- (void)startPreview {
  if (_previewTimer || _tornDown) return;
  _previewTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _renderQueue);
  dispatch_source_set_timer(_previewTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 24, 5 * NSEC_PER_MSEC);
  GPPreviewState *state = _state;
  __weak UIImageView *view = _preview;
  __weak UILabel *label = _noFrame;
  dispatch_source_set_event_handler(_previewTimer, ^{ GPRenderPreview(state, view, label); });
  dispatch_resume(_previewTimer);
}

- (void)stopPreview {
  if (!_previewTimer) return;
  dispatch_source_cancel(_previewTimer);
  _previewTimer = nil;
}

- (CGSize)photoSize {
  CGSize bounds = _preview.bounds.size;
  return bounds.width > bounds.height ? CGSizeMake(4032, 3024) : CGSizeMake(3024, 4032);
}

- (void)capturePhoto {
  UIImagePickerController *picker = _picker;
  if (_delivering || _cancelled || !picker || _tornDown) return;
  _delivering = YES;
  NSUInteger token = ++_captureToken;
  NSInteger lens = GPShownLens(picker);
  CGSize size = [self photoSize];
  __weak GPCaptureController *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    UIImage *photo = GCFeedImage(lens, size, NO);
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf photoReady:photo token:token]; });
  });
}

- (void)photoReady:(UIImage *)photo token:(NSUInteger)token {
  if (token != _captureToken) return;
  UIImagePickerController *picker = _picker;
  if (!photo || !picker) {
    _delivering = NO;
    [self requestNoFrameLabel];
    return;
  }
  NSMutableDictionary *info = [@{
    UIImagePickerControllerOriginalImage : photo,
    UIImagePickerControllerMediaType : GPImageType,
    UIImagePickerControllerMediaMetadata : GPPhotoMetadata(photo),
  } mutableCopy];
  if (picker.allowsEditing) {
    info[UIImagePickerControllerEditedImage] = photo;
    info[UIImagePickerControllerCropRect] = [NSValue valueWithCGRect:CGRectMake(0, 0, photo.size.width, photo.size.height)];
  }
  [self finishWithInfo:info];
}

- (void)finishWithInfo:(NSDictionary *)info {
  UIImagePickerController *picker = _picker;
  _delivering = NO;
  id<UIImagePickerControllerDelegate> delegate = (id)picker.delegate;
  if ([delegate respondsToSelector:@selector(imagePickerController:didFinishPickingMediaWithInfo:)]) {
    [delegate imagePickerController:picker didFinishPickingMediaWithInfo:info];
  } else {
    [picker.presentingViewController dismissViewControllerAnimated:YES completion:nil];
  }
}

- (void)cancel {
  if (_cancelled) return;
  _cancelled = YES;
  _captureToken++;
  [self discardRecording];
  UIImagePickerController *picker = _picker;
  id<UIImagePickerControllerDelegate> delegate = (id)picker.delegate;
  if ([delegate respondsToSelector:@selector(imagePickerControllerDidCancel:)]) {
    [delegate imagePickerControllerDidCancel:picker];
  } else {
    [picker.presentingViewController dismissViewControllerAnimated:YES completion:nil];
  }
}

- (CGSize)videoSize {
  CGSize bounds = _preview.bounds.size;
  return bounds.width > bounds.height ? CGSizeMake(1280, 720) : CGSizeMake(720, 1280);
}

- (GPRecording *)newRecordingForPicker:(UIImagePickerController *)picker {
  CGSize size = [self videoSize];
  NSString *name = [NSString stringWithFormat:@"glint-camera-%@.mp4", NSUUID.UUID.UUIDString];
  NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
  AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeMPEG4 error:nil];
  NSDictionary *settings = @{AVVideoCodecKey : AVVideoCodecTypeH264, AVVideoWidthKey : @(size.width), AVVideoHeightKey : @(size.height)};
  AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
  input.expectsMediaDataInRealTime = YES;
  NSDictionary *attrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(size.width),
    (id)kCVPixelBufferHeightKey : @(size.height),
  };
  GPRecording *rec = [GPRecording new];
  rec.adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:attrs];
  if (!writer || ![writer canAddInput:input]) return nil;
  [writer addInput:input];
  if (![writer startWriting]) return nil;
  [writer startSessionAtSourceTime:kCMTimeZero];
  NSTimeInterval cap = picker.videoMaximumDuration;
  rec.writer = writer;
  rec.input = input;
  rec.url = url;
  rec.cap = cap <= 0 || cap == GPUnsetMaxRecording ? GPDefaultMaxRecording : cap;
  rec.lens = GPShownLens(picker);
  rec.start = CFAbsoluteTimeGetCurrent();
  rec.token = ++_captureToken;
  rec.active = YES;
  return rec;
}

- (BOOL)startRecording {
  UIImagePickerController *picker = _picker;
  if ([self isRecording]) return YES;
  if (!picker || _tornDown || _cancelled || _delivering) return NO;
  GPRecording *rec = [self newRecordingForPicker:picker];
  if (!rec) return NO;
  _recording = rec;
  [self updateShutterLook];
  _recordTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _recordQueue);
  dispatch_source_set_timer(_recordTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 30, 2 * NSEC_PER_MSEC);
  __weak GPCaptureController *weakSelf = self;
  dispatch_source_set_event_handler(_recordTimer, ^{
    if (!GPAppendFrame(rec)) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf recordingCapReached:rec]; });
  });
  dispatch_resume(_recordTimer);
  return YES;
}

- (void)recordingCapReached:(GPRecording *)rec {
  if (rec == _recording && rec.active) [self stopRecording];
}

- (void)endRecordingTimer {
  _recording.active = NO;
  if (_recordTimer) dispatch_source_cancel(_recordTimer);
  _recordTimer = nil;
}

- (void)stopRecording {
  GPRecording *rec = _recording;
  if (!rec || !rec.active) return;
  [self endRecordingTimer];
  [self updateShutterLook];
  _delivering = YES;
  __weak GPCaptureController *weakSelf = self;
  dispatch_async(_recordQueue, ^{
    if (rec.frames == 0) {
      [rec.writer cancelWriting];
      GPRemoveFile(rec.url);
      dispatch_async(dispatch_get_main_queue(), ^{ GPFinishRecording(weakSelf, rec); });
      return;
    }
    [rec.input markAsFinished];
    [rec.writer finishWritingWithCompletionHandler:^{
      dispatch_async(dispatch_get_main_queue(), ^{ GPFinishRecording(weakSelf, rec); });
    }];
  });
}

- (void)recordingFinished:(GPRecording *)rec {
  BOOL stale = rec.token != _captureToken;
  BOOL done = rec.writer.status == AVAssetWriterStatusCompleted;
  if (stale || !done) GPRemoveFile(rec.url);
  if (stale) return;
  _recording = nil;
  if (!done) {
    _delivering = NO;
    [self requestNoFrameLabel];
    return;
  }
  [self finishWithInfo:@{UIImagePickerControllerMediaURL : rec.url, UIImagePickerControllerMediaType : GPMovieType}];
}

- (void)discardRecording {
  GPRecording *rec = _recording;
  if (!rec) return;
  [self endRecordingTimer];
  _recording = nil;
  dispatch_async(_recordQueue, ^{
    [rec.writer cancelWriting];
    GPRemoveFile(rec.url);
  });
}

- (void)tearDown {
  if (_tornDown) return;
  _tornDown = YES;
  _captureToken++;
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [self discardRecording];
  [self stopPreview];
  _root.onWindowChange = nil;
  [self removePlacedOverlay];
  UIImagePickerController *picker = _picker;
  BOOL hidden = !picker.view.window || picker.sourceType != UIImagePickerControllerSourceTypeCamera;
  if (picker && hidden && picker.viewControllers.firstObject == self) {
    [picker setViewControllers:_savedStack animated:NO];
    [picker setNavigationBarHidden:_savedBarHidden animated:NO];
  }
  objc_setAssociatedObject(picker, kTakeoverKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

static void GPFinishRecording(GPCaptureController *controller, GPRecording *rec) {
  if (controller) {
    [controller recordingFinished:rec];
  } else {
    GPRemoveFile(rec.url);
  }
}

static void GPHookClass(Class cls, SEL sel, id (^make)(IMP orig)) {
  Method m = class_getInstanceMethod(object_getClass(cls), sel);
  if (!m) return;
  method_setImplementation(m, imp_implementationWithBlock(make(method_getImplementation(m))));
}

static void GPHookInstance(Class cls, SEL sel, id (^make)(IMP orig)) {
  Method m = class_getInstanceMethod(cls, sel);
  if (!m) return;
  IMP newImp = imp_implementationWithBlock(make(method_getImplementation(m)));
  if (!class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) method_setImplementation(m, newImp);
}

static GPCaptureController *GPControllerOf(UIImagePickerController *picker) {
  return objc_getAssociatedObject(picker, kTakeoverKey);
}

static BOOL GPShouldTakeOver(UIImagePickerController *picker) {
  if (picker.sourceType != UIImagePickerControllerSourceTypeCamera || !GCFeedActive()) return NO;
  NSArray *types = GPMediaTypes(picker);
  return GPWantsPhotos(types) || GPWantsVideo(types);
}

static NSArray *GPWithoutCaptureControllers(NSArray *stack) {
  return [stack filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id vc, NSDictionary *bindings) {
    return ![vc isKindOfClass:GPCaptureController.class];
  }]];
}

static void GPKeepAppSettings(UIImagePickerController *picker) {
  if (!objc_getAssociatedObject(picker, kRequestedControlsKey)) {
    objc_setAssociatedObject(picker, kRequestedControlsKey, @(picker.showsCameraControls), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  if (!objc_getAssociatedObject(picker, kRequestedOverlayKey)) {
    objc_setAssociatedObject(picker, kRequestedOverlayKey, picker.cameraOverlayView ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
}

static void GPTakeOver(UIImagePickerController *picker) {
  if (!GPShouldTakeOver(picker)) return;
  GPCaptureController *current = GPControllerOf(picker);
  if (current) {
    [current applyConfiguration];
    return;
  }
  GPKeepAppSettings(picker);
  NSArray *saved = GPWithoutCaptureControllers(picker.viewControllers);
  GPCaptureController *capture = [[GPCaptureController alloc] initWithPicker:picker savedStack:saved barHidden:picker.navigationBarHidden];
  objc_setAssociatedObject(picker, kTakeoverKey, capture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [picker setNavigationBarHidden:YES animated:NO];
  [picker setViewControllers:@[ capture ] animated:NO];
}

static void GPHookPickerClassMethods(Class picker) {
  GPHookClass(picker, @selector(isSourceTypeAvailable:), ^id(IMP orig) {
    return ^BOOL(id self, UIImagePickerControllerSourceType type) {
      if (type == UIImagePickerControllerSourceTypeCamera && GCFeedActive()) return YES;
      return ((BOOL(*)(id, SEL, UIImagePickerControllerSourceType))orig)(self, @selector(isSourceTypeAvailable:), type);
    };
  });
  GPHookClass(picker, @selector(availableMediaTypesForSourceType:), ^id(IMP orig) {
    return ^NSArray *(id self, UIImagePickerControllerSourceType type) {
      if (type == UIImagePickerControllerSourceTypeCamera && GCFeedActive()) return @[ GPImageType, GPMovieType ];
      return ((NSArray * (*)(id, SEL, UIImagePickerControllerSourceType))orig)(self, @selector(availableMediaTypesForSourceType:), type);
    };
  });
  GPHookClass(picker, @selector(isCameraDeviceAvailable:), ^id(IMP orig) {
    return ^BOOL(id self, UIImagePickerControllerCameraDevice device) {
      if (GCFeedActive()) return GCFeedHasLens(device == UIImagePickerControllerCameraDeviceFront ? 1 : 0);
      return ((BOOL(*)(id, SEL, UIImagePickerControllerCameraDevice))orig)(self, @selector(isCameraDeviceAvailable:), device);
    };
  });
  GPHookClass(picker, @selector(isFlashAvailableForCameraDevice:), ^id(IMP orig) {
    return ^BOOL(id self, UIImagePickerControllerCameraDevice device) {
      if (GCFeedActive()) return NO;
      return ((BOOL(*)(id, SEL, UIImagePickerControllerCameraDevice))orig)(self, @selector(isFlashAvailableForCameraDevice:), device);
    };
  });
  GPHookClass(picker, @selector(availableCaptureModesForCameraDevice:), ^id(IMP orig) {
    return ^NSArray *(id self, UIImagePickerControllerCameraDevice device) {
      if (GCFeedActive()) return @[ @(UIImagePickerControllerCameraCaptureModePhoto), @(UIImagePickerControllerCameraCaptureModeVideo) ];
      return ((NSArray * (*)(id, SEL, UIImagePickerControllerCameraDevice))orig)(self, @selector(availableCaptureModesForCameraDevice:), device);
    };
  });
}

static void GPHookPickerLifecycle(Class picker) {
  GPHookInstance(picker, @selector(viewWillAppear:), ^id(IMP orig) {
    return ^void(UIImagePickerController *self, BOOL animated) {
      GPTakeOver(self);
      ((void (*)(id, SEL, BOOL))orig)(self, @selector(viewWillAppear:), animated);
    };
  });
  GPHookInstance(picker, @selector(viewDidDisappear:), ^id(IMP orig) {
    return ^void(UIImagePickerController *self, BOOL animated) {
      ((void (*)(id, SEL, BOOL))orig)(self, @selector(viewDidDisappear:), animated);
      [GPControllerOf(self) tearDown];
    };
  });
  GPHookInstance(picker, @selector(setSourceType:), ^id(IMP orig) {
    return ^void(UIImagePickerController *self, UIImagePickerControllerSourceType type) {
      ((void (*)(id, SEL, UIImagePickerControllerSourceType))orig)(self, @selector(setSourceType:), type);
      [GPControllerOf(self) tearDown];
      if (self.isViewLoaded && self.view.window) GPTakeOver(self);
    };
  });
}

static void GPHookPickerCapture(Class picker) {
  GPHookInstance(picker, @selector(takePicture), ^id(IMP orig) {
    return ^void(UIImagePickerController *self) {
      GPCaptureController *capture = GPControllerOf(self);
      if (capture) {
        [capture capturePhoto];
        return;
      }
      ((void (*)(id, SEL))orig)(self, @selector(takePicture));
    };
  });
  GPHookInstance(picker, @selector(startVideoCapture), ^id(IMP orig) {
    return ^BOOL(UIImagePickerController *self) {
      GPCaptureController *capture = GPControllerOf(self);
      return capture ? [capture startRecording] : ((BOOL(*)(id, SEL))orig)(self, @selector(startVideoCapture));
    };
  });
  GPHookInstance(picker, @selector(stopVideoCapture), ^id(IMP orig) {
    return ^void(UIImagePickerController *self) {
      GPCaptureController *capture = GPControllerOf(self);
      if (capture) {
        [capture stopRecording];
        return;
      }
      ((void (*)(id, SEL))orig)(self, @selector(stopVideoCapture));
    };
  });
}

static void GPHookPickerSetters(Class picker) {
  GPHookInstance(picker, @selector(setCameraDevice:), ^id(IMP orig) {
    return ^void(UIImagePickerController *self, UIImagePickerControllerCameraDevice value) {
      ((void (*)(id, SEL, UIImagePickerControllerCameraDevice))orig)(self, @selector(setCameraDevice:), value);
      [GPControllerOf(self) applyConfiguration];
    };
  });
  GPHookInstance(picker, @selector(setShowsCameraControls:), ^id(IMP orig) {
    return ^void(UIImagePickerController *self, BOOL value) {
      objc_setAssociatedObject(self, kRequestedControlsKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      ((void (*)(id, SEL, BOOL))orig)(self, @selector(setShowsCameraControls:), value);
      [GPControllerOf(self) applyConfiguration];
    };
  });
  GPHookInstance(picker, @selector(setCameraOverlayView:), ^id(IMP orig) {
    return ^void(UIImagePickerController *self, UIView *value) {
      objc_setAssociatedObject(self, kRequestedOverlayKey, value ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      ((void (*)(id, SEL, id))orig)(self, @selector(setCameraOverlayView:), value);
      [GPControllerOf(self) applyConfiguration];
    };
  });
  GPHookInstance(picker, @selector(setMediaTypes:), ^id(IMP orig) {
    return ^void(UIImagePickerController *self, NSArray *value) {
      objc_setAssociatedObject(self, kRequestedTypesKey, [value copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      NSArray *accepted = value;
      if (self.sourceType == UIImagePickerControllerSourceTypeCamera && GCFeedActive()) {
        accepted = [value filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *identifier, NSDictionary *bindings) {
          return GPAnyConforms(@[ identifier ], UTTypeImage);
        }]];
      }
      if (accepted.count > 0 || value.count == 0) ((void (*)(id, SEL, id))orig)(self, @selector(setMediaTypes:), accepted);
      [GPControllerOf(self) applyConfiguration];
    };
  });
  GPHookInstance(picker, @selector(mediaTypes), ^id(IMP orig) {
    return ^NSArray *(UIImagePickerController *self) {
      NSArray *requested = objc_getAssociatedObject(self, kRequestedTypesKey);
      if (requested && self.sourceType == UIImagePickerControllerSourceTypeCamera && GCFeedActive()) return requested;
      return ((NSArray * (*)(id, SEL))orig)(self, @selector(mediaTypes));
    };
  });
}

void GCInstallPickerHooks(void) {
  Class picker = UIImagePickerController.class;
  GPHookPickerClassMethods(picker);
  GPHookPickerLifecycle(picker);
  GPHookPickerCapture(picker);
  GPHookPickerSetters(picker);
}
