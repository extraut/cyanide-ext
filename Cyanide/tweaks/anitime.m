//
//  anitime.m
//  Lock-screen clock digit replacement via bundled animated GIFs.
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

static const int   kAniTimeMaxDigits     = 6;     // 4 base + optional AM/PM dot; 6 covers HHMMSS
static const int   kAniTimeMaxFrames     = 8;     // safety bound for animation frames per digit GIF
static const double kAniTimeMaxFrameBytes = 256 * 1024; // per-frame upper bound (8 frames * 256 KB = 2 MB ceiling per digit)
static const uint64_t kAniTimeContainerTag = 0x414E4954ULL; // "ANIT"
static const uint64_t kAniTimeDigitTagBase = 0x414E4954ULL; // per-slot: base + slot

#pragma mark - Cached remote state

static uint64_t gAniTimeClockView   = 0;
static uint64_t gAniTimeContainer   = 0;
static uint64_t gAniTimeDigitViews[kAniTimeMaxDigits] = { 0, 0, 0, 0, 0, 0 };
static uint64_t gAniTimeDigitImages[10] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
static uint64_t gAniTimeUIViewClass         = 0;
static uint64_t gAniTimeUIImageViewClass    = 0;
static uint64_t gAniTimeUIImageClass        = 0;
static uint64_t gAniTimeNSDataClass         = 0;
static uint64_t gAniTimeSetAnimationSel     = 0;
static uint64_t gAniTimeSetDurationSel      = 0;
static uint64_t gAniTimeAddSubviewSel       = 0;
static int      gAniTimeLoadedGifs          = 0;
static bool     gAniTimeCachedConfigValid   = false;
static AniTimeConfig gAniTimeCachedConfig   = { AniTimeSizeNormal, 4, false, false };

#pragma mark - Defaults accessor (host-side)

AniTimeConfig anitime_config_from_defaults(void)
{
    AniTimeConfig cfg;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSInteger size = [d integerForKey:@"AniTimeSize"];
    if (size < 0 || size > 2) size = AniTimeSizeNormal;
    cfg.size        = (AniTimeSize)size;
    NSInteger sp    = [d integerForKey:@"AniTimeSpacing"];
    if (sp < 0) sp = 0;
    if (sp > 16) sp = 16;
    cfg.spacing     = (int)sp;
    cfg.format24h   = [d boolForKey:@"AniTimeFormat24h"];
    cfg.showSeconds = [d boolForKey:@"AniTimeShowSeconds"];
    return cfg;
}

static bool anitime_config_equal(AniTimeConfig a, AniTimeConfig b)
{
    return a.size == b.size && a.spacing == b.spacing &&
           a.format24h == b.format24h && a.showSeconds == b.showSeconds;
}

#pragma mark - Helpers

static void anitime_log_apply(AniTimeConfig cfg)
{
    static const char *names[] = { "Small", "Compact", "Normal" };
    int idx = (int)cfg.size;
    if (idx < 0) idx = 0;
    if (idx > 2) idx = 2;
    printf("[ANITIME] apply size=%s spacing=%dpt format=%s seconds=%s\n",
           names[idx], cfg.spacing, cfg.format24h ? "24h" : "12h",
           cfg.showSeconds ? "ON" : "OFF");
}

static double anitime_frame_for_size(AniTimeSize size)
{
    switch (size) {
        case AniTimeSizeSmall:   return 28.0;
        case AniTimeSizeCompact: return 40.0;
        case AniTimeSizeNormal:  return 56.0;
    }
    return 56.0;
}

#pragma mark - Lazy selector / class resolution

static void anitime_resolve_selectors(void)
{
    if (!gAniTimeSetAnimationSel)   gAniTimeSetAnimationSel   = r_sel("setAnimationImages:");
    if (!gAniTimeSetDurationSel)    gAniTimeSetDurationSel    = r_sel("setAnimationDuration:");
    if (!gAniTimeAddSubviewSel)     gAniTimeAddSubviewSel     = r_sel("addSubview:");
}

static void anitime_resolve_classes(void)
{
    if (!gAniTimeUIViewClass)      gAniTimeUIViewClass      = r_class("UIView");
    if (!gAniTimeUIImageViewClass) gAniTimeUIImageViewClass = r_class("UIImageView");
    if (!gAniTimeUIImageClass)     gAniTimeUIImageClass     = r_class("UIImage");
    if (!gAniTimeNSDataClass)      gAniTimeNSDataClass      = r_class("NSData");
}

#pragma mark - Lock-screen clock view discovery

// Returns the SBCoverSheetWindow if found, else 0. Walks the application's
// windows.
static uint64_t anitime_find_cover_sheet_window(void)
{
    uint64_t UIApp = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApp)) return 0;
    uint64_t app = r_msg2_main(UIApp, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) return 0;
    uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
    if (!r_is_objc_ptr(windows)) {
        // Fallback to keyWindow
        return r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    }
    uint64_t count = r_msg2_main(windows, "count", 0, 0, 0, 0);
    if (count == 0 || count > 32) {
        return r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    }

    // Preferred: SBCoverSheetWindow class. Fallback: SBHomeScreenWindow.
    uint64_t csClass = r_class("SBCoverSheetWindow");
    uint64_t homeClass = r_class("SBHomeScreenWindow");

    for (uint64_t i = 0; i < count; i++) {
        uint64_t w = r_msg2_main(windows, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(w)) continue;
        if (r_is_objc_ptr(csClass) &&
            (r_msg2(w, "isKindOfClass:", csClass, 0, 0, 0) & 0xff)) {
            return w;
        }
    }
    // Fallback: return cover-sheet-ish window via SBHomeScreenWindow.
    for (uint64_t i = 0; i < count; i++) {
        uint64_t w = r_msg2_main(windows, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(w)) continue;
        if (r_is_objc_ptr(homeClass) &&
            (r_msg2(w, "isKindOfClass:", homeClass, 0, 0, 0) & 0xff)) {
            return w;
        }
    }
    return r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
}
    return r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
}

// Recursive subview walk, looking for the lock-screen clock view. Picks the
// first view that is a kind of any of these classes (priority order):
//   CSLockScreenClockView (iOS 18+), _UILockScreenClockView (iOS 16/17),
//   SBUIMainClockView (older).
// Bounded by depth 12 and 4096 visited nodes.
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

// Read a bundled GIF named `0`..`9` (e.g. "0.gif") into a remote UIImage
// pointer. The returned pointer is autoreleased in target — caller retains
// it via gAniTimeDigitImages[d] = r_dlsym_call(... "retain" ...).
// Returns 0 on failure.
static uint64_t anitime_load_gif_as_remote_uiimage(int digit)
{
    if (digit < 0 || digit > 9) return 0;
    if (!gAniTimeUIImageClass || !gAniTimeNSDataClass) return 0;

    NSString *name = [NSString stringWithFormat:@"%d", digit];
    NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"gif"];
    if (!path) {
        printf("[ANITIME] bundled GIF missing for digit %d\n", digit);
        return 0;
    }
    NSData *bytes = [NSData dataWithContentsOfFile:path];
    if (!bytes || bytes.length == 0) {
        printf("[ANITIME] GIF empty for digit %d at %s\n", digit, path.UTF8String);
        return 0;
    }
    if ((double)bytes.length > kAniTimeMaxFrameBytes * (double)kAniTimeMaxFrames) {
        printf("[ANITIME] GIF too large for digit %d (%lu bytes)\n", digit, (unsigned long)bytes.length);
        return 0;
    }

    // 1. malloc a remote scratch buffer for the raw bytes.
    uint64_t scratch = r_dlsym_call(R_TIMEOUT, "malloc", (uint64_t)bytes.length, 0,0,0,0,0,0,0);
    if (!scratch) return 0;
    remote_write(scratch, bytes.bytes, bytes.length);

    // 2. Wrap the scratch into a remote NSData (initWithBytes:length:).
    uint64_t alloc = r_msg2_main(gAniTimeNSDataClass, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(alloc)) {
        r_dlsym_call(R_TIMEOUT, "free", scratch, 0,0,0,0,0,0,0);
        return 0;
    }
    uint64_t nsData = r_msg2_main(alloc, "initWithBytes:length:", scratch, (uint64_t)bytes.length, 0, 0);
    if (!r_is_objc_ptr(nsData)) {
        r_dlsym_call(R_TIMEOUT, "free", scratch, 0,0,0,0,0,0,0);
        return 0;
    }

    // 3. UIImage imageWithData: → autoreleased UIImage.
    uint64_t image = r_msg2_main(gAniTimeUIImageClass, "imageWithData:", nsData, 0, 0, 0);

    // 4. Release the wrapping NSData and the scratch buffer.
    r_msg2_main(nsData, "release", 0, 0, 0, 0);
    r_dlsym_call(R_TIMEOUT, "free", scratch, 0, 0, 0, 0, 0, 0, 0);

    return r_is_objc_ptr(image) ? image : 0;
}

static void anitime_release_remote_image(uint64_t image)
{
    if (!r_is_objc_ptr(image)) return;
    r_msg2_main(image, "release", 0, 0, 0, 0);
}

#pragma mark - Digit image management

static void anitime_load_all_digit_images(void)
{
    if (gAniTimeLoadedGifs) return;
    anitime_resolve_classes();
    if (!gAniTimeUIImageClass || !gAniTimeNSDataClass) return;

    for (int d = 0; d < 10; d++) {
        uint64_t img = anitime_load_gif_as_remote_uiimage(d);
        if (r_is_objc_ptr(img)) {
            gAniTimeDigitImages[d] = r_msg2_main(img, "retain", 0, 0, 0, 0);
        } else {
            gAniTimeDigitImages[d] = 0;
        }
    }
    gAniTimeLoadedGifs = 1;
}

#pragma mark - Container management

// Make sure gAniTimeContainer exists as a UIView with the same frame as
// gAniTimeClockView. If a previously-installed container is still attached
// (and the cached clock view is the same), reuse it. Otherwise remove and
// recreate.
static uint64_t anitime_ensure_container(AniTimeConfig cfg)
{
    if (!r_is_objc_ptr(gAniTimeClockView)) return 0;
    if (!r_is_objc_ptr(gAniTimeUIViewClass)) return 0;

    // If we already have a container, check whether it is still in the view
    // hierarchy. If so, reuse it (the digit set will be updated in place).
    if (r_is_objc_ptr(gAniTimeContainer)) {
        uint64_t super = r_msg2_main(gAniTimeContainer, "superview", 0, 0, 0, 0);
        if (r_is_objc_ptr(super)) {
            return gAniTimeContainer;
        }
        // Container was orphaned (e.g. SB respawn). Drop and recreate.
        r_msg2_main(gAniTimeContainer, "removeFromSuperview", 0, 0, 0, 0);
        r_msg2_main(gAniTimeContainer, "release", 0, 0, 0, 0);
        gAniTimeContainer = 0;
    }

    // Alloc/init a new UIView.
    uint64_t alloc = r_msg2_main(gAniTimeUIViewClass, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(alloc)) return 0;
    uint64_t container = r_msg2_main(alloc, "init", 0, 0, 0, 0);
    if (!r_is_objc_ptr(container)) return 0;

    // Match the clock view's frame.
    struct { double x, y, w, h; } rect;
    if (r_msg2_main_struct_ret(gAniTimeClockView, "bounds", &rect, sizeof(rect), NULL, 0, NULL, 0, NULL, 0, NULL, 0)) {
        r_msg2_main_raw(container, "setFrame:",
                        &rect, sizeof(rect),
                        NULL, 0, NULL, 0, NULL, 0, NULL, 0);
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
    r_msg2_main(container, "setTag:", kAniTimeContainerTag, 0, 0, 0);

    r_msg2_main(gAniTimeClockView, "addSubview:", container, 0, 0, 0);
    gAniTimeContainer = container;
    return container;
}

static void anitime_remove_container(void)
{
    if (r_is_objc_ptr(gAniTimeContainer)) {
        r_msg2_main_async(gAniTimeContainer, "removeFromSuperview", 0, 0, 0, 0);
        r_msg2_main(gAniTimeContainer, "release", 0, 0, 0, 0);
        gAniTimeContainer = 0;
    }
    for (int i = 0; i < kAniTimeMaxDigits; i++) {
        gAniTimeDigitViews[i] = 0;
    }
}

#pragma mark - Digit layout

// Compute the absolute frame for a given digit slot within the container,
// given the total width of all digits + spacing.
static void anitime_compute_digit_frame(int slot, int totalSlots, double frameW, double frameH,
                                        double digitW, double digitH, double spacing,
                                        double *outX, double *outY)
{
    double total = (double)totalSlots * digitW + (double)(totalSlots - 1) * spacing;
    if (total < 0) total = 0;
    double startX = (frameW - total) / 2.0;
    if (startX < 0) startX = 0;
    *outX = startX + (double)slot * (digitW + spacing);
    *outY = (frameH - digitH) / 2.0;
    if (*outY < 0) *outY = 0;
}

#pragma mark - Apply / stop

bool anitime_apply_in_session(AniTimeConfig cfg)
{
    anitime_resolve_selectors();
    anitime_resolve_classes();

    if (!r_is_objc_ptr(gAniTimeUIViewClass) ||
        !r_is_objc_ptr(gAniTimeUIImageClass) ||
        !r_is_objc_ptr(gAniTimeNSDataClass)) {
        printf("[ANITIME] required classes missing\n");
        return false;
    }

    if (gAniTimeCachedConfigValid && anitime_config_equal(cfg, gAniTimeCachedConfig) &&
        r_is_objc_ptr(gAniTimeContainer) && r_is_objc_ptr(gAniTimeClockView)) {
        // Nothing structural changed — the next per-second tick will refresh
        // the digit selection. Bail cheaply.
        return true;
    }

    anitime_load_all_digit_images();
    for (int d = 0; d < 10; d++) {
        if (!r_is_objc_ptr(gAniTimeDigitImages[d])) {
            printf("[ANITIME] digit %d image unavailable; bailing\n", d);
            return false;
        }
    }

    // Locate the cover sheet / lock screen window.
    uint64_t win = anitime_find_cover_sheet_window();
    if (!r_is_objc_ptr(win)) {
        printf("[ANITIME] cover sheet window not found\n");
        return false;
    }

    // rootViewController → view.
    uint64_t rvc = r_msg2_main(win, "rootViewController", 0, 0, 0, 0);
    uint64_t rootView = r_is_objc_ptr(rvc) ? r_msg2_main(rvc, "view", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(rootView)) {
        // Cover sheet may render directly to its window's view; try the window's own view.
        rootView = r_msg2_main(win, "view", 0, 0, 0, 0);
    }
    if (!r_is_objc_ptr(rootView)) {
        printf("[ANITIME] rootView missing\n");
        return false;
    }

    // Walk for the lock-screen clock view.
    uint64_t clockView = anitime_find_clock_view(rootView);
    if (!r_is_objc_ptr(clockView)) {
        // Fallback: if the window itself is the clock view, use it.
        if (r_responds_main(win, "frame") && r_responds_main(win, "bounds")) {
            clockView = win;
        } else {
            printf("[ANITIME] clock view not found in cover sheet\n");
            return false;
        }
    }
    gAniTimeClockView = clockView;

    // Build / reuse container.
    uint64_t container = anitime_ensure_container(cfg);
    if (!r_is_objc_ptr(container)) {
        printf("[ANITIME] container alloc failed\n");
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
    if (!r_msg2_main_struct_ret(container, "bounds", &bounds, sizeof(bounds), NULL, 0, NULL, 0, NULL, 0, NULL, 0)) {
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

        uint64_t iv = gAniTimeDigitViews[i];
        if (!r_is_objc_ptr(iv)) {
            uint64_t alloc = r_msg2_main(gAniTimeUIImageViewClass, "alloc", 0, 0, 0, 0);
            if (!r_is_objc_ptr(alloc)) continue;
            iv = r_msg2_main(alloc, "init", 0, 0, 0, 0);
            if (!r_is_objc_ptr(iv)) continue;
            r_msg2_main(iv, "setTag:", kAniTimeDigitTagBase + (uint64_t)i, 0, 0, 0);
            r_msg2_main(container, "addSubview:", iv, 0, 0, 0);
            gAniTimeDigitViews[i] = iv;
        }
        r_msg2_main_raw(iv, "setFrame:", &fr, sizeof(fr), NULL, 0, NULL, 0, NULL, 0, NULL, 0);

        // Wrap the digit UIImage in a single-element NSArray for animationImages.
        uint64_t NSArrayCls = r_class("NSArray");
        if (r_is_objc_ptr(NSArrayCls)) {
            uint64_t arr = r_msg2_main(NSArrayCls, "arrayWithObject:", gAniTimeDigitImages[slotValues[i]], 0, 0, 0);
            if (r_is_objc_ptr(arr)) {
                r_msg2_main(iv, "setAnimationImages:", arr, 0, 0, 0);
            }
        }
        double dur = 1.0;
        r_msg2_main_raw(iv, "setAnimationDuration:", &dur, sizeof(dur), NULL, 0, NULL, 0, NULL, 0, NULL, 0);
        r_msg2_main(iv, "startAnimating", 0, 0, 0, 0);
    }

    gAniTimeCachedConfig = cfg;
    gAniTimeCachedConfigValid = true;
    anitime_log_apply(cfg);
    return true;
}

bool anitime_stop_in_session(void)
{
    if (r_is_objc_ptr(gAniTimeContainer)) {
        r_msg2_main_async(gAniTimeContainer, "removeFromSuperview", 0, 0, 0, 0);
        r_msg2_main(gAniTimeContainer, "release", 0, 0, 0, 0);
        gAniTimeContainer = 0;
    }
    for (int i = 0; i < kAniTimeMaxDigits; i++) {
        if (r_is_objc_ptr(gAniTimeDigitViews[i])) {
            r_msg2_main(gAniTimeDigitViews[i], "stopAnimating", 0, 0, 0, 0);
            r_msg2_main_async(gAniTimeDigitViews[i], "removeFromSuperview", 0, 0, 0, 0);
            r_msg2_main(gAniTimeDigitViews[i], "release", 0, 0, 0, 0);
            gAniTimeDigitViews[i] = 0;
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
    for (int i = 0; i < kAniTimeMaxDigits; i++) gAniTimeDigitViews[i] = 0;
    for (int d = 0; d < 10; d++) {
        if (r_is_objc_ptr(gAniTimeDigitImages[d])) {
            anitime_release_remote_image(gAniTimeDigitImages[d]);
            gAniTimeDigitImages[d] = 0;
        }
    }
    gAniTimeLoadedGifs = 0;
    gAniTimeCachedConfigValid = false;
    gAniTimeUIViewClass = 0;
    gAniTimeUIImageViewClass = 0;
    gAniTimeUIImageClass = 0;
    gAniTimeNSDataClass = 0;
    gAniTimeSetAnimationSel = 0;
    gAniTimeSetDurationSel = 0;
    gAniTimeAddSubviewSel = 0;
    printf("[ANITIME] forgot remote state\n");
}
