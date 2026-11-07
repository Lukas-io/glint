#import <Foundation/Foundation.h>

#define GSI_PROTOCOL 1

@protocol GSIModule <NSObject>
+ (NSString *)moduleName;
- (void)activateWithConfig:(NSDictionary *)config;
- (void)deactivate;
@end

void GSIRegisterModule(Class moduleClass);
NSString *GSIControlDir(void);
