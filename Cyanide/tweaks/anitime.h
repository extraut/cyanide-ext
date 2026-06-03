//
//  anitime.h
//  AniTime: replace the iOS lock-screen clock digits with bundled animated GIFs.
//  Tweak by extra.
//

#ifndef anitime_h
#define anitime_h

#import <stdbool.h>
#import <stdint.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

typedef enum {
    AniTimeFormat12h = 0,
    AniTimeFormat24h = 1,
} AniTimeFormat;

typedef struct {
    bool enabled;   // master on/off (AniTimeEnabled)
    int  spacing;   // pt between slots, 0..16
} AniTimeConfig;

bool anitime_apply_in_session(AniTimeConfig cfg, AniTimeFormat fmt);
bool anitime_stop_in_session(void);
bool anitime_stop_in_session_fast(void);
void anitime_forget_remote_state(void);

#ifdef __OBJC__
AniTimeConfig anitime_config_from_defaults(void);
AniTimeFormat anitime_format_from_defaults(void);
#endif

#endif /* anitime_h */
