#import "RimeMobile.h"
#include <rime_api.h>
#include <string>

// Each process owns the engine; each controller owns a distinct session. Main thread only.
@implementation RimeMobile {
    RimeSessionId _session;
}
- (instancetype)initWithResources:(NSString *)resources userDirectory:(NSString *)directory {
    self = [super init];
    if (!self) return nil;
    NSAssert([NSThread isMainThread], @"Rime must use one serialized thread");
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static std::string shared, user, prebuilt;
        shared = resources.UTF8String; user = directory.UTF8String; prebuilt = shared + "/build";
        RIME_STRUCT(RimeTraits, traits);
        traits.shared_data_dir = shared.c_str(); traits.user_data_dir = user.c_str();
        traits.prebuilt_data_dir = prebuilt.c_str(); traits.staging_dir = prebuilt.c_str();
        traits.distribution_name = "RIMES iOS"; traits.distribution_code_name = "rimes_ios";
        traits.distribution_version = "0.1"; traits.app_name = "rime.rimes_ios";
        traits.min_log_level = 3;
        rime_get_api()->setup(&traits); rime_get_api()->initialize(&traits);
        // No deployer/maintenance/downloads during keyboard startup.
    });
    _session = rime_get_api()->create_session();
    return _session ? self : nil;
}
- (void)dealloc { if (_session) rime_get_api()->destroy_session(_session); }
- (BOOL)selectSchema:(NSString *)schema {
    [self clear];
    return rime_get_api()->select_schema(_session, schema.UTF8String);
}
- (NSDictionary *)snapshot {
    NSMutableArray *candidates = [NSMutableArray array]; NSString *preedit = @"", *committed = @"";
    RIME_STRUCT(RimeCommit, commit);
    if (rime_get_api()->get_commit(_session, &commit)) {
        if (commit.text) committed = [NSString stringWithUTF8String:commit.text] ?: @"";
        rime_get_api()->free_commit(&commit);
    }
    RIME_STRUCT(RimeContext, context);
    if (rime_get_api()->get_context(_session, &context)) {
        if (context.composition.preedit) preedit = [NSString stringWithUTF8String:context.composition.preedit] ?: @"";
        rime_get_api()->free_context(&context);
    }
    RimeCandidateListIterator iterator = {0};
    if (rime_get_api()->candidate_list_begin(_session, &iterator)) {
        while (candidates.count < 60 && rime_get_api()->candidate_list_next(&iterator)) {
            if (iterator.candidate.text) [candidates addObject:[NSString stringWithUTF8String:iterator.candidate.text] ?: @""];
        }
        rime_get_api()->candidate_list_end(&iterator);
    }
    return @{@"preedit":preedit, @"commit":committed, @"candidates":candidates};
}
- (NSDictionary *)processKey:(int32_t)key {
    BOOL handled = rime_get_api()->process_key(_session, key, 0);
    NSMutableDictionary *snapshot = [[self snapshot] mutableCopy]; snapshot[@"handled"] = @(handled); return snapshot;
}
- (NSDictionary *)selectCandidate:(NSUInteger)index { rime_get_api()->select_candidate(_session, index); return [self snapshot]; }
- (void)clear { if (_session) rime_get_api()->clear_composition(_session); }
@end
