#import "NotesSharedShim.h"

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

@end
