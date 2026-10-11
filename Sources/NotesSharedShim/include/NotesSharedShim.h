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

// Typed sends, one per argument signature. Each checks respondsToSelector and catches exceptions.
// Void-returning selectors must use these: reading a return value from a void method is undefined.
+ (BOOL)send:(id)target selector:(NSString *)selector error:(NSError **)error;
+ (BOOL)send:(id)target selector:(NSString *)selector unsignedInteger:(NSUInteger)value error:(NSError **)error;
+ (BOOL)send:(id)target selector:(NSString *)selector range:(NSRange)range error:(NSError **)error;
+ (BOOL)send:(id)target selector:(NSString *)selector string:(NSString *)string index:(NSUInteger)index error:(NSError **)error;
+ (BOOL)send:(id)target selector:(NSString *)selector attributes:(NSDictionary *)attributes range:(NSRange)range error:(NSError **)error;
+ (BOOL)send:(id)target selector:(NSString *)selector unsignedInteger:(NSUInteger)value range:(NSRange)range integer:(NSInteger)delta error:(NSError **)error;
/// Object-returning send with two NSUInteger arguments. The result may legitimately be nil.
+ (BOOL)send:(id)target selector:(NSString *)selector unsignedInteger:(NSUInteger)first unsignedInteger:(NSUInteger)second result:(id _Nullable * _Nonnull)result error:(NSError **)error;
/// Object-returning send with one object argument. The result may legitimately be nil.
+ (BOOL)send:(id)target selector:(NSString *)selector object:(nullable id)argument result:(id _Nullable * _Nonnull)result error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
