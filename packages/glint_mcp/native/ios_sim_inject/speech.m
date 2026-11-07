#import "siminject.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>

static NSString *const GSDomainAssistant = @"kAFAssistantErrorDomain";
static NSString *const GSDomainRecognizer = @"kLSRErrorDomain";

enum { GSTaskStarting = 0, GSTaskRunning = 1, GSTaskFinishing = 2, GSTaskCanceling = 3, GSTaskCompleted = 4 };
static const NSInteger GSAuthorized = 3;
static const NSInteger GSRecordGranted = 'grnt';
static const double GSLeadSeconds = 0.3;

@interface GSTaskState : NSObject
@property(nonatomic, strong) id recognizer;
@property(nonatomic, strong) id task;
@property(nonatomic, weak) id request;
@property(nonatomic, strong) id delegate;
@property(nonatomic, copy) void (^handler)(id result, NSError *error);
@property(nonatomic, copy) NSString *kind;
@property(nonatomic) NSInteger state;
@property(nonatomic) BOOL reportPartials;
@property(nonatomic) BOOL speaking;
@property(nonatomic) BOOL endedAudio;
@property(nonatomic) NSInteger generation;
@property(nonatomic) NSInteger seq;
@property(nonatomic) double confidence;
@property(nonatomic) double wordSeconds;
@property(nonatomic) double finalSeconds;
@property(nonatomic) double clock;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *words;
@property(nonatomic) NSInteger partials;
@property(nonatomic) NSInteger finals;
@property(nonatomic) NSInteger buffers;
@property(nonatomic, copy) NSString *text;
@property(nonatomic, copy) NSString *failure;
@property(nonatomic, strong) NSError *error;
@end
@implementation GSTaskState
- (instancetype)init {
  if ((self = [super init])) _words = [NSMutableArray new];
  return self;
}
@end

static BOOL GSOn;
static BOOL GSStatusFrozen;
static NSString *GSEpoch;
static NSInteger GSSeenSeq;
static int GSForegroundOverride = -1;
static NSInteger GSTakenSeq;
static NSInteger GSExpiredSeq;
static NSInteger GSSettledSeq;
static NSInteger GSFakeStarts;
static NSInteger GSRealStarts;
static NSInteger GSAuthRequests;
static NSInteger GSMicRequests;
static BOOL GSHooked;
static NSMutableArray<GSTaskState *> *GSTasks;
static NSMutableArray<NSDictionary *> *GSHistory;
static NSMutableDictionary<NSNumber *, NSNumber *> *GSOutstanding;
static NSMutableArray<NSString *> *GSJournal;
static NSDictionary *GSPending;
static NSInteger GSPendingToken;

static const void *GSPayloadKey = &GSPayloadKey;
static const void *GSRequestStateKey = &GSRequestStateKey;

static void GSWriteStatus(void);
static BOOL GSTaskClassAvailable(void);
static BOOL GSForeground(void);
static void GSReset(void);

static void GSNote(NSString *line) {
  if (!GSJournal) GSJournal = [NSMutableArray new];
  [GSJournal addObject:line];
  if (GSJournal.count > 30) [GSJournal removeObjectAtIndex:0];
}

static NSMutableArray<GSTaskState *> *GSActive(void) {
  if (!GSTasks) GSTasks = [NSMutableArray new];
  return GSTasks;
}

static NSString *GSStatusPath(void) {
  NSString *dir = GSIControlDir();
  return dir ? [NSString stringWithFormat:@"%@/events/speech-%d.json", dir, getpid()] : nil;
}

static IMP GSReplace(Class cls, SEL sel, BOOL meta, id (^make)(IMP orig)) {
  Class target = meta ? object_getClass(cls) : cls;
  Method method = target ? class_getInstanceMethod(target, sel) : NULL;
  if (!method) return NULL;
  IMP orig = method_getImplementation(method);
  class_replaceMethod(target, sel, imp_implementationWithBlock(make(orig)), method_getTypeEncoding(method));
  return orig;
}

static id GSSend(id target, SEL sel) { return ((id(*)(id, SEL))objc_msgSend)(target, sel); }

static NSDictionary *GSPayload(id object) { return objc_getAssociatedObject(object, GSPayloadKey); }

static NSString *GSBoolTypes(void) { return [NSString stringWithFormat:@"%s@:", @encode(BOOL)]; }

static Class GSSubclass(NSString *baseName, NSString *name, void (^build)(Class cls)) {
  Class existing = NSClassFromString(name);
  if (existing) return existing;
  Class base = NSClassFromString(baseName);
  if (!base) return nil;
  Class cls = objc_allocateClassPair(base, name.UTF8String, 0);
  if (!cls) return nil;
  build(cls);
  objc_registerClassPair(cls);
  return cls;
}

static void GSAdd(Class cls, NSString *sel, NSString *types, id block) {
  class_addMethod(cls, NSSelectorFromString(sel), imp_implementationWithBlock(block), types.UTF8String);
}

static void GSAddPayloadGetter(Class cls, NSString *sel, NSString *types) {
  GSAdd(cls, sel, types, ^id(id self) { return GSPayload(self)[sel]; });
}

static void GSAddNumberGetter(Class cls, NSString *sel, NSString *types, NSString *kind) {
  if ([kind isEqualToString:@"d"]) {
    GSAdd(cls, sel, types, ^double(id self) { return [GSPayload(self)[sel] doubleValue]; });
  } else if ([kind isEqualToString:@"f"]) {
    GSAdd(cls, sel, types, ^float(id self) { return [GSPayload(self)[sel] floatValue]; });
  } else {
    GSAdd(cls, sel, types, ^NSInteger(id self) { return [GSPayload(self)[sel] integerValue]; });
  }
}

static Class GSSegmentClass(void) {
  return GSSubclass(@"SFTranscriptionSegment", @"GlintSpeechSegment", ^(Class cls) {
    GSAddPayloadGetter(cls, @"substring", @"@@:");
    GSAddNumberGetter(cls, @"timestamp", @"d@:", @"d");
    GSAddNumberGetter(cls, @"duration", @"d@:", @"d");
    GSAddNumberGetter(cls, @"confidence", @"f@:", @"f");
    GSAdd(cls, @"substringRange", @"{_NSRange=QQ}@:", ^NSRange(id self) { return [GSPayload(self)[@"substringRange"] rangeValue]; });
    GSAdd(cls, @"alternativeSubstrings", @"@@:", ^id(id self) { return @[]; });
    GSAdd(cls, @"voiceAnalytics", @"@@:", ^id(id self) { return nil; });
  });
}

static Class GSTranscriptionClass(void) {
  return GSSubclass(@"SFTranscription", @"GlintSpeechTranscription", ^(Class cls) {
    GSAddPayloadGetter(cls, @"formattedString", @"@@:");
    GSAddPayloadGetter(cls, @"segments", @"@@:");
    GSAddNumberGetter(cls, @"speakingRate", @"d@:", @"d");
    GSAddNumberGetter(cls, @"averagePauseDuration", @"d@:", @"d");
  });
}

static Class GSMetadataClass(void) {
  return GSSubclass(@"SFSpeechRecognitionMetadata", @"GlintSpeechMetadata", ^(Class cls) {
    GSAddNumberGetter(cls, @"speakingRate", @"d@:", @"d");
    GSAddNumberGetter(cls, @"averagePauseDuration", @"d@:", @"d");
    GSAddNumberGetter(cls, @"speechStartTimestamp", @"d@:", @"d");
    GSAddNumberGetter(cls, @"speechDuration", @"d@:", @"d");
    GSAdd(cls, @"voiceAnalytics", @"@@:", ^id(id self) { return nil; });
  });
}

static Class GSResultClass(void) {
  return GSSubclass(@"SFSpeechRecognitionResult", @"GlintSpeechResult", ^(Class cls) {
    GSAddPayloadGetter(cls, @"bestTranscription", @"@@:");
    GSAddPayloadGetter(cls, @"transcriptions", @"@@:");
    GSAddPayloadGetter(cls, @"speechRecognitionMetadata", @"@@:");
    GSAdd(cls, @"isFinal", GSBoolTypes(), ^BOOL(id self) { return [GSPayload(self)[@"isFinal"] boolValue]; });
  });
}

static id GSInstance(Class cls, NSDictionary *payload) {
  id object = [cls new];
  objc_setAssociatedObject(object, GSPayloadKey, payload, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return object;
}

static BOOL GSClassesAvailable(void) {
  return GSSegmentClass() && GSTranscriptionClass() && GSResultClass() && GSTaskClassAvailable();
}

static id GSBuildTranscription(GSTaskState *s, NSArray<NSDictionary *> *words, BOOL final) {
  NSMutableArray *segments = [NSMutableArray new];
  NSMutableString *text = [NSMutableString new];
  for (NSDictionary *word in words) {
    if (text.length) [text appendString:@" "];
    NSRange range = NSMakeRange(text.length, [word[@"text"] length]);
    [text appendString:word[@"text"]];
    [segments addObject:GSInstance(GSSegmentClass(), @{
      @"substring" : word[@"text"],
      @"substringRange" : [NSValue valueWithRange:range],
      @"timestamp" : word[@"timestamp"],
      @"duration" : word[@"duration"],
      @"confidence" : @(final ? s.confidence : 0),
    })];
  }
  return GSInstance(GSTranscriptionClass(), @{
    @"formattedString" : [text copy],
    @"segments" : segments,
    @"speakingRate" : @(s.wordSeconds > 0 ? 60.0 / s.wordSeconds : 0),
    @"averagePauseDuration" : @0,
  });
}

static id GSBuildResult(GSTaskState *s, NSArray<NSDictionary *> *words, BOOL final) {
  id transcription = GSBuildTranscription(s, words, final);
  id metadata = nil;
  Class metadataClass = GSMetadataClass();
  if (final && metadataClass) {
    NSDictionary *last = words.lastObject;
    metadata = GSInstance(metadataClass, @{
      @"speakingRate" : @(s.wordSeconds > 0 ? 60.0 / s.wordSeconds : 0),
      @"averagePauseDuration" : @0,
      @"speechStartTimestamp" : @(0),
      @"speechDuration" : @([last[@"timestamp"] doubleValue] + [last[@"duration"] doubleValue]),
    });
  }
  NSMutableDictionary *payload = [@{
    @"bestTranscription" : transcription,
    @"transcriptions" : @[ transcription ],
    @"isFinal" : @(final),
  } mutableCopy];
  if (metadata) payload[@"speechRecognitionMetadata"] = metadata;
  return GSInstance(GSResultClass(), payload);
}

static void GSOnRecognizerQueue(GSTaskState *s, dispatch_block_t block) {
  id queue = [s.recognizer respondsToSelector:NSSelectorFromString(@"queue")] ? GSSend(s.recognizer, NSSelectorFromString(@"queue")) : nil;
  if ([queue isKindOfClass:NSOperationQueue.class]) {
    [(NSOperationQueue *)queue addOperationWithBlock:block];
  } else {
    dispatch_async(dispatch_get_main_queue(), block);
  }
}

static void GSDelegateCall(id delegate, NSString *selector, id first, id second) {
  SEL sel = NSSelectorFromString(selector);
  if (![delegate respondsToSelector:sel]) return;
  if (second == (id)kCFNull) {
    ((void (*)(id, SEL, id))objc_msgSend)(delegate, sel, first);
  } else {
    ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, first, second);
  }
}

static void GSDelegateFinished(id delegate, id task, BOOL success) {
  SEL sel = NSSelectorFromString(@"speechRecognitionTask:didFinishSuccessfully:");
  if ([delegate respondsToSelector:sel]) ((void (*)(id, SEL, id, BOOL))objc_msgSend)(delegate, sel, task, success);
}

static void GSRecordHistory(GSTaskState *s) {
  if (!GSHistory) GSHistory = [NSMutableArray new];
  [GSHistory addObject:@{
    @"kind" : s.kind ?: @"",
    @"seq" : @(s.seq),
    @"partials" : @(s.partials),
    @"finals" : @(s.finals),
    @"text" : s.text ?: @"",
    @"failure" : s.failure ?: @"",
    @"buffers" : @(s.buffers),
  }];
  if (GSHistory.count > 8) [GSHistory removeObjectAtIndex:0];
}

static void GSSettle(GSTaskState *s) {
  if (s.seq > 0) {
    NSNumber *left = @(MAX(0, GSOutstanding[@(s.seq)].integerValue - 1));
    GSOutstanding[@(s.seq)] = left;
    if (left.integerValue == 0 && s.seq > GSSettledSeq) GSSettledSeq = s.seq;
  }
}

static void GSComplete(GSTaskState *s, NSError *error) {
  s.state = GSTaskCompleted;
  s.error = error;
  s.speaking = NO;
  s.generation++;
  BOOL cancelled = error.code == 301 && [error.domain isEqualToString:GSDomainRecognizer];
  s.failure = !error ? nil : cancelled ? @"cancelled" : [NSString stringWithFormat:@"%@ %ld", error.domain, (long)error.code];
  [GSActive() removeObject:s];
  GSRecordHistory(s);
  GSSettle(s);
  s.task = nil;
  s.handler = nil;
  s.delegate = nil;
  GSWriteStatus();
}

static void GSDeliverPartial(GSTaskState *s, NSArray<NSDictionary *> *words) {
  id result = GSBuildResult(s, words, NO);
  s.partials++;
  s.text = GSPayload(GSBuildTranscription(s, words, NO))[@"formattedString"];
  void (^handler)(id, NSError *) = s.handler;
  id delegate = s.delegate;
  id task = s.task;
  BOOL first = s.partials == 1;
  GSWriteStatus();
  GSOnRecognizerQueue(s, ^{
    if (handler) {
      handler(result, nil);
      return;
    }
    if (first) GSDelegateCall(delegate, @"speechRecognitionDidDetectSpeech:", task, (id)kCFNull);
    GSDelegateCall(delegate, @"speechRecognitionTask:didHypothesizeTranscription:", task, GSSend(result, NSSelectorFromString(@"bestTranscription")));
  });
}

static void GSFinalize(GSTaskState *s) {
  if (s.state == GSTaskCompleted || s.state == GSTaskCanceling) return;
  NSArray *words = [s.words copy];
  id result = GSBuildResult(s, words, YES);
  s.finals++;
  s.text = GSPayload(GSPayload(result)[@"bestTranscription"])[@"formattedString"];
  s.state = GSTaskCompleted;
  void (^handler)(id, NSError *) = s.handler;
  id delegate = s.delegate;
  id task = s.task;
  GSOnRecognizerQueue(s, ^{
    if (handler) {
      handler(result, nil);
      return;
    }
    GSDelegateCall(delegate, @"speechRecognitionTask:didFinishRecognition:", task, result);
    GSDelegateFinished(delegate, task, YES);
  });
  GSNote([NSString stringWithFormat:@"final \"%@\" to %@ task", s.text, s.kind]);
  GSComplete(s, nil);
}

static NSError *GSError(NSString *domain, NSInteger code, NSString *message) {
  return [NSError errorWithDomain:domain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

static NSError *GSNamedError(NSString *name) {
  if ([name isEqualToString:@"siriDisabled"]) return GSError(GSDomainRecognizer, 201, @"Siri and Dictation are disabled");
  if ([name isEqualToString:@"interrupted"]) return GSError(GSDomainAssistant, 1107, @"Connection to speech process was interrupted");
  return GSError(GSDomainAssistant, 1110, @"No speech detected");
}

static void GSFail(GSTaskState *s, NSError *error) {
  if (s.state == GSTaskCompleted) return;
  void (^handler)(id, NSError *) = s.handler;
  id delegate = s.delegate;
  id task = s.task;
  GSOnRecognizerQueue(s, ^{
    if (handler) {
      handler(nil, error);
      return;
    }
    GSDelegateFinished(delegate, task, NO);
  });
  GSNote([NSString stringWithFormat:@"error %ld to %@ task", (long)error.code, s.kind]);
  GSComplete(s, error);
}

static void GSCancel(GSTaskState *s) {
  if (s.state == GSTaskCompleted || s.state == GSTaskCanceling) return;
  s.state = GSTaskCanceling;
  s.generation++;
  id delegate = s.delegate;
  id task = s.task;
  void (^handler)(id, NSError *) = s.handler;
  NSError *error = GSError(GSDomainRecognizer, 301, @"Request was canceled");
  GSOnRecognizerQueue(s, ^{
    if (handler) {
      handler(nil, error);
      return;
    }
    GSDelegateCall(delegate, @"speechRecognitionTaskWasCancelled:", task, (id)kCFNull);
    GSDelegateFinished(delegate, task, NO);
  });
  GSNote([NSString stringWithFormat:@"canceled %@ task", s.kind]);
  GSComplete(s, error);
}

static void GSFlush(GSTaskState *s) {
  if (s.state != GSTaskRunning) return;
  s.state = GSTaskFinishing;
  s.generation++;
  s.speaking = NO;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (s.state != GSTaskFinishing) return;
    if (s.words.count) {
      GSFinalize(s);
    } else {
      GSFail(s, GSNamedError(@"noSpeech"));
    }
  });
}

static void GSEndAudio(GSTaskState *s) {
  if (s.endedAudio) return;
  s.endedAudio = YES;
  id delegate = s.delegate;
  id task = s.task;
  GSOnRecognizerQueue(s, ^{ GSDelegateCall(delegate, @"speechRecognitionTaskFinishedReadingAudio:", task, (id)kCFNull); });
  GSFlush(s);
  GSWriteStatus();
}

static Class GSTaskClass(void) {
  return GSSubclass(@"SFSpeechRecognitionTask", @"GlintSpeechTask", ^(Class cls) {
    GSAdd(cls, @"state", @"q@:", ^NSInteger(id self) { return [objc_getAssociatedObject(self, GSPayloadKey) state]; });
    GSAdd(cls, @"isFinishing", GSBoolTypes(), ^BOOL(id self) {
      NSInteger state = [objc_getAssociatedObject(self, GSPayloadKey) state];
      return state == GSTaskFinishing;
    });
    GSAdd(cls, @"isCancelled", GSBoolTypes(), ^BOOL(id self) {
      NSError *error = [objc_getAssociatedObject(self, GSPayloadKey) error];
      return error.code == 301 && [error.domain isEqualToString:GSDomainRecognizer];
    });
    GSAdd(cls, @"error", @"@@:", ^id(id self) { return [objc_getAssociatedObject(self, GSPayloadKey) error]; });
    GSAdd(cls, @"finish", @"v@:", ^(id self) {
      GSTaskState *s = objc_getAssociatedObject(self, GSPayloadKey);
      dispatch_async(dispatch_get_main_queue(), ^{ GSFlush(s); GSWriteStatus(); });
    });
    GSAdd(cls, @"cancel", @"v@:", ^(id self) {
      GSTaskState *s = objc_getAssociatedObject(self, GSPayloadKey);
      dispatch_async(dispatch_get_main_queue(), ^{ GSCancel(s); });
    });
  });
}

static BOOL GSTaskClassAvailable(void) { return GSTaskClass() != nil; }

static BOOL GSIsListening(GSTaskState *s) { return s.state == GSTaskRunning && !s.endedAudio; }

static NSArray<NSDictionary *> *GSWords(NSString *text, double startSeconds, double wordSeconds) {
  NSMutableArray *words = [NSMutableArray new];
  NSArray<NSString *> *parts = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  double at = startSeconds;
  for (NSString *part in parts) {
    if (!part.length) continue;
    [words addObject:@{@"text" : part, @"timestamp" : @(at), @"duration" : @(wordSeconds * 0.9)}];
    at += wordSeconds;
  }
  return words;
}

static void GSAfter(double seconds, dispatch_block_t block) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

static BOOL GSAcceptsUtterance(GSTaskState *s) { return GSIsListening(s) && !s.speaking; }

static void GSSpeak(GSTaskState *s, NSDictionary *command, NSInteger seq) {
  double wordSeconds = MAX(0.05, [command[@"wordMs"] doubleValue] / 1000.0);
  NSArray *added = GSWords(command[@"text"] ?: @"", s.clock, wordSeconds);
  NSInteger base = s.words.count;
  s.generation++;
  NSInteger generation = s.generation;
  s.seq = seq;
  s.wordSeconds = wordSeconds;
  s.confidence = command[@"confidence"] ? [command[@"confidence"] doubleValue] : 0.92;
  s.finalSeconds = MAX(0, [command[@"finalMs"] doubleValue] / 1000.0);
  [s.words addObjectsFromArray:added];
  s.clock += added.count * wordSeconds + 0.2;
  s.speaking = YES;
  GSOutstanding[@(seq)] = @(GSOutstanding[@(seq)].integerValue + 1);
  BOOL partials = [command[@"partials"] boolValue] && s.reportPartials;
  for (NSUInteger i = 0; i < added.count; i++) {
    BOOL last = i + 1 == added.count;
    GSAfter(GSLeadSeconds + (i + 1) * wordSeconds, ^{
      if (s.generation != generation || s.state != GSTaskRunning) return;
      if (partials && !last) GSDeliverPartial(s, [s.words subarrayWithRange:NSMakeRange(0, base + i + 1)]);
      if (!last) return;
      s.speaking = NO;
      if (partials) GSDeliverPartial(s, [s.words copy]);
      GSWriteStatus();
      GSAfter(s.finalSeconds, ^{
        if (s.generation == generation && s.state == GSTaskRunning) GSFinalize(s);
      });
    });
  }
  GSNote([NSString stringWithFormat:@"utterance of %lu words to %@ task", (unsigned long)added.count, s.kind]);
}

static NSInteger GSDeliver(NSDictionary *command, NSInteger seq) {
  NSInteger taken = 0;
  BOOL failing = [command[@"do"] isEqualToString:@"fail"];
  for (GSTaskState *s in [GSActive() copy]) {
    if (failing ? !GSIsListening(s) : !GSAcceptsUtterance(s)) continue;
    taken++;
    if (failing) {
      s.seq = seq;
      GSOutstanding[@(seq)] = @(GSOutstanding[@(seq)].integerValue + 1);
      GSFail(s, GSNamedError(command[@"error"]));
    } else {
      GSSpeak(s, command, seq);
    }
  }
  if (taken > 0) GSTakenSeq = MAX(GSTakenSeq, seq);
  return taken;
}

static const double GSNotifySlackMs = 2000;

static double GSNowMs(void) { return NSDate.date.timeIntervalSince1970 * 1000; }

static double GSRemainingMs(NSDictionary *command) {
  return [command[@"sentAtMs"] doubleValue] + [command[@"waitMs"] doubleValue] + GSNotifySlackMs - GSNowMs();
}

static BOOL GSIsTarget(NSDictionary *command) {
  NSString *target = [command[@"target"] isKindOfClass:NSString.class] ? command[@"target"] : @"";
  if (target.length) return [target isEqualToString:NSBundle.mainBundle.bundleIdentifier];
  return GSForeground();
}

static void GSApplyCommand(NSDictionary *command) {
  NSString *verb = command[@"do"];
  if (![verb isEqualToString:@"say"] && ![verb isEqualToString:@"fail"]) return;
  NSInteger seq = [command[@"seq"] integerValue];
  if (GSRemainingMs(command) <= 0 || !GSIsTarget(command)) {
    GSExpiredSeq = seq;
    return;
  }
  GSPending = nil;
  GSPendingToken++;
  if (GSDeliver(command, seq) > 0) return;
  double waitSeconds = MIN([command[@"waitMs"] doubleValue], GSRemainingMs(command)) / 1000.0;
  if (waitSeconds <= 0) {
    GSExpiredSeq = seq;
    return;
  }
  GSPending = command;
  NSInteger token = GSPendingToken;
  GSAfter(waitSeconds, ^{
    if (token != GSPendingToken || !GSPending) return;
    GSPending = nil;
    GSExpiredSeq = seq;
    GSNote(@"no recognition task started in time");
    GSWriteStatus();
  });
}

static void GSOfferPending(void) {
  if (!GSPending) return;
  NSDictionary *command = GSPending;
  if (GSDeliver(command, [command[@"seq"] integerValue]) > 0) {
    GSPending = nil;
    GSPendingToken++;
  }
}

static id GSNewTask(id recognizer, id request, void (^handler)(id, NSError *), id delegate) {
  Class cls = GSTaskClass();
  id task = [cls new];
  GSTaskState *s = [GSTaskState new];
  s.recognizer = recognizer;
  s.task = task;
  s.request = request;
  s.handler = handler;
  s.delegate = delegate;
  s.kind = [request respondsToSelector:NSSelectorFromString(@"endAudio")] ? @"buffer" : @"url";
  s.state = GSTaskRunning;
  SEL partialsSel = NSSelectorFromString(@"shouldReportPartialResults");
  s.reportPartials = [request respondsToSelector:partialsSel] ? ((BOOL(*)(id, SEL))objc_msgSend)(request, partialsSel) : YES;
  objc_setAssociatedObject(task, GSPayloadKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(request, GSRequestStateKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [GSActive() addObject:s];
  GSNote([NSString stringWithFormat:@"%@ task started", s.kind]);
  dispatch_async(dispatch_get_main_queue(), ^{
    GSOfferPending();
    GSWriteStatus();
  });
  return task;
}

static GSTaskState *GSStateOfRequest(id request) { return objc_getAssociatedObject(request, GSRequestStateKey); }

static void GSInstallSpeechHooks(void) {
  Class recognizer = NSClassFromString(@"SFSpeechRecognizer");
  if (!recognizer) return;
  SEL status = NSSelectorFromString(@"authorizationStatus");
  GSReplace(recognizer, status, YES, ^id(IMP orig) {
    return ^NSInteger(id self) {
      if (GSOn) return GSAuthorized;
      return ((NSInteger(*)(id, SEL))orig)(self, status);
    };
  });
  SEL request = NSSelectorFromString(@"requestAuthorization:");
  GSReplace(recognizer, request, YES, ^id(IMP orig) {
    return ^void(id self, void (^handler)(NSInteger)) {
      if (!GSOn) return ((void (*)(id, SEL, id))orig)(self, request, handler);
      GSAuthRequests++;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (handler) handler(GSAuthorized);
        GSWriteStatus();
      });
    };
  });
  SEL available = NSSelectorFromString(@"isAvailable");
  GSReplace(recognizer, available, NO, ^id(IMP orig) {
    return ^BOOL(id self) {
      if (GSOn) return YES;
      return ((BOOL(*)(id, SEL))orig)(self, available);
    };
  });
  SEL withHandler = NSSelectorFromString(@"recognitionTaskWithRequest:resultHandler:");
  GSReplace(recognizer, withHandler, NO, ^id(IMP orig) {
    return ^id(id self, id req, void (^handler)(id, NSError *)) {
      if (!GSOn || !GSClassesAvailable()) return ((id(*)(id, SEL, id, id))orig)(self, withHandler, req, handler);
      return GSNewTask(self, req, handler, nil);
    };
  });
  SEL withDelegate = NSSelectorFromString(@"recognitionTaskWithRequest:delegate:");
  GSReplace(recognizer, withDelegate, NO, ^id(IMP orig) {
    return ^id(id self, id req, id delegate) {
      if (!GSOn || !GSClassesAvailable()) return ((id(*)(id, SEL, id, id))orig)(self, withDelegate, req, delegate);
      return GSNewTask(self, req, nil, delegate);
    };
  });
  Class buffer = NSClassFromString(@"SFSpeechAudioBufferRecognitionRequest");
  SEL end = NSSelectorFromString(@"endAudio");
  GSReplace(buffer, end, NO, ^id(IMP orig) {
    return ^void(id self) {
      GSTaskState *s = GSStateOfRequest(self);
      if (!s) return ((void (*)(id, SEL))orig)(self, end);
      dispatch_async(dispatch_get_main_queue(), ^{ GSEndAudio(s); });
    };
  });
  for (NSString *name in @[ @"appendAudioPCMBuffer:", @"appendAudioSampleBuffer:" ]) {
    SEL append = NSSelectorFromString(name);
    GSReplace(buffer, append, NO, ^id(IMP orig) {
      return ^void(id self, id audio) {
        GSTaskState *s = GSStateOfRequest(self);
        if (!s) return ((void (*)(id, SEL, id))orig)(self, append, audio);
        s.buffers++;
      };
    });
  }
}

static void GSInstallPermissionHooks(void) {
  Class session = AVAudioSession.class;
  SEL permission = NSSelectorFromString(@"recordPermission");
  GSReplace(session, permission, NO, ^id(IMP orig) {
    return ^NSInteger(id self) {
      if (GSOn) return GSRecordGranted;
      return ((NSInteger(*)(id, SEL))orig)(self, permission);
    };
  });
  SEL requestSession = NSSelectorFromString(@"requestRecordPermission:");
  GSReplace(session, requestSession, NO, ^id(IMP orig) {
    return ^void(id self, void (^handler)(BOOL)) {
      if (!GSOn) return ((void (*)(id, SEL, id))orig)(self, requestSession, handler);
      GSMicRequests++;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (handler) handler(YES);
        GSWriteStatus();
      });
    };
  });
  Class application = NSClassFromString(@"AVAudioApplication");
  SEL applicationPermission = NSSelectorFromString(@"recordPermission");
  GSReplace(application, applicationPermission, NO, ^id(IMP orig) {
    return ^NSInteger(id self) {
      if (GSOn) return GSRecordGranted;
      return ((NSInteger(*)(id, SEL))orig)(self, applicationPermission);
    };
  });
  SEL requestApplication = NSSelectorFromString(@"requestRecordPermissionWithCompletionHandler:");
  GSReplace(application, requestApplication, YES, ^id(IMP orig) {
    return ^void(id self, void (^handler)(BOOL)) {
      if (!GSOn) return ((void (*)(id, SEL, id))orig)(self, requestApplication, handler);
      GSMicRequests++;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (handler) handler(YES);
        GSWriteStatus();
      });
    };
  });
  SEL captureStatus = @selector(authorizationStatusForMediaType:);
  GSReplace(AVCaptureDevice.class, captureStatus, YES, ^id(IMP orig) {
    return ^AVAuthorizationStatus(id self, AVMediaType type) {
      if (GSOn && [type isEqualToString:AVMediaTypeAudio]) return AVAuthorizationStatusAuthorized;
      return ((AVAuthorizationStatus(*)(id, SEL, AVMediaType))orig)(self, captureStatus, type);
    };
  });
  SEL captureRequest = @selector(requestAccessForMediaType:completionHandler:);
  GSReplace(AVCaptureDevice.class, captureRequest, YES, ^id(IMP orig) {
    return ^void(id self, AVMediaType type, void (^handler)(BOOL)) {
      if (!GSOn || ![type isEqualToString:AVMediaTypeAudio]) return ((void (*)(id, SEL, AVMediaType, id))orig)(self, captureRequest, type, handler);
      GSMicRequests++;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (handler) handler(YES);
        GSWriteStatus();
      });
    };
  });
}

@interface GSFakeTap : NSObject
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, weak) id engine;
@end
@implementation GSFakeTap
@end

static NSMutableDictionary<NSString *, GSFakeTap *> *GSFakeTaps;
static NSHashTable *GSFakeRunningEngines;
static const void *GSFakeRunningKey = &GSFakeRunningKey;

static AVAudioFormat *GSSilentFormat(void) { return [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1]; }

static NSString *GSTapKey(id node, AVAudioNodeBus bus) { return [NSString stringWithFormat:@"%p:%lu", node, (unsigned long)bus]; }

static BOOL GSEngineIsFake(id engine) { return [objc_getAssociatedObject(engine, GSFakeRunningKey) boolValue]; }

static void GSSetEngineFake(id engine, BOOL fake) {
  objc_setAssociatedObject(engine, GSFakeRunningKey, fake ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  @synchronized(GSFakeTaps) {
    if (fake) {
      [GSFakeRunningEngines addObject:engine];
    } else {
      [GSFakeRunningEngines removeObject:engine];
    }
  }
}

static void GSStartSilentTap(id node, AVAudioNodeBus bus, AVAudioFrameCount size, AVAudioNodeTapBlock block) {
  AVAudioFormat *format = GSSilentFormat();
  AVAudioFrameCount frames = MIN(MAX(size, 1024), 19200);
  double interval = frames / format.sampleRate;
  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), (uint64_t)(interval * NSEC_PER_SEC), 0);
  dispatch_source_set_event_handler(timer, ^{
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frames];
    buffer.frameLength = frames;
    memset(buffer.floatChannelData[0], 0, frames * sizeof(float));
    block(buffer, [AVAudioTime timeWithHostTime:mach_absolute_time()]);
  });
  GSFakeTap *tap = [GSFakeTap new];
  tap.timer = timer;
  tap.engine = GSSend(node, NSSelectorFromString(@"engine"));
  @synchronized(GSFakeTaps) {
    NSString *key = GSTapKey(node, bus);
    GSFakeTap *old = GSFakeTaps[key];
    if (old) dispatch_source_cancel(old.timer);
    GSFakeTaps[key] = tap;
  }
  dispatch_resume(timer);
  GSNote(@"silent microphone input for a tap: the real input is not opened");
}

static BOOL GSStopSilentTap(id node, AVAudioNodeBus bus) {
  @synchronized(GSFakeTaps) {
    NSString *key = GSTapKey(node, bus);
    GSFakeTap *tap = GSFakeTaps[key];
    if (!tap) return NO;
    dispatch_source_cancel(tap.timer);
    [GSFakeTaps removeObjectForKey:key];
    return YES;
  }
}

static void GSStopSilentTapsOf(id engine) {
  @synchronized(GSFakeTaps) {
    for (NSString *key in GSFakeTaps.allKeys) {
      GSFakeTap *tap = GSFakeTaps[key];
      if (tap.engine != engine) continue;
      dispatch_source_cancel(tap.timer);
      [GSFakeTaps removeObjectForKey:key];
    }
  }
  GSSetEngineFake(engine, NO);
}

static BOOL GSEngineHasSilentTap(id engine) {
  @synchronized(GSFakeTaps) {
    for (GSFakeTap *tap in GSFakeTaps.allValues) {
      if (tap.engine == engine) return YES;
    }
    return NO;
  }
}

static void GSStopAllSilentTaps(void) {
  NSArray *engines;
  @synchronized(GSFakeTaps) {
    for (GSFakeTap *tap in GSFakeTaps.allValues) dispatch_source_cancel(tap.timer);
    [GSFakeTaps removeAllObjects];
    engines = GSFakeRunningEngines.allObjects;
  }
  for (id engine in engines) GSSetEngineFake(engine, NO);
}

static void GSInstallInputHooks(void) {
  GSFakeTaps = [NSMutableDictionary new];
  GSFakeRunningEngines = [NSHashTable weakObjectsHashTable];
  Class input = NSClassFromString(@"AVAudioInputNode");
  for (NSString *name in @[ @"outputFormatForBus:", @"inputFormatForBus:" ]) {
    SEL format = NSSelectorFromString(name);
    GSReplace(input, format, NO, ^id(IMP orig) {
      return ^id(id self, AVAudioNodeBus bus) {
        if (GSOn) return GSSilentFormat();
        return ((id(*)(id, SEL, AVAudioNodeBus))orig)(self, format, bus);
      };
    });
  }
  SEL install = @selector(installTapOnBus:bufferSize:format:block:);
  GSReplace(input, install, NO, ^id(IMP orig) {
    return ^void(id self, AVAudioNodeBus bus, AVAudioFrameCount size, AVAudioFormat *format, AVAudioNodeTapBlock block) {
      if (GSOn) return GSStartSilentTap(self, bus, size, block);
      ((void (*)(id, SEL, AVAudioNodeBus, AVAudioFrameCount, id, id))orig)(self, install, bus, size, format, block);
    };
  });
  SEL remove = @selector(removeTapOnBus:);
  GSReplace(input, remove, NO, ^id(IMP orig) {
    return ^void(id self, AVAudioNodeBus bus) {
      if (GSStopSilentTap(self, bus)) return;
      ((void (*)(id, SEL, AVAudioNodeBus))orig)(self, remove, bus);
    };
  });
  Class engineClass = AVAudioEngine.class;
  SEL start = @selector(startAndReturnError:);
  GSReplace(engineClass, start, NO, ^id(IMP orig) {
    return ^BOOL(id self, NSError **error) {
      if (GSOn && GSEngineHasSilentTap(self)) {
        GSSetEngineFake(self, YES);
        GSFakeStarts++;
        return YES;
      }
      if (GSOn) GSRealStarts++;
      return ((BOOL(*)(id, SEL, NSError **))orig)(self, start, error);
    };
  });
  SEL running = @selector(isRunning);
  GSReplace(engineClass, running, NO, ^id(IMP orig) {
    return ^BOOL(id self) {
      if (GSEngineIsFake(self)) return YES;
      return ((BOOL(*)(id, SEL))orig)(self, running);
    };
  });
  SEL prepare = @selector(prepare);
  GSReplace(engineClass, prepare, NO, ^id(IMP orig) {
    return ^void(id self) {
      if (GSEngineHasSilentTap(self)) return;
      ((void (*)(id, SEL))orig)(self, prepare);
    };
  });
  for (NSString *name in @[ @"stop", @"pause", @"reset" ]) {
    SEL end = NSSelectorFromString(name);
    BOOL keepsTaps = [name isEqualToString:@"pause"];
    GSReplace(engineClass, end, NO, ^id(IMP orig) {
      return ^void(id self) {
        if (keepsTaps) {
          GSSetEngineFake(self, NO);
        } else {
          GSStopSilentTapsOf(self);
        }
        ((void (*)(id, SEL))orig)(self, end);
      };
    });
  }
}

static void GSInstallHooks(void) {
  if (GSHooked) return;
  GSHooked = YES;
  GSInstallSpeechHooks();
  GSInstallPermissionHooks();
  GSInstallInputHooks();
}

static BOOL GSForeground(void) {
  if (GSForegroundOverride >= 0) return GSForegroundOverride == 1;
  return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

static NSString *GSStateName(GSTaskState *s) {
  if (s.speaking) return @"speaking";
  return @[ @"starting", @"listening", @"finishing", @"canceling", @"completed" ][s.state];
}

static void GSWriteStatus(void) {
  NSString *path = GSStatusPath();
  if (!path || GSStatusFrozen) return;
  [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  NSMutableArray *tasks = [NSMutableArray new];
  for (GSTaskState *s in GSActive()) {
    [tasks addObject:@{@"kind" : s.kind, @"seq" : @(s.seq), @"state" : GSStateName(s), @"partials" : @(s.partials), @"text" : s.text ?: @"", @"buffers" : @(s.buffers), @"audioEnded" : @(s.endedAudio)}];
  }
  NSDictionary *info = @{
    @"pid" : @(getpid()),
    @"bundleId" : NSBundle.mainBundle.bundleIdentifier ?: @"",
    @"epoch" : GSEpoch ?: @"",
    @"ack" : @(GSSeenSeq),
    @"taken" : @(GSTakenSeq),
    @"expired" : @(GSExpiredSeq),
    @"settled" : @(GSSettledSeq),
    @"fakeEngineStarts" : @(GSFakeStarts),
    @"realEngineStarts" : @(GSRealStarts),
    @"foreground" : GSForeground() ? @YES : @NO,
    @"speechLinked" : NSClassFromString(@"SFSpeechRecognizer") != nil ? @YES : @NO,
    @"pending" : GSPending != nil ? @YES : @NO,
    @"tasks" : tasks,
    @"history" : GSHistory ?: @[],
    @"authRequests" : @(GSAuthRequests),
    @"micRequests" : @(GSMicRequests),
    @"journal" : GSJournal ?: @[],
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
  [data writeToFile:path atomically:YES];
}

static NSMutableArray *GSLifecycleTokens;

static void GSObserveLifecycle(void) {
  if (GSLifecycleTokens) return;
  GSLifecycleTokens = [NSMutableArray new];
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  [GSLifecycleTokens addObject:[center addObserverForName:UIApplicationDidBecomeActiveNotification
                                                   object:nil
                                                    queue:NSOperationQueue.mainQueue
                                               usingBlock:^(NSNotification *n) {
                                                 if (!GSOn) return;
                                                 GSForegroundOverride = 1;
                                                 GSWriteStatus();
                                               }]];
  [GSLifecycleTokens addObject:[center addObserverForName:UIApplicationWillResignActiveNotification
                                                   object:nil
                                                    queue:NSOperationQueue.mainQueue
                                               usingBlock:^(NSNotification *n) {
                                                 if (!GSOn) return;
                                                 GSForegroundOverride = 0;
                                                 GSWriteStatus();
                                               }]];
}

static void GSReset(void) {
  GSSeenSeq = 0;
  GSTakenSeq = 0;
  GSExpiredSeq = 0;
  GSSettledSeq = 0;
  GSAuthRequests = 0;
  GSMicRequests = 0;
  GSPending = nil;
  GSPendingToken++;
  GSOutstanding = [NSMutableDictionary new];
  GSHistory = nil;
  GSJournal = nil;
}

static void GSFinishDeactivation(void) {
  if (GSOn) return;
  for (id token in GSLifecycleTokens) [NSNotificationCenter.defaultCenter removeObserver:token];
  GSLifecycleTokens = nil;
  GSForegroundOverride = -1;
  GSEpoch = nil;
  GSReset();
  NSString *path = GSStatusPath();
  if (path) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

@interface GSSpeechModule : NSObject <GSIModule>
@end

@implementation GSSpeechModule
+ (NSString *)moduleName { return @"speech"; }

- (void)activateWithConfig:(NSDictionary *)config {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSString *epoch = [config[@"epoch"] isKindOfClass:NSString.class] ? config[@"epoch"] : @"";
    if (![epoch isEqualToString:GSEpoch]) {
      GSReset();
      GSEpoch = epoch;
    }
    GSOn = YES;
    GSStatusFrozen = NO;
    GSInstallHooks();
    GSObserveLifecycle();
    NSDictionary *command = [config[@"command"] isKindOfClass:NSDictionary.class] ? config[@"command"] : nil;
    NSInteger seq = [command[@"seq"] integerValue];
    if (command && seq > GSSeenSeq) {
      GSSeenSeq = seq;
      GSApplyCommand(command);
    }
    GSWriteStatus();
  });
}

- (void)deactivate {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!GSOn) return;
    GSOn = NO;
    GSStatusFrozen = YES;
    for (GSTaskState *s in [GSActive() copy]) GSCancel(s);
    GSStopAllSilentTaps();
    GSAfter(0.3, ^{ GSFinishDeactivation(); });
  });
}
@end

__attribute__((constructor)) static void GSRegister(void) { GSIRegisterModule(GSSpeechModule.class); }
