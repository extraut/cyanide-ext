//
//  livewp.m
//  Live Wallpaper — AVPlayer + AVPlayerLooper → 2 AVPlayerLayer
//  (home SBHomeScreenWindow + lock SBCoverSheetWindow).
//

#import "livewp.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <unistd.h>

static uint64_t g_player = 0, g_item = 0, g_looper = 0;
static uint64_t g_home_layer = 0, g_lock_layer = 0;
static uint64_t g_home_win = 0, g_lock_win = 0;
static bool g_on = false;

NSString * const kLiveWPEnabled = @"LiveWPEnabled";
NSString * const kLiveWPVideoPath = @"LiveWPVideoPath";

static bool create_player(NSString *path);
static bool attach_and_play(void);
static void zero_state(void);

NSString *livewp_absolute_path(void) {
    NSString *rel = [[NSUserDefaults standardUserDefaults] stringForKey:kLiveWPVideoPath];
    if (!rel.length) return nil;
    if ([rel hasPrefix:@"/"]) return rel;
    return [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]
            stringByAppendingPathComponent:rel];
}

bool livewp_apply_in_session(void) {
    NSString *path = livewp_absolute_path();
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        log_user("[LIVEWP] no video\n");
        return false;
    }
    if (g_on) { livewp_stop_in_session(); usleep(100000); }
    if (!create_player(path)) return false;
    if (!attach_and_play()) { zero_state(); return false; }
    g_on = true;
    log_user("[LIVEWP] on\n");
    return true;
}

bool livewp_stop_in_session(void) {
    if (!g_on) return true;
    if (r_is_objc_ptr(g_player))   r_msg2_main(g_player, "pause", 0, 0, 0, 0);
    if (r_is_objc_ptr(g_home_layer)) r_msg2_main(g_home_layer, "removeFromSuperlayer", 0, 0, 0, 0);
    if (r_is_objc_ptr(g_lock_layer)) r_msg2_main(g_lock_layer, "removeFromSuperlayer", 0, 0, 0, 0);
    zero_state();
    g_on = false;
    return true;
}

bool livewp_repair_in_session(void) {
    if (!g_on) return false;
    return attach_and_play();
}

bool livewp_swap_video_in_session(NSString *path) {
    if (!g_on || !r_is_objc_ptr(g_player)) return false;
    uint64_t s = r_nsstr_retained(path.UTF8String);
    if (!r_is_objc_ptr(s)) return false;
    uint64_t url = r_msg2_main(r_class("NSURL"), "fileURLWithPath:", s, 0, 0, 0);
    r_msg2(s, "release", 0, 0, 0, 0);
    if (!r_is_objc_ptr(url)) return false;

    uint64_t item = r_msg2_main(r_class("AVPlayerItem"), "playerItemWithURL:", url, 0, 0, 0);
    if (!r_is_objc_ptr(item)) return false;
    r_msg2_main(item, "retain", 0, 0, 0, 0);

    r_msg2_main(g_player, "replaceCurrentItemWithPlayerItem:", item, 0, 0, 0);
    g_item = item;

    // rebuild looper bound to the new item
    uint64_t lc = r_class("AVPlayerLooper");
    g_looper = r_is_objc_ptr(lc)
        ? r_msg2_main(lc, "playerLooperWithPlayer:templateItem:", g_player, item, 0, 0)
        : 0;
    r_msg2_main(g_player, "play", 0, 0, 0, 0);
    return true;
}

void livewp_forget_remote_state(void) { zero_state(); g_on = false; }

// ---------- private ----------

static uint64_t make_layer(uint64_t player) {
    uint64_t l = r_msg2_main(r_class("AVPlayerLayer"), "playerLayerWithPlayer:", player, 0, 0, 0);
    if (!r_is_objc_ptr(l)) return 0;
    uint64_t g = r_nsstr_retained("AVLayerVideoGravityResizeAspectFill");
    if (r_is_objc_ptr(g)) { r_msg2_main(l, "setVideoGravity:", g, 0, 0, 0); r_msg2(g, "release", 0, 0, 0, 0); }
    return l;
}

static bool create_player(NSString *path) {
    uint64_t avf = r_alloc_str("/System/Library/Frameworks/AVFoundation.framework/AVFoundation");
    if (avf) { r_dlsym_call(R_TIMEOUT, "dlopen", avf, 2, 0, 0, 0, 0, 0, 0); r_free(avf); }

    uint64_t s = r_nsstr_retained(path.UTF8String);
    if (!r_is_objc_ptr(s)) return false;
    uint64_t url = r_msg2_main(r_class("NSURL"), "fileURLWithPath:", s, 0, 0, 0);
    r_msg2(s, "release", 0, 0, 0, 0);
    if (!r_is_objc_ptr(url)) return false;

    uint64_t item = r_msg2_main(r_class("AVPlayerItem"), "playerItemWithURL:", url, 0, 0, 0);
    if (!r_is_objc_ptr(item)) return false;
    r_msg2_main(item, "retain", 0, 0, 0, 0);

    // AVQueuePlayer is required for AVPlayerLooper
    uint64_t pc = r_class("AVQueuePlayer");
    if (!r_is_objc_ptr(pc)) pc = r_class("AVPlayer");
    if (!r_is_objc_ptr(pc)) return false;
    uint64_t p = r_msg2_main(pc, "playerWithPlayerItem:", item, 0, 0, 0);
    if (!r_is_objc_ptr(p)) return false;

    double z = 0.0;
    r_msg2_main_raw(p, "setVolume:", &z, sizeof(z), NULL, 0, NULL, 0, NULL, 0);
    r_msg2_main(p, "setPreventsDisplaySleepDuringVideoPlayback:", 0, 0, 0, 0);

    uint64_t lc = r_class("AVPlayerLooper");
    uint64_t lp = r_is_objc_ptr(lc)
        ? r_msg2_main(lc, "playerLooperWithPlayer:templateItem:", p, item, 0, 0)
        : 0;

    uint64_t hl = make_layer(p);
    uint64_t ll = make_layer(p);
    if (!r_is_objc_ptr(hl) || !r_is_objc_ptr(ll)) return false;

    // ambient audio session — no music ducking
    uint64_t ses = r_msg2_main(r_class("AVAudioSession"), "sharedInstance", 0, 0, 0, 0);
    if (r_is_objc_ptr(ses)) {
        uint64_t cat = r_nsstr_retained("AVAudioSessionCategoryAmbient");
        if (r_is_objc_ptr(cat)) {
            r_dlsym_call(R_TIMEOUT, "objc_msgSend", ses, r_sel("setCategory:withOptions:error:"),
                         cat, (uint64_t)1, (uint64_t)0, 0, 0, 0);
            r_msg2(cat, "release", 0, 0, 0, 0);
        }
    }

    g_player = p;
    g_item = item;
    g_looper = lp;
    g_home_layer = hl;
    g_lock_layer = ll;
    return true;
}

static bool ensure_in_window(uint64_t layer, uint64_t window) {
    if (!r_is_objc_ptr(layer) || !r_is_objc_ptr(window)) return false;
    uint64_t wl = r_msg2_main(window, "layer", 0, 0, 0, 0);
    if (!r_is_objc_ptr(wl)) return false;

    // match window bounds
    struct { double x, y, w, h; } b = {0};
    r_msg2_main_struct_ret(window, "bounds", &b, sizeof(b),
                           NULL, 0, NULL, 0, NULL, 0, NULL, 0);
    r_msg2_main_raw(layer, "setFrame:", &b, sizeof(b), NULL, 0, NULL, 0, NULL, 0);

    uint64_t sup = r_msg2_main(layer, "superlayer", 0, 0, 0, 0);
    if (sup != wl) {
        if (r_is_objc_ptr(sup)) r_msg2_main(layer, "removeFromSuperlayer", 0, 0, 0, 0);
        r_msg2_main(wl, "insertSublayer:atIndex:", layer, 0, 0, 0);
    }
    return true;
}

static bool attach_and_play(void) {
    bool h = ensure_in_window(g_home_layer, g_home_win);
    bool l = ensure_in_window(g_lock_layer, g_lock_win);
    if (h || l) { r_msg2_main(g_player, "play", 0, 0, 0, 0); return true; }

    uint64_t app = r_msg2_main(r_class("UIApplication"), "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) return false;
    uint64_t wins = r_msg2_main(app, "windows", 0, 0, 0, 0);
    uint64_t n = r_is_objc_ptr(wins) ? r_msg2_main(wins, "count", 0, 0, 0, 0) : 0;
    uint64_t homeCls = r_class("SBHomeScreenView");
    uint64_t lockCls = r_class("SBCoverSheetWindow");

    for (uint64_t i = 0; i < n && i < 32; i++) {
        uint64_t w = r_msg2_main(wins, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(w)) continue;
        if (!g_lock_win && r_is_objc_ptr(lockCls) &&
            r_msg2_main(w, "isKindOfClass:", lockCls, 0, 0, 0)) {
            g_lock_win = w; if (g_home_win) break; continue;
        }
        if (!g_home_win && r_is_objc_ptr(homeCls)) {
            uint64_t subs = r_msg2_main(w, "subviews", 0, 0, 0, 0);
            uint64_t sn = r_is_objc_ptr(subs) ? r_msg2_main(subs, "count", 0, 0, 0, 0) : 0;
            for (uint64_t j = 0; j < sn && j < 4; j++) {
                uint64_t sv = r_msg2_main(subs, "objectAtIndex:", j, 0, 0, 0);
                if (r_is_objc_ptr(sv) && r_msg2_main(sv, "isKindOfClass:", homeCls, 0, 0, 0)) {
                    g_home_win = w; if (g_lock_win) break; break;
                }
            }
        }
    }

    h = ensure_in_window(g_home_layer, g_home_win);
    l = ensure_in_window(g_lock_layer, g_lock_win);
    if (!h && !l) return false;
    r_msg2_main(g_player, "play", 0, 0, 0, 0);
    return true;
}

static void zero_state(void) {
    g_player = g_item = g_looper = 0;
    g_home_layer = g_lock_layer = 0;
    g_home_win = g_lock_win = 0;
}
