#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface RimeMobile : NSObject
- (nullable instancetype)initWithResources:(NSString *)resources userDirectory:(NSString *)directory;
- (BOOL)selectSchema:(NSString *)schema;
- (NSDictionary *)processKey:(int32_t)key;
- (NSDictionary *)selectCandidate:(NSUInteger)index;
- (void)clear;
@end
NS_ASSUME_NONNULL_END
