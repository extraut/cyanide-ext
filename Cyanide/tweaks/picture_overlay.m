//
//  picture_overlay.m
//
//  Picture Overlay tweak — displays images/GIFs on SpringBoard.
//  Each overlay is rendered in its own UIWindow at a level above
//  the icon layer but below Control Center / notification banners.
//

#import "picture_overlay.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <stdio.h>
#import <string.h>
#import <stdint.h>

// ── Window levels (correct values for iOS 18) ────────────────────────────
//   UIWindowLevelNormal          =       0.0   (app content / home-screen icons)
//   UIWindowLevelStatusBar       =    1000.0   (status bar row)
//   UIWindowLevelAlert           =    2000.0   (UIAlertController)
//   Control Center / Cover Sheet =  ~4000–8000 (private SB windows)
//   UIRemoteKeyboardWindow       = 10000001.0  (system keyboard — always on top)
//
// kDefaultWindowLevel (1050) sits above icons/status-bar but below alerts and
// Control Center, which is where a decorative overlay belongs.
#define kDefaultWindowLevel   1050.0f
#define kMinWindowLevel          1.0f
#define kMaxWindowLevel       9999.0f

// Per-overlay window levels (index == overlayId).  0 means "use default".
static CGFloat gPictureOverlayWindowLevels[32];

static CGFloat picture_overlay_clamped_level(int zIndex)
{
    if (zIndex <= 0) return kDefaultWindowLevel;
    CGFloat lvl = (CGFloat)zIndex;
    if (lvl < kMinWindowLevel) lvl = kMinWindowLevel;
    if (lvl > kMaxWindowLevel) lvl = kMaxWindowLevel;
    return lvl;
}

// Tag base for overlay views (used to find/stop overlays later)
static const uint64_t kPictureOverlayTagBase = 0xC0A15000;
static const uint64_t kPictureOverlayTagMask = 0x0000FFFF;

// Cached remote pointers
static uint64_t gPictureOverlayWindows[32] = {0};  // Per-overlay windows
static uint64_t gPictureOverlayScene = 0;

#pragma mark - Helpers

static uint64_t picture_overlay_tag_for_id(uint64_t overlayId)
{
    return kPictureOverlayTagBase | (overlayId & kPictureOverlayTagMask);
}

// FIX #1: Get the SpringBoard scene using connectedScenes (iOS 13+).
// The old approach used keyWindow which is unreliable in SpringBoard context
// and often returns nil, causing result=0 / WARN refresh on every run.
static uint64_t picture_overlay_get_scene(void)
{
    if (gPictureOverlayScene && r_is_objc_ptr(gPictureOverlayScene)) {
        return gPictureOverlayScene;
    }

    uint64_t UIApplication = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApplication)) return 0;

    uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) return 0;

    // Primary path: iterate connectedScenes (iOS 13+, preferred in SpringBoard)
    uint64_t scenes = r_msg2_main(app, "connectedScenes", 0, 0, 0, 0);
    if (r_is_objc_ptr(scenes)) {
        uint64_t enumerator = r_msg2_main(scenes, "objectEnumerator", 0, 0, 0, 0);
        if (r_is_objc_ptr(enumerator)) {
            uint64_t UIWindowScene_cls = r_class("UIWindowScene");
            uint64_t scene = 0;
            while ((scene = r_msg2_main(enumerator, "nextObject", 0, 0, 0, 0)) &&
                   r_is_objc_ptr(scene)) {
                if (r_is_objc_ptr(UIWindowScene_cls)) {
                    uint64_t isKind = r_msg2_main(scene, "isKindOfClass:", UIWindowScene_cls, 0, 0, 0);
                    if (isKind) {
                        gPictureOverlayScene = scene;
                        printf("[PICTURE] got scene via connectedScenes: 0x%llx\n", scene);
                        return scene;
                    }
                } else {
                    // No UIWindowScene class available — take first scene we get
                    gPictureOverlayScene = scene;
                    printf("[PICTURE] got scene (no class check) via connectedScenes: 0x%llx\n", scene);
                    return scene;
                }
            }
        }
    }

    // Fallback 1: keyWindow -> windowScene
    uint64_t keyWin = r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    if (r_is_objc_ptr(keyWin)) {
        uint64_t scene = r_msg2_main(keyWin, "windowScene", 0, 0, 0, 0);
        if (r_is_objc_ptr(scene)) {
            gPictureOverlayScene = scene;
            printf("[PICTURE] got scene via keyWindow fallback: 0x%llx\n", scene);
            return scene;
        }
    }

    // Fallback 2: windows array -> first window -> windowScene
    uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
    if (r_is_objc_ptr(windows)) {
        uint64_t firstWin = r_msg2_main(windows, "firstObject", 0, 0, 0, 0);
        if (r_is_objc_ptr(firstWin)) {
            uint64_t scene = r_msg2_main(firstWin, "windowScene", 0, 0, 0, 0);
            if (r_is_objc_ptr(scene)) {
                gPictureOverlayScene = scene;
                printf("[PICTURE] got scene via windows.firstObject: 0x%llx\n", scene);
                return scene;
            }
        }
    }

    printf("[PICTURE] WARNING: could not get UIWindowScene — overlay will not appear\n");
    return 0;
}

// Create a dedicated overlay window at the requested level
static uint64_t picture_overlay_create_window(uint64_t scene, uint64_t overlayId, CGFloat windowLevel)
{
    uint64_t UIWindow = r_class("UIWindow");
    if (!r_is_objc_ptr(UIWindow)) {
        printf("[PICTURE] UIWindow class not found\n");
        return 0;
    }

    uint64_t winAlloc = r_msg2_main(UIWindow, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(winAlloc)) {
        printf("[PICTURE] UIWindow alloc failed\n");
        return 0;
    }

    uint64_t win = r_msg2_main(winAlloc, "initWithWindowScene:", scene, 0, 0, 0);
    // FIX #2: Do NOT release winAlloc after -init. The init family consumes
    // the alloc retain — calling release here causes an over-release / crash.
    if (!r_is_objc_ptr(win)) {
        printf("[PICTURE] initWithWindowScene: failed\n");
        return 0;
    }

    printf("[PICTURE] created window=0x%llx for id=%llu level=%.1f\n", win, overlayId, windowLevel);
    printf("[PICTURE-DIAG] create_window OK win=0x%llx scene=0x%llx id=%llu level=%.1f\n",
           win, scene, overlayId, windowLevel);

    // Set window level (passed by caller; clamped to 1–9999)
    r_msg2_main(win, "setWindowLevel:", *(uint64_t *)&windowLevel, 0, 0, 0);

    // Set background to clear (CRITICAL: without this the window has default white background)
    uint64_t UIColor = r_class("UIColor");
    if (r_is_objc_ptr(UIColor)) {
        uint64_t clear = r_msg2_main(UIColor, "clearColor", 0, 0, 0, 0);
        if (r_is_objc_ptr(clear)) r_msg2_main(win, "setBackgroundColor:", clear, 0, 0, 0);
    }

    // Make it non-interactive (let touches pass through)
    r_msg2_main(win, "setUserInteractionEnabled:", 0, 0, 0, 0);

    // Set root view controller so window has a view (required for hit testing/layer setup)
    uint64_t UIViewController = r_class("UIViewController");
    if (r_is_objc_ptr(UIViewController)) {
        uint64_t vcAlloc = r_msg2_main(UIViewController, "alloc", 0, 0, 0, 0);
        if (r_is_objc_ptr(vcAlloc)) {
            uint64_t vc = r_msg2_main(vcAlloc, "init", 0, 0, 0, 0);
            // FIX #2 (same pattern): no release on vcAlloc after init
            if (r_is_objc_ptr(vc)) {
                r_msg2_main(win, "setRootViewController:", vc, 0, 0, 0);
                r_msg2_main(vc, "release", 0, 0, 0, 0);
            }
        }
    }

    // Set hidden = NO to show window
    r_msg2_main(win, "setHidden:", 0, 0, 0, 0);

    return win;
}

// Get or create overlay window for a given overlay ID
static uint64_t picture_overlay_get_window(uint64_t overlayId)
{
    if (overlayId >= 32) return 0;

    uint64_t cached = gPictureOverlayWindows[overlayId];
    if (r_is_objc_ptr(cached)) {
        return cached;
    }

    uint64_t scene = picture_overlay_get_scene();
    if (!r_is_objc_ptr(scene)) return 0;

    CGFloat level = gPictureOverlayWindowLevels[overlayId];
    if (level < kMinWindowLevel) level = kDefaultWindowLevel;

    uint64_t win = picture_overlay_create_window(scene, overlayId, level);
    if (r_is_objc_ptr(win)) {
        gPictureOverlayWindows[overlayId] = win;
    }
    return win;
}

#pragma mark - GIF Loading

// Load all frames from a GIF file into an NSArray of UIImages
static uint64_t picture_overlay_load_gif(const char *imagePath)
{
    if (!imagePath || !*imagePath) return 0;

    NSString *path = [NSString stringWithUTF8String:imagePath];
    NSData *data = [NSData dataWithContentsOfFile:path];

    if (!data) return 0;

    // Check if it's a GIF
    if (![[[path pathExtension] lowercaseString] isEqualToString:@"gif"]) {
        // Not a GIF, use regular image loading
        return 0;
    }

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return 0;

    size_t frameCount = CGImageSourceGetCount(source);
    if (frameCount <= 1) {
        CFRelease(source);
        return 0;
    }

    // Create GIF image source for animation
    uint64_t UIImageAnimated = r_class("UIImage");
    if (!r_is_objc_ptr(UIImageAnimated)) {
        CFRelease(source);
        return 0;
    }

    // We'll create an array of images and set animation properties
    uint64_t NSMutableArray_class = r_class("NSMutableArray");
    uint64_t images = r_msg2_main(NSMutableArray_class, "alloc", 0, 0, 0, 0);
    uint64_t imagesArr = r_msg2_main(images, "init", 0, 0, 0, 0);
    // FIX #2 (same pattern): no release on images after init
    if (!r_is_objc_ptr(imagesArr)) {
        CFRelease(source);
        return 0;
    }

    // Add each frame
    for (size_t i = 0; i < frameCount && i < 30; i++) {  // Limit to 30 frames
        CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, i, NULL);
        if (!cgImage) continue;

        uint64_t UIImage_class = r_class("UIImage");
        uint64_t imgAlloc = r_msg2_main(UIImage_class, "alloc", 0, 0, 0, 0);

        // Create UIImage with CGImage
        // We'll use a simpler approach: just load the image and return it
        // For GIFs, we set animationImages on the UIImageView instead

        CGImageRelease(cgImage);
        if (i == 0) {
            // For simplicity, return the first frame for now
            // Full GIF support requires more complex frame extraction
        }
    }

    CFRelease(source);

    // Fall back to loading as regular image if GIF loading failed
    return 0;
}

// Load image and return remote UIImage pointer
static uint64_t picture_overlay_load_image(const char *imagePath)
{
    if (!imagePath || !*imagePath) return 0;

    NSData *imageData = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:imagePath]];

    printf("[PICTURE-DIAG] load_image local data=%p len=%lu for path=%s\n",
           (__bridge void *)imageData, (unsigned long)(imageData ? imageData.length : 0), imagePath);
    if (!imageData || imageData.length == 0) return 0;

    uint64_t NSData_class = r_class("NSData");
    if (!r_is_objc_ptr(NSData_class)) return 0;

    size_t dataLen = imageData.length;
    uint64_t remoteDataPtr = r_dlsym_call(5, "malloc", dataLen, 0, 0, 0, 0, 0, 0, 0);
    if (!remoteDataPtr) return 0;

    remote_write(remoteDataPtr, imageData.bytes, dataLen);

    uint64_t NSDataAlloc = r_msg2_main(NSData_class, "alloc", 0, 0, 0, 0);
    uint64_t remoteData = r_msg2_main(NSDataAlloc, "initWithBytes:length:", remoteDataPtr, dataLen, 0, 0);
    // FIX #2 (same pattern): no release on NSDataAlloc after init

    if (!r_is_objc_ptr(remoteData)) {
        r_dlsym_call(5, "free", remoteDataPtr, 0, 0, 0, 0, 0, 0, 0);
        return 0;
    }

    uint64_t UIImage_class = r_class("UIImage");
    if (!r_is_objc_ptr(UIImage_class)) {
        r_dlsym_call(5, "CFRelease", remoteData, 0, 0, 0, 0, 0, 0, 0);
        return 0;
    }

    uint64_t remoteImage = r_msg2_main(UIImage_class, "imageWithData:", remoteData, 0, 0, 0);
    r_dlsym_call(5, "CFRelease", remoteData, 0, 0, 0, 0, 0, 0, 0);

    return r_is_objc_ptr(remoteImage) ? remoteImage : 0;
}

// Check if image path is a GIF
static BOOL picture_overlay_is_gif(const char *imagePath)
{
    if (!imagePath) return NO;
    NSString *path = [NSString stringWithUTF8String:imagePath];
    NSString *ext = [path pathExtension] ?: @"";
    return [[ext lowercaseString] isEqualToString:@"gif"];
}

#pragma mark - Apply

bool picture_overlay_apply_in_session(uint64_t overlayId, BOOL enabled, const char *imagePath,
                                      int offsetX, int offsetY,
                                      int scalePct, int alphaPct,
                                      int zIndex)
{
    printf("[PICTURE-DIAG] apply id=%llu enabled=%d path=%s off=(%d,%d) scale=%d alpha=%d zIndex=%d\n",
           overlayId, (int)enabled, imagePath ? imagePath : "(null)",
           offsetX, offsetY, scalePct, alphaPct, zIndex);
    if (!enabled) {
        bool r = picture_overlay_stop_in_session(overlayId);
        printf("[PICTURE-DIAG] stop_in_session returned %d for id=%llu\n", r, overlayId);
        return r;
    }

    if (!imagePath || !*imagePath) {
        printf("[PICTURE] no image path for id=%llu\n", overlayId);
        return false;
    }

    // Store and apply window level (1–9999 → UIWindowLevel float)
    CGFloat windowLevel = picture_overlay_clamped_level(zIndex);
    if (overlayId < 32) {
        gPictureOverlayWindowLevels[overlayId] = windowLevel;
    }
    printf("[PICTURE-DIAG] windowLevel=%.1f for id=%llu\n", windowLevel, overlayId);

    // Get or create overlay window
    uint64_t window = picture_overlay_get_window(overlayId);
    printf("[PICTURE-DIAG] get_window returned 0x%llx (scene=0x%llx) for id=%llu\n",
           window, gPictureOverlayScene, overlayId);
    if (!r_is_objc_ptr(window)) {
        printf("[PICTURE] FAIL: could not get overlay window for id=%llu (scene=0x%llx)\n",
               overlayId, gPictureOverlayScene);
        return false;
    }

    // Load image
    uint64_t image = picture_overlay_load_image(imagePath);
    printf("[PICTURE-DIAG] load_image returned 0x%llx for id=%llu path=%s\n",
           image, overlayId, imagePath);
    if (!r_is_objc_ptr(image)) {
        printf("[PICTURE] failed to load image for id=%llu: %s\n", overlayId, imagePath);
        return false;
    }

    // FIX #3: resolve rootViewController.view as the add/search target.
    // UIWindow itself is not a reliable viewWithTag: search root in SpringBoard;
    // always use rootVC.view when available.
    uint64_t rootVC   = r_msg2_main(window, "rootViewController", 0, 0, 0, 0);
    uint64_t rootView = r_is_objc_ptr(rootVC)
                        ? r_msg2_main(rootVC, "view", 0, 0, 0, 0)
                        : 0;
    uint64_t addTarget    = r_is_objc_ptr(rootView) ? rootView : window;
    uint64_t searchTarget = addTarget;

    // Find existing image view
    uint64_t tag = picture_overlay_tag_for_id(overlayId);
    uint64_t existingView = r_msg2_main(searchTarget, "viewWithTag:", tag, 0, 0, 0);

    if (r_is_objc_ptr(existingView)) {
        // Refresh window level in case the user changed it
        r_msg2_main(window, "setWindowLevel:", *(uint64_t *)&windowLevel, 0, 0, 0);

        // Update existing view
        r_msg2_main(existingView, "setImage:", image, 0, 0, 0);
        r_dlsym_call(5, "CFRelease", image, 0, 0, 0, 0, 0, 0, 0);

        // Update frame
        struct { double x, y, w, h; } bounds = {0};
        r_msg2_main_struct_ret(window, "bounds", &bounds, sizeof(bounds),
                               NULL, 0, NULL, 0, NULL, 0, NULL, 0);
        printf("[PICTURE-DIAG] update-existing bounds=(%.0f,%.0f,%.0f,%.0f) for id=%llu\n",
               bounds.x, bounds.y, bounds.w, bounds.h, overlayId);

        CGFloat scaleFactor = (CGFloat)scalePct / 100.0;
        CGFloat scaledW = bounds.w * 0.3 * scaleFactor;  // 30% of screen as base
        CGFloat scaledH = bounds.h * 0.3 * scaleFactor;
        CGFloat posX = bounds.x + (bounds.w - scaledW) / 2.0 + offsetX;
        CGFloat posY = bounds.y + (bounds.h - scaledH) / 2.0 + offsetY;

        struct { double x, y, w, h; } frame = { posX, posY, scaledW, scaledH };
        r_msg2_main_raw(existingView, "setFrame:", &frame, sizeof(frame),
                        NULL, 0, NULL, 0, NULL, 0);

        CGFloat alpha = (CGFloat)alphaPct / 100.0;
        r_msg2_main(existingView, "setAlpha:", *(uint64_t *)&alpha, 0, 0, 0);

        r_msg2_main(existingView, "setHidden:", 0, 0, 0, 0);
        r_msg2_main(window, "setHidden:", 0, 0, 0, 0);

        printf("[PICTURE] updated view id=%llu at (%.0f, %.0f)\n", overlayId, posX, posY);
        return true;
    }

    // Create new UIImageView
    uint64_t UIImageView_class = r_class("UIImageView");
    if (!r_is_objc_ptr(UIImageView_class)) {
        r_dlsym_call(5, "CFRelease", image, 0, 0, 0, 0, 0, 0, 0);
        return false;
    }

    uint64_t ivAlloc = r_msg2_main(UIImageView_class, "alloc", 0, 0, 0, 0);
    uint64_t imageView = r_msg2_main(ivAlloc, "initWithImage:", image, 0, 0, 0);
    r_dlsym_call(5, "CFRelease", image, 0, 0, 0, 0, 0, 0, 0);
    // FIX #2 (same pattern): no release on ivAlloc after init

    if (!r_is_objc_ptr(imageView)) {
        printf("[PICTURE] failed to create UIImageView\n");
        return false;
    }

    // Configure view
    r_msg2_main(imageView, "setTag:", tag, 0, 0, 0);

    CGFloat alpha = (CGFloat)alphaPct / 100.0;
    r_msg2_main(imageView, "setAlpha:", *(uint64_t *)&alpha, 0, 0, 0);

    // Content mode
    uint64_t aspectFit = 6;  // UIViewContentModeScaleAspectFit
    r_msg2_main(imageView, "setContentMode:", aspectFit, 0, 0, 0);

    // Set frame
    struct { double x, y, w, h; } bounds = {0};
    r_msg2_main_struct_ret(window, "bounds", &bounds, sizeof(bounds),
                           NULL, 0, NULL, 0, NULL, 0, NULL, 0);
    printf("[PICTURE-DIAG] create-new bounds=(%.0f,%.0f,%.0f,%.0f) for id=%llu\n",
           bounds.x, bounds.y, bounds.w, bounds.h, overlayId);

    CGFloat scaleFactor = (CGFloat)scalePct / 100.0;
    CGFloat scaledW = bounds.w * 0.3 * scaleFactor;
    CGFloat scaledH = bounds.h * 0.3 * scaleFactor;
    CGFloat posX = bounds.x + (bounds.w - scaledW) / 2.0 + offsetX;
    CGFloat posY = bounds.y + (bounds.h - scaledH) / 2.0 + offsetY;

    struct { double x, y, w, h; } frame = { posX, posY, scaledW, scaledH };
    r_msg2_main_raw(imageView, "setFrame:", &frame, sizeof(frame),
                    NULL, 0, NULL, 0, NULL, 0);

    // FIX #3: add to rootVC.view (or window as fallback) so viewWithTag: works next time
    r_msg2_main(addTarget, "addSubview:", imageView, 0, 0, 0);
    r_msg2_main(window, "setHidden:", 0, 0, 0, 0);

    printf("[PICTURE] created overlay id=%llu tag=0x%llx level=%.0f at (%.0f, %.0f) size (%.0f, %.0f)\n",
           overlayId, tag, windowLevel, posX, posY, scaledW, scaledH);
    printf("[PICTURE-DIAG] apply_in_session OK id=%llu frame=(%.0f,%.0f,%.0f,%.0f)\n",
           overlayId, posX, posY, scaledW, scaledH);

    return true;
}

#pragma mark - Stop

bool picture_overlay_stop_in_session(uint64_t overlayId)
{
    if (overlayId >= 32) return false;

    uint64_t window = gPictureOverlayWindows[overlayId];
    if (!r_is_objc_ptr(window)) {
        // Try to find window
        window = picture_overlay_get_window(overlayId);
        if (!r_is_objc_ptr(window)) return true;  // Already gone
    }

    // FIX #3: search on rootVC.view, mirroring apply logic
    uint64_t rootVC   = r_msg2_main(window, "rootViewController", 0, 0, 0, 0);
    uint64_t rootView = r_is_objc_ptr(rootVC)
                        ? r_msg2_main(rootVC, "view", 0, 0, 0, 0)
                        : 0;
    uint64_t searchTarget = r_is_objc_ptr(rootView) ? rootView : window;

    uint64_t tag = picture_overlay_tag_for_id(overlayId);
    uint64_t view = r_msg2_main(searchTarget, "viewWithTag:", tag, 0, 0, 0);

    if (r_is_objc_ptr(view)) {
        r_msg2_main(view, "removeFromSuperview", 0, 0, 0, 0);
        // FIX #4: do NOT call release after removeFromSuperview.
        // removeFromSuperview already releases the superview's retain;
        // an extra release here causes an over-release / crash.
        printf("[PICTURE] removed overlay id=%llu\n", overlayId);
    }

    // Hide the window
    r_msg2_main(window, "setHidden:", 1, 0, 0, 0);

    // Clear cache
    gPictureOverlayWindows[overlayId] = 0;

    return true;
}

#pragma mark - Apply/Remove All

bool picture_overlay_apply_all_in_session(void)
{
    return true;  // Handled by SettingsViewController
}

bool picture_overlay_stop_all_in_session(void)
{
    for (int i = 0; i < 32; i++) {
        if (r_is_objc_ptr(gPictureOverlayWindows[i])) {
            picture_overlay_stop_in_session(i);
        }
    }
    return true;
}

bool picture_overlay_remove_all_in_session(void)
{
    return picture_overlay_stop_all_in_session();
}

#pragma mark - Forget State

void picture_overlay_forget_remote_state(void)
{
    printf("[PICTURE] forgetting remote state\n");
    gPictureOverlayScene = 0;
    for (int i = 0; i < 32; i++) {
        gPictureOverlayWindows[i] = 0;
        gPictureOverlayWindowLevels[i] = 0;   // will re-apply from zIndex on next call
    }
}
