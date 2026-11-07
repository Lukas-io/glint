#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>

extern NSString *const GCFeedChangedNotification;

BOOL GCFeedActive(void);
BOOL GCFeedHasLens(NSInteger lens);
BOOL GCFeedRenderInto(NSInteger lens, CVPixelBufferRef pb, BOOL mirror);
CIImage *GCFeedFit(NSInteger lens, CGSize size, BOOL mirror);
CIContext *GCFeedContext(void);
UIImage *GCFeedImage(NSInteger lens, CGSize size, BOOL mirror);
void GCInstallPickerHooks(void);

@interface GCSource : NSObject
- (instancetype)initWithSpec:(NSDictionary *)spec;
- (CIImage *)currentImage;
@end
