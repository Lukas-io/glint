#import "siminject.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>

static id GCNew(Class c) { return class_createInstance(c, 0); }

typedef NS_ENUM(NSInteger, GCLens) { GCLensBack = 0, GCLensFront = 1 };

@interface GCFeedConfig : NSObject
+ (instancetype)current;
- (NSDictionary *)forLens:(GCLens)lens;
- (void)setFront:(NSDictionary *)front back:(NSDictionary *)back;
@end

@implementation GCFeedConfig {
  NSDictionary *_front;
  NSDictionary *_back;
}
+ (instancetype)current {
  static GCFeedConfig *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [GCFeedConfig new]; });
  return shared;
}
- (NSDictionary *)forLens:(GCLens)lens {
  @synchronized(self) {
    return lens == GCLensFront ? _front : _back;
  }
}
- (void)setFront:(NSDictionary *)front back:(NSDictionary *)back {
  @synchronized(self) {
    _front = [front copy];
    _back = [back copy];
  }
}
@end

static __thread int GCBypassDepth;

static BOOL GCActive(void) {
  if (GCBypassDepth > 0) return NO;
  GCFeedConfig *c = GCFeedConfig.current;
  return [c forLens:GCLensFront] != nil || [c forLens:GCLensBack] != nil;
}

@interface GCWebcamReader : NSObject
+ (CIImage *)latestFrameFromFile:(NSString *)path seq:(uint32_t *)seqOut;
@end

@implementation GCWebcamReader
+ (CIImage *)latestFrameFromFile:(NSString *)path seq:(uint32_t *)seqOut {
  static NSMutableDictionary<NSString *, NSValue *> *maps;
  static NSMutableDictionary<NSString *, NSNumber *> *sizes;
  static NSMutableDictionary<NSString *, NSNumber *> *inodes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    maps = [NSMutableDictionary new];
    sizes = [NSMutableDictionary new];
    inodes = [NSMutableDictionary new];
  });
  @synchronized(maps) {
    static CFAbsoluteTime lastTouch;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastTouch > 1.0) {
      lastTouch = now;
      NSString *marker = [path stringByAppendingString:@".read"];
      int mfd = open(marker.fileSystemRepresentation, O_WRONLY | O_CREAT, 0644);
      if (mfd >= 0) {
        futimens(mfd, NULL);
        close(mfd);
      }
    }
    struct stat onDisk;
    if (stat(path.fileSystemRepresentation, &onDisk) != 0) return nil;
    NSNumber *known = inodes[path];
    NSValue *mapped = maps[path];
    if (mapped && known.unsignedLongLongValue != (unsigned long long)onDisk.st_ino) {
      munmap(mapped.pointerValue, sizes[path].unsignedLongValue);
      [maps removeObjectForKey:path];
      mapped = nil;
    }
    if (!mapped) {
      int fd = open(path.fileSystemRepresentation, O_RDONLY);
      if (fd < 0) return nil;
      struct stat st;
      fstat(fd, &st);
      void *base = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
      close(fd);
      if (base == MAP_FAILED) return nil;
      maps[path] = [NSValue valueWithPointer:base];
      sizes[path] = @(st.st_size);
      inodes[path] = @((unsigned long long)st.st_ino);
      mapped = maps[path];
    }
    uint32_t *h = (uint32_t *)mapped.pointerValue;
    uint32_t w = h[1], ht = h[2], stride = h[3];
    if (h[5] != 1) return nil;
    if (w == 0 || ht == 0 || 32 + (size_t)stride * ht > sizes[path].unsignedLongValue) return nil;
    for (int attempt = 0; attempt < 4; attempt++) {
      uint32_t seqA = __atomic_load_n(&h[0], __ATOMIC_ACQUIRE);
      if (seqA == 0 || __atomic_load_n(&h[4], __ATOMIC_ACQUIRE) != seqA) continue;
      CVPixelBufferRef pb = NULL;
      CVPixelBufferCreate(NULL, w, ht, kCVPixelFormatType_32BGRA, NULL, &pb);
      if (!pb) return nil;
      CVPixelBufferLockBaseAddress(pb, 0);
      uint8_t *dst = CVPixelBufferGetBaseAddress(pb);
      size_t dstStride = CVPixelBufferGetBytesPerRow(pb);
      const uint8_t *src = (const uint8_t *)h + 32;
      for (uint32_t y = 0; y < ht; y++) memcpy(dst + y * dstStride, src + (size_t)y * stride, MIN((size_t)stride, dstStride));
      CVPixelBufferUnlockBaseAddress(pb, 0);
      __atomic_thread_fence(__ATOMIC_ACQUIRE);
      if (__atomic_load_n(&h[4], __ATOMIC_ACQUIRE) == seqA && __atomic_load_n(&h[0], __ATOMIC_ACQUIRE) == seqA) {
        CIImage *img = [CIImage imageWithCVPixelBuffer:pb];
        CVPixelBufferRelease(pb);
        if (seqOut) *seqOut = seqA;
        return img;
      }
      CVPixelBufferRelease(pb);
    }
  }
  return nil;
}
@end

@interface GCSource : NSObject
- (instancetype)initWithSpec:(NSDictionary *)spec;
- (CIImage *)currentImage;
@end

@implementation GCSource {
  NSDictionary *_spec;
  CIImage *_still;
  NSURL *_url;
  AVAssetReader *_reader;
  AVAssetReaderTrackOutput *_out;
  CGImagePropertyOrientation _videoOrientation;
  CIImage *_current;
  uint32_t _lastSeq;
  CFAbsoluteTime _lastChange;
  CMTime _pendingPTS;
  CVPixelBufferRef _pending;
  CFAbsoluteTime _loopStart;
  CMTime _firstPTS;
  BOOL _haveFirst;
}
- (instancetype)initWithSpec:(NSDictionary *)spec {
  if ((self = [super init])) {
    _spec = spec;
    NSString *kind = spec[@"kind"];
    NSString *path = spec[@"path"];
    if ([kind isEqualToString:@"image"]) {
      _still = [CIImage imageWithContentsOfURL:[NSURL fileURLWithPath:path] options:@{kCIImageApplyOrientationProperty : @YES}];
    } else if ([kind isEqualToString:@"video"]) {
      _url = [NSURL fileURLWithPath:path];
    }
  }
  return self;
}
- (void)dealloc {
  if (_pending) CVPixelBufferRelease(_pending);
}
- (void)startReader {
  _reader = nil;
  _out = nil;
  if (_pending) {
    CVPixelBufferRelease(_pending);
    _pending = NULL;
  }
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:_url options:nil];
  AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  if (!track) return;
  CGAffineTransform t = track.preferredTransform;
  if (t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0) _videoOrientation = kCGImagePropertyOrientationRight;
  else if (t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0) _videoOrientation = kCGImagePropertyOrientationLeft;
  else if (t.a == -1 && t.d == -1) _videoOrientation = kCGImagePropertyOrientationDown;
  else _videoOrientation = kCGImagePropertyOrientationUp;
  NSError *err = nil;
  _reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
  _out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
                                                    outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)}];
  [_reader addOutput:_out];
  [_reader startReading];
  _loopStart = CFAbsoluteTimeGetCurrent();
  _haveFirst = NO;
}
- (void)advanceVideo {
  if (!_reader) [self startReader];
  if (!_reader) return;
  CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - _loopStart;
  for (int guard = 0; guard < 8; guard++) {
    if (!_pending) {
      CMSampleBufferRef sb = [_out copyNextSampleBuffer];
      if (!sb) {
        _reader = nil;
        return;
      }
      CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
      if (!_haveFirst) {
        _firstPTS = pts;
        _haveFirst = YES;
      }
      _pendingPTS = CMTimeSubtract(pts, _firstPTS);
      _pending = (CVPixelBufferRef)CFRetain(CMSampleBufferGetImageBuffer(sb));
      CFRelease(sb);
    }
    if (CMTimeGetSeconds(_pendingPTS) <= elapsed) {
      _current = [[CIImage imageWithCVPixelBuffer:_pending] imageByApplyingCGOrientation:_videoOrientation];
      CVPixelBufferRelease(_pending);
      _pending = NULL;
    } else {
      break;
    }
  }
}
- (CIImage *)currentImage {
  @synchronized(self) {
    NSString *kind = _spec[@"kind"];
    if (_still) return _still;
    if ([kind isEqualToString:@"video"]) {
      [self advanceVideo];
      return _current;
    }
    if ([kind isEqualToString:@"webcam"]) {
      CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
      uint32_t seq = 0;
      CIImage *f = [GCWebcamReader latestFrameFromFile:_spec[@"path"] seq:&seq];
      if (f && seq != _lastSeq) {
        _lastSeq = seq;
        _lastChange = now;
        _current = f;
        return f;
      }
      if (_lastChange == 0) _lastChange = now;
      return now - _lastChange < 1.5 ? _current : nil;
    }
    return nil;
  }
}
@end

static GCSource *GCSourceFor(GCLens lens) {
  static GCSource *sources[2];
  static NSDictionary *specs[2];
  @synchronized(GCFeedConfig.class) {
    NSDictionary *spec = [GCFeedConfig.current forLens:lens];
    if (!spec) {
      sources[lens] = nil;
      specs[lens] = nil;
      return nil;
    }
    if (!sources[lens] || ![specs[lens] isEqualToDictionary:spec]) {
      sources[lens] = [[GCSource alloc] initWithSpec:spec];
      specs[lens] = spec;
    }
    return sources[lens];
  }
}

static CIContext *GCContext(void) {
  static CIContext *ctx;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer : @NO}]; });
  return ctx;
}

static CIImage *GCFit(CIImage *scene, CGSize size, BOOL mirror, BOOL cover, CGFloat zoom) {
  CGRect e = scene.extent;
  if (CGRectIsEmpty(e) || CGRectIsInfinite(e)) return nil;
  CGFloat sx = size.width / e.size.width, sy = size.height / e.size.height;
  CGFloat s = (cover ? MAX(sx, sy) : MIN(sx, sy)) * zoom;
  CIImage *img = [scene imageByApplyingTransform:CGAffineTransformMakeTranslation(-e.origin.x, -e.origin.y)];
  img = [img imageByApplyingTransform:CGAffineTransformMakeScale(s, s)];
  CGFloat w = e.size.width * s, h = e.size.height * s;
  img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation((size.width - w) / 2, (size.height - h) / 2)];
  CIImage *bg = [[CIImage imageWithColor:CIColor.blackColor] imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];
  img = [[img imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)] imageByCompositingOverImage:bg];
  if (mirror) img = [img imageByApplyingTransform:CGAffineTransformMake(-1, 0, 0, 1, size.width, 0)];
  return img;
}

static CVPixelBufferRef GCRender(GCLens lens, CGSize size, BOOL mirror, OSType format) {
  GCSource *src = GCSourceFor(lens);
  CIImage *scene = src.currentImage;
  if (!scene) return NULL;
  BOOL cover = [[GCFeedConfig.current forLens:lens][@"fit"] isEqual:@"cover"];
  CGFloat zoom = [[GCFeedConfig.current forLens:lens][@"zoom"] doubleValue];
  CIImage *fit = GCFit(scene, size, mirror, cover, zoom > 0.05 && zoom <= 1.0 ? zoom : 1.0);
  if (!fit) return NULL;
  CVPixelBufferRef pb = NULL;
  NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}, (id)kCVPixelBufferMetalCompatibilityKey : @YES};
  CVPixelBufferCreate(NULL, (size_t)size.width, (size_t)size.height, format, (__bridge CFDictionaryRef)attrs, &pb);
  if (!pb) return NULL;
  [GCContext() render:fit toCVPixelBuffer:pb];
  return pb;
}

@interface GCRange : AVFrameRateRange
@end
@implementation GCRange
- (Float64)minFrameRate { return 1; }
- (Float64)maxFrameRate { return 30; }
- (CMTime)maxFrameDuration { return CMTimeMake(1, 1); }
- (CMTime)minFrameDuration { return CMTimeMake(1, 30); }
@end

@interface GCFormat : AVCaptureDeviceFormat
@property(nonatomic) int32_t width;
@property(nonatomic) int32_t height;
@property(nonatomic) CMFormatDescriptionRef desc;
+ (instancetype)formatWidth:(int32_t)w height:(int32_t)h;
@end
@implementation GCFormat
+ (instancetype)formatWidth:(int32_t)w height:(int32_t)h {
  GCFormat *f = GCNew(GCFormat.class);
  f.width = w;
  f.height = h;
  CMVideoFormatDescriptionRef d = NULL;
  CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_JPEG, w, h, NULL, &d);
  f.desc = d;
  return f;
}
- (NSString *)mediaType { return AVMediaTypeVideo; }
- (CMFormatDescriptionRef)formatDescription { return _desc; }
- (NSArray<AVFrameRateRange *> *)videoSupportedFrameRateRanges { return @[ GCNew(GCRange.class) ]; }
- (BOOL)isVideoBinned { return NO; }
- (BOOL)isVideoStabilizationModeSupported:(AVCaptureVideoStabilizationMode)m { return m == AVCaptureVideoStabilizationModeOff; }
- (BOOL)isVideoHDRSupported { return NO; }
- (float)videoFieldOfView { return 63; }
- (CGFloat)videoMaxZoomFactor { return 1; }
- (CGFloat)videoZoomFactorUpscaleThreshold { return 1; }
- (CMVideoDimensions)highResolutionStillImageDimensions { return (CMVideoDimensions){4032, 3024}; }
- (NSArray<NSValue *> *)supportedMaxPhotoDimensions {
  CMVideoDimensions d = {4032, 3024};
  return @[ [NSValue valueWithBytes:&d objCType:@encode(CMVideoDimensions)] ];
}
- (BOOL)isHighestPhotoQualitySupported { return NO; }
@end

@interface GCDevice : AVCaptureDevice
@property(nonatomic) GCLens lens;
@property(nonatomic, strong) GCFormat *fmt;
@property(nonatomic, strong) NSArray *allFormats;
+ (instancetype)deviceForLens:(GCLens)lens;
@end

static GCDevice *GCDevices[2];

@implementation GCDevice
+ (instancetype)deviceForLens:(GCLens)lens {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    for (int i = 0; i < 2; i++) {
      GCDevice *d = GCNew(GCDevice.class);
      d.lens = (GCLens)i;
      d.allFormats = @[ [GCFormat formatWidth:1920 height:1080], [GCFormat formatWidth:1280 height:720], [GCFormat formatWidth:640 height:480] ];
      d.fmt = d.allFormats[0];
      GCDevices[i] = d;
    }
  });
  return GCDevices[lens];
}
- (NSString *)uniqueID { return _lens == GCLensFront ? @"glint-front-camera" : @"glint-back-camera"; }
- (NSString *)modelID { return @"GlintVirtualCamera"; }
- (NSString *)localizedName { return _lens == GCLensFront ? @"Front Camera" : @"Back Camera"; }
- (AVCaptureDevicePosition)position { return _lens == GCLensFront ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack; }
- (AVCaptureDeviceType)deviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }
- (BOOL)hasMediaType:(AVMediaType)t { return [t isEqualToString:AVMediaTypeVideo]; }
- (BOOL)isConnected { return YES; }
- (BOOL)isSuspended { return NO; }
- (BOOL)lockForConfiguration:(NSError **)e { return YES; }
- (void)unlockForConfiguration {}
- (NSArray<AVCaptureDeviceFormat *> *)formats { return _allFormats; }
- (AVCaptureDeviceFormat *)activeFormat { return _fmt; }
- (void)setActiveFormat:(AVCaptureDeviceFormat *)f { if ([f isKindOfClass:GCFormat.class]) _fmt = (GCFormat *)f; }
- (CMTime)activeVideoMinFrameDuration { return CMTimeMake(1, 30); }
- (void)setActiveVideoMinFrameDuration:(CMTime)t {}
- (CMTime)activeVideoMaxFrameDuration { return CMTimeMake(1, 30); }
- (void)setActiveVideoMaxFrameDuration:(CMTime)t {}
- (BOOL)supportsAVCaptureSessionPreset:(AVCaptureSessionPreset)p { return YES; }
- (BOOL)hasFlash { return NO; }
- (BOOL)hasTorch { return NO; }
- (BOOL)isFlashAvailable { return NO; }
- (BOOL)isTorchAvailable { return NO; }
- (BOOL)isFlashActive { return NO; }
- (BOOL)isTorchActive { return NO; }
- (BOOL)isFlashModeSupported:(AVCaptureFlashMode)m { return NO; }
- (BOOL)isTorchModeSupported:(AVCaptureTorchMode)m { return m == AVCaptureTorchModeOff; }
- (AVCaptureTorchMode)torchMode { return AVCaptureTorchModeOff; }
- (void)setTorchMode:(AVCaptureTorchMode)m {}
- (BOOL)isFocusModeSupported:(AVCaptureFocusMode)m { return m == AVCaptureFocusModeContinuousAutoFocus || m == AVCaptureFocusModeLocked; }
- (AVCaptureFocusMode)focusMode { return AVCaptureFocusModeContinuousAutoFocus; }
- (void)setFocusMode:(AVCaptureFocusMode)m {}
- (BOOL)isFocusPointOfInterestSupported { return NO; }
- (BOOL)isExposureModeSupported:(AVCaptureExposureMode)m { return m == AVCaptureExposureModeContinuousAutoExposure || m == AVCaptureExposureModeLocked; }
- (AVCaptureExposureMode)exposureMode { return AVCaptureExposureModeContinuousAutoExposure; }
- (void)setExposureMode:(AVCaptureExposureMode)m {}
- (BOOL)isExposurePointOfInterestSupported { return NO; }
- (float)minExposureTargetBias { return -8; }
- (float)maxExposureTargetBias { return 8; }
- (void)setExposureTargetBias:(float)b completionHandler:(void (^)(CMTime))h { if (h) h(kCMTimeZero); }
- (CGFloat)videoZoomFactor { return 1; }
- (void)setVideoZoomFactor:(CGFloat)z {}
- (CGFloat)minAvailableVideoZoomFactor { return 1; }
- (CGFloat)maxAvailableVideoZoomFactor { return 1; }
- (BOOL)isLowLightBoostSupported { return NO; }
- (BOOL)isSmoothAutoFocusSupported { return NO; }
- (BOOL)isAdjustingFocus { return NO; }
- (BOOL)isAdjustingExposure { return NO; }
- (AVCaptureWhiteBalanceMode)whiteBalanceMode { return AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance; }
- (BOOL)isWhiteBalanceModeSupported:(AVCaptureWhiteBalanceMode)m { return m == AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance; }
- (BOOL)isVirtualDevice { return NO; }
- (NSArray *)constituentDevices { return @[]; }
- (BOOL)isInUseByAnotherApplication { return NO; }
- (BOOL)isRampingVideoZoom { return NO; }
- (CGPoint)focusPointOfInterest { return CGPointMake(0.5, 0.5); }
- (CGPoint)exposurePointOfInterest { return CGPointMake(0.5, 0.5); }
- (float)lensPosition { return 0.5; }
- (float)lensAperture { return 1.8; }
- (CMTime)exposureDuration { return CMTimeMake(1, 60); }
- (float)ISO { return 100; }
- (float)exposureTargetBias { return 0; }
- (float)exposureTargetOffset { return 0; }
- (NSArray *)supportedFalseColorFormats { return @[]; }
- (id)valueForUndefinedKey:(NSString *)key { return nil; }
- (void)setValue:(id)v forUndefinedKey:(NSString *)key {}
@end

@interface GCDiscovery : AVCaptureDeviceDiscoverySession
@property(nonatomic, copy) NSArray<AVCaptureDevice *> *found;
@end
@implementation GCDiscovery
- (NSArray<AVCaptureDevice *> *)devices { return _found ?: @[]; }
- (NSArray *)supportedMultiCamDeviceSets { return @[]; }
@end

@interface GCPort : AVCaptureInputPort
@property(nonatomic, weak) AVCaptureInput *owner;
@end
@implementation GCPort
- (AVMediaType)mediaType { return AVMediaTypeVideo; }
- (AVCaptureInput *)input { return _owner; }
- (BOOL)isEnabled { return YES; }
- (CMFormatDescriptionRef)formatDescription { return [GCDevice deviceForLens:GCLensBack].fmt.desc; }
- (CMClockRef)clock { return CMClockGetHostTimeClock(); }
@end

static const void *kFakeInputKey = &kFakeInputKey;
static const void *kInputDeviceKey = &kInputDeviceKey;
static const void *kInputPortsKey = &kInputPortsKey;
static const void *kSessionStateKey = &kSessionStateKey;
static const void *kOutputStateKey = &kOutputStateKey;
static const void *kConnectionStateKey = &kConnectionStateKey;

@interface GCConnState : NSObject
@property(nonatomic) BOOL mirrored;
@property(nonatomic) AVCaptureVideoOrientation orientation;
@property(nonatomic, weak) AVCaptureOutput *output;
@property(nonatomic, strong) AVCaptureInput *input;
@property(nonatomic, strong) NSArray *ports;
@end
@implementation GCConnState
- (instancetype)init {
  if ((self = [super init])) _orientation = AVCaptureVideoOrientationLandscapeRight;
  return self;
}
@end

@interface GCOutState : NSObject
@property(nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSDictionary *videoSettings;
@property(nonatomic, strong) AVCaptureConnection *connection;
@property(nonatomic, weak) AVCaptureSession *session;
@end
@implementation GCOutState
@end

@interface GCSessState : NSObject
@property(nonatomic, strong) NSMutableArray *inputs;
@property(nonatomic, strong) NSMutableArray *outputs;
@property(nonatomic, strong) NSMutableArray *connections;
@property(nonatomic, copy) AVCaptureSessionPreset preset;
@property(nonatomic) BOOL running;
@property(nonatomic) BOOL idleRunning;
@property(nonatomic, strong) dispatch_source_t timer;
@end
@implementation GCSessState
- (instancetype)init {
  if ((self = [super init])) {
    _inputs = [NSMutableArray new];
    _outputs = [NSMutableArray new];
    _connections = [NSMutableArray new];
    _preset = AVCaptureSessionPresetHigh;
  }
  return self;
}
@end

static BOOL GCIsFakeInput(id input) { return input && objc_getAssociatedObject(input, kFakeInputKey) != nil; }

static GCSessState *GCStateOf(AVCaptureSession *s, BOOL create) {
  GCSessState *st = objc_getAssociatedObject(s, kSessionStateKey);
  if (!st && create) {
    st = [GCSessState new];
    objc_setAssociatedObject(s, kSessionStateKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return st;
}

static BOOL GCSessionIsFake(AVCaptureSession *s) {
  GCSessState *st = GCStateOf(s, NO);
  return st && st.inputs.count > 0;
}

static GCOutState *GCOutStateOf(id out) {
  GCOutState *st = objc_getAssociatedObject(out, kOutputStateKey);
  if (!st) {
    st = [GCOutState new];
    objc_setAssociatedObject(out, kOutputStateKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return st;
}

static GCConnState *GCConnStateOf(AVCaptureConnection *c) { return objc_getAssociatedObject(c, kConnectionStateKey); }

static CGSize GCOrientedSize(CGSize base, AVCaptureVideoOrientation o) {
  BOOL portrait = o == AVCaptureVideoOrientationPortrait || o == AVCaptureVideoOrientationPortraitUpsideDown;
  return portrait ? CGSizeMake(base.height, base.width) : base;
}

static OSType GCRequestedFormat(GCOutState *st) {
  NSNumber *n = st.videoSettings[(id)kCVPixelBufferPixelFormatTypeKey];
  return n ? (OSType)n.unsignedIntValue : kCVPixelFormatType_32BGRA;
}

static void GCDeliverFrame(AVCaptureSession *session, GCSessState *st) {
  NSArray *inputs;
  NSArray *outputs;
  @synchronized(st) {
    inputs = [st.inputs copy];
    outputs = [st.outputs copy];
  }
  AVCaptureDeviceInput *input = (AVCaptureDeviceInput *)inputs.firstObject;
  GCDevice *dev = (GCDevice *)objc_getAssociatedObject(input, kInputDeviceKey);
  if (!dev) return;
  GCFormat *fmt = dev.fmt;
  for (AVCaptureOutput *out in outputs) {
    if (![out isKindOfClass:AVCaptureVideoDataOutput.class]) continue;
    GCOutState *os = GCOutStateOf(out);
    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = os.delegate;
    if (!delegate || !os.connection) continue;
    GCConnState *cs = GCConnStateOf(os.connection);
    CGSize size = GCOrientedSize(CGSizeMake(fmt.width, fmt.height), cs.orientation);
    CVPixelBufferRef pb = GCRender(dev.lens, size, cs.mirrored, GCRequestedFormat(os));
    if (!pb) continue;
    CMVideoFormatDescriptionRef desc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, pb, &desc);
    CMTime now = CMClockGetTime(CMClockGetHostTimeClock());
    CMSampleTimingInfo timing = {CMTimeMake(1, 30), now, now};
    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(NULL, pb, desc, &timing, &sb);
    CFRelease(desc);
    CVPixelBufferRelease(pb);
    if (!sb) continue;
    if ([delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
      [delegate captureOutput:(AVCaptureVideoDataOutput *)out didOutputSampleBuffer:sb fromConnection:os.connection];
    }
    CFRelease(sb);
  }
}

static void GCStartTimer(AVCaptureSession *session, GCSessState *st) {
  dispatch_queue_t q = nil;
  NSArray *outputs;
  @synchronized(st) { outputs = [st.outputs copy]; }
  for (AVCaptureOutput *out in outputs) {
    GCOutState *os = objc_getAssociatedObject(out, kOutputStateKey);
    if (os.queue) q = os.queue;
  }
  if (!q) q = dispatch_queue_create("glint.camera.frames", DISPATCH_QUEUE_SERIAL);
  dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
  dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC / 30, NSEC_PER_MSEC);
  __weak AVCaptureSession *weak = session;
  dispatch_source_set_event_handler(t, ^{
    AVCaptureSession *s = weak;
    GCSessState *state = s ? GCStateOf(s, NO) : nil;
    if (!state || !state.running) return;
    @autoreleasepool { GCDeliverFrame(s, state); }
  });
  st.timer = t;
  dispatch_resume(t);
}

@interface GCPhoto : AVCapturePhoto
@property(nonatomic, strong) NSData *jpeg;
@property(nonatomic, strong) NSDictionary *meta;
@property(nonatomic) CMTime stamp;
@property(nonatomic) CVPixelBufferRef pixels;
@end
@implementation GCPhoto
- (NSData *)fileDataRepresentation { return _jpeg; }
- (NSData *)fileDataRepresentationWithCustomizer:(id)c { return _jpeg; }
- (CMTime)timestamp { return _stamp; }
- (NSDictionary<NSString *, id> *)metadata { return _meta; }
- (BOOL)isRawPhoto { return NO; }
- (CVPixelBufferRef)pixelBuffer { return _pixels; }
- (CVPixelBufferRef)previewPixelBuffer { return NULL; }
- (CGImageRef)CGImageRepresentation { return NULL; }
- (NSInteger)photoCount { return 1; }
- (AVCaptureResolvedPhotoSettings *)resolvedSettings { return nil; }
- (AVCaptureBracketedStillImageSettings *)bracketSettings { return nil; }
- (NSInteger)sequenceCount { return 1; }
- (void)dealloc { if (_pixels) CVPixelBufferRelease(_pixels); }
@end

static void GCCapturePhoto(AVCapturePhotoOutput *output, AVCapturePhotoSettings *settings, id<AVCapturePhotoCaptureDelegate> delegate) {
  AVCaptureSession *session = GCOutStateOf(output).session;
  GCSessState *st = session ? GCStateOf(session, NO) : nil;
  NSArray *inputs;
  NSArray *outputs;
  @synchronized(st) {
    inputs = [st.inputs copy];
    outputs = [st.outputs copy];
  }
  GCDevice *dev = inputs.firstObject ? (GCDevice *)objc_getAssociatedObject(inputs.firstObject, kInputDeviceKey) : nil;
  AVCaptureVideoOrientation orientation = AVCaptureVideoOrientationPortrait;
  for (AVCaptureOutput *o in outputs) {
    GCOutState *s = objc_getAssociatedObject(o, kOutputStateKey);
    GCConnState *cs = s.connection ? GCConnStateOf(s.connection) : nil;
    if (cs && [o isKindOfClass:AVCaptureVideoDataOutput.class]) orientation = cs.orientation;
  }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *error = nil;
    GCPhoto *photo = nil;
    if (dev) {
      CGSize size = GCOrientedSize(CGSizeMake(4032, 3024), orientation);
      CVPixelBufferRef pb = GCRender(dev.lens, size, NO, kCVPixelFormatType_32BGRA);
      if (pb) {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        NSData *jpeg = [GCContext() JPEGRepresentationOfImage:ci colorSpace:cs options:@{(id)kCGImageDestinationLossyCompressionQuality : @0.9}];
        CGColorSpaceRelease(cs);
        photo = GCNew(GCPhoto.class);
        photo.jpeg = jpeg;
        photo.stamp = CMClockGetTime(CMClockGetHostTimeClock());
        photo.meta = @{};
        photo.pixels = pb;
      }
    }
    if (!photo) error = [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorNoDataCaptured userInfo:@{NSLocalizedDescriptionKey : @"glint camera has no frame yet"}];
    if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
      [delegate captureOutput:output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:error];
    }
  });
}

static void GCReplace(Class cls, SEL sel, BOOL meta, id (^make)(IMP orig)) {
  Class target = meta ? object_getClass(cls) : cls;
  Method m = class_getInstanceMethod(target, sel);
  if (!m) return;
  IMP orig = method_getImplementation(m);
  method_setImplementation(m, imp_implementationWithBlock(make(orig)));
}

static NSArray<AVCaptureDevice *> *GCDevicesMatching(NSArray<AVCaptureDeviceType> *types, AVMediaType media, AVCaptureDevicePosition pos) {
  if (GCBypassDepth > 0) return @[];
  if (media && ![media isEqualToString:AVMediaTypeVideo]) return @[];
  GCFeedConfig *cfg = GCFeedConfig.current;
  NSMutableArray *out = [NSMutableArray new];
  BOOL wide = !types || [types containsObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
  if (!wide) return @[];
  if ([cfg forLens:GCLensBack] && (pos == AVCaptureDevicePositionUnspecified || pos == AVCaptureDevicePositionBack)) [out addObject:[GCDevice deviceForLens:GCLensBack]];
  if ([cfg forLens:GCLensFront] && (pos == AVCaptureDevicePositionUnspecified || pos == AVCaptureDevicePositionFront)) [out addObject:[GCDevice deviceForLens:GCLensFront]];
  return out;
}

static void GCInstallDeviceHooks(void) {
  GCReplace(AVCaptureDevice.class, @selector(authorizationStatusForMediaType:), YES, ^id(IMP orig) {
    return ^AVAuthorizationStatus(id self, AVMediaType t) {
      if ([t isEqualToString:AVMediaTypeVideo] && GCActive()) return AVAuthorizationStatusAuthorized;
      return ((AVAuthorizationStatus(*)(id, SEL, AVMediaType))orig)(self, @selector(authorizationStatusForMediaType:), t);
    };
  });
  GCReplace(AVCaptureDevice.class, @selector(requestAccessForMediaType:completionHandler:), YES, ^id(IMP orig) {
    return ^void(id self, AVMediaType t, void (^h)(BOOL)) {
      if ([t isEqualToString:AVMediaTypeVideo] && GCActive()) {
        if (h) dispatch_async(dispatch_get_main_queue(), ^{ h(YES); });
        return;
      }
      ((void (*)(id, SEL, AVMediaType, id))orig)(self, @selector(requestAccessForMediaType:completionHandler:), t, h);
    };
  });
  GCReplace(AVCaptureDevice.class, @selector(defaultDeviceWithMediaType:), YES, ^id(IMP orig) {
    return ^id(id self, AVMediaType t) {
      NSArray *found = GCDevicesMatching(nil, t, AVCaptureDevicePositionUnspecified);
      if (found.count) return found.firstObject;
      return ((id(*)(id, SEL, AVMediaType))orig)(self, @selector(defaultDeviceWithMediaType:), t);
    };
  });
  GCReplace(AVCaptureDevice.class, @selector(defaultDeviceWithDeviceType:mediaType:position:), YES, ^id(IMP orig) {
    return ^id(id self, AVCaptureDeviceType type, AVMediaType t, AVCaptureDevicePosition p) {
      if ([t isEqualToString:AVMediaTypeVideo] && GCActive()) {
        NSArray *found = GCDevicesMatching(@[ type ], t, p == AVCaptureDevicePositionUnspecified ? AVCaptureDevicePositionBack : p);
        return found.firstObject;
      }
      return ((id(*)(id, SEL, id, id, NSInteger))orig)(self, @selector(defaultDeviceWithDeviceType:mediaType:position:), type, t, p);
    };
  });
  GCReplace(AVCaptureDevice.class, @selector(deviceWithUniqueID:), YES, ^id(IMP orig) {
    return ^id(id self, NSString *uid) {
      if (GCActive() && [uid isEqualToString:@"glint-back-camera"] && [GCFeedConfig.current forLens:GCLensBack]) return [GCDevice deviceForLens:GCLensBack];
      if (GCActive() && [uid isEqualToString:@"glint-front-camera"] && [GCFeedConfig.current forLens:GCLensFront]) return [GCDevice deviceForLens:GCLensFront];
      return ((id(*)(id, SEL, id))orig)(self, @selector(deviceWithUniqueID:), uid);
    };
  });
  GCReplace(AVCaptureDevice.class, @selector(devicesWithMediaType:), YES, ^id(IMP orig) {
    return ^id(id self, AVMediaType t) {
      NSArray *found = GCDevicesMatching(nil, t, AVCaptureDevicePositionUnspecified);
      NSArray *real = ((id(*)(id, SEL, id))orig)(self, @selector(devicesWithMediaType:), t);
      return [found arrayByAddingObjectsFromArray:real ?: @[]];
    };
  });
  GCReplace(AVCaptureDeviceDiscoverySession.class, @selector(discoverySessionWithDeviceTypes:mediaType:position:), YES, ^id(IMP orig) {
    return ^id(id self, NSArray *types, AVMediaType t, AVCaptureDevicePosition p) {
      if (!GCActive()) return ((id(*)(id, SEL, id, id, NSInteger))orig)(self, @selector(discoverySessionWithDeviceTypes:mediaType:position:), types, t, p);
      GCDiscovery *d = GCNew(GCDiscovery.class);
      d.found = GCDevicesMatching(types, t, p);
      return d;
    };
  });
}

static void GCInstallInputHooks(void) {
  GCReplace(AVCaptureDeviceInput.class, @selector(initWithDevice:error:), NO, ^id(IMP orig) {
    return ^id(id self, AVCaptureDevice *device, NSError **err) {
      if ([device isKindOfClass:GCDevice.class]) {
        CFRetain((__bridge CFTypeRef)self);
        objc_setAssociatedObject(self, kFakeInputKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kInputDeviceKey, device, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        GCPort *port = GCNew(GCPort.class);
        port.owner = self;
        objc_setAssociatedObject(self, kInputPortsKey, @[ port ], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return self;
      }
      return ((id(*)(id, SEL, id, NSError **))orig)(self, @selector(initWithDevice:error:), device, err);
    };
  });
  GCReplace(AVCaptureDeviceInput.class, @selector(device), NO, ^id(IMP orig) {
    return ^id(id self) {
      id d = objc_getAssociatedObject(self, kInputDeviceKey);
      return d ?: ((id(*)(id, SEL))orig)(self, @selector(device));
    };
  });
  GCReplace(AVCaptureDeviceInput.class, @selector(ports), NO, ^id(IMP orig) {
    return ^id(id self) {
      id p = objc_getAssociatedObject(self, kInputPortsKey);
      return p ?: ((id(*)(id, SEL))orig)(self, @selector(ports));
    };
  });
  GCReplace(AVCaptureDeviceInput.class, @selector(setUnifiedAutoExposureDefaultsEnabled:), NO, ^id(IMP orig) {
    return ^void(id self, BOOL b) {
      if (GCIsFakeInput(self)) return;
      ((void (*)(id, SEL, BOOL))orig)(self, @selector(setUnifiedAutoExposureDefaultsEnabled:), b);
    };
  });
}

#define GC_CONN_BOOL(selname, fake)                                                              \
  GCReplace(AVCaptureConnection.class, @selector(selname), NO, ^id(IMP orig) {                   \
    return ^BOOL(id self) {                                                                      \
      return GCConnStateOf(self) ? (fake) : ((BOOL(*)(id, SEL))orig)(self, @selector(selname));  \
    };                                                                                           \
  });

static void GCInstallConnectionHooks(void) {
  GCReplace(AVCaptureConnection.class, @selector(initWithInputPorts:output:), NO, ^id(IMP orig) {
    return ^id(id self, NSArray *ports, AVCaptureOutput *output) {
      if ([ports.firstObject isKindOfClass:GCPort.class]) {
        GCConnState *cs = [GCConnState new];
        cs.output = output;
        cs.ports = ports;
        cs.input = ((GCPort *)ports.firstObject).input;
        CFRetain((__bridge CFTypeRef)self);
        objc_setAssociatedObject(self, kConnectionStateKey, cs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return self;
      }
      return ((id(*)(id, SEL, id, id))orig)(self, @selector(initWithInputPorts:output:), ports, output);
    };
  });
  GCReplace(AVCaptureConnection.class, @selector(inputPorts), NO, ^id(IMP orig) {
    return ^id(id self) {
      GCConnState *cs = GCConnStateOf(self);
      return cs ? cs.ports : ((id(*)(id, SEL))orig)(self, @selector(inputPorts));
    };
  });
  GCReplace(AVCaptureConnection.class, @selector(output), NO, ^id(IMP orig) {
    return ^id(id self) {
      GCConnState *cs = GCConnStateOf(self);
      return cs ? cs.output : ((id(*)(id, SEL))orig)(self, @selector(output));
    };
  });
  GCReplace(AVCaptureConnection.class, @selector(isVideoMirrored), NO, ^id(IMP orig) {
    return ^BOOL(id self) {
      GCConnState *cs = GCConnStateOf(self);
      return cs ? cs.mirrored : ((BOOL(*)(id, SEL))orig)(self, @selector(isVideoMirrored));
    };
  });
  GCReplace(AVCaptureConnection.class, @selector(setVideoMirrored:), NO, ^id(IMP orig) {
    return ^void(id self, BOOL b) {
      GCConnState *cs = GCConnStateOf(self);
      if (cs) cs.mirrored = b;
      else ((void (*)(id, SEL, BOOL))orig)(self, @selector(setVideoMirrored:), b);
    };
  });
  GC_CONN_BOOL(isVideoMirroringSupported, YES)
  GC_CONN_BOOL(automaticallyAdjustsVideoMirroring, NO)
  GC_CONN_BOOL(isVideoOrientationSupported, YES)
  GC_CONN_BOOL(isVideoStabilizationSupported, NO)
  GC_CONN_BOOL(isEnabled, YES)
  GC_CONN_BOOL(isActive, YES)
  GCReplace(AVCaptureConnection.class, @selector(setAutomaticallyAdjustsVideoMirroring:), NO, ^id(IMP orig) {
    return ^void(id self, BOOL b) {
      if (!GCConnStateOf(self)) ((void (*)(id, SEL, BOOL))orig)(self, @selector(setAutomaticallyAdjustsVideoMirroring:), b);
    };
  });
  GCReplace(AVCaptureConnection.class, @selector(videoOrientation), NO, ^id(IMP orig) {
    return ^AVCaptureVideoOrientation(id self) {
      GCConnState *cs = GCConnStateOf(self);
      return cs ? cs.orientation : ((AVCaptureVideoOrientation(*)(id, SEL))orig)(self, @selector(videoOrientation));
    };
  });
  GCReplace(AVCaptureConnection.class, @selector(setVideoOrientation:), NO, ^id(IMP orig) {
    return ^void(id self, AVCaptureVideoOrientation o) {
      GCConnState *cs = GCConnStateOf(self);
      if (cs) cs.orientation = o;
      else ((void (*)(id, SEL, AVCaptureVideoOrientation))orig)(self, @selector(setVideoOrientation:), o);
    };
  });
  GCReplace(AVCaptureConnection.class, @selector(isVideoRotationAngleSupported:), NO, ^id(IMP orig) {
    return ^BOOL(id self, CGFloat a) {
      return GCConnStateOf(self) ? YES : ((BOOL(*)(id, SEL, CGFloat))orig)(self, @selector(isVideoRotationAngleSupported:), a);
    };
  });
  GCReplace(AVCaptureConnection.class, @selector(videoRotationAngle), NO, ^id(IMP orig) {
    return ^CGFloat(id self) {
      GCConnState *cs = GCConnStateOf(self);
      if (!cs) return ((CGFloat(*)(id, SEL))orig)(self, @selector(videoRotationAngle));
      switch (cs.orientation) {
        case AVCaptureVideoOrientationPortrait: return 90;
        case AVCaptureVideoOrientationPortraitUpsideDown: return 270;
        case AVCaptureVideoOrientationLandscapeLeft: return 180;
        default: return 0;
      }
    };
  });
  GCReplace(AVCaptureConnection.class, @selector(setVideoRotationAngle:), NO, ^id(IMP orig) {
    return ^void(id self, CGFloat a) {
      GCConnState *cs = GCConnStateOf(self);
      if (!cs) { ((void (*)(id, SEL, CGFloat))orig)(self, @selector(setVideoRotationAngle:), a); return; }
      int q = ((int)llround(a / 90.0) % 4 + 4) % 4;
      AVCaptureVideoOrientation map[4] = {AVCaptureVideoOrientationLandscapeRight, AVCaptureVideoOrientationPortrait, AVCaptureVideoOrientationLandscapeLeft, AVCaptureVideoOrientationPortraitUpsideDown};
      cs.orientation = map[q];
    };
  });
  GCReplace(AVCaptureConnection.class, @selector(setPreferredVideoStabilizationMode:), NO, ^id(IMP orig) {
    return ^void(id self, AVCaptureVideoStabilizationMode m) {
      if (!GCConnStateOf(self)) ((void (*)(id, SEL, AVCaptureVideoStabilizationMode))orig)(self, @selector(setPreferredVideoStabilizationMode:), m);
    };
  });
}

static AVCaptureConnection *GCMakeConnection(AVCaptureSession *s, GCSessState *st, AVCaptureOutput *out) {
  AVCaptureInput *input = st.inputs.firstObject;
  AVCaptureConnection *c = [[AVCaptureConnection alloc] initWithInputPorts:[input ports] output:out];
  [st.connections addObject:c];
  return c;
}

static void GCInstallSessionHooks(void) {
  Class S = AVCaptureSession.class;
  GCReplace(S, @selector(addInputWithNoConnections:), NO, ^id(IMP orig) {
    return ^void(AVCaptureSession *self, AVCaptureInput *input) {
      if (GCIsFakeInput(input)) {
        GCSessState *st = GCStateOf(self, YES);
        @synchronized(st) { [st.inputs addObject:input]; }
        return;
      }
      ((void (*)(id, SEL, id))orig)(self, @selector(addInputWithNoConnections:), input);
    };
  });
  GCReplace(S, @selector(addInput:), NO, ^id(IMP orig) {
    return ^void(AVCaptureSession *self, AVCaptureInput *input) {
      if (GCIsFakeInput(input)) {
        GCSessState *st = GCStateOf(self, YES);
        @synchronized(st) {
          [st.inputs addObject:input];
          for (AVCaptureOutput *o in [st.outputs copy]) GCOutStateOf(o).connection = GCMakeConnection(self, st, o);
        }
        return;
      }
      ((void (*)(id, SEL, id))orig)(self, @selector(addInput:), input);
    };
  });
  GCReplace(S, @selector(canAddInput:), NO, ^id(IMP orig) {
    return ^BOOL(AVCaptureSession *self, AVCaptureInput *input) {
      if (GCIsFakeInput(input)) return YES;
      return ((BOOL(*)(id, SEL, id))orig)(self, @selector(canAddInput:), input);
    };
  });
  GCReplace(S, @selector(removeInput:), NO, ^id(IMP orig) {
    return ^void(AVCaptureSession *self, AVCaptureInput *input) {
      if (GCIsFakeInput(input)) {
        GCSessState *st = GCStateOf(self, NO);
        @synchronized(st) { [st.inputs removeObject:input]; }
        return;
      }
      ((void (*)(id, SEL, id))orig)(self, @selector(removeInput:), input);
    };
  });
  GCReplace(S, @selector(addOutputWithNoConnections:), NO, ^id(IMP orig) {
    return ^void(AVCaptureSession *self, AVCaptureOutput *out) {
      GCSessState *st = GCStateOf(self, NO);
      if (st && st.inputs.count) {
        @synchronized(st) { [st.outputs addObject:out]; }
        GCOutStateOf(out).session = self;
        return;
      }
      ((void (*)(id, SEL, id))orig)(self, @selector(addOutputWithNoConnections:), out);
    };
  });
  GCReplace(S, @selector(addOutput:), NO, ^id(IMP orig) {
    return ^void(AVCaptureSession *self, AVCaptureOutput *out) {
      GCSessState *st = GCStateOf(self, NO);
      if (st && st.inputs.count) {
        GCOutState *os = GCOutStateOf(out);
        os.session = self;
        @synchronized(st) {
          [st.outputs addObject:out];
          os.connection = GCMakeConnection(self, st, out);
        }
        return;
      }
      ((void (*)(id, SEL, id))orig)(self, @selector(addOutput:), out);
    };
  });
  GCReplace(S, @selector(canAddOutput:), NO, ^id(IMP orig) {
    return ^BOOL(AVCaptureSession *self, AVCaptureOutput *out) {
      if (GCSessionIsFake(self)) return YES;
      return ((BOOL(*)(id, SEL, id))orig)(self, @selector(canAddOutput:), out);
    };
  });
  GCReplace(S, @selector(removeOutput:), NO, ^id(IMP orig) {
    return ^void(AVCaptureSession *self, AVCaptureOutput *out) {
      GCSessState *st = GCStateOf(self, NO);
      if (st && [st.outputs containsObject:out]) {
        @synchronized(st) { [st.outputs removeObject:out]; }
        return;
      }
      ((void (*)(id, SEL, id))orig)(self, @selector(removeOutput:), out);
    };
  });
  GCReplace(S, @selector(canAddConnection:), NO, ^id(IMP orig) {
    return ^BOOL(AVCaptureSession *self, AVCaptureConnection *c) {
      if (GCConnStateOf(c)) return YES;
      return ((BOOL(*)(id, SEL, id))orig)(self, @selector(canAddConnection:), c);
    };
  });
  GCReplace(S, @selector(addConnection:), NO, ^id(IMP orig) {
    return ^void(AVCaptureSession *self, AVCaptureConnection *c) {
      GCConnState *cs = GCConnStateOf(c);
      if (cs) {
        GCSessState *st = GCStateOf(self, YES);
        @synchronized(st) { [st.connections addObject:c]; }
        if (cs.output) GCOutStateOf(cs.output).connection = c;
        return;
      }
      ((void (*)(id, SEL, id))orig)(self, @selector(addConnection:), c);
    };
  });
  GCReplace(S, @selector(inputs), NO, ^id(IMP orig) {
    return ^id(AVCaptureSession *self) {
      GCSessState *st = GCStateOf(self, NO);
      if (st && st.inputs.count) { @synchronized(st) { return [st.inputs copy]; } }
      return ((id(*)(id, SEL))orig)(self, @selector(inputs));
    };
  });
  GCReplace(S, @selector(outputs), NO, ^id(IMP orig) {
    return ^id(AVCaptureSession *self) {
      GCSessState *st = GCStateOf(self, NO);
      if (st && st.inputs.count) { @synchronized(st) { return [st.outputs copy]; } }
      return ((id(*)(id, SEL))orig)(self, @selector(outputs));
    };
  });
  GCReplace(S, @selector(connections), NO, ^id(IMP orig) {
    return ^id(AVCaptureSession *self) {
      GCSessState *st = GCStateOf(self, NO);
      if (st && st.inputs.count) { @synchronized(st) { return [st.connections copy]; } }
      return ((id(*)(id, SEL))orig)(self, @selector(connections));
    };
  });
  GCReplace(S, @selector(setSessionPreset:), NO, ^id(IMP orig) {
    return ^void(AVCaptureSession *self, AVCaptureSessionPreset p) {
      GCSessState *st = GCStateOf(self, NO);
      if (st && st.inputs.count) { st.preset = p; return; }
      ((void (*)(id, SEL, id))orig)(self, @selector(setSessionPreset:), p);
    };
  });
  GCReplace(S, @selector(sessionPreset), NO, ^id(IMP orig) {
    return ^id(AVCaptureSession *self) {
      GCSessState *st = GCStateOf(self, NO);
      return st && st.inputs.count ? st.preset : ((id(*)(id, SEL))orig)(self, @selector(sessionPreset));
    };
  });
  GCReplace(S, @selector(canSetSessionPreset:), NO, ^id(IMP orig) {
    return ^BOOL(AVCaptureSession *self, AVCaptureSessionPreset p) {
      if (GCSessionIsFake(self)) return YES;
      return ((BOOL(*)(id, SEL, id))orig)(self, @selector(canSetSessionPreset:), p);
    };
  });
  GCReplace(S, @selector(startRunning), NO, ^id(IMP orig) {
    return ^void(AVCaptureSession *self) {
      GCSessState *st = GCStateOf(self, NO);
      if (GCActive() && !st.inputs.count && ((NSArray *)((id(*)(id, SEL))objc_msgSend)(self, @selector(inputs))).count == 0) {
        GCStateOf(self, YES).idleRunning = YES;
        return;
      }
      if (st && st.inputs.count) {
        if (st.running) return;
        st.running = YES;
        GCStartTimer(self, st);
        dispatch_async(dispatch_get_main_queue(), ^{
          [NSNotificationCenter.defaultCenter postNotificationName:AVCaptureSessionDidStartRunningNotification object:self];
        });
        return;
      }
      ((void (*)(id, SEL))orig)(self, @selector(startRunning));
    };
  });
  GCReplace(S, @selector(stopRunning), NO, ^id(IMP orig) {
    return ^void(AVCaptureSession *self) {
      GCSessState *st = GCStateOf(self, NO);
      if (st.idleRunning && !st.inputs.count) { st.idleRunning = NO; return; }
      if (st && st.inputs.count) {
        st.running = NO;
        if (st.timer) { dispatch_source_cancel(st.timer); st.timer = nil; }
        dispatch_async(dispatch_get_main_queue(), ^{
          [NSNotificationCenter.defaultCenter postNotificationName:AVCaptureSessionDidStopRunningNotification object:self];
        });
        return;
      }
      ((void (*)(id, SEL))orig)(self, @selector(stopRunning));
    };
  });
  GCReplace(S, @selector(isRunning), NO, ^id(IMP orig) {
    return ^BOOL(AVCaptureSession *self) {
      GCSessState *st = GCStateOf(self, NO);
      if (st.idleRunning && !st.inputs.count) return YES;
      return st && st.inputs.count ? st.running : ((BOOL(*)(id, SEL))orig)(self, @selector(isRunning));
    };
  });
  GCReplace(S, @selector(beginConfiguration), NO, ^id(IMP orig) {
    return ^void(AVCaptureSession *self) {
      if (GCSessionIsFake(self)) return;
      ((void (*)(id, SEL))orig)(self, @selector(beginConfiguration));
    };
  });
  GCReplace(S, @selector(commitConfiguration), NO, ^id(IMP orig) {
    return ^void(AVCaptureSession *self) {
      if (GCSessionIsFake(self)) return;
      ((void (*)(id, SEL))orig)(self, @selector(commitConfiguration));
    };
  });
}

static void GCInstallOutputHooks(void) {
  GCReplace(AVCapturePhotoOutput.class, @selector(init), NO, ^id(IMP orig) {
    return ^id(id self) {
      GCBypassDepth++;
      id r = ((id(*)(id, SEL))orig)(self, @selector(init));
      GCBypassDepth--;
      return r;
    };
  });
  GCReplace(AVCapturePhotoSettings.class, @selector(photoSettings), YES, ^id(IMP orig) {
    return ^id(id self) {
      GCBypassDepth++;
      id r = ((id(*)(id, SEL))orig)(self, @selector(photoSettings));
      GCBypassDepth--;
      return r;
    };
  });
  GCReplace(AVCapturePhotoSettings.class, @selector(photoSettingsWithFormat:), YES, ^id(IMP orig) {
    return ^id(id self, id f) {
      GCBypassDepth++;
      id r = ((id(*)(id, SEL, id))orig)(self, @selector(photoSettingsWithFormat:), f);
      GCBypassDepth--;
      return r;
    };
  });
  Class V = AVCaptureVideoDataOutput.class;
  GCReplace(V, @selector(setSampleBufferDelegate:queue:), NO, ^id(IMP orig) {
    return ^void(AVCaptureVideoDataOutput *self, id d, dispatch_queue_t q) {
      GCOutState *st = GCOutStateOf(self);
      st.delegate = d;
      st.queue = q;
      ((void (*)(id, SEL, id, id))orig)(self, @selector(setSampleBufferDelegate:queue:), d, q);
    };
  });
  GCReplace(V, @selector(setVideoSettings:), NO, ^id(IMP orig) {
    return ^void(AVCaptureVideoDataOutput *self, NSDictionary *s) {
      GCOutStateOf(self).videoSettings = s;
      if (!GCActive()) ((void (*)(id, SEL, id))orig)(self, @selector(setVideoSettings:), s);
    };
  });
  GCReplace(V, @selector(videoSettings), NO, ^id(IMP orig) {
    return ^id(AVCaptureVideoDataOutput *self) {
      GCOutState *st = objc_getAssociatedObject(self, kOutputStateKey);
      if (st.videoSettings && GCActive()) return st.videoSettings;
      return ((id(*)(id, SEL))orig)(self, @selector(videoSettings));
    };
  });
  GCReplace(V, @selector(availableVideoCVPixelFormatTypes), NO, ^id(IMP orig) {
    return ^id(AVCaptureVideoDataOutput *self) {
      if (GCOutStateOf(self).session) return @[ @(kCVPixelFormatType_32BGRA), @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ];
      return ((id(*)(id, SEL))orig)(self, @selector(availableVideoCVPixelFormatTypes));
    };
  });
  GCReplace(AVCaptureOutput.class, @selector(connectionWithMediaType:), NO, ^id(IMP orig) {
    return ^id(AVCaptureOutput *self, AVMediaType t) {
      GCOutState *os = objc_getAssociatedObject(self, kOutputStateKey);
      if (os.connection && [t isEqualToString:AVMediaTypeVideo]) return os.connection;
      return ((id(*)(id, SEL, id))orig)(self, @selector(connectionWithMediaType:), t);
    };
  });
  GCReplace(AVCaptureOutput.class, @selector(connections), NO, ^id(IMP orig) {
    return ^id(AVCaptureOutput *self) {
      GCOutState *os = objc_getAssociatedObject(self, kOutputStateKey);
      if (os.connection) return @[ os.connection ];
      return ((id(*)(id, SEL))orig)(self, @selector(connections));
    };
  });
  Class P = AVCapturePhotoOutput.class;
  GCReplace(P, @selector(capturePhotoWithSettings:delegate:), NO, ^id(IMP orig) {
    return ^void(AVCapturePhotoOutput *self, AVCapturePhotoSettings *s, id d) {
      if (GCOutStateOf(self).session) { GCCapturePhoto(self, s, d); return; }
      ((void (*)(id, SEL, id, id))orig)(self, @selector(capturePhotoWithSettings:delegate:), s, d);
    };
  });
  GCReplace(P, @selector(setMaxPhotoDimensions:), NO, ^id(IMP orig) {
    return ^void(AVCapturePhotoOutput *self, CMVideoDimensions d) {
      if (GCOutStateOf(self).session) return;
      ((void (*)(id, SEL, CMVideoDimensions))orig)(self, @selector(setMaxPhotoDimensions:), d);
    };
  });
  GCReplace(P, @selector(maxPhotoDimensions), NO, ^id(IMP orig) {
    return ^CMVideoDimensions(AVCapturePhotoOutput *self) {
      if (GCOutStateOf(self).session) return (CMVideoDimensions){4032, 3024};
      return ((CMVideoDimensions(*)(id, SEL))orig)(self, @selector(maxPhotoDimensions));
    };
  });
  GCReplace(P, @selector(setHighResolutionCaptureEnabled:), NO, ^id(IMP orig) {
    return ^void(AVCapturePhotoOutput *self, BOOL b) {
      if (GCOutStateOf(self).session) return;
      ((void (*)(id, SEL, BOOL))orig)(self, @selector(setHighResolutionCaptureEnabled:), b);
    };
  });
  GCReplace(P, @selector(isHighResolutionCaptureEnabled), NO, ^id(IMP orig) {
    return ^BOOL(AVCapturePhotoOutput *self) {
      if (GCOutStateOf(self).session) return YES;
      return ((BOOL(*)(id, SEL))orig)(self, @selector(isHighResolutionCaptureEnabled));
    };
  });
  GCReplace(P, @selector(supportedFlashModes), NO, ^id(IMP orig) {
    return ^id(AVCapturePhotoOutput *self) {
      return GCOutStateOf(self).session ? @[ @(AVCaptureFlashModeOff) ] : ((id(*)(id, SEL))orig)(self, @selector(supportedFlashModes));
    };
  });
  GCReplace(P, @selector(availablePhotoCodecTypes), NO, ^id(IMP orig) {
    return ^id(AVCapturePhotoOutput *self) {
      return GCOutStateOf(self).session ? @[ AVVideoCodecTypeJPEG ] : ((id(*)(id, SEL))orig)(self, @selector(availablePhotoCodecTypes));
    };
  });
}

@interface GSICameraModule : NSObject <GSIModule>
@end

@implementation GSICameraModule
+ (NSString *)moduleName { return @"camera"; }
- (void)activateWithConfig:(NSDictionary *)config {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    GCInstallDeviceHooks();
    GCInstallInputHooks();
    GCInstallConnectionHooks();
    GCInstallSessionHooks();
    GCInstallOutputHooks();
  });
  [GCFeedConfig.current setFront:config[@"front"] back:config[@"back"]];
}
- (void)deactivate {
  [GCFeedConfig.current setFront:nil back:nil];
}
@end

__attribute__((constructor(110))) static void GSICameraRegister(void) {
  GSIRegisterModule(GSICameraModule.class);
}
