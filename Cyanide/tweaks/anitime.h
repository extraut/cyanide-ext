//
//  anitime.h
//  AniTime: lock-screen clock digit replacement via bundled animated GIFs.
//

#ifndef anitime_h
#define anitime_h

#import <stdbool.h>
#import <stdint.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

typedef enum {
    AniTimeSizeSmall   = 0,
    AniTimeSizeCompact = 1,
    AniTimeSizeNormal  = 2,
} AniTimeSize;

typedef struct {
    AniTimeSize size;     // small / compact / normal
    int         spacing;  // pt between digit frames, 0..16
    bool        format24h;
    bool        showSeconds;
} AniTimeConfig;

bool anitime_apply_in_session(AniTimeConfig cfg);
bool anitime_stop_in_session(void);
bool anitime_stop_in_session_fast(void);
void anitime_forget_remote_state(void);

#ifdef __OBJC__
AniTimeConfig anitime_config_from_defaults(void);
#endif

#endif /* anitime_h */
