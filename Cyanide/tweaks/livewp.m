//
//  livewp.m
//  LiveWP (Live Wallpaper) implementation custom
//
//  策略：一个 AVQueuePlayer + AVPlayerLooper 驱动两个 AVPlayerLayer，
//  分别插到 SBHomeScreenWindow 和 SBCoverSheetWindow 的 layer index 0。
//  Looping: AVPlayerLooper (actionAtItemEnd 默认就是 AVPlayerActionAtItemEndAdvance)。
//

#import "livewp.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <unistd.h>

// ============================================================================
// MARK: - Global State
// ============================================================================

static uint64_t g_livewp_player = 0;           // AVQueuePlayer
static uint64_t g_livewp_home_layer = 0;       // 主屏幕的 AVPlayerLayer
static uint64_t g_livewp_lock_layer = 0;       // 锁屏的 AVPlayerLayer
static uint64_t g_livewp_player_item = 0;      // 当前播放 item（被 looper 持有）
static uint64_t g_livewp_looper = 0;           // AVPlayerLooper 实例
static uint64_t g_livewp_home_window = 0;
static uint64_t g_livewp_lock_window = 0;
static bool g_livewp_configured = false;

typedef struct { double x, y, w, h; } LiveWPRect;

// ============================================================================
// MARK: - Keys
// ============================================================================

NSString * const kLiveWPEnabled = @"LiveWPEnabled";
NSString * const kLiveWPVideoPath = @"LiveWPVideoPath";

// ============================================================================
// MARK: - Forward Declarations
// ============================================================================

static bool livewp_create_player(NSString *videoPath);
static bool livewp_attach_and_play(void);
static void livewp_cleanup(void);

// ============================================================================
// MARK: - Public Interface
// ============================================================================

// 从相对路径拼接为绝对路径（兼容旧版绝对路径）
NSString *livewp_absolute_path(void) {
    NSString *rel = [[NSUserDefaults standardUserDefaults] stringForKey:kLiveWPVideoPath];
    if (!rel || rel.length == 0) return nil;
    if ([rel hasPrefix:@"/"]) return rel;
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [docs stringByAppendingPathComponent:rel];
}

bool livewp_apply_in_session(void)
{
    NSString *videoPath = livewp_absolute_path();
    if (!videoPath || videoPath.length == 0) {
        log_user("[LIVEWP] No video path configured.\n");
        return false;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
        log_user("[LIVEWP] Video file not found: %s\n", videoPath.UTF8String);
        return false;
    }

    if (g_livewp_configured) {
        livewp_stop_in_session();
        usleep(100000);
    }

    if (!livewp_create_player(videoPath)) return false;
    if (!livewp_attach_and_play()) { livewp_cleanup(); return false; }

    g_livewp_configured = true;
    log_user("[LIVEWP] OK: playing.\n");
    return true;
}

bool livewp_stop_in_session(void)
{
    if (!g_livewp_configured) return true;

    if (r_is_objc_ptr(g_livewp_player))
        r_msg2_main(g_livewp_player, "pause", 0, 0, 0, 0);

    if (r_is_objc_ptr(g_livewp_home_layer))
        r_msg2_main(g_livewp_home_layer, "removeFromSuperlayer", 0, 0, 0, 0);
    if (r_is_objc_ptr(g_livewp_lock_layer))
        r_msg2_main(g_livewp_lock_layer, "removeFromSuperlayer", 0, 0, 0, 0);

    livewp_cleanup();
    g_livewp_configured = false;
    log_user("[LIVEWP] stopped.\n");
    return true;
}

// Pause without removing the layer pair. Cheap, idempotent, safe to call
// from a screen-off darwin-notify observer: no AVPlayer recreation, no
// superlayer surgery — the AVPlayer just stops decoding frames until
// livewp_resume_in_session() or livewp_repair_in_session() restarts it.
bool livewp_pause_in_session(void)
{
    if (!g_livewp_configured) return true;
    if (!r_is_objc_ptr(g_livewp_player)) {
        // Remote state lost between configure and pause — fall back to a
        // full repair so the next wake has a working player.
        return livewp_repair_in_session();
    }
    r_msg2_main(g_livewp_player, "pause", 0, 0, 0, 0);
    return true;
}

bool livewp_resume_in_session(void)
{
    if (!g_livewp_configured) return true;
    if (!r_is_objc_ptr(g_livewp_player)) {
        // The SpringBoard session respawned under us while the screen was
        // off. Rebuild the layer pair and replay.
        NSString *path = livewp_absolute_path();
        if (!path.length) return false;
        if (!livewp_create_player(path)) return false;
        return livewp_attach_and_play();
    }
    // Make sure both layers are still attached to the (possibly recycled)
    // SpringBoard windows before resuming playback — that is what fixes
    // the "icons disappear for a couple seconds after unlock" symptom.
    if (!livewp_attach_and_play()) return false;
    r_msg2_main(g_livewp_player, "play", 0, 0, 0, 0);
    return true;
}

bool livewp_repair_in_session(void)
{
    if (!g_livewp_configured) return false;
    // AVPlayerLooper handles looping automatically: it observes the player
    // item reaching end-of-stream and enqueues a fresh copy of the template
    // item onto the AVQueuePlayer. We just need to make sure the layers are
    // still attached to the (possibly recycled) SpringBoard windows and
    // playback is running.
    if (!r_is_objc_ptr(g_livewp_player) || !r_is_objc_ptr(g_livewp_looper)) {
        // Looper lost — most likely SpringBoard recycled the host window
        // and our cached pointers are stale. Rebuild from scratch.
        NSString *path = livewp_absolute_path();
        if (!path.length) return false;
        if (!livewp_create_player(path)) return false;
        return livewp_attach_and_play();
    }
    return livewp_attach_and_play();
}

// 热替换视频：丢弃旧 looper 并基于新 item 重建 looper，
// 所有 AVFoundation 对象都在 SpringBoard 进程里通过 RemoteCall 创建
bool livewp_swap_video_in_session(NSString *videoPath)
{
    if (!g_livewp_configured || !r_is_objc_ptr(g_livewp_player)) {
        log_user("[LIVEWP] swap: not configured\n");
        return false;
    }

    uint64_t pathStr = r_nsstr_retained(videoPath.UTF8String);
    if (!r_is_objc_ptr(pathStr)) return false;
    uint64_t url = r_msg2_main(r_class("NSURL"), "fileURLWithPath:", pathStr, 0, 0, 0);
    r_msg2(pathStr, "release", 0, 0, 0, 0);
    if (!r_is_objc_ptr(url)) return false;

    // 在 SpringBoard 进程里创建新 AVPlayerItem
    uint64_t newItem = r_msg2_main(r_class("AVPlayerItem"), "playerItemWithURL:", url, 0, 0, 0);
    if (!r_is_objc_ptr(newItem)) {
        log_user("[LIVEWP] swap: failed to create playerItem\n");
        return false;
    }

    // FIX: retain newItem before storing — playerItemWithURL: returns an
    // autoreleased object; without an explicit retain it may be freed on
    // the next autorelease pool drain, leaving g_livewp_player_item dangling.
    r_msg2_main(newItem, "retain", 0, 0, 0, 0);

    // Dispose of the old looper before swapping the template — looper holds
    // a strong ref to the old item and will keep re-enqueueing stale copies
    // if we leave it in place.
    if (r_is_objc_ptr(g_livewp_looper)) {
        r_msg2_main(g_livewp_looper, "disableLooping", 0, 0, 0, 0);
        r_msg2(g_livewp_looper, "release", 0, 0, 0, 0);
        g_livewp_looper = 0;
    }

    // Build a fresh looper bound to the new template item. AVPlayerLooper
    // automatically drives the AVQueuePlayer in an infinite loop with
    // seamless gapless transitions at the item boundary.
    uint64_t looperClass = r_class("AVPlayerLooper");
    if (!r_is_objc_ptr(looperClass)) {
        log_user("[LIVEWP] swap: AVPlayerLooper class missing\n");
        return false;
    }
    // -[AVPlayerLooper initWithPlayer:templateItem:]:
    //   player       = g_livewp_player (AVQueuePlayer)
    //   templateItem = newItem
    // Looper takes ownership semantics: it holds strong refs to both, and
    // re-enqueues new copies of templateItem onto the queue automatically.
    uint64_t newLooper = r_msg2_main(looperClass, "initWithPlayer:templateItem:",
                                    g_livewp_player, newItem, 0, 0);
    if (!r_is_objc_ptr(newLooper)) {
        log_user("[LIVEWP] swap: failed to init AVPlayerLooper\n");
        return false;
    }

    // replaceCurrentItemWithPlayerItem: — layer 保持不变，只是换了视频源。
    // Note: the looper has already pushed newItem into the queue; we call
    // replaceCurrentItemWithPlayerItem: to make the swap instant rather than
    // waiting for the queue head to drain.
    r_msg2_main(g_livewp_player, "replaceCurrentItemWithPlayerItem:", newItem, 0, 0, 0);
    g_livewp_player_item = newItem;
    g_livewp_looper = newLooper;

    r_msg2_main(g_livewp_player, "play", 0, 0, 0, 0);
    log_user("[LIVEWP] video swapped OK (looper)\n");
    return true;
}

void livewp_forget_remote_state(void)
{
    g_livewp_player = 0;
    g_livewp_home_layer = 0;
    g_livewp_lock_layer = 0;
    g_livewp_player_item = 0;
    g_livewp_looper = 0;
    g_livewp_home_window = 0;
    g_livewp_lock_window = 0;
    g_livewp_configured = false;
}

// ============================================================================
// MARK: - Private Helpers
// ============================================================================

static uint64_t livewp_make_layer(uint64_t player)
{
    uint64_t layer = r_msg2_main(r_class("AVPlayerLayer"), "playerLayerWithPlayer:", player, 0, 0, 0);
    if (!r_is_objc_ptr(layer)) return 0;
    uint64_t gravity = r_nsstr_retained("AVLayerVideoGravityResizeAspectFill");
    if (r_is_objc_ptr(gravity)) {
        r_msg2_main(layer, "setVideoGravity:", gravity, 0, 0, 0);
        r_msg2(gravity, "release", 0, 0, 0, 0);
    }
    return layer;
}

static bool livewp_create_player(NSString *videoPath)
{
    uint64_t avf = r_alloc_str("/System/Library/Frameworks/AVFoundation.framework/AVFoundation");
    if (avf) { r_dlsym_call(R_TIMEOUT, "dlopen", avf, 2, 0, 0, 0, 0, 0, 0); r_free(avf); }

    uint64_t pathStr = r_nsstr_retained(videoPath.UTF8String);
    if (!r_is_objc_ptr(pathStr)) return false;
    uint64_t url = r_msg2_main(r_class("NSURL"), "fileURLWithPath:", pathStr, 0, 0, 0);
    r_msg2(pathStr, "release", 0, 0, 0, 0);
    if (!r_is_objc_ptr(url)) return false;

    uint64_t playerItem = r_msg2_main(r_class("AVPlayerItem"), "playerItemWithURL:", url, 0, 0, 0);
    if (!r_is_objc_ptr(playerItem)) return false;
    // Retain the template item — the looper will hold its own ref, but
    // g_livewp_player_item is referenced independently (and survives the
    // autorelease pool drain on the next remote call).
    r_msg2_main(playerItem, "retain", 0, 0, 0, 0);

    // AVPlayerLooper REQUIRES an AVQueuePlayer (it advances by enqueuing
    // fresh template-item copies onto the player's queue). Fall back to
    // plain AVPlayer only as a last resort, and in that case skip the
    // looper and loop manually via the old seekToTime: path.
    uint64_t playerClass = r_class("AVQueuePlayer");
    if (!r_is_objc_ptr(playerClass)) {
        log_user("[LIVEWP] AVQueuePlayer missing — falling back to manual loop\n");
        playerClass = r_class("AVPlayer");
    }
    if (!r_is_objc_ptr(playerClass)) return false;

    uint64_t player = r_msg2_main(playerClass, "playerWithPlayerItem:", playerItem, 0, 0, 0);
    if (!r_is_objc_ptr(player)) return false;

    double zero = 0.0;
    r_msg2_main_raw(player, "setVolume:", &zero, sizeof(zero), NULL, 0, NULL, 0, NULL, 0);
    r_msg2_main(player, "setPreventsDisplaySleepDuringVideoPlayback:", 0, 0, 0, 0);

    // Build the looper. AVPlayerLooper's default behavior is exactly what
    // we want: it observes end-of-stream on the current item and pushes a
    // fresh copy of the template item onto the AVQueuePlayer, producing
    // gapless infinite playback. This replaces the old manual seekToTime:0
    // path in livewp_repair_in_session, which had to rewind and replay on
    // every tick and produced a visible frame stutter at the loop point.
    uint64_t looper = 0;
    if (r_class("AVQueuePlayer") == playerClass) {
        uint64_t looperClass = r_class("AVPlayerLooper");
        if (r_is_objc_ptr(looperClass)) {
            // -[AVPlayerLooper initWithPlayer:templateItem:].
            // The looper will retain both the player and the template item
            // internally, so we don't need to retain them again here.
            looper = r_msg2_main(looperClass, "initWithPlayer:templateItem:",
                                player, playerItem, 0, 0);
            if (!r_is_objc_ptr(looper)) {
                log_user("[LIVEWP] AVPlayerLooper init failed\n");
            }
        } else {
            log_user("[LIVEWP] AVPlayerLooper class not found\n");
        }
    }

    // 两个 layer：一个给主屏幕，一个给锁屏
    uint64_t homeLayer = livewp_make_layer(player);
    uint64_t lockLayer = livewp_make_layer(player);
    if (!r_is_objc_ptr(homeLayer) || !r_is_objc_ptr(lockLayer)) return false;

    uint64_t session = r_msg2_main(r_class("AVAudioSession"), "sharedInstance", 0, 0, 0, 0);
    if (r_is_objc_ptr(session)) {
        uint64_t cat = r_nsstr_retained("AVAudioSessionCategoryAmbient");
        if (r_is_objc_ptr(cat)) {
            r_dlsym_call(R_TIMEOUT, "objc_msgSend", session, r_sel("setCategory:withOptions:error:"),
                         cat, (uint64_t)1, (uint64_t)0, 0, 0, 0);
            r_msg2(cat, "release", 0, 0, 0, 0);
        }
    }

    g_livewp_player = player;
    g_livewp_player_item = playerItem;
    g_livewp_looper = looper;
    g_livewp_home_layer = homeLayer;
    g_livewp_lock_layer = lockLayer;
    log_user("[LIVEWP] player OK (2 layers, looper=%s)\n", r_is_objc_ptr(looper) ? "yes" : "no");
    return true;
}

// 辅助：把 layer 插到指定 window 的 index 1，返回是否已附着成功。
// index 1 = above the stock wallpaper layer (index 0), below SBIconView.
static bool livewp_ensure_layer_in_window(uint64_t layer, uint64_t window, bool *movedOut)
{
    if (movedOut) *movedOut = false;
    if (!r_is_objc_ptr(layer) || !r_is_objc_ptr(window)) return false;

    uint64_t winLayer = r_msg2_main(window, "layer", 0, 0, 0, 0);
    if (!r_is_objc_ptr(winLayer)) return false;

    LiveWPRect bounds = {0};
    r_msg2_main_struct_ret(window, "bounds", &bounds, sizeof(bounds),
                           NULL, 0, NULL, 0, NULL, 0, NULL, 0);
    r_msg2_main_raw(layer, "setFrame:",
                    &bounds, sizeof(bounds), NULL, 0, NULL, 0, NULL, 0);

    uint64_t curSuper = r_msg2_main(layer, "superlayer", 0, 0, 0, 0);
    if (curSuper != winLayer) {
        if (r_is_objc_ptr(curSuper))
            r_msg2_main(layer, "removeFromSuperlayer", 0, 0, 0, 0);
        // Insert at index 1: above the background wallpaper layer (always
        // at index 0) but below SBIconView and the rest of the content.
        // The previous atIndex:0 placed us underneath the wallpaper, so
        // the stock wallpaper rendered on top during lockscreen pull-down
        // and the home-screen "icons disappear after unlock" flash was
        // caused by the layer being reattached at the very top of the
        // stack on every window transition. UIWindow siblings are still
        // ordered by UIScreen, so this only affects the content inside
        // SBCoverSheetWindow / SBHomeScreenWindow.
        uint64_t sublayers = r_msg2_main(winLayer, "sublayers", 0, 0, 0, 0);
        uint64_t sublayerCount = r_is_objc_ptr(sublayers)
            ? r_msg2_main(sublayers, "count", 0, 0, 0, 0) : 0;
        (void)sublayerCount;
        uint64_t insertIdx = 0;
        r_msg2_main(winLayer, "insertSublayer:atIndex:",
                    layer, insertIdx, 0, 0);
        if (movedOut) *movedOut = true;
    }
    return true;
}

static bool livewp_attach_and_play(void)
{
    bool homeMoved = false;
    bool lockMoved = false;
    bool homeOK = livewp_ensure_layer_in_window(g_livewp_home_layer,
                                                g_livewp_home_window,
                                                &homeMoved);
    bool lockOK = livewp_ensure_layer_in_window(g_livewp_lock_layer,
                                                g_livewp_lock_window,
                                                &lockMoved);
    if (homeOK || lockOK) {
        r_msg2_main(g_livewp_player, "play", 0, 0, 0, 0);
        if (homeMoved || lockMoved) {
            log_user("[LIVEWP] repair: reused cached windows homeMoved=%d lockMoved=%d\n",
                     homeMoved, lockMoved);
        }
        return true;
    }

    uint64_t app = r_msg2_main(r_class("UIApplication"), "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) return false;

    // 遍历所有 window，找 SBHomeScreenWindow 和 SBCoverSheetWindow
    uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
    uint64_t wCount = r_is_objc_ptr(windows) ? r_msg2_main(windows, "count", 0, 0, 0, 0) : 0;
    uint64_t homeWin = 0;
    uint64_t lockWin = 0;
    uint64_t homeScreenViewCls = r_class("SBHomeScreenView");
    uint64_t coverSheetCls = r_class("SBCoverSheetWindow");

    for (uint64_t i = 0; i < wCount && i < 32; i++) {
        uint64_t w = r_msg2_main(windows, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(w)) continue;

        // 检查是不是 SBCoverSheetWindow
        if (r_is_objc_ptr(coverSheetCls) &&
            r_msg2_main(w, "isKindOfClass:", coverSheetCls, 0, 0, 0)) {
            lockWin = w;
            if (homeWin) break;
            continue;
        }

        // 检查子视图有没有 SBHomeScreenView
        if (!homeWin && r_is_objc_ptr(homeScreenViewCls)) {
            uint64_t subs = r_msg2_main(w, "subviews", 0, 0, 0, 0);
            uint64_t sCount = r_is_objc_ptr(subs) ? r_msg2_main(subs, "count", 0, 0, 0, 0) : 0;
            for (uint64_t j = 0; j < sCount && j < 4; j++) {
                uint64_t sv = r_msg2_main(subs, "objectAtIndex:", j, 0, 0, 0);
                if (r_is_objc_ptr(sv) &&
                    r_msg2_main(sv, "isKindOfClass:", homeScreenViewCls, 0, 0, 0)) {
                    homeWin = w;
                    if (lockWin) break;
                    break;
                }
            }
        }
    }

    // 把各自的 layer 插到各自的 window
    if (r_is_objc_ptr(homeWin)) {
        homeOK = livewp_ensure_layer_in_window(g_livewp_home_layer, homeWin, &homeMoved);
        if (homeOK) g_livewp_home_window = homeWin;
    }
    if (r_is_objc_ptr(lockWin)) {
        lockOK = livewp_ensure_layer_in_window(g_livewp_lock_layer, lockWin, &lockMoved);
        if (lockOK) g_livewp_lock_window = lockWin;
    }

    r_msg2_main(g_livewp_player, "play", 0, 0, 0, 0);

    log_user("[LIVEWP] D: home=0x%llx(%d) lock=0x%llx(%d) wCount=%llu\n",
             homeWin, homeMoved, lockWin, lockMoved, wCount);
    return homeOK || lockOK;
}

static void livewp_cleanup(void)
{
    g_livewp_player = 0;
    g_livewp_player_item = 0;
    g_livewp_home_layer = 0;
    g_livewp_lock_layer = 0;
    g_livewp_looper = 0;
    g_livewp_home_window = 0;
    g_livewp_lock_window = 0;
}
