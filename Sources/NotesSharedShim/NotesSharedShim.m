#import "NotesSharedShim.h"
#import <objc/message.h>

static NSError *ShimError(NSString *message) {
    return [NSError errorWithDomain:@"NotesSharedShim" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// Resolves the selector, failing with an error (not an exception) when the target lacks it.
static SEL ShimSelector(id target, NSString *name, NSError **error) {
    SEL sel = NSSelectorFromString(name);
    if (![target respondsToSelector:sel]) {
        if (error) *error = ShimError([NSString stringWithFormat:@"%@ does not respond to %@", [target class], name]);
        return NULL;
    }
    return sel;
}

@implementation NSShim

+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: @"";
            *error = [NSError errorWithDomain:@"NotesSharedShim" code:1 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", exception.name, reason],
            }];
        }
        return NO;
    }
}

+ (BOOL)send:(id)target selector:(NSString *)selector error:(NSError **)error {
    SEL sel = ShimSelector(target, selector, error);
    if (!sel) return NO;
    return [self performBlock:^{ ((void (*)(id, SEL))objc_msgSend)(target, sel); } error:error];
}

+ (BOOL)send:(id)target selector:(NSString *)selector unsignedInteger:(NSUInteger)value error:(NSError **)error {
    SEL sel = ShimSelector(target, selector, error);
    if (!sel) return NO;
    return [self performBlock:^{ ((void (*)(id, SEL, NSUInteger))objc_msgSend)(target, sel, value); } error:error];
}

+ (BOOL)send:(id)target selector:(NSString *)selector range:(NSRange)range error:(NSError **)error {
    SEL sel = ShimSelector(target, selector, error);
    if (!sel) return NO;
    return [self performBlock:^{ ((void (*)(id, SEL, NSRange))objc_msgSend)(target, sel, range); } error:error];
}

+ (BOOL)send:(id)target selector:(NSString *)selector string:(NSString *)string index:(NSUInteger)index error:(NSError **)error {
    SEL sel = ShimSelector(target, selector, error);
    if (!sel) return NO;
    return [self performBlock:^{ ((void (*)(id, SEL, NSString *, NSUInteger))objc_msgSend)(target, sel, string, index); } error:error];
}

+ (BOOL)send:(id)target selector:(NSString *)selector attributes:(NSDictionary *)attributes range:(NSRange)range error:(NSError **)error {
    SEL sel = ShimSelector(target, selector, error);
    if (!sel) return NO;
    return [self performBlock:^{ ((void (*)(id, SEL, NSDictionary *, NSRange))objc_msgSend)(target, sel, attributes, range); } error:error];
}

+ (BOOL)send:(id)target selector:(NSString *)selector unsignedInteger:(NSUInteger)value range:(NSRange)range integer:(NSInteger)delta error:(NSError **)error {
    SEL sel = ShimSelector(target, selector, error);
    if (!sel) return NO;
    return [self performBlock:^{ ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(target, sel, value, range, delta); } error:error];
}

+ (BOOL)send:(id)target selector:(NSString *)selector unsignedInteger:(NSUInteger)first unsignedInteger:(NSUInteger)second result:(id _Nullable * _Nonnull)result error:(NSError **)error {
    SEL sel = ShimSelector(target, selector, error);
    if (!sel) return NO;
    __block id value = nil;
    BOOL ok = [self performBlock:^{ value = ((id (*)(id, SEL, NSUInteger, NSUInteger))objc_msgSend)(target, sel, first, second); } error:error];
    *result = value;
    return ok;
}

+ (BOOL)send:(id)target selector:(NSString *)selector object:(nullable id)argument result:(id _Nullable * _Nonnull)result error:(NSError **)error {
    SEL sel = ShimSelector(target, selector, error);
    if (!sel) return NO;
    __block id value = nil;
    BOOL ok = [self performBlock:^{ value = ((id (*)(id, SEL, id))objc_msgSend)(target, sel, argument); } error:error];
    *result = value;
    return ok;
}

@end
