//
//  anitime.m
//  AniTime: replace the iOS lock-screen clock digits with bundled animated GIFs.
//  Author: extra
//
//  5-slot layout HH:MM (digits 0..9 + a single colon/dash). On the lock screen
//  the overlay is attached as a sibling of the system clock view, so it moves
//  with the lock screen as the user drags the sheet.
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
static AniTimeConfig gAniTimeCachedConfig = { AniTimeSizeCompact, 4 };
static AniTimeFormat gAniTimeCachedFormat = AniTimeFormat12h;

#pragma mark - Defaults accessor (host-side)

AniTimeConfig anitime_config_from_defaults(void)
{
    AniTimeConfig cfg;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSInteger size = [d integerForKey:@"AniTimeSize"];
    if (size != 0 && size != 1) size = 1; // default = on (compact)
    cfg.size = (AniTimeSize)size;
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
    return a.size == b.size && a.spacing == b.spacing;
}

#pragma mark - Helpers

static void anitime_log_apply(AniTimeConfig cfg, AniTimeFormat fmt)
{
    static const char *sizeNames[] = { "Off", "Compact" };
    static const char *fmtNames[]  = { "12h", "24h" };
    int sIdx = (int)cfg.size;
    if (sIdx < 0) sIdx = 0;
    if (sIdx > 1) sIdx = 1;
    int fIdx = (int)fmt;
    if (fIdx < 0) fIdx = 0;
    if (fIdx > 1) fIdx = 1;
    printf("[ANITIME] apply size=%s spacing=%dpt format=%s\n",
           sizeNames[sIdx], cfg.spacing, fmtNames[fIdx]);
}

static double anitime_frame_for_size(AniTimeSize size)
{
    return (size == AniTimeSizeOff) ? 0.0 : 96.0;
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

// Returns the SBCoverSheetWindow if found, else 0.
static uint64_t anitime_find_cover_sheet_window(void)
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
    if (count == 0 || count > 32) {
        return r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    }
    uint64_t csClass = r_class("SBCoverSheetWindow");
    for (uint64_t i = 0; i < count; i++) {
        uint64_t w = r_msg2_main(windows, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(w)) continue;
        if (r_is_objc_ptr(csClass) &&
            (r_msg2(w, "isKindOfClass:", csClass, 0, 0, 0) & 0xff)) {
            return w;
        }
    }
    return r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
}

// Recursive subview walk for the lock-screen clock view.
static uint64_t anitime_walk_for_clock_view(uint64_t view, int depth, int *visited)
{
    if (depth > 12) return 0;
    if (!r_is_objc_ptr(view)) return 0;
    if (*visited > 4096) return 0;
    (*visited)++;

    static const char *kCandidates[] = {
        "CSLockScreenClockView",
        "_UILockScreenClockView",
        "SBUIMainClockView",
        "SBUIClockView",
        "SBUIAnalogClockView",
        "CSLockScreenView",
    };
    for (size_t i = 0; i < sizeof(kCandidates)/sizeof(kCandidates[0]); i++) {
        uint64_t cls = r_class(kCandidates[i]);
        if (!r_is_objc_ptr(cls)) continue;
        if ((r_msg2(view, "isKindOfClass:", cls, 0, 0, 0) & 0xff)) {
            return view;
        }
    }

    uint64_t subs = r_msg2_main(view, "subviews", 0, 0, 0, 0);
    if (!r_is_objc_ptr(subs)) return 0;
    uint64_t cnt = r_msg2_main(subs, "count", 0, 0, 0, 0);
    if (cnt == 0 || cnt > 256) return 0;
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

    // Match the clock view's bounds.
    struct { double x, y, w, h; } rect;
    if (r_msg2_main_struct_ret(gAniTimeClockView, "bounds", &rect, sizeof(rect), NULL,0, NULL,0, NULL,0, NULL,0)) {
        r_msg2_main_raw(container, "setFrame:",
                        &rect, sizeof(rect),
                        NULL, 0, NULL, 0, NULL, 0);
    }

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
    r_msg2_main(gAniTimeClockView, "addSubview:", container, 0, 0, 0);
    gAniTimeContainer = container;
    return container;
}

#pragma mark - Layout

// 5 slots: H H : M M  (slot 2 is the colon dash).
// Colon width is half the digit width.
static void anitime_layout_slots(double containerW, double containerH, AniTimeSize size, int spacing,
                                  double *digitW, double *digitH,
                                  double slotX[5], double slotY[5],
                                  double slotW[5], double slotH[5])
{
    double dh = anitime_frame_for_size(size);
    if (size == AniTimeSizeOff || dh <= 0.0) {
        // Off: hide slots by giving them zero size.
        for (int i = 0; i < kAniTimeSlots; i++) {
            slotX[i] = slotY[i] = slotW[i] = slotH[i] = 0.0;
        }
        *digitW = 0; *digitH = 0;
        return;
    }
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

bool anitime_apply_in_session(AniTimeConfig cfg, AniTimeFormat fmt)
{
    anitime_resolve_classes();

    if (!r_is_objc_ptr(gAniTimeUIViewClass) ||
        !r_is_objc_ptr(gAniTimeUIImageClass) ||
        !r_is_objc_ptr(gAniTimeNSDataClass)) {
        printf("[ANITIME] required classes missing\n");
        return false;
    }

    if (gAniTimeCachedConfigValid && anitime_config_equal(cfg, gAniTimeCachedConfig) &&
        fmt == gAniTimeCachedFormat &&
        r_is_objc_ptr(gAniTimeContainer) && r_is_objc_ptr(gAniTimeClockView)) {
        return true;
    }

    if (cfg.size == AniTimeSizeOff) {
        // Off: just remove the overlay (don't even load GIFs).
        anitime_stop_in_session();
        gAniTimeCachedConfig = cfg;
        gAniTimeCachedFormat = fmt;
        gAniTimeCachedConfigValid = true;
        return true;
    }

    anitime_load_all_slot_images();
    for (int d = 0; d < kAniTimeDigitCount; d++) {
        if (!r_is_objc_ptr(gAniTimeSlotImages[d])) {
            printf("[ANITIME] digit %d image unavailable; bailing\n", d);
            return false;
        }
    }
    if (!r_is_objc_ptr(gAniTimeSlotImages[kAniTimeDigitCount])) {
        printf("[ANITIME] colon image unavailable; bailing\n");
        return false;
    }

    uint64_t win = anitime_find_cover_sheet_window();
    if (!r_is_objc_ptr(win)) {
        printf("[ANITIME] cover sheet window not found\n");
        return false;
    }
    uint64_t rvc = r_msg2_main(win, "rootViewController", 0, 0, 0, 0);
    uint64_t rootView = r_is_objc_ptr(rvc) ? r_msg2_main(rvc, "view", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(rootView)) {
        rootView = r_msg2_main(win, "view", 0, 0, 0, 0);
    }
    if (!r_is_objc_ptr(rootView)) {
        printf("[ANITIME] rootView missing\n");
        return false;
    }
    uint64_t clockView = anitime_find_clock_view(rootView);
    if (!r_is_objc_ptr(clockView)) {
        clockView = win;
    }
    gAniTimeClockView = clockView;

    uint64_t container = anitime_ensure_container();
    if (!r_is_objc_ptr(container)) {
        printf("[ANITIME] container alloc failed\n");
        return false;
    }

    struct { double x, y, w, h; } bounds;
    if (!r_msg2_main_struct_ret(container, "bounds", &bounds, sizeof(bounds), NULL,0, NULL,0, NULL,0, NULL,0)) {
        printf("[ANITIME] failed to read container bounds\n");
        return false;
    }

    double slotX[5], slotY[5], slotW[5], slotH[5];
    double digitW = 0, digitH = 0;
    anitime_layout_slots(bounds.w, bounds.h, cfg.size, cfg.spacing,
                         &digitW, &digitH, slotX, slotY, slotW, slotH);

    NSDate *now = [NSDate date];

    for (int i = 0; i < kAniTimeSlots; i++) {
        struct { double x, y, w, h; } fr = { slotX[i], slotY[i], slotW[i], slotH[i] };

        uint64_t iv = gAniTimeSlotViews[i];
        if (!r_is_objc_ptr(iv)) {
            uint64_t alloc = r_msg2_main(gAniTimeUIImageViewClass, "alloc", 0, 0, 0, 0);
            if (!r_is_objc_ptr(alloc)) continue;
            iv = r_msg2_main(alloc, "init", 0, 0, 0, 0);
            if (!r_is_objc_ptr(iv)) continue;
            r_msg2_main(container, "addSubview:", iv, 0, 0, 0);
            gAniTimeSlotViews[i] = iv;
        }
        r_msg2_main_raw(iv, "setFrame:", &fr, sizeof(fr), NULL, 0, NULL, 0, NULL, 0);

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
            gAniTimeSlotArrayDigit[i] = targetDigit;
            if (r_is_objc_ptr(gAniTimeSlotArrays[i])) {
                r_msg2_main(iv, "setAnimationImages:", gAniTimeSlotArrays[i], 0, 0, 0);
                double dur = 1.0;
                r_msg2_main_raw(iv, "setAnimationDuration:", &dur, sizeof(dur), NULL, 0, NULL, 0, NULL, 0);
                r_msg2_main(iv, "startAnimating", 0, 0, 0, 0);
            }
        }
    }

    gAniTimeCachedConfig = cfg;
    gAniTimeCachedFormat = fmt;
    gAniTimeCachedConfigValid = true;
    anitime_log_apply(cfg, fmt);
    return true;
}

bool anitime_stop_in_session(void)
{
    if (r_is_objc_ptr(gAniTimeContainer)) {
        r_msg2_main_async(gAniTimeContainer, "removeFromSuperview", 0, 0, 0, 0);
        r_msg2_main(gAniTimeContainer, "release", 0, 0, 0, 0);
        gAniTimeContainer = 0;
    }
    for (int i = 0; i < kAniTimeSlots; i++) {
        if (r_is_objc_ptr(gAniTimeSlotViews[i])) {
            r_msg2_main(gAniTimeSlotViews[i], "stopAnimating", 0, 0, 0, 0);
            r_msg2_main_async(gAniTimeSlotViews[i], "removeFromSuperview", 0, 0, 0, 0);
            r_msg2_main(gAniTimeSlotViews[i], "release", 0, 0, 0, 0);
            gAniTimeSlotViews[i] = 0;
        }
    }
    gAniTimeCachedConfigValid = false;
    printf("[ANITIME] overlay: stopped\n");
    return true;
}

bool anitime_stop_in_session_fast(void)
{
    anitime_forget_remote_state();
    return true;
}

void anitime_forget_remote_state(void)
{
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