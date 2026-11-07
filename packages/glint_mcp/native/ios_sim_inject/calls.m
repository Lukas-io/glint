#import "siminject.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <os/lock.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const GCKindCellular = @"cellular";
static NSString *const GCKindVoip = @"voip";
static NSString *const GCStateRinging = @"ringing";
static NSString *const GCStateConnected = @"connected";
static NSString *const GCStateEnded = @"ended";
static NSString *const GCTransitionAnswering = @"answering";
static NSString *const GCTransitionEnding = @"ending";

@interface GCCall : NSObject <NSCopying>
@property(nonatomic, strong) NSUUID *uuid;
@property(nonatomic, copy) NSString *kind;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *state;
@property(nonatomic) BOOL onHold;
@property(nonatomic) BOOL hasConnected;
@property(nonatomic, copy) NSString *transition;
@property(nonatomic, weak) id provider;
@end
@implementation GCCall
- (id)copyWithZone:(NSZone *)zone {
  GCCall *copy = [GCCall new];
  copy.uuid = self.uuid;
  copy.kind = self.kind;
  copy.name = self.name;
  copy.state = self.state;
  copy.onHold = self.onHold;
  copy.hasConnected = self.hasConnected;
  copy.transition = self.transition;
  copy.provider = self.provider;
  return copy;
}
@end

static NSMutableArray<GCCall *> *GCCalls(void) {
  static NSMutableArray *calls;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ calls = [NSMutableArray new]; });
  return calls;
}

static os_unfair_lock GCPublishedLock = OS_UNFAIR_LOCK_INIT;
static NSArray<GCCall *> *GCPublished;

static void GCPublish(void) {
  NSMutableArray *copies = [NSMutableArray new];
  for (GCCall *c in GCCalls()) [copies addObject:[c copy]];
  os_unfair_lock_lock(&GCPublishedLock);
  GCPublished = copies;
  os_unfair_lock_unlock(&GCPublishedLock);
}

static NSArray<GCCall *> *GCPublishedCalls(void) {
  os_unfair_lock_lock(&GCPublishedLock);
  NSArray *calls = GCPublished ?: @[];
  os_unfair_lock_unlock(&GCPublishedLock);
  return calls;
}

static GCCall *GCFindPublished(NSUUID *uuid) {
  for (GCCall *c in GCPublishedCalls()) {
    if ([c.uuid isEqual:uuid]) return c;
  }
  return nil;
}

static NSHashTable *GCObservers(void) {
  static NSHashTable *table;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
  return table;
}

static NSHashTable *GCProviders(void) {
  static NSHashTable *table;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
  return table;
}

static BOOL GCOn;
static BOOL GCStatusFrozen;
static NSString *GCEpoch;
static NSInteger GCSeenSeq;
static int GCForegroundOverride = -1;
static NSString *GCInterruption = @"none";
static NSMutableArray<NSString *> *GCJournal;
static NSInteger GCObserverDeliveries;

static void GCWriteStatus(void);

static void GCNote(NSString *line) {
  if (!GCJournal) GCJournal = [NSMutableArray new];
  [GCJournal addObject:line];
  if (GCJournal.count > 30) [GCJournal removeObjectAtIndex:0];
}

static NSString *GCStatusPath(void) {
  NSString *dir = GSIControlDir();
  return dir ? [NSString stringWithFormat:@"%@/events/calls-%d.json", dir, getpid()] : nil;
}


typedef struct {
  Class cls;
  SEL sel;
  IMP original;
} GCHookRecord;

static GCHookRecord GCHookRecords[16];
static int GCHookCount;

static IMP GCHookMethod(Class cls, SEL sel, id block) {
  Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
  if (!method || GCHookCount >= 16) return NULL;
  IMP original = method_getImplementation(method);
  method_setImplementation(method, imp_implementationWithBlock(block));
  GCHookRecords[GCHookCount++] = (GCHookRecord){cls, sel, original};
  return original;
}

static void GCUnhookAll(void) {
  for (int i = 0; i < GCHookCount; i++) {
    Method method = class_getInstanceMethod(GCHookRecords[i].cls, GCHookRecords[i].sel);
    if (method) method_setImplementation(method, GCHookRecords[i].original);
  }
  GCHookCount = 0;
}


static id GCSend(id target, SEL sel) { return ((id(*)(id, SEL))objc_msgSend)(target, sel); }

static id GCSendIfResponds(id target, SEL sel) {
  return [target respondsToSelector:sel] ? GCSend(target, sel) : nil;
}

static const void *GCObserverQueueKey = &GCObserverQueueKey;

static dispatch_queue_t GCQueueOf(id object, SEL sel) {
  if (![object respondsToSelector:sel]) return dispatch_get_main_queue();
  id queue = GCSend(object, sel);
  return queue ? (dispatch_queue_t)queue : dispatch_get_main_queue();
}

static BOOL GCObserversUnavailable;

static id GCSnapshot(GCCall *call) {
  Class cls = NSClassFromString(@"CXCall");
  NSArray<NSString *> *needed = @[ @"initWithUUID:", @"setOutgoing:", @"setOnHold:", @"setHasConnected:", @"setHasEnded:" ];
  BOOL complete = cls != nil;
  for (NSString *name in needed) {
    if (complete && ![cls instancesRespondToSelector:NSSelectorFromString(name)]) complete = NO;
  }
  if (!complete) {
    if (cls) GCObserversUnavailable = YES;
    return nil;
  }
  id cx = ((id(*)(id, SEL, NSUUID *))objc_msgSend)([cls alloc], NSSelectorFromString(@"initWithUUID:"), call.uuid);
  ((void (*)(id, SEL, BOOL))objc_msgSend)(cx, NSSelectorFromString(@"setOutgoing:"), NO);
  ((void (*)(id, SEL, BOOL))objc_msgSend)(cx, NSSelectorFromString(@"setOnHold:"), call.onHold);
  ((void (*)(id, SEL, BOOL))objc_msgSend)(cx, NSSelectorFromString(@"setHasConnected:"), call.hasConnected);
  ((void (*)(id, SEL, BOOL))objc_msgSend)(cx, NSSelectorFromString(@"setHasEnded:"), [call.state isEqualToString:GCStateEnded]);
  return cx;
}

static dispatch_queue_t GCObserverQueue(id observer) {
  dispatch_queue_t queue = objc_getAssociatedObject(observer, GCObserverQueueKey);
  return queue ?: GCQueueOf(observer, NSSelectorFromString(@"delegateQueue"));
}

static void GCNotifyObservers(GCCall *call) {
  id snapshot = GCSnapshot(call);
  if (!snapshot) {
    GCNote(@"observers not told: CXCall has no usable private API on this iOS");
    return;
  }
  NSArray *observers;
  @synchronized(GCObservers()) { observers = GCObservers().allObjects; }
  SEL changed = NSSelectorFromString(@"callObserver:callChanged:");
  for (id observer in observers) {
    id delegate = GCSendIfResponds(observer, @selector(delegate));
    if (!delegate || ![delegate respondsToSelector:changed]) continue;
    GCObserverDeliveries++;
    dispatch_async(GCObserverQueue(observer), ^{
      ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, changed, observer, snapshot);
    });
  }
  GCNote([NSString stringWithFormat:@"observer %@", call.state]);
}

static void GCPostInterruption(BOOL began) {
  AVAudioSession *session = AVAudioSession.sharedInstance;
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  info[AVAudioSessionInterruptionTypeKey] = @(began ? AVAudioSessionInterruptionTypeBegan : AVAudioSessionInterruptionTypeEnded);
  if (began) {
    info[AVAudioSessionInterruptionReasonKey] = @(AVAudioSessionInterruptionReasonDefault);
  } else {
    info[AVAudioSessionInterruptionOptionKey] = @(AVAudioSessionInterruptionOptionShouldResume);
  }
  [NSNotificationCenter.defaultCenter postNotificationName:AVAudioSessionInterruptionNotification
                                                    object:session
                                                  userInfo:info];
  GCInterruption = began ? @"began" : @"ended";
  GCNote(began ? @"interruption began" : @"interruption ended");
}


@interface GCOverlay : NSObject
+ (void)refresh;
+ (void)remove;
@end

static void GCWriteStatus(void);
static void GCEnd(GCCall *call, NSString *via);
static void GCAnswer(GCCall *call, NSString *via);

static GCCall *GCLiveCall(void) {
  for (GCCall *c in GCCalls().reverseObjectEnumerator) {
    if (![c.state isEqualToString:GCStateEnded]) return c;
  }
  return nil;
}

@implementation GCOverlay
static UIWindow *window;

+ (UIWindowScene *)activeScene {
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive)
      return (UIWindowScene *)scene;
  }
  return nil;
}

+ (UIButton *)buttonTitled:(NSString *)title color:(UIColor *)color frame:(CGRect)frame action:(void (^)(void))action {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
  button.frame = frame;
  button.backgroundColor = color;
  button.layer.cornerRadius = 20;
  [button setTitle:title forState:UIControlStateNormal];
  [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  button.titleLabel.font = [UIFont boldSystemFontOfSize:17];
  button.accessibilityLabel = title;
  button.accessibilityTraits = UIAccessibilityTraitButton;
  [button addAction:[UIAction actionWithHandler:^(UIAction *a) { action(); }]
      forControlEvents:UIControlEventTouchUpInside];
  return button;
}

+ (UIBarButtonItem *)barItemTitled:(NSString *)title color:(UIColor *)color width:(CGFloat)width action:(void (^)(void))action {
  UIButton *button = [self buttonTitled:title color:color frame:CGRectMake(0, 0, width, 40) action:action];
  [button.widthAnchor constraintEqualToConstant:width].active = YES;
  [button.heightAnchor constraintEqualToConstant:40].active = YES;
  return [[UIBarButtonItem alloc] initWithCustomView:button];
}

+ (UILabel *)labelText:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight alpha:(CGFloat)alpha frame:(CGRect)frame {
  UILabel *label = [[UILabel alloc] initWithFrame:frame];
  label.text = text;
  label.font = [UIFont systemFontOfSize:size weight:weight];
  label.textColor = [UIColor colorWithWhite:1 alpha:alpha];
  return label;
}

+ (void)refresh {
  GCCall *call = GCLiveCall();
  if (!call) return [self remove];
  UIWindowScene *scene = [self activeScene];
  if (!scene) return;
  CGFloat top = scene.windows.firstObject.safeAreaInsets.top;
  CGFloat width = scene.coordinateSpace.bounds.size.width - 16;
  [self remove];
  window = [[UIWindow alloc] initWithWindowScene:scene];
  window.frame = CGRectMake(8, top + 4, width, 132);
  window.windowLevel = UIWindowLevelAlert + 1000;
  window.backgroundColor = UIColor.clearColor;
  window.rootViewController = [UIViewController new];
  window.rootViewController.view.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1];
  window.rootViewController.view.layer.cornerRadius = 26;
  UIView *card = window.rootViewController.view;
  BOOL ringing = [call.state isEqualToString:GCStateRinging];
  NSString *heading = ringing ? @"Incoming call" : @"Call in progress";
  [card addSubview:[self labelText:heading size:13 weight:UIFontWeightRegular alpha:0.6 frame:CGRectMake(20, 14, width - 40, 18)]];
  [card addSubview:[self labelText:call.name size:22 weight:UIFontWeightSemibold alpha:1 frame:CGRectMake(20, 34, width - 40, 28)]];
  UIColor *red = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:1];
  UIColor *green = [UIColor colorWithRed:0.2 green:0.7 blue:0.3 alpha:1];
  NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray new];
  UIBarButtonItem *flexible = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
  if (ringing) {
    CGFloat half = (width - 52) / 2;
    [items addObjectsFromArray:@[
      flexible,
      [self barItemTitled:@"Decline" color:red width:half action:^{ GCEnd(call, @"overlay"); }],
      [self barItemTitled:@"Answer" color:green width:half action:^{ GCAnswer(call, @"overlay"); }],
      flexible
    ]];
  } else {
    [items addObjectsFromArray:@[flexible, [self barItemTitled:@"End call" color:red width:width - 40 action:^{ GCEnd(call, @"overlay"); }], flexible]];
  }
  UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 70, width, 54)];
  [toolbar setBackgroundImage:[UIImage new] forToolbarPosition:UIBarPositionAny barMetrics:UIBarMetricsDefault];
  [toolbar setShadowImage:[UIImage new] forToolbarPosition:UIBarPositionAny];
  toolbar.items = items;
  toolbar.accessibilityIdentifier = heading;
  [card addSubview:toolbar];
  window.hidden = NO;
  GCWriteStatus();
}

+ (void)remove {
  window.hidden = YES;
  window = nil;
}
@end


static GCCall *GCFind(NSUUID *uuid) {
  for (GCCall *c in GCCalls()) {
    if ([c.uuid isEqual:uuid]) return c;
  }
  return nil;
}

static id GCProviderDelegate(id provider) { return GCSendIfResponds(provider, @selector(delegate)); }

static void GCCallDelegate(GCCall *call, NSString *actionClass, NSString *selector, void (^after)(void)) {
  id provider = call.provider;
  id delegate = GCProviderDelegate(provider);
  Class cls = NSClassFromString(actionClass);
  SEL sel = NSSelectorFromString(selector);
  SEL initSel = NSSelectorFromString(@"initWithCallUUID:");
  if (!delegate || !cls || ![cls instancesRespondToSelector:initSel] || ![delegate respondsToSelector:sel]) {
    GCNote([NSString stringWithFormat:@"no delegate for %@", selector]);
    if (after) after();
    return;
  }
  id action = ((id(*)(id, SEL, NSUUID *))objc_msgSend)([cls alloc], initSel, call.uuid);
  dispatch_async(GCQueueOf(provider, NSSelectorFromString(@"queue")), ^{
    ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, provider, action);
    dispatch_async(dispatch_get_main_queue(), ^{ if (after) after(); });
  });
}

static void GCAudioActivation(GCCall *call, BOOL active) {
  id provider = call.provider;
  id delegate = GCProviderDelegate(provider);
  SEL sel = NSSelectorFromString(active ? @"provider:didActivateAudioSession:" : @"provider:didDeactivateAudioSession:");
  if (!delegate || ![delegate respondsToSelector:sel]) return;
  dispatch_async(GCQueueOf(provider, NSSelectorFromString(@"queue")), ^{
    ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, provider, AVAudioSession.sharedInstance);
  });
}

static void GCFinish(GCCall *call) {
  if (![GCCalls() containsObject:call]) return;
  call.state = GCStateEnded;
  GCNotifyObservers(call);
  if ([call.kind isEqualToString:GCKindCellular]) GCPostInterruption(NO);
  [GCCalls() removeObject:call];
  GCPublish();
  [GCOverlay refresh];
  GCWriteStatus();
}

static void GCConnect(GCCall *call) {
  if (![call.state isEqualToString:GCStateRinging]) return;
  call.state = GCStateConnected;
  call.hasConnected = YES;
  call.transition = nil;
  GCPublish();
  GCNotifyObservers(call);
  if ([call.kind isEqualToString:GCKindVoip]) GCAudioActivation(call, YES);
  [GCOverlay refresh];
  GCWriteStatus();
}

static void GCAnswer(GCCall *call, NSString *via) {
  if (![call.state isEqualToString:GCStateRinging] || call.transition) return;
  GCNote([NSString stringWithFormat:@"answer via %@", via]);
  if ([call.kind isEqualToString:GCKindVoip]) {
    call.transition = GCTransitionAnswering;
    GCCallDelegate(call, @"CXAnswerCallAction", @"provider:performAnswerCallAction:", ^{ GCConnect(call); });
  } else {
    GCConnect(call);
  }
}

static void GCEnd(GCCall *call, NSString *via) {
  if ([call.state isEqualToString:GCStateEnded] || [call.transition isEqualToString:GCTransitionEnding]) return;
  GCNote([NSString stringWithFormat:@"end via %@", via]);
  BOOL wasConnected = [call.state isEqualToString:GCStateConnected];
  if ([call.kind isEqualToString:GCKindVoip]) {
    call.transition = GCTransitionEnding;
    GCCallDelegate(call, @"CXEndCallAction", @"provider:performEndCallAction:", ^{
      if (wasConnected) GCAudioActivation(call, NO);
      GCFinish(call);
    });
  } else {
    GCFinish(call);
  }
}

static void GCRing(NSString *number, NSString *name) {
  for (GCCall *c in GCCalls()) {
    if ([c.kind isEqualToString:GCKindCellular]) return;
  }
  GCCall *call = [GCCall new];
  call.uuid = [NSUUID UUID];
  call.kind = GCKindCellular;
  call.name = name.length ? name : number;
  call.state = GCStateRinging;
  [GCCalls() addObject:call];
  GCPublish();
  GCPostInterruption(YES);
  GCNotifyObservers(call);
  [GCOverlay refresh];
  GCWriteStatus();
}


static IMP GCOriginalCalls;
static IMP GCOriginalObserverDelegate;
static IMP GCOriginalProviderDelegate;
static IMP GCOriginalReportIncoming;
static IMP GCOriginalReportUpdated;
static IMP GCOriginalReportEnded;
static IMP GCOriginalRequestTransaction;

static NSString *GCCallerName(id update) {
  id name = [update respondsToSelector:NSSelectorFromString(@"localizedCallerName")] ? GCSend(update, NSSelectorFromString(@"localizedCallerName")) : nil;
  if ([name length]) return name;
  id handle = [update respondsToSelector:NSSelectorFromString(@"remoteHandle")] ? GCSend(update, NSSelectorFromString(@"remoteHandle")) : nil;
  id value = handle ? GCSend(handle, NSSelectorFromString(@"value")) : nil;
  return [value length] ? value : @"Unknown caller";
}

static NSDictionary<NSString *, NSString *> *GCActionSelectors(void) {
  return @{
    @"CXEndCallAction" : @"provider:performEndCallAction:",
    @"CXAnswerCallAction" : @"provider:performAnswerCallAction:",
    @"CXSetHeldCallAction" : @"provider:performSetHeldCallAction:",
    @"CXSetMutedCallAction" : @"provider:performSetMutedCallAction:",
    @"CXPlayDTMFCallAction" : @"provider:performPlayDTMFCallAction:",
  };
}

static NSError *GCTransactionError(NSString *reason) {
  return [NSError errorWithDomain:@"com.apple.CallKit.error.requesttransaction"
                             code:1
                         userInfo:@{NSLocalizedDescriptionKey : reason}];
}

static void GCApplyAction(NSString *actionClass, GCCall *call, id action) {
  if ([actionClass isEqualToString:@"CXEndCallAction"]) {
    GCFinish(call);
  } else if ([actionClass isEqualToString:@"CXAnswerCallAction"]) {
    GCConnect(call);
  } else if ([actionClass isEqualToString:@"CXSetHeldCallAction"]) {
    SEL holdSel = NSSelectorFromString(@"isOnHold");
    if ([action respondsToSelector:holdSel]) call.onHold = ((BOOL(*)(id, SEL))objc_msgSend)(action, holdSel);
    GCPublish();
    GCNotifyObservers(call);
    GCWriteStatus();
  }
}

static void GCRunTransaction(id transaction, void (^completion)(NSError *)) {
  NSArray *actions = GCSendIfResponds(transaction, NSSelectorFromString(@"actions"));
  NSDictionary *selectors = GCActionSelectors();
  dispatch_group_t group = dispatch_group_create();
  __block NSError *failure = nil;
  for (id action in actions) {
    GCCall *call = GCFind(GCSendIfResponds(action, NSSelectorFromString(@"callUUID")));
    NSString *actionClass = NSStringFromClass([action class]);
    NSString *selector = selectors[actionClass];
    id provider = call.provider;
    id delegate = GCProviderDelegate(provider);
    SEL sel = NSSelectorFromString(selector ?: @"");
    if (!call || !selector || ![delegate respondsToSelector:sel]) {
      if (!failure) failure = GCTransactionError([NSString stringWithFormat:@"the provider delegate does not handle %@", actionClass]);
      continue;
    }
    BOOL ending = [actionClass isEqualToString:@"CXEndCallAction"];
    BOOL answering = [actionClass isEqualToString:@"CXAnswerCallAction"];
    if ((ending && [call.transition isEqualToString:GCTransitionEnding]) || (answering && call.transition)) continue;
    if (ending) call.transition = GCTransitionEnding;
    if (answering) call.transition = GCTransitionAnswering;
    dispatch_group_enter(group);
    dispatch_async(GCQueueOf(provider, NSSelectorFromString(@"queue")), ^{
      ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, provider, action);
      dispatch_async(dispatch_get_main_queue(), ^{
        GCApplyAction(actionClass, call, action);
        dispatch_group_leave(group);
      });
    });
  }
  dispatch_group_notify(group, dispatch_get_main_queue(), ^{ completion(failure); });
}

static BOOL GCTransactionIsOurs(id transaction) {
  NSArray *actions = GCSendIfResponds(transaction, NSSelectorFromString(@"actions"));
  if (!actions.count) return NO;
  for (id action in actions) {
    if (![action respondsToSelector:NSSelectorFromString(@"callUUID")]) return NO;
    if (!GCFindPublished(GCSend(action, NSSelectorFromString(@"callUUID")))) return NO;
  }
  return YES;
}

static void GCRemember(NSHashTable *table, id object) {
  @synchronized(table) { [table addObject:object]; }
}

static NSUInteger GCCountWithDelegate(NSHashTable *table) {
  NSArray *objects;
  @synchronized(table) { objects = table.allObjects; }
  NSUInteger count = 0;
  for (id object in objects) {
    if ([object respondsToSelector:@selector(delegate)] && GCSend(object, @selector(delegate))) count++;
  }
  return count;
}

static void GCInstallHooks(void) {
  if (GCHookCount > 0) return;
  Class observerClass = NSClassFromString(@"CXCallObserver");
  Class providerClass = NSClassFromString(@"CXProvider");
  Class controllerClass = NSClassFromString(@"CXCallController");
  if (observerClass) {
    SEL callsSel = NSSelectorFromString(@"calls");
    GCOriginalCalls = GCHookMethod(observerClass, callsSel, ^NSArray *(id observer) {
      NSArray *real = ((NSArray * (*)(id, SEL)) GCOriginalCalls)(observer, callsSel) ?: @[];
      if (!GCOn) return real;
      GCRemember(GCObservers(), observer);
      NSMutableArray *all = [real mutableCopy];
      for (GCCall *c in GCPublishedCalls()) {
        id snapshot = GCSnapshot(c);
        if (snapshot) [all addObject:snapshot];
      }
      return all;
    });
    SEL delegateSel = NSSelectorFromString(@"setDelegate:queue:");
    GCOriginalObserverDelegate = GCHookMethod(observerClass, delegateSel, ^(id observer, id delegate, dispatch_queue_t queue) {
      ((void (*)(id, SEL, id, dispatch_queue_t)) GCOriginalObserverDelegate)(observer, delegateSel, delegate, queue);
      objc_setAssociatedObject(observer, GCObserverQueueKey, queue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      GCRemember(GCObservers(), observer);
    });
  }
  if (providerClass) {
    SEL delegateSel = NSSelectorFromString(@"setDelegate:queue:");
    GCOriginalProviderDelegate = GCHookMethod(providerClass, delegateSel, ^(id provider, id delegate, dispatch_queue_t queue) {
      ((void (*)(id, SEL, id, dispatch_queue_t)) GCOriginalProviderDelegate)(provider, delegateSel, delegate, queue);
      GCRemember(GCProviders(), provider);
    });
    SEL incoming = NSSelectorFromString(@"reportNewIncomingCallWithUUID:update:completion:");
    GCOriginalReportIncoming = GCHookMethod(providerClass, incoming, ^(id provider, NSUUID *uuid, id update, void (^completion)(NSError *)) {
      if (!GCOn) return ((void (*)(id, SEL, NSUUID *, id, id)) GCOriginalReportIncoming)(provider, incoming, uuid, update, completion);
      dispatch_async(dispatch_get_main_queue(), ^{
        GCRemember(GCProviders(), provider);
        GCCall *call = [GCCall new];
        call.uuid = uuid;
        call.kind = GCKindVoip;
        call.name = GCCallerName(update);
        call.state = GCStateRinging;
        call.provider = provider;
        [GCCalls() addObject:call];
        GCPublish();
        GCNote([NSString stringWithFormat:@"voip incoming %@", call.name]);
        GCNotifyObservers(call);
        [GCOverlay refresh];
        GCWriteStatus();
        if (completion) dispatch_async(GCQueueOf(provider, NSSelectorFromString(@"queue")), ^{ completion(nil); });
      });
    });
    SEL updated = NSSelectorFromString(@"reportCallWithUUID:updated:");
    GCOriginalReportUpdated = GCHookMethod(providerClass, updated, ^(id provider, NSUUID *uuid, id update) {
      if (!GCFindPublished(uuid)) return ((void (*)(id, SEL, NSUUID *, id)) GCOriginalReportUpdated)(provider, updated, uuid, update);
      dispatch_async(dispatch_get_main_queue(), ^{
        GCCall *call = GCFind(uuid);
        call.name = GCCallerName(update);
        GCPublish();
        [GCOverlay refresh];
      });
    });
    SEL ended = NSSelectorFromString(@"reportCallWithUUID:endedAtDate:reason:");
    GCOriginalReportEnded = GCHookMethod(providerClass, ended, ^(id provider, NSUUID *uuid, NSDate *date, NSInteger reason) {
      if (!GCFindPublished(uuid)) return ((void (*)(id, SEL, NSUUID *, NSDate *, NSInteger)) GCOriginalReportEnded)(provider, ended, uuid, date, reason);
      dispatch_async(dispatch_get_main_queue(), ^{
        GCCall *call = GCFind(uuid);
        if (!call) return;
        GCNote(@"voip ended by app");
        GCFinish(call);
      });
    });
  }
  if (controllerClass) {
    SEL request = NSSelectorFromString(@"requestTransaction:completion:");
    GCOriginalRequestTransaction = GCHookMethod(controllerClass, request, ^(id controller, id transaction, void (^completion)(NSError *)) {
      if (!GCTransactionIsOurs(transaction)) return ((void (*)(id, SEL, id, id)) GCOriginalRequestTransaction)(controller, request, transaction, completion);
      dispatch_async(dispatch_get_main_queue(), ^{
        GCRunTransaction(transaction, ^(NSError *error) { if (completion) completion(error); });
      });
    });
  }
}


static BOOL GCForeground(void) {
  if (GCForegroundOverride >= 0) return GCForegroundOverride == 1;
  return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

static void GCWriteStatus(void) {
  NSString *path = GCStatusPath();
  if (!path || GCStatusFrozen) return;
  [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  NSMutableArray *calls = [NSMutableArray new];
  for (GCCall *c in GCCalls()) {
    [calls addObject:@{@"uuid" : c.uuid.UUIDString, @"kind" : c.kind, @"name" : c.name ?: @"", @"state" : c.state, @"onHold" : c.onHold ? @YES : @NO, @"transition" : c.transition ?: @""}];
  }
  NSDictionary *info = @{
    @"pid" : @(getpid()),
    @"bundleId" : NSBundle.mainBundle.bundleIdentifier ?: @"",
    @"epoch" : GCEpoch ?: @"",
    @"ack" : @(GCSeenSeq),
    @"foreground" : GCForeground() ? @YES : @NO,
    @"calls" : calls,
    @"observers" : @(GCCountWithDelegate(GCObservers())),
    @"providers" : @(GCCountWithDelegate(GCProviders())),
    @"observerDeliveries" : @(GCObserverDeliveries),
    @"observerPath" : GCObserversUnavailable ? @"unavailable" : @"ok",
    @"callkitLinked" : NSClassFromString(@"CXProvider") != nil ? @YES : @NO,
    @"interruption" : GCInterruption,
    @"overlay" : window != nil ? @YES : @NO,
    @"journal" : GCJournal ?: @[],
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
  [data writeToFile:path atomically:YES];
}


static GCCall *GCTarget(NSString *uuid, NSString *verb) {
  if (uuid.length) return GCFind([[NSUUID alloc] initWithUUIDString:uuid]);
  NSArray<NSString *> *order = [verb isEqualToString:@"end"] ? @[ GCStateConnected, GCStateRinging ] : @[ GCStateRinging ];
  for (NSString *state in order) {
    for (GCCall *c in GCCalls()) {
      if ([c.state isEqualToString:state]) return c;
    }
  }
  return nil;
}

static void GCApplyCommand(NSDictionary *command) {
  NSString *verb = command[@"do"];
  GCInterruption = @"none";
  if ([verb isEqualToString:@"ring"]) {
    GCRing(command[@"number"] ?: @"5551234", command[@"name"]);
  } else if ([verb isEqualToString:@"answer"]) {
    GCCall *call = GCTarget(command[@"uuid"], verb);
    if (call) GCAnswer(call, @"glint");
  } else if ([verb isEqualToString:@"decline"] || [verb isEqualToString:@"end"]) {
    GCCall *call = GCTarget(command[@"uuid"], verb);
    if (call) GCEnd(call, @"glint");
  }
}

static NSMutableArray *GCLifecycleTokens;

static void GCObserveLifecycle(void) {
  if (GCLifecycleTokens) return;
  GCLifecycleTokens = [NSMutableArray new];
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  [GCLifecycleTokens addObject:[center addObserverForName:UIApplicationDidBecomeActiveNotification
                                                   object:nil
                                                    queue:NSOperationQueue.mainQueue
                                               usingBlock:^(NSNotification *n) {
                                                 if (!GCOn) return;
                                                 GCForegroundOverride = 1;
                                                 [GCOverlay refresh];
                                                 GCWriteStatus();
                                               }]];
  [GCLifecycleTokens addObject:[center addObserverForName:UIApplicationWillResignActiveNotification
                                                   object:nil
                                                    queue:NSOperationQueue.mainQueue
                                               usingBlock:^(NSNotification *n) {
                                                 if (!GCOn) return;
                                                 GCForegroundOverride = 0;
                                                 GCWriteStatus();
                                               }]];
}

static void GCFinishDeactivation(int attempt) {
  if (GCOn) return;
  if (GCCalls().count > 0 && attempt < 40) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      GCFinishDeactivation(attempt + 1);
    });
    return;
  }
  [GCCalls() removeAllObjects];
  GCPublish();
  [GCOverlay remove];
  GCUnhookAll();
  for (id token in GCLifecycleTokens) [NSNotificationCenter.defaultCenter removeObserver:token];
  GCLifecycleTokens = nil;
  GCForegroundOverride = -1;
  GCSeenSeq = 0;
  GCEpoch = nil;
  GCInterruption = @"none";
  GCObserversUnavailable = NO;
  GCJournal = nil;
  NSString *path = GCStatusPath();
  if (path) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

@interface GSICallsModule : NSObject <GSIModule>
@end

@implementation GSICallsModule
+ (NSString *)moduleName { return @"calls"; }

- (void)activateWithConfig:(NSDictionary *)config {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSString *epoch = [config[@"epoch"] isKindOfClass:NSString.class] ? config[@"epoch"] : @"";
    if (!GCOn || ![epoch isEqualToString:GCEpoch]) {
      GCEpoch = epoch;
      GCSeenSeq = 0;
    }
    GCOn = YES;
    GCStatusFrozen = NO;
    GCInstallHooks();
    GCObserveLifecycle();
    NSDictionary *command = [config[@"command"] isKindOfClass:NSDictionary.class] ? config[@"command"] : nil;
    NSInteger seq = [command[@"seq"] integerValue];
    if (command && seq > GCSeenSeq) {
      GCSeenSeq = seq;
      GCApplyCommand(command);
    }
    GCWriteStatus();
  });
}

- (void)deactivate {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!GCOn) return;
    GCOn = NO;
    GCStatusFrozen = YES;
    for (GCCall *c in [GCCalls() copy]) GCEnd(c, @"stop");
    GCFinishDeactivation(0);
  });
}
@end

__attribute__((constructor)) static void GCRegister(void) { GSIRegisterModule(GSICallsModule.class); }
