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

+ (BOOL)send:(id)target selector:(NSString *)selector object:(id)argument index:(NSUInteger)index error:(NSError **)error {
    SEL sel = ShimSelector(target, selector, error);
    if (!sel) return NO;
    return [self performBlock:^{ ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(target, sel, argument, index); } error:error];
}

+ (BOOL)send:(id)target selector:(NSString *)selector boolean:(BOOL)flag result:(id _Nullable * _Nonnull)result error:(NSError **)error {
    SEL sel = ShimSelector(target, selector, error);
    if (!sel) return NO;
    __block id value = nil;
    BOOL ok = [self performBlock:^{ value = ((id (*)(id, SEL, BOOL))objc_msgSend)(target, sel, flag); } error:error];
    *result = value;
    return ok;
}

+ (BOOL)send:(id)target selector:(NSString *)selector unsignedInteger:(NSUInteger)argument result:(id _Nullable * _Nonnull)result error:(NSError **)error {
    SEL sel = ShimSelector(target, selector, error);
    if (!sel) return NO;
    __block id value = nil;
    BOOL ok = [self performBlock:^{ value = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(target, sel, argument); } error:error];
    *result = value;
    return ok;
}

+ (BOOL)send:(id)target selector:(NSString *)selector object:(id)first object:(id)second result:(id _Nullable * _Nonnull)result error:(NSError **)error {
    SEL sel = ShimSelector(target, selector, error);
    if (!sel) return NO;
    __block id value = nil;
    BOOL ok = [self performBlock:^{ value = ((id (*)(id, SEL, id, id))objc_msgSend)(target, sel, first, second); } error:error];
    *result = value;
    return ok;
}

+ (BOOL)send:(id)target selector:(NSString *)selector object:(id)argument unsignedInteger:(NSUInteger)first unsignedInteger:(NSUInteger)second error:(NSError **)error {
    SEL sel = ShimSelector(target, selector, error);
    if (!sel) return NO;
    return [self performBlock:^{ ((void (*)(id, SEL, id, NSUInteger, NSUInteger))objc_msgSend)(target, sel, argument, first, second); } error:error];
}

+ (BOOL)send:(id)target selector:(NSString *)selector boolean:(BOOL)flag error:(NSError **)error {
    SEL sel = ShimSelector(target, selector, error);
    if (!sel) return NO;
    return [self performBlock:^{ ((void (*)(id, SEL, BOOL))objc_msgSend)(target, sel, flag); } error:error];
}

+ (BOOL)send:(id)target selector:(NSString *)selector object:(id)argument error:(NSError **)error {
    SEL sel = ShimSelector(target, selector, error);
    if (!sel) return NO;
    return [self performBlock:^{ ((void (*)(id, SEL, id))objc_msgSend)(target, sel, argument); } error:error];
}

+ (BOOL)allocClass:(NSString *)className initSelector:(NSString *)selector object:(id)argument boolean:(BOOL)flag result:(id _Nullable * _Nonnull)result error:(NSError **)error {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(selector);
    if (!cls || ![cls instancesRespondToSelector:sel]) {
        if (error) *error = ShimError([NSString stringWithFormat:@"%@ does not respond to %@", className, selector]);
        return NO;
    }
    __block id value = nil;
    BOOL ok = [self performBlock:^{ value = ((id (*)(id, SEL, id, BOOL))objc_msgSend)([cls alloc], sel, argument, flag); } error:error];
    *result = value;
    return ok;
}

+ (void)installParagraphStyleToBodyConversion {
    SEL sel = NSSelectorFromString(@"ic_convertParagraphStyleToBodyInRange:");
    Class cls = [NSMutableAttributedString class];
    if ([cls instancesRespondToSelector:sel]) return;
    // Every character in the range ends up with a body paragraph style, as in tables made
    // by Notes itself: an existing style is copied with style = 3 (body), a missing one is
    // created. Cells without a paragraph style lay out on top of each other.
    IMP imp = imp_implementationWithBlock(^(NSMutableAttributedString *string, NSRange range) {
        NSString *key = @"TTStyle";
        Class styleClass = NSClassFromString(@"ICTTParagraphStyle");
        SEL setStyle = NSSelectorFromString(@"setStyle:");
        if (!styleClass || ![styleClass instancesRespondToSelector:setStyle]) return;
        NSMutableArray *changes = [NSMutableArray array];
        [string enumerateAttribute:key inRange:range options:0 usingBlock:^(id value, NSRange run, BOOL *stop) {
            id style = value ? [value mutableCopy] : [[styleClass alloc] init];
            if (![style respondsToSelector:setStyle]) return;
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(style, setStyle, 3);
            [changes addObject:@[[NSValue valueWithRange:run], style]];
        }];
        for (NSArray *change in changes) {
            [string addAttribute:key value:change[1] range:[change[0] rangeValue]];
        }
    });
    class_addMethod(cls, sel, imp, "v32@0:8{_NSRange=QQ}16");
}

@end
