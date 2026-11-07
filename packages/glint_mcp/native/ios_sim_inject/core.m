#import "siminject.h"
#import <notify.h>
#import <unistd.h>

static NSMutableDictionary<NSString *, id<GSIModule>> *GSIModules(void) {
  static NSMutableDictionary *modules;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ modules = [NSMutableDictionary new]; });
  return modules;
}

static NSMutableSet<NSString *> *GSIActive(void) {
  static NSMutableSet *active;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ active = [NSMutableSet new]; });
  return active;
}

static BOOL GSIIsThirdPartyApp(void) {
  NSString *bundleId = NSBundle.mainBundle.bundleIdentifier;
  if (!bundleId.length || [bundleId hasPrefix:@"com.apple."]) return NO;
  return [NSBundle.mainBundle.bundlePath containsString:@"/Containers/Bundle/Application/"];
}

static BOOL GSIStarted;

static void GSIWire(NSString *name);

void GSIRegisterModule(Class moduleClass) {
  if (!GSIIsThirdPartyApp()) return;
  NSString *name = [moduleClass moduleName];
  BOOL late;
  @synchronized(GSIModules()) {
    if (GSIModules()[name]) return;
    GSIModules()[name] = [moduleClass new];
    late = GSIStarted;
  }
  if (late) GSIWire(name);
}

NSString *GSIControlDir(void) {
  NSDictionary *env = NSProcessInfo.processInfo.environment;
  NSString *udid = env[@"SIMULATOR_UDID"];
  if (!udid.length) return nil;
  NSString *home = env[@"SIMULATOR_HOST_HOME"] ?: NSHomeDirectory();
  return [NSString stringWithFormat:@"%@/.glint/siminject/%@", home, udid];
}

static NSDictionary *GSIReadJSON(NSString *path) {
  NSData *data = [NSData dataWithContentsOfFile:path];
  if (!data) return nil;
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

static void GSIWriteReady(void) {
  NSString *dir = [GSIControlDir() stringByAppendingPathComponent:@"ready"];
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  NSArray *active;
  @synchronized(GSIActive()) { active = [GSIActive().allObjects sortedArrayUsingSelector:@selector(compare:)]; }
  NSDictionary *info = @{
    @"pid" : @(getpid()),
    @"protocol" : @(GSI_PROTOCOL),
    @"bundleId" : NSBundle.mainBundle.bundleIdentifier ?: @"",
    @"modules" : [GSIModules().allKeys sortedArrayUsingSelector:@selector(compare:)],
    @"active" : active,
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
  [data writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.json", getpid()]] atomically:YES];
}

static void GSIApplyState(NSString *name) {
  id<GSIModule> module = GSIModules()[name];
  if (!module) return;
  NSDictionary *config = GSIReadJSON([GSIControlDir() stringByAppendingFormat:@"/modules/%@.json", name]);
  if (config) {
    [module activateWithConfig:config];
    @synchronized(GSIActive()) { [GSIActive() addObject:name]; }
  } else {
    [module deactivate];
    @synchronized(GSIActive()) { [GSIActive() removeObject:name]; }
  }
  GSIWriteReady();
}

static void GSIObserve(NSString *notification, void (^handler)(void)) {
  int token;
  notify_register_dispatch(notification.UTF8String, &token, dispatch_get_main_queue(), ^(int t) { handler(); });
}

static void GSIWire(NSString *name) {
  GSIApplyState(name);
  GSIObserve([@"glint.siminject." stringByAppendingString:name], ^{ GSIApplyState(name); });
}

__attribute__((constructor(200))) static void GSIStart(void) {
  if (!GSIIsThirdPartyApp() || !GSIControlDir()) return;
  NSArray *names;
  @synchronized(GSIModules()) {
    GSIStarted = YES;
    names = GSIModules().allKeys;
  }
  for (NSString *name in names) GSIWire(name);
  GSIObserve(@"glint.siminject.ping", ^{ GSIWriteReady(); });
  GSIWriteReady();
}
