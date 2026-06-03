//
//  PatreonAuth.m
//  Cyanide
//
//  Patreon gating has been removed from this build. This file is kept so
//  the existing pbxproj entry and the call sites in PackageCatalog /
//  Package / PackageDetailViewController / SettingsViewController keep
//  compiling. Every accessor returns a safe default (NO / nil / 0), so
//  Patreon-only branches in those files are skipped at runtime.
//

#import "PatreonAuth.h"

NSString * const kCyanidePatreonStatusDidChangeNotification = @"CyanidePatreonStatusDidChangeNotification";

NSURL *cyanide_patreon_join_url(void)
{
    return nil;
}

BOOL cyanide_patreon_is_linked(void) { return NO; }
BOOL cyanide_is_patron(void)          { return NO; }
BOOL cyanide_is_creator(void)         { return NO; }

NSString * _Nullable cyanide_patreon_display_name(void)    { return nil; }
NSString * _Nullable cyanide_patreon_tier_title(void)     { return nil; }
NSInteger cyanide_patreon_pledge_cents(void)              { return 0; }
NSDate * _Nullable cyanide_patreon_last_refresh_date(void) { return nil; }

void cyanide_patreon_authenticate(UIViewController *presenter,
                                  void (^_Nullable completion)(BOOL success, NSError * _Nullable error))
{
    (void)presenter;
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, [NSError errorWithDomain:@"CyanidePatreon"
                                                code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Patreon gating has been removed from this build."}]);
        });
    }
}

void cyanide_patreon_sign_out(void) {}
void cyanide_patreon_refresh(void (^_Nullable completion)(BOOL success, NSError * _Nullable error))
{
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, nil);
        });
    }
}
