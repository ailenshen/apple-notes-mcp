// Thin Objective-C adapter under NotesKit. It holds no state: it only turns Objective-C
// exceptions from private NotesShared calls into NSError, and makes calls whose
// arguments are C scalars or structs, which Swift cannot send dynamically.
// 当 Swift 能直接捕获 ObjC 异常，或 Apple 开放官方 Notes API 时，删除这个包装层。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSShim : NSObject
/// Runs the block, catching any Objective-C exception as an NSError.
/// The block must not hold Swift cleanups (defer, owned locals) that an exception would skip.
+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
