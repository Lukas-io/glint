#import "siminject.h"
#import "camera_feed.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>

static NSString *const GSBUploadPoint = @"com.apple.broadcast-services-upload";
static const int GSBTypeVideo = 1;
static const int GSBTypeAudioApp = 2;
static const double GSBSampleRate = 44100;
static const uint32_t GSBAudioChunk = 1024;

extern int NSExtensionMain(int argc, char **argv);

static NSString *GSBDir(void) {
  NSString *dir = [GSIControlDir() stringByAppendingPathComponent:@"broadcast"];
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  return dir;
}

static void GSBWriteJSON(NSString *name, NSDictionary *object) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
  NSString *path = [GSBDir() stringByAppendingPathComponent:name];
  [data writeToFile:path atomically:YES];
}

static NSDictionary *GSBReadConfig(void) {
  NSData *data = [NSData dataWithContentsOfFile:[GSIControlDir() stringByAppendingString:@"/modules/broadcast.json"]];
  id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

static void GSBLog(NSString *line) { fprintf(stderr, "glint-broadcast: %s\n", line.UTF8String); }

static BOOL GSBIsUploadExtension(void) {
  NSDictionary *ext = NSBundle.mainBundle.infoDictionary[@"NSExtension"];
  return [ext isKindOfClass:NSDictionary.class] && [ext[@"NSExtensionPointIdentifier"] isEqual:GSBUploadPoint];
}

static BOOL GSBHostedByGlint(void) {
  if (!getenv("GLINT_BROADCAST_HOST") || !GSBIsUploadExtension()) return NO;
  return [NSBundle.mainBundle.bundlePath containsString:@"/Containers/Bundle/Application/"];
}

static BOOL GSBTargets(NSDictionary *config, NSString *key) {
  NSString *want = config[key];
  return want.length && [want isEqualToString:NSBundle.mainBundle.bundleIdentifier];
}

static NSString *GSBHash(NSString *text) {
  uint32_t h = 0x811c9dc5;
  for (const unsigned char *p = (const unsigned char *)text.UTF8String; *p; p++) h = (h ^ *p) * 0x01000193;
  return [NSString stringWithFormat:@"%08x", h];
}

static NSString *volatile GSBShortRoot;

static NSURL *GSBShortURL(NSURL *real, NSString *root) {
  NSString *target = real.path;
  if (target.length + 18 <= 100) return real;
  NSFileManager *fm = NSFileManager.defaultManager;
  [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions : @0700} error:nil];
  NSString *link = [root stringByAppendingPathComponent:GSBHash(target)];
  NSString *current = [fm destinationOfSymbolicLinkAtPath:link error:nil];
  if (![current isEqualToString:target]) {
    [fm removeItemAtPath:link error:nil];
    if (symlink(target.fileSystemRepresentation, link.fileSystemRepresentation) != 0) return real;
  }
  return [NSURL fileURLWithPath:link isDirectory:YES];
}

static void GSBInstallGroupHook(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    SEL sel = @selector(containerURLForSecurityApplicationGroupIdentifier:);
    Method m = class_getInstanceMethod(NSFileManager.class, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^NSURL *(NSFileManager *self, NSString *group) {
      NSURL *real = ((NSURL * (*)(id, SEL, id)) orig)(self, sel, group);
      NSString *root = GSBShortRoot;
      return real && root ? GSBShortURL(real, root) : real;
    }));
  });
}

static NSString *volatile GSBPickerAppId;
static volatile BOOL GSBCapturing;
static volatile pid_t GSBOwner;

static BOOL GSBOwnerAlive(void) {
  pid_t owner = GSBOwner;
  return owner <= 0 || kill(owner, 0) == 0 || errno == EPERM;
}

static dispatch_source_t GSBWatchProcess(pid_t target, void (^gone)(void)) {
  if (target <= 0) return nil;
  if (kill(target, 0) != 0 && errno != EPERM) {
    dispatch_async(dispatch_get_main_queue(), gone);
    return nil;
  }
  dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, target, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
  dispatch_source_set_event_handler(source, gone);
  dispatch_resume(source);
  return source;
}

static void GSBHookPicker(void) {
  static dispatch_once_t once;
  Class picker = NSClassFromString(@"RPSystemBroadcastPickerView");
  if (!picker) return;
  dispatch_once(&once, ^{
    SEL sel = NSSelectorFromString(@"buttonPressed:");
    Method m = class_getInstanceMethod(picker, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^void(id self, id sender) {
      if (!GSBPickerAppId || !GSBOwnerAlive()) {
        ((void (*)(id, SEL, id)) orig)(self, sel, sender);
        return;
      }
      NSDictionary *press = @{
        @"pid" : @(getpid()),
        @"bundleId" : NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"at" : @([NSDate.date timeIntervalSince1970]),
        @"preferredExtension" : [self valueForKey:@"preferredExtension"] ?: NSNull.null,
        @"showsMicrophoneButton" : [self valueForKey:@"showsMicrophoneButton"] ?: @NO,
      };
      GSBWriteJSON(@"picker.json", press);
    }));
  });
}

static void GSBHookCaptured(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    SEL sel = @selector(isCaptured);
    Method m = class_getInstanceMethod(UIScreen.class, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^BOOL(UIScreen *self) {
      return GSBCapturing ?: ((BOOL (*)(id, SEL)) orig)(self, sel);
    }));
  });
}

static void GSBImageAdded(const struct mach_header *header, intptr_t slide) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (GSBPickerAppId) GSBHookPicker();
  });
}

static void GSBSetCapturing(BOOL capturing);

static void GSBWatchOwner(pid_t owner) {
  static dispatch_source_t watch;
  static pid_t watched;
  if (owner == watched && (owner <= 0 || watch)) return;
  if (watch) dispatch_source_cancel(watch);
  watch = nil;
  watched = owner;
  GSBOwner = owner;
  if (owner <= 0) return;
  watch = GSBWatchProcess(owner, ^{
    GSBSetCapturing(NO);
    GSBPickerAppId = nil;
    GSBShortRoot = nil;
  });
}

static void GSBSetCapturing(BOOL capturing) {
  if (GSBCapturing == capturing) return;
  GSBCapturing = capturing;
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSNotificationCenter.defaultCenter postNotificationName:UIScreenCapturedDidChangeNotification object:UIScreen.mainScreen];
  });
}


static CIImage *GSBContain(CIImage *scene, CGSize size) {
  CGRect e = scene.extent;
  if (CGRectIsEmpty(e) || CGRectIsInfinite(e)) return nil;
  CGFloat s = MIN(size.width / e.size.width, size.height / e.size.height);
  CIImage *img = [scene imageByApplyingTransform:CGAffineTransformMakeTranslation(-e.origin.x, -e.origin.y)];
  img = [img imageByApplyingTransform:CGAffineTransformMakeScale(s, s)];
  img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation((size.width - e.size.width * s) / 2,
                                                                       (size.height - e.size.height * s) / 2)];
  CGRect frame = CGRectMake(0, 0, size.width, size.height);
  CIImage *black = [[CIImage imageWithColor:CIColor.blackColor] imageByCroppingToRect:frame];
  return [[img imageByCroppingToRect:frame] imageByCompositingOverImage:black];
}

typedef NS_ENUM(NSInteger, GSBRefill) { GSBRefillData, GSBRefillEnd, GSBRefillFailed };

@interface GSBAudioSource : NSObject
@property(atomic, copy) NSString *error;
- (instancetype)initWithSpec:(NSDictionary *)spec;
- (NSData *)framesOfCount:(uint32_t)count;
@end

@implementation GSBAudioSource {
  NSDictionary *_spec;
  double _phase;
  NSMutableData *_pcm;
  AVAssetReader *_reader;
  AVAssetReaderTrackOutput *_out;
}
- (instancetype)initWithSpec:(NSDictionary *)spec {
  if ((self = [super init])) {
    _spec = spec;
    _pcm = [NSMutableData new];
  }
  return self;
}
- (GSBRefill)refillFromFile {
  if (!_reader) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:_spec[@"path"]] options:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!track) {
      self.error = @"the audio file has no audio track";
      return GSBRefillFailed;
    }
    NSDictionary *settings = @{
      AVFormatIDKey : @(kAudioFormatLinearPCM),
      AVLinearPCMBitDepthKey : @16,
      AVLinearPCMIsFloatKey : @NO,
      AVLinearPCMIsBigEndianKey : @NO,
      AVLinearPCMIsNonInterleaved : @NO,
      AVSampleRateKey : @(GSBSampleRate),
      AVNumberOfChannelsKey : @2,
    };
    NSError *made = nil;
    _reader = [AVAssetReader assetReaderWithAsset:asset error:&made];
    if (!_reader) {
      self.error = made.localizedDescription ?: @"the audio file cannot be opened";
      return GSBRefillFailed;
    }
    _out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
    [_reader addOutput:_out];
    if (![_reader startReading]) {
      self.error = _reader.error.localizedDescription ?: @"the audio file cannot be decoded";
      _reader = nil;
      return GSBRefillFailed;
    }
  }
  CMSampleBufferRef sb = [_out copyNextSampleBuffer];
  if (!sb) {
    if (_reader.status == AVAssetReaderStatusFailed) {
      self.error = _reader.error.localizedDescription ?: @"the audio reader failed";
      _reader = nil;
      return GSBRefillFailed;
    }
    _reader = nil;
    return GSBRefillEnd;
  }
  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sb);
  size_t length = CMBlockBufferGetDataLength(block);
  NSMutableData *chunk = [NSMutableData dataWithLength:length];
  CMBlockBufferCopyDataBytes(block, 0, length, chunk.mutableBytes);
  [_pcm appendData:chunk];
  CFRelease(sb);
  return GSBRefillData;
}
- (NSData *)framesOfCount:(uint32_t)count {
  size_t need = (size_t)count * 4;
  if ([_spec[@"kind"] isEqualToString:@"file"]) {
    if (self.error) return nil;
    BOOL restarted = NO;
    BOOL decodedSinceRestart = NO;
    while (_pcm.length < need) {
      GSBRefill step = [self refillFromFile];
      if (step == GSBRefillFailed) return nil;
      if (step == GSBRefillData) {
        decodedSinceRestart = YES;
        continue;
      }
      if (restarted && !decodedSinceRestart) {
        self.error = @"the audio file decodes to no audio";
        return nil;
      }
      if (restarted) break;
      restarted = YES;
      decodedSinceRestart = NO;
    }
    if (_pcm.length < need) return nil;
    NSData *out = [_pcm subdataWithRange:NSMakeRange(0, need)];
    [_pcm replaceBytesInRange:NSMakeRange(0, need) withBytes:NULL length:0];
    return out;
  }
  double hz = [_spec[@"hz"] doubleValue] ?: 440;
  NSMutableData *out = [NSMutableData dataWithLength:need];
  int16_t *p = out.mutableBytes;
  for (uint32_t i = 0; i < count; i++) {
    int16_t v = (int16_t)(sin(_phase) * 8000);
    p[2 * i] = v;
    p[2 * i + 1] = v;
    _phase += 2 * M_PI * hz / GSBSampleRate;
    if (_phase > 2 * M_PI) _phase -= 2 * M_PI;
  }
  return out;
}
@end

static CMSampleBufferRef GSBAudioSampleBuffer(NSData *pcm, uint32_t frames, CMTime pts) {
  AudioStreamBasicDescription asbd = {GSBSampleRate, kAudioFormatLinearPCM,
                                      kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 4, 1, 4, 2, 16, 0};
  CMAudioFormatDescriptionRef format = NULL;
  if (CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, 0, NULL, NULL, &format) != noErr) return NULL;
  CMBlockBufferRef block = NULL;
  CMBlockBufferCreateWithMemoryBlock(NULL, NULL, pcm.length, NULL, NULL, 0, pcm.length, kCMBlockBufferAssureMemoryNowFlag,
                                     &block);
  CMSampleBufferRef sb = NULL;
  if (block) {
    CMBlockBufferReplaceDataBytes(pcm.bytes, block, 0, pcm.length);
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, block, format, frames, pts, NULL, &sb);
    CFRelease(block);
  }
  CFRelease(format);
  return sb;
}


@interface GSBRun : NSObject
@property(nonatomic, strong) id handler;
@property(nonatomic, strong) NSDictionary *config;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) dispatch_source_t videoTimer;
@property(nonatomic, strong) dispatch_source_t audioTimer;
@property(nonatomic, strong) dispatch_source_t reportTimer;
@property(nonatomic, strong) GCSource *video;
@property(nonatomic, strong) GSBAudioSource *audio;
@property(nonatomic) BOOL paused;
@property(atomic) BOOL finishing;
@property(nonatomic) CVPixelBufferPoolRef pool;
@property(nonatomic) CGSize size;
@property(nonatomic, strong) CIContext *context;
@property(nonatomic) CMTime audioClock;
@property(nonatomic) CMTime frameDuration;
@property(nonatomic, strong) NSMutableDictionary *report;
@property(nonatomic, strong) NSDate *startedAt;
+ (instancetype)shared;
- (void)begin;
- (void)setPausedFromConfig:(BOOL)paused;
- (void)finishWithState:(NSString *)state callHandler:(BOOL)callHandler;
- (void)recordFinishError:(NSError *)error;
- (void)bump:(NSString *)key;
- (void)setReport:(id)value forKey:(NSString *)key;
@end

static NSDictionary *GSBErrorJSON(NSError *error) {
  return @{@"domain" : error.domain ?: @"", @"code" : @(error.code), @"message" : error.localizedDescription ?: @""};
}

static void GSBSend(id handler, NSString *selector, id arg) {
  @try {
    ((void (*)(id, SEL, id))objc_msgSend)(handler, NSSelectorFromString(selector), arg);
  } @catch (NSException *e) {
    GSBLog([NSString stringWithFormat:@"%@ threw %@: %@", selector, e.name, e.reason]);
    [GSBRun.shared setReport:@{@"in" : selector, @"name" : e.name ?: @"", @"reason" : e.reason ?: @""} forKey:@"exception"];
  }
}

static void GSBSendSample(id handler, CMSampleBufferRef sb, int type) {
  @try {
    ((void (*)(id, SEL, CMSampleBufferRef, NSInteger))objc_msgSend)(
        handler, NSSelectorFromString(@"processSampleBuffer:withType:"), sb, type);
  } @catch (NSException *e) {
    GSBLog([NSString stringWithFormat:@"processSampleBuffer threw %@: %@", e.name, e.reason]);
    [GSBRun.shared setReport:@{@"in" : @"processSampleBuffer", @"name" : e.name ?: @"", @"reason" : e.reason ?: @""}
                      forKey:@"exception"];
  }
}

@implementation GSBRun
+ (instancetype)shared {
  static GSBRun *run;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    run = [GSBRun new];
    run.queue = dispatch_queue_create("glint.broadcast.samples", DISPATCH_QUEUE_SERIAL);
    run.report = [NSMutableDictionary new];
  });
  return run;
}

- (void)bump:(NSString *)key {
  @synchronized(self.report) {
    self.report[key] = @([self.report[key] longLongValue] + 1);
  }
}

- (void)setReport:(id)value forKey:(NSString *)key {
  @synchronized(self.report) {
    self.report[key] = value;
  }
}

- (void)flushReport {
  NSDictionary *copy;
  @synchronized(self.report) {
    copy = [self.report copy];
  }
  GSBWriteJSON(@"report.json", copy);
}

- (void)setState:(NSString *)state {
  @synchronized(self.report) {
    self.report[@"state"] = state;
  }
  [self flushReport];
}

- (void)fail:(NSString *)reason detail:(NSString *)detail {
  GSBLog([NSString stringWithFormat:@"%@: %@", reason, detail]);
  @synchronized(self.report) {
    self.report[@"failure"] = @{@"reason" : reason, @"detail" : detail};
  }
  [self setState:@"failed"];
}

- (CVPixelBufferRef)newVideoBuffer:(CIImage *)image {
  if (!self.pool) {
    CGRect e = image.extent;
    CGSize size = CGSizeMake([self.config[@"width"] doubleValue], [self.config[@"height"] doubleValue]);
    if (size.width < 2 || size.height < 2) size = e.size;
    size = CGSizeMake(floor(size.width / 2) * 2, floor(size.height / 2) * 2);
    self.size = size;
    NSDictionary *attrs = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
      (id)kCVPixelBufferWidthKey : @(size.width),
      (id)kCVPixelBufferHeightKey : @(size.height),
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    CVPixelBufferPoolRef pool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &pool);
    self.pool = pool;
    @synchronized(self.report) {
      self.report[@"video"] = @{
        @"width" : @(size.width),
        @"height" : @(size.height),
        @"pixelFormat" : @"420f",
        @"fps" : self.config[@"fps"] ?: @15
      };
    }
  }
  CIImage *fitted = GSBContain(image, self.size);
  if (!fitted) return NULL;
  CVPixelBufferRef pb = NULL;
  CVPixelBufferPoolCreatePixelBuffer(NULL, self.pool, &pb);
  if (!pb) return NULL;
  CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  [self.context render:fitted toCVPixelBuffer:pb bounds:CGRectMake(0, 0, self.size.width, self.size.height) colorSpace:rgb];
  CGColorSpaceRelease(rgb);
  return pb;
}

- (void)deliverVideo {
  if (self.paused || self.finishing) return;
  CIImage *image = [self.video currentImage];
  if (!image) {
    [self bump:@"videoSkipped"];
    return;
  }
  CVPixelBufferRef pb = [self newVideoBuffer:image];
  if (!pb) {
    [self bump:@"videoSkipped"];
    return;
  }
  CMVideoFormatDescriptionRef format = NULL;
  CMVideoFormatDescriptionCreateForImageBuffer(NULL, pb, &format);
  CMSampleTimingInfo timing = {self.frameDuration, CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid};
  CMSampleBufferRef sb = NULL;
  CMSampleBufferCreateReadyWithImageBuffer(NULL, pb, format, &timing, &sb);
  if (sb) {
    int orientation = 1;
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberIntType, &orientation);
    CMSetAttachment(sb, CFSTR("RPVideoSampleOrientationKey"), value, kCMAttachmentMode_ShouldPropagate);
    CFRelease(value);
    GSBSendSample(self.handler, sb, GSBTypeVideo);
    [self bump:@"videoDelivered"];
    CFRelease(sb);
  }
  if (format) CFRelease(format);
  CVPixelBufferRelease(pb);
}

- (void)deliverAudio {
  if (self.paused || self.finishing || !self.audio) return;
  CMTime now = CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), (int32_t)GSBSampleRate, kCMTimeRoundingMethod_Default);
  for (int chunks = 0; chunks < 24 && CMTimeCompare(CMTimeAdd(self.audioClock, CMTimeMake(GSBAudioChunk, (int32_t)GSBSampleRate)), now) <= 0; chunks++) {
    NSData *pcm = [self.audio framesOfCount:GSBAudioChunk];
    if (!pcm) {
      if (self.audio.error) {
        [self setReport:self.audio.error forKey:@"audioError"];
        GSBLog([NSString stringWithFormat:@"audio source failed: %@", self.audio.error]);
        self.audio = nil;
      }
      return;
    }
    CMSampleBufferRef sb = GSBAudioSampleBuffer(pcm, GSBAudioChunk, self.audioClock);
    if (!sb) return;
    self.audioClock = CMTimeAdd(self.audioClock, CMTimeMake(GSBAudioChunk, (int32_t)GSBSampleRate));
    GSBSendSample(self.handler, sb, GSBTypeAudioApp);
    [self bump:@"audioAppDelivered"];
    CFRelease(sb);
  }
}

- (dispatch_source_t)timerEvery:(double)seconds block:(void (^)(void))block {
  dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
  dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                            (uint64_t)(seconds * NSEC_PER_SEC), NSEC_PER_MSEC);
  dispatch_source_set_event_handler(t, block);
  dispatch_resume(t);
  return t;
}

- (void)startPumps {
  double fps = MAX(1, MIN(60, [self.config[@"fps"] doubleValue] ?: 15));
  self.frameDuration = CMTimeMake(1, (int32_t)fps);
  __weak GSBRun *weak = self;
  self.videoTimer = [self timerEvery:1.0 / fps block:^{ [weak deliverVideo]; }];
  if (self.audio) {
    CMTime now = CMClockGetTime(CMClockGetHostTimeClock());
    self.audioClock = CMTimeConvertScale(now, (int32_t)GSBSampleRate, kCMTimeRoundingMethod_Default);
    self.audioTimer = [self timerEvery:GSBAudioChunk / GSBSampleRate block:^{ [weak deliverAudio]; }];
  }
  self.reportTimer = [self timerEvery:1 block:^{ [weak flushReport]; }];
}

- (void)begin {
  self.startedAt = NSDate.date;
  self.context = [CIContext contextWithOptions:nil];
  NSString *principal = NSBundle.mainBundle.infoDictionary[@"NSExtension"][@"NSExtensionPrincipalClass"];
  Class cls = principal.length ? NSClassFromString(principal) : Nil;
  @synchronized(self.report) {
    self.report[@"pid"] = @(getpid());
    self.report[@"bundleId"] = NSBundle.mainBundle.bundleIdentifier ?: @"";
    self.report[@"handlerClass"] = principal ?: @"";
    self.report[@"executable"] = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
    self.report[@"startedAt"] = @([self.startedAt timeIntervalSince1970]);
  }
  [self setState:@"starting"];
  if (!cls) {
    [self fail:@"principalClassMissing" detail:[NSString stringWithFormat:@"NSExtensionPrincipalClass %@ is not a class in this extension", principal]];
    exit(70);
  }
  NSDictionary *videoSpec = self.config[@"video"];
  if (![videoSpec isKindOfClass:NSDictionary.class]) {
    [self fail:@"noVideoSource" detail:@"the session has no video source"];
    exit(70);
  }
  self.video = [[GCSource alloc] initWithSpec:videoSpec];
  NSDictionary *audioSpec = self.config[@"audio"];
  if ([audioSpec isKindOfClass:NSDictionary.class] && ![audioSpec[@"kind"] isEqual:@"none"]) {
    self.audio = [[GSBAudioSource alloc] initWithSpec:audioSpec];
  }
  self.handler = [cls new];
  dispatch_async(dispatch_get_main_queue(), ^{
    GSBSend(self.handler, @"broadcastStartedWithSetupInfo:", nil);
    @synchronized(self.report) {
      self.report[@"broadcastStarted"] = @YES;
    }
    [self startPumps];
    [self setState:@"running"];
  });
}

- (void)setPausedFromConfig:(BOOL)paused {
  if (paused == self.paused || self.finishing || !self.handler) return;
  dispatch_sync(self.queue, ^{
    self.paused = paused;
    if (!paused) self.audioClock = CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), (int32_t)GSBSampleRate, kCMTimeRoundingMethod_Default);
  });
  GSBSend(self.handler, paused ? @"broadcastPaused" : @"broadcastResumed", nil);
  [self setState:paused ? @"paused" : @"running"];
}

- (void)finishWithState:(NSString *)state callHandler:(BOOL)callHandler {
  if (self.finishing || !self.handler) return;
  self.finishing = YES;
  for (dispatch_source_t t in @[ self.videoTimer ?: (id)NSNull.null, self.audioTimer ?: (id)NSNull.null, self.reportTimer ?: (id)NSNull.null ]) {
    if (t != (id)NSNull.null) dispatch_source_cancel(t);
  }
  dispatch_sync(self.queue, ^{});
  if (callHandler) {
    GSBSend(self.handler, @"broadcastFinished", nil);
    @synchronized(self.report) {
      self.report[@"broadcastFinished"] = @YES;
    }
  }
  @synchronized(self.report) {
    self.report[@"endedAt"] = @([NSDate.date timeIntervalSince1970]);
  }
  [self setState:state];
  exit(0);
}

- (void)recordFinishError:(NSError *)error {
  @synchronized(self.report) {
    self.report[@"finishError"] = error ? GSBErrorJSON(error) : @{};
  }
}
@end

static void GSBHookHandlerBase(void) {
  Class base = NSClassFromString(@"RPBroadcastSampleHandler");
  if (!base) return;
  SEL finish = NSSelectorFromString(@"finishBroadcastWithError:");
  Method m = class_getInstanceMethod(base, finish);
  if (m) {
    method_setImplementation(m, imp_implementationWithBlock(^void(id self, NSError *error) {
      [GSBRun.shared recordFinishError:error];
      dispatch_async(dispatch_get_main_queue(), ^{ [GSBRun.shared finishWithState:@"finishedByExtension" callHandler:NO]; });
    }));
  }
  for (NSString *name in @[ @"updateServiceInfo:", @"updateBroadcastURL:" ]) {
    Method note = class_getInstanceMethod(base, NSSelectorFromString(name));
    if (!note) continue;
    NSString *key = [name stringByReplacingOccurrencesOfString:@":" withString:@""];
    method_setImplementation(note, imp_implementationWithBlock(^void(id self, id value) {
      @synchronized(GSBRun.shared.report) {
        GSBRun.shared.report[key] = [value description] ?: @"";
      }
    }));
  }
}

static void GSBKeepAlive(CFRunLoopTimerRef timer, void *info) {}

static int GSBExtensionMain(int argc, char **argv) {
  if (!GSBHostedByGlint()) return NSExtensionMain(argc, argv);
  @autoreleasepool {
    GSBRun *run = GSBRun.shared;
    run.config = GSBReadConfig();
    if (!run.config || !GSBTargets(run.config, @"extension")) {
      [run fail:@"noSession" detail:@"no broadcast session is configured for this extension"];
      return 70;
    }
    GSBHookHandlerBase();
    [run begin];
    static dispatch_source_t ownerWatch;
    ownerWatch = GSBWatchProcess([run.config[@"ownerPid"] intValue], ^{
      [GSBRun.shared setReport:@"glint exited" forKey:@"endedBy"];
      [GSBRun.shared finishWithState:@"finished" callHandler:YES];
    });
  }
  signal(SIGTERM, SIG_IGN);
  static dispatch_source_t terminate;
  terminate = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(terminate, ^{ [GSBRun.shared finishWithState:@"finished" callHandler:YES]; });
  dispatch_resume(terminate);
  CFRunLoopTimerRef keepAlive = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0, GSBKeepAlive, NULL);
  CFRunLoopAddTimer(CFRunLoopGetMain(), keepAlive, kCFRunLoopCommonModes);
  CFRunLoopRun();
  return 0;
}

__attribute__((used)) static const struct {
  const void *replacement;
  const void *replacee;
} GSBInterpose[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)GSBExtensionMain, (const void *)NSExtensionMain},
};


@interface GSBModule : NSObject <GSIModule>
@end

@implementation GSBModule
+ (NSString *)moduleName { return @"broadcast"; }

- (void)activateWithConfig:(NSDictionary *)config {
  BOOL isExtension = GSBTargets(config, @"extension") && GSBIsUploadExtension();
  BOOL isApp = GSBTargets(config, @"appId");
  if (!isExtension && !isApp) return;
  NSString *shortRoot = config[@"shortPaths"];
  if (shortRoot.length) {
    GSBShortRoot = shortRoot;
    GSBInstallGroupHook();
  }
  if (isExtension) {
    if (GSBHostedByGlint()) [GSBRun.shared setPausedFromConfig:[config[@"paused"] boolValue]];
    return;
  }
  GSBPickerAppId = config[@"appId"];
  GSBWatchOwner([config[@"ownerPid"] intValue]);
  GSBHookCaptured();
  GSBHookPicker();
  static dispatch_once_t once;
  dispatch_once(&once, ^{ _dyld_register_func_for_add_image(GSBImageAdded); });
  GSBSetCapturing([config[@"capturing"] boolValue]);
}

- (void)deactivate {
  GSBShortRoot = nil;
  GSBPickerAppId = nil;
  GSBWatchOwner(0);
  GSBSetCapturing(NO);
  if (GSBHostedByGlint()) {
    dispatch_async(dispatch_get_main_queue(), ^{ [GSBRun.shared finishWithState:@"finished" callHandler:YES]; });
  }
}
@end

__attribute__((constructor(120))) static void GSBRegister(void) {
  GSIRegisterModule(GSBModule.class);
}
