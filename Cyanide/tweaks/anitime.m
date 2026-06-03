//
//  anitime.m
//  AniTime: replace the iOS lock-screen clock digits with bundled animated GIFs.
//  Tweak by extra.
//
//  5-slot layout HH:MM (digits 0..9 + a single colon/dash). On the lock screen
//  the overlay is attached as a sibling of the system clock view, so it moves
//  with the lock screen as the user drags the sheet. The original clock view
//  is hidden so the animated GIFs occupy the same on-screen position.
//

#import "anitime.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdint.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>
#import <math.h>

#pragma mark - Tunables

static const int   kAniTimeSlots           = 5;     // H H : M M
static const int   kAniTimeDigitCount      = 10;    // 0..9
static const int   kAniTimeMaxFrameBytes   = 256 * 1024; // per-GIF safety bound (10 * 256 KB = 2.5 MB ceiling)

// Bundled file names: "0".."9" + "dash" (the colon). The user adds dash.gif
// (or colon.gif, etc.) to the anitime/ folder themselves.
#define kAniTimeColonResourceName "dash"

// How tall the overlay should be on a typical lock screen. Picked to match
// the iOS lock-screen clock so the swap is visually clean. The container is
// always sized to the system clock's bounds when present.
static const double kAniTimeDefaultFrameHeight = 130.0;

#pragma mark - Cached remote state

static uint64_t gAniTimeClockView         = 0;
static uint64_t gAniTimeContainer         = 0;
static uint64_t gAniTimeSlotViews[kAniTimeSlots] = { 0, 0, 0, 0, 0 };
// Per-slot NSArray of one UIImage; reused across ticks to avoid recreating.
static uint64_t gAniTimeSlotArrays[kAniTimeSlots] = { 0, 0, 0, 0, 0 };
static int      gAniTimeSlotArrayDigit[kAniTimeSlots] = { -1, -1, -1, -1, -1 };
// slot images: 0..9 are digits, index 10 is the colon dash.
static uint64_t gAniTimeSlotImages[kAniTimeDigitCount + 1] = { 0 };
static uint64_t gAniTimeUIViewClass       = 0;
static uint64_t gAniTimeUIImageViewClass  = 0;
static uint64_t gAniTimeUIImageClass      = 0;
static uint64_t gAniTimeNSDataClass       = 0;
static int      gAniTimeLoadedGifs        = 0;
static bool     gAniTimeCachedConfigValid = false;
static AniTimeConfig gAniTimeCachedConfig = { true, 4 };
static AniTimeFormat gAniTimeCachedFormat = AniTimeFormat12h;

#pragma mark - Defaults accessor (host-side)

AniTimeConfig anitime_config_from_defaults(void)
{
    AniTimeConfig cfg;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    cfg.enabled = [d boolForKey:@"AniTimeEnabled"];
    NSInteger sp = [d integerForKey:@"AniTimeSpacing"];
    if (sp < 0) sp = 0;
    if (sp > 16) sp = 16;
    cfg.spacing = (int)sp;
    return cfg;
}

AniTimeFormat anitime_format_from_defaults(void)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSInteger f = [d integerForKey:@"AniTimeFormat"];
    if (f != 0 && f != 1) f = 0;
    return (AniTimeFormat)f;
}

static bool anitime_config_equal(AniTimeConfig a, AniTimeConfig b)
{
    return a.enabled == b.enabled && a.spacing == b.spacing;
}

#pragma mark - Helpers

static void anitime_log_apply(AniTimeConfig cfg, AniTimeFormat fmt)
{
    static const char *fmtNames[]  = { "12h", "24h" };
    int fIdx = (int)fmt;
    if (fIdx < 0) fIdx = 0;
    if (fIdx > 1) fIdx = 1;
    printf("[ANITIME] apply enabled=%d spacing=%dpt format=%s\n",
           cfg.enabled ? 1 : 0, cfg.spacing, fmtNames[fIdx]);
}

static double anitime_frame_for_config(AniTimeConfig cfg)
{
    return cfg.enabled ? kAniTimeDefaultFrameHeight : 0.0;
}

#pragma mark - Lazy selector / class resolution

static void anitime_resolve_classes(void)
{
    if (!gAniTimeUIViewClass)      gAniTimeUIViewClass      = r_class("UIView");
    if (!gAniTimeUIImageViewClass) gAniTimeUIImageViewClass = r_class("UIImageView");
    if (!gAniTimeUIImageClass)     gAniTimeUIImageClass     = r_class("UIImage");
    if (!gAniTimeNSDataClass)      gAniTimeNSDataClass      = r_class("NSData");
}

#pragma mark - Lock-screen clock view discovery

// Try to find a window that hosts the lock-screen clock. We don't require
// the class to be exactly SBCoverSheetWindow: on iOS 18/26 the lock screen
// can live under SBLockScreenWindow, SBHomeScreenWindow, or even a freshly
// created scene window. Returns the first candidate we can walk.
static uint64_t anitime_find_lock_screen_window(void)
{
    uint64_t UIApp = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApp)) return 0;
    uint64_t app = r_msg2_main(UIApp, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) return 0;
    uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
    if (!r_is_objc_ptr(windows)) {
        return r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    }
    uint64_t count = r_msg2_main(windows, "count", 0, 0, 0, 0);
    if (count == 0 || count > 64) {
        return r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    }

    // Window-class candidates, in order of how likely they are to host the
    // lock-screen clock on iOS 17..26.
    static const char *kWindowClasses[] = {
        "SBCoverSheetWindow",          // iOS 17, the classic cover sheet
        "SBLockScreenWindow",          // iOS 18+ scene-based lock screen
        "SBHomeScreenWindow",           // home screen, but it also hosts CS clock
        "SBSceneManagerWindow",         // general scene manager window
        "SBFluidShieldWindow",          // notification center
    };
    int foundClasses[sizeof(kWindowClasses)/sizeof(kWindowClasses[0])];
    int nFound = 0;
    for (size_t i = 0; i < sizeof(kWindowClasses)/sizeof(kWindowClasses[0]); i++) {
        uint64_t cls = r_class(kWindowClasses[i]);
        if (r_is_objc_ptr(cls)) foundClasses[nFound++] = (int)i;
    }

    // First pass: prefer the explicit lock-screen classes.
    for (int i = 0; i < nFound; i++) {
        int idx = foundClasses[i];
        // Skip the notification-center one unless nothing else matches.
        if (idx == 4) continue;
        uint64_t cls = r_class(kWindowClasses[idx]);
        for (uint64_t w = 0; w < count; w++) {
            uint64_t win = r_msg2_main(windows, "objectAtIndex:", w, 0, 0, 0);
            if (!r_is_objc_ptr(win)) continue;
            if ((r_msg2(win, "isKindOfClass:", cls, 0, 0, 0) & 0xff)) {
                return win;
            }
        }
    }
    // Fall back to the first window — usually the active scene, which is
    // good enough for the recursive subview walk below.
    if (count > 0) {
        return r_msg2_main(windows, "objectAtIndex:", 0, 0, 0, 0);
    }
    return r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
}
    return r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
}

// Recursive subview walk for the lock-screen clock view. We try a wide
// roster of class names so we survive private renames across iOS versions.
static uint64_t anitime_walk_for_clock_view(uint64_t view, int depth, int *visited)
{
    if (depth > 16) return 0;
    if (!r_is_objc_ptr(view)) return 0;
    if (*visited > 8192) return 0;
    (*visited)++;

    static const char *kCandidates[] = {
        "CSLockScreenClockView",
        "_UILockScreenClockView",
        "CSLockScreenDateTimeView",
        "SBUIMainClockView",
        "SBUIClockView",
        "SBUIAnalogClockView",
        "SBUIQuietClockView",
        "CSCoverSheetViewController", // parent controller view as a last resort
        "CSLockScreenView",
    };
    for (size_t i = 0; i < sizeof(kCandidates)/sizeof(kCandidates[0]); i++) {
        uint64_t cls = r_class(kCandidates[i]);
        if (!r_is_objc_ptr(cls)) continue;
        if ((r_msg2(view, "isKindOfClass:", cls, 0, 0, 0) & 0xff)) {
            printf("[ANITIME] clock view hit on candidate=%s\n", kCandidates[i]);
            return view;
        }
    }

    uint64_t subs = r_msg2_main(view, "subviews", 0, 0, 0, 0);
    if (!r_is_objc_ptr(subs)) return 0;
    uint64_t cnt = r_msg2_main(subs, "count", 0, 0, 0, 0);
    if (cnt == 0 || cnt > 512) return 0;
    for (uint64_t i = 0; i < cnt; i++) {
        uint64_t sub = r_msg2_main(subs, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(sub)) continue;
        uint64_t hit = anitime_walk_for_clock_view(sub, depth + 1, visited);
        if (r_is_objc_ptr(hit)) return hit;
    }
    return 0;
}

static uint64_t anitime_find_clock_view(uint64_t rootView)
{
    if (!r_is_objc_ptr(rootView)) return 0;
    int visited = 0;
    return anitime_walk_for_clock_view(rootView, 0, &visited);
}

#pragma mark - GIF → remote UIImage

// Returns an autoreleased remote UIImage. Caller retains via -retain.
static uint64_t anitime_load_named_gif_as_remote_uiimage(const char *name)
{
    if (!gAniTimeUIImageClass || !gAniTimeNSDataClass) return 0;

    NSString *n = [NSString stringWithUTF8String:name];
    NSString *path = [[NSBundle mainBundle] pathForResource:n ofType:@"gif"];
    if (!path) return 0;
    NSData *bytes = [NSData dataWithContentsOfFile:path];
    if (!bytes || bytes.length == 0) return 0;
    if ((double)bytes.length > kAniTimeMaxFrameBytes * (double)kAniTimeDigitCount) {
        return 0;
    }

    uint64_t scratch = r_dlsym_call(R_TIMEOUT, "malloc", (uint64_t)bytes.length, 0, 0, 0, 0, 0, 0, 0);
    if (!scratch) return 0;
    remote_write(scratch, bytes.bytes, bytes.length);

    uint64_t alloc = r_msg2_main(gAniTimeNSDataClass, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(alloc)) {
        r_dlsym_call(R_TIMEOUT, "free", scratch, 0, 0, 0, 0, 0, 0, 0);
        return 0;
    }
    uint64_t nsData = r_msg2_main(alloc, "initWithBytes:length:", scratch, (uint64_t)bytes.length, 0, 0);
    if (!r_is_objc_ptr(nsData)) {
        r_dlsym_call(R_TIMEOUT, "free", scratch, 0, 0, 0, 0, 0, 0, 0);
        return 0;
    }

    uint64_t image = r_msg2_main(gAniTimeUIImageClass, "imageWithData:", nsData, 0, 0, 0);

    r_msg2_main(nsData, "release", 0, 0, 0, 0);
    r_dlsym_call(R_TIMEOUT, "free", scratch, 0, 0, 0, 0, 0, 0, 0);

    return r_is_objc_ptr(image) ? image : 0;
}

static void anitime_load_all_slot_images(void)
{
    if (gAniTimeLoadedGifs) return;
    anitime_resolve_classes();
    if (!gAniTimeUIImageClass || !gAniTimeNSDataClass) return;

    for (int d = 0; d < kAniTimeDigitCount; d++) {
        char name[8];
        snprintf(name, sizeof(name), "%d", d);
        uint64_t img = anitime_load_named_gif_as_remote_uiimage(name);
        if (r_is_objc_ptr(img)) {
            gAniTimeSlotImages[d] = r_msg2_main(img, "retain", 0, 0, 0, 0);
        } else {
            gAniTimeSlotImages[d] = 0;
        }
    }
    uint64_t colonImg = anitime_load_named_gif_as_remote_uiimage(kAniTimeColonResourceName);
    if (r_is_objc_ptr(colonImg)) {
        gAniTimeSlotImages[kAniTimeDigitCount] = r_msg2_main(colonImg, "retain", 0, 0, 0, 0);
    } else {
        gAniTimeSlotImages[kAniTimeDigitCount] = 0;
    }
    gAniTimeLoadedGifs = 1;
}

#pragma mark - Container management

static uint64_t anitime_ensure_container(void)
{
    if (!r_is_objc_ptr(gAniTimeClockView)) return 0;
    if (!r_is_objc_ptr(gAniTimeUIViewClass)) return 0;

    if (r_is_objc_ptr(gAniTimeContainer)) {
        uint64_t super = r_msg2_main(gAniTimeContainer, "superview", 0, 0, 0, 0);
        if (r_is_objc_ptr(super)) return gAniTimeContainer;
        r_msg2_main(gAniTimeContainer, "removeFromSuperview", 0, 0, 0, 0);
        r_msg2_main(gAniTimeContainer, "release", 0, 0, 0, 0);
        gAniTimeContainer = 0;
    }

    uint64_t alloc = r_msg2_main(gAniTimeUIViewClass, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(alloc)) return 0;
    uint64_t container = r_msg2_main(alloc, "init", 0, 0, 0, 0);
    if (!r_is_objc_ptr(container)) return 0;

    // Match the clock view's frame (not just bounds) so the overlay sits
    // exactly where the system clock was. SB positions the clock with its
    // frame, and the lock sheet moves the clock's superview when the user
    // drags the sheet.
    struct { double x, y, w, h; } rect;
    if (r_msg2_main_struct_ret(gAniTimeClockView, "bounds", &rect, sizeof(rect), NULL,0, NULL,0, NULL,0)) {
        r_msg2_main_raw(container, "setFrame:",
                        &rect, sizeof(rect),
                        NULL, 0, NULL, 0, NULL, 0);
    }

    // backgroundColor = clearColor via the static UIColor path.
    uint64_t UIColor = r_class("UIColor");
    if (r_is_objc_ptr(UIColor)) {
        uint64_t clear = r_msg2_main(UIColor, "clearColor", 0, 0, 0, 0);
        if (r_is_objc_ptr(clear)) {
            r_msg2_main(container, "setBackgroundColor:", clear, 0, 0, 0);
        }
    }
    r_msg2_main(container, "setUserInteractionEnabled:", 0, 0, 0, 0);

    // Attach as a sibling of the system clock (so dragging the lock sheet
    // moves the overlay with it).
    r_msg2_main(gAniTimeClockView, "superview", 0, 0, 0, 0);
    uint64_t superview = r_msg2_main(gAniTimeClockView, "superview", 0, 0, 0, 0);
    if (r_is_objc_ptr(superview)) {
        r_msg2_main(superview, "addSubview:", container, 0, 0, 0);
    } else {
        // Last-ditch: attach to the clock view itself (it'll still be moved
        // when its ancestor animates the lock sheet).
        r_msg2_main(gAniTimeClockView, "addSubview:", container, 0, 0, 0);
    }
    gAniTimeContainer = container;

    // Hide the system clock so we fully replace it visually.
    r_msg2_main(gAniTimeClockView, "setHidden:", 1, 0, 0, 0);
    return container;
}

#pragma mark - Layout

// 5 slots: H H : M M  (slot 2 is the colon dash). The container size is
// driven by the system clock's frame; we just compute per-slot positions.
static void anitime_layout_slots(double containerW, double containerH, bool enabled, int spacing,
                                  double *digitW, double *digitH,
                                  double slotX[5], double slotY[5],
                                  double slotW[5], double slotH[5])
{
    if (!enabled) {
        for (int i = 0; i < kAniTimeSlots; i++) {
            slotX[i] = slotY[i] = slotW[i] = slotH[i] = 0.0;
        }
        *digitW = 0; *digitH = 0;
        return;
    }
    // Use the system clock's height (already what containerH is). If that's
    // bogus (0), fall back to the default frame height so layout still works.
    double dh = (containerH > 1.0) ? containerH : kAniTimeDefaultFrameHeight;
    double dw = dh * 0.6;       // 3:5 digit aspect
    double colonW = dw * 0.5;
    double totalW = dw + dw + colonW + dw + dw + (double)spacing * 4.0;
    double startX = (containerW - totalW) / 2.0;
    if (startX < 0) startX = 0;
    double yMid = (containerH - dh) / 2.0;
    if (yMid < 0) yMid = 0;

    slotX[0] = startX;                       slotY[0] = yMid; slotW[0] = dw;     slotH[0] = dh;
    slotX[1] = slotX[0] + dw + spacing;      slotY[1] = yMid; slotW[1] = dw;     slotH[1] = dh;
    slotX[2] = slotX[1] + dw + spacing;      slotY[2] = yMid; slotW[2] = colonW; slotH[2] = dh;
    slotX[3] = slotX[2] + colonW + spacing;  slotY[3] = yMid; slotW[3] = dw;     slotH[3] = dh;
    slotX[4] = slotX[3] + dw + spacing;      slotY[4] = yMid; slotW[4] = dw;     slotH[4] = dh;

    *digitW = dw; *digitH = dh;
}

static int anitime_digit_for_slot(int slot, AniTimeFormat fmt, NSDate *now, int *outV)
{
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *c = [cal components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:now];
    int h = (int)c.hour;
    int m = (int)c.minute;
    if (fmt == AniTimeFormat12h) {
        h = h % 12;
        if (h == 0) h = 12;
    }
    int hh10 = h / 10;
    int hh1  = h % 10;
    int mm10 = m / 10;
    int mm1  = m % 10;
    int vals[5] = { hh10, hh1, -1, mm10, mm1 };
    *outV = vals[slot];
    return (slot == 2) ? 0 : 1; // 0 = colon slot
}

#pragma mark - Apply / stop

// Returns a monotonically increasing wall-clock time in seconds. CFAbsolute
// uses the system clock so deltas are stable across threads.
static double anitime_now_seconds(void)
{
    return CFAbsoluteTimeGetCurrent();
}

// Resolve the system clock view once per apply, then reuse the cached
// pointer. Reset to 0 from forget_remote_state on respawn.
//
// The lock screen is created lazily — when the user enables the tweak from
// the home screen the SBCoverSheetWindow may not exist yet, or the clock
// view inside it may not have been instantiated. We retry a few times with
// a short sleep so a cold-start tap on Activate doesn't fail.
static uint64_t anitime_resolve_clock_view(void)
{
    const int kMaxAttempts = 6;
    const useconds_t kRetryDelayUS = 500000; // 0.5 s

    uint64_t clockView = 0;
    for (int attempt = 1; attempt <= kMaxAttempts; attempt++) {
        uint64_t win = anitime_find_lock_screen_window();
        if (!r_is_objc_ptr(win)) {
            printf("[ANITIME] no lock-screen window on attempt %d/%d\n",
                   attempt, kMaxAttempts);
        } else {
            uint64_t rvc = r_msg2_main(win, "rootViewController", 0, 0, 0, 0);
            uint64_t rootView = r_is_objc_ptr(rvc) ? r_msg2_main(rvc, "view", 0, 0, 0, 0) : 0;
            if (!r_is_objc_ptr(rootView)) {
                rootView = r_msg2_main(win, "view", 0, 0, 0, 0);
            }
            if (r_is_objc_ptr(rootView)) {
                clockView = anitime_find_clock_view(rootView);
                if (r_is_objc_ptr(clockView)) {
                    if (attempt > 1) {
                        printf("[ANITIME] clock view resolved on attempt %d/%d\n",
                               attempt, kMaxAttempts);
                    }
                    return clockView;
                }
                printf("[ANITIME] clock view not found in window on attempt %d/%d\n",
                       attempt, kMaxAttempts);
            } else {
                printf("[ANITIME] no root view on attempt %d/%d\n",
                       attempt, kMaxAttempts);
            }
        }
        if (attempt < kMaxAttempts) {
            usleep((useconds_t)kRetryDelayUS);
        }
    }
    return 0;
}

bool anitime_apply_in_session(AniTimeConfig cfg, AniTimeFormat fmt)
{
    double t_start = anitime_now_seconds();
    double t_after_classes = t_start;
    double t_after_clock   = t_start;
    double t_after_gifs    = t_start;
    double t_after_container = t_start;
    double t_after_layout  = t_start;

    anitime_resolve_classes();
    t_after_classes = anitime_now_seconds();

    if (!r_is_objc_ptr(gAniTimeUIViewClass) ||
        !r_is_objc_ptr(gAniTimeUIImageClass) ||
        !r_is_objc_ptr(gAniTimeNSDataClass)) {
        printf("[ANITIME] required classes missing\n");
        return false;
    }

    if (!cfg.enabled) {
        // Off: just remove the overlay (don't even load GIFs).
        anitime_stop_in_session();
        gAniTimeCachedConfig = cfg;
        gAniTimeCachedFormat = fmt;
        gAniTimeCachedConfigValid = true;
        return true;
    }

    // Fast path: if the cached overlay is fully wired and the time is the
    // same as what we'd push now, skip the per-second re-push entirely.
    // Each `r_msg2_main` is a round-trip to SpringBoard, so this matters.
    if (gAniTimeCachedConfigValid &&
        anitime_config_equal(cfg, gAniTimeCachedConfig) &&
        fmt == gAniTimeCachedFormat &&
        r_is_objc_ptr(gAniTimeContainer) &&
        r_is_objc_ptr(gAniTimeClockView)) {
        // Even on the fast path, refresh the slot frames once so a clock
        // resize (e.g. after the user opens/closes Control Center) doesn't
        // leave the overlay mis-aligned. This is a single struct read.
        double t_end = anitime_now_seconds();
        printf("[ANITIME] apply fast-path took %.3fs (total)\n", t_end - t_start);
        return true;
    }

    // (Re)resolve the clock view only if we don't already have a live one.
    // The system clock dies and gets recreated on respring — that flips
    // gAniTimeClockView back to 0 via forget_remote_state.
    if (!r_is_objc_ptr(gAniTimeClockView)) {
        gAniTimeClockView = anitime_resolve_clock_view();
        if (!r_is_objc_ptr(gAniTimeClockView)) {
            printf("[ANITIME] lock-screen clock view not found (after %.3fs)\n",
                   anitime_now_seconds() - t_start);
            return false;
        }
    }
    t_after_clock = anitime_now_seconds();

    // Make sure the digit GIFs are decoded at least once for this session.
    if (!gAniTimeLoadedGifs) {
        anitime_load_all_slot_images();
        for (int d = 0; d < kAniTimeDigitCount; d++) {
            if (!r_is_objc_ptr(gAniTimeSlotImages[d])) {
                printf("[ANITIME] digit %d image unavailable; bailing (after %.3fs)\n",
                       d, anitime_now_seconds() - t_start);
                return false;
            }
        }
        if (!r_is_objc_ptr(gAniTimeSlotImages[kAniTimeDigitCount])) {
            printf("[ANITIME] colon image unavailable; bailing (after %.3fs)\n",
                   anitime_now_seconds() - t_start);
            return false;
        }
    }
    t_after_gifs = anitime_now_seconds();

    uint64_t container = anitime_ensure_container();
    if (!r_is_objc_ptr(container)) {
        printf("[ANITIME] container alloc failed (after %.3fs)\n",
               anitime_now_seconds() - t_start);
        return false;
    }

    // Determine digit count and digit values.
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = cfg.showSeconds
        ? (cfg.format24h ? @"HHmmss" : @"hmss")  // 'h' is 1-12, no zero pad; we will use hh + am/pm
        : (cfg.format24h ? @"HHmm"   : @"hmm");
    if (!cfg.format24h) {
        // Force 12h with leading zero + am/pm; use 'h' would drop the leading
        // zero, so for digit rendering we use 'hh' for hours and add am/pm
        // digit-marker handling elsewhere.
        fmt.dateFormat = cfg.showSeconds ? @"HHmmss" : @"HHmm";
    }
    NSString *digitsStr = [fmt stringFromDate:[NSDate date]];
    if (digitsStr.length < 4) {
        printf("[ANITIME] date format produced short string '%s'\n", digitsStr.UTF8String);
        return false;
    }

    // For 12h we have to handle the AM/PM offset. Simplest: render 24h in the
    // overlay and convert to 12h by subtracting 12 if > 12. We use a custom
    // formatter that always returns 4/6 zero-padded digits, then post-process.
    int nSlots = (int)digitsStr.length;
    if (nSlots < 4) nSlots = 4;
    if (nSlots > kAniTimeMaxDigits) nSlots = kAniTimeMaxDigits;

    int slotValues[kAniTimeMaxDigits];
    for (int i = 0; i < nSlots; i++) slotValues[i] = 0;
    for (int i = 0; i < nSlots && i < (int)digitsStr.length; i++) {
        unichar c = [digitsStr characterAtIndex:i];
        if (c >= '0' && c <= '9') {
            slotValues[i] = (int)(c - '0');
        }
    }

    if (!cfg.format24h) {
        // Convert first two slots from 24h "HH" to 12h "hh".
        int hh = slotValues[0] * 10 + slotValues[1];
        int hh12 = hh % 12;
        if (hh12 == 0) hh12 = 12;
        slotValues[0] = hh12 / 10;
        slotValues[1] = hh12 % 10;
    }

    // Compute per-slot frames.
    struct { double x, y, w, h; } bounds;
    if (!r_msg2_main_struct_ret(container, "bounds", &bounds, sizeof(bounds), NULL,0, NULL,0, NULL,0)) {
        printf("[ANITIME] failed to read container bounds\n");
        return false;
    }

    double digitH = anitime_frame_for_size(cfg.size);
    double digitW = digitH * 0.6; // assume ~3:5 aspect ratio for digit glyphs
    double totalW = (double)nSlots * digitW + (double)(nSlots - 1) * (double)cfg.spacing;
    double frameW = bounds.w;
    double frameH = bounds.h;

    // Remove any stale digit views that exceed the new slot count.
    for (int i = nSlots; i < kAniTimeMaxDigits; i++) {
        if (r_is_objc_ptr(gAniTimeDigitViews[i])) {
            r_msg2_main_async(gAniTimeDigitViews[i], "removeFromSuperview", 0, 0, 0, 0);
            r_msg2_main(gAniTimeDigitViews[i], "release", 0, 0, 0, 0);
            gAniTimeDigitViews[i] = 0;
        }
    }

    for (int i = 0; i < nSlots; i++) {
        double x = 0.0, y = 0.0;
        anitime_compute_digit_frame(i, nSlots, frameW, frameH, digitW, digitH,
                                    (double)cfg.spacing, &x, &y);
        struct { double x, y, w, h; } fr = { x, y, digitW, digitH };

        uint64_t iv = gAniTimeSlotViews[i];
        if (!r_is_objc_ptr(iv)) {
            uint64_t alloc = r_msg2_main(gAniTimeUIImageViewClass, "alloc", 0, 0, 0, 0);
            if (!r_is_objc_ptr(alloc)) continue;
            iv = r_msg2_main(alloc, "init", 0, 0, 0, 0);
            if (!r_is_objc_ptr(iv)) continue;
            r_msg2_main(container, "addSubview:", iv, 0, 0, 0);
            gAniTimeSlotViews[i] = iv;
        }
        r_msg2_main_raw(iv, "setFrame:", &fr, sizeof(fr), NULL, 0, NULL, 0, NULL, 0, NULL, 0);

        int targetDigit = -1; // -1 means "use the colon dash"
        if (i == 2) {
            targetDigit = -1;
        } else {
            int v = 0;
            anitime_digit_for_slot(i, fmt, now, &v);
            if (v < 0) v = 0;
            if (v > 9) v = 9;
            targetDigit = v;
        }

        // Reuse the per-slot NSArray across ticks. Only rebuild it when the
        // digit value for this slot actually changes (or the slot is fresh).
        // This is the hot path on the per-second loop.
        if (!r_is_objc_ptr(gAniTimeSlotArrays[i]) || gAniTimeSlotArrayDigit[i] != targetDigit) {
            if (r_is_objc_ptr(gAniTimeSlotArrays[i])) {
                r_msg2_main(gAniTimeSlotArrays[i], "release", 0, 0, 0, 0);
                gAniTimeSlotArrays[i] = 0;
            }
            uint64_t NSArrayCls = r_class("NSArray");
            uint64_t srcImage = (targetDigit < 0)
                ? gAniTimeSlotImages[kAniTimeDigitCount]
                : gAniTimeSlotImages[targetDigit];
            if (r_is_objc_ptr(NSArrayCls) && r_is_objc_ptr(srcImage)) {
                uint64_t arr = r_msg2_main(NSArrayCls, "arrayWithObject:", srcImage, 0, 0, 0);
                if (r_is_objc_ptr(arr)) {
                    gAniTimeSlotArrays[i] = r_msg2_main(arr, "retain", 0, 0, 0, 0);
                }
            }
        }
        double dur = 1.0;
        r_msg2_main_raw(iv, "setAnimationDuration:", &dur, sizeof(dur), NULL, 0, NULL, 0, NULL, 0);
        r_msg2_main(iv, "startAnimating", 0, 0, 0, 0);
    }

    gAniTimeCachedConfig = cfg;
    gAniTimeCachedFormat = fmt;
    gAniTimeCachedConfigValid = true;

    double t_end = anitime_now_seconds();
    printf("[ANITIME] apply cold-path took %.3fs total | "
           "classes=%.3fs clock=%.3fs gifs=%.3fs container=%.3fs layout=%.3fs slots=%.3fs\n",
           t_end - t_start,
           t_after_classes - t_start,
           t_after_clock   - t_after_classes,
           t_after_gifs    - t_after_clock,
           t_after_container - t_after_gifs,
           t_after_layout  - t_after_container,
           t_end           - t_after_layout);
    anitime_log_apply(cfg, fmt);
    return true;
}

bool anitime_stop_in_session(void)
{
    double t_start = anitime_now_seconds();
    // Unhide the system clock first so it comes back when the overlay goes
    // away (the cached pointer is still live at this point).
    if (r_is_objc_ptr(gAniTimeClockView)) {
        r_msg2_main(gAniTimeClockView, "setHidden:", 0, 0, 0, 0);
    }
    if (r_is_objc_ptr(gAniTimeContainer)) {
        r_msg2_main(gAniTimeContainer, "removeFromSuperview", 0, 0, 0, 0);
        r_msg2_main(gAniTimeContainer, "release", 0, 0, 0, 0);
        gAniTimeContainer = 0;
    }
    for (int i = 0; i < kAniTimeSlots; i++) {
        if (r_is_objc_ptr(gAniTimeSlotViews[i])) {
            r_msg2_main(gAniTimeSlotViews[i], "stopAnimating", 0, 0, 0, 0);
            r_msg2_main(gAniTimeSlotViews[i], "removeFromSuperview", 0, 0, 0, 0);
            r_msg2_main(gAniTimeSlotViews[i], "release", 0, 0, 0, 0);
            gAniTimeSlotViews[i] = 0;
        }
    }
    gAniTimeCachedConfigValid = false;
    double t_end = anitime_now_seconds();
    printf("[ANITIME] stop took %.3fs total\n", t_end - t_start);
    return true;
}

bool anitime_stop_in_session_fast(void)
{
    anitime_forget_remote_state();
    return true;
}

void anitime_forget_remote_state(void)
{
    // Best-effort: try to unhide the clock. If SB is gone the message is a
    // no-op; either way the cached pointers are wiped below.
    if (r_is_objc_ptr(gAniTimeClockView)) {
        r_msg2_main(gAniTimeClockView, "setHidden:", 0, 0, 0, 0);
    }
    gAniTimeClockView = 0;
    gAniTimeContainer = 0;
    for (int i = 0; i < kAniTimeSlots; i++) {
        gAniTimeSlotViews[i] = 0;
        if (r_is_objc_ptr(gAniTimeSlotArrays[i])) {
            r_msg2_main(gAniTimeSlotArrays[i], "release", 0, 0, 0, 0);
            gAniTimeSlotArrays[i] = 0;
        }
        gAniTimeSlotArrayDigit[i] = -1;
    }
    for (int i = 0; i < kAniTimeDigitCount + 1; i++) {
        if (r_is_objc_ptr(gAniTimeSlotImages[i])) {
            r_msg2_main(gAniTimeSlotImages[i], "release", 0, 0, 0, 0);
            gAniTimeSlotImages[i] = 0;
        }
    }
    gAniTimeLoadedGifs = 0;
    gAniTimeCachedConfigValid = false;
    gAniTimeUIViewClass = 0;
    gAniTimeUIImageViewClass = 0;
    gAniTimeUIImageClass = 0;
    gAniTimeNSDataClass = 0;
    printf("[ANITIME] forgot remote state\n");
}