//
//  picture_overlay.m
//
//  Picture Overlay tweak — displays an image/GIF on SpringBoard.
//  Only visible on home screen and lock screen.
//

#import "picture_overlay.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>

// Tag for idempotent reapply — view retrieval by tag
static const uint64_t kPictureOverlayTag = 0xC0A15000;

// Cached remote pointers — reset on SpringBoard restart
static uint64_t gPictureOverlayWindow = 0;
static uint64_t gPictureOverlayImageView = 0;
static uint64_t gPictureOverlayLastImagePath = 0;

#pragma mark - Helpers

// Find home screen window (SBIconController view)
static uint64_t picture_overlay_find_home_screen_window(void)
{
    uint64_t UIApplication = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApplication)) return 0;

    uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) return 0;

    // Find SBIconController - the main home screen controller
    uint64_t SBIconController = r_class("SBIconController");
    if (!r_is_objc_ptr(SBIconController)) {
        printf("[PICTURE] SBIconController not found\n");
        return 0;
    }

    uint64_t sharedIconController = r_msg2_main(SBIconController, "sharedInstance", 0, 0, 0, 0);
    if (!r_is_objc_ptr(sharedIconController)) {
        printf("[PICTURE] sharedInstance failed\n");
        return 0;
    }

    // Get the view
    uint64_t iconView = r_msg2_main(sharedIconController, "view", 0, 0, 0, 0);
    if (!r_is_objc_ptr(iconView)) {
        printf("[PICTURE] SBIconController view not found\n");
        return 0;
    }

    // Get the window containing this view
    uint64_t window = r_msg2_main(iconView, "window", 0, 0, 0, 0);
    if (r_is_objc_ptr(window)) {
        printf("[PICTURE] found home screen window=0x%llx\n", window);
        return window;
    }

    // Fallback: find windows and check for SB windows
    uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
    if (!r_is_objc_ptr(windows)) return 0;

    uint64_t count = r_msg2_main(windows, "count", 0, 0, 0, 0);
    for (uint64_t i = 0; i < count && i < 32; i++) {
        uint64_t win = r_msg2_main(windows, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(win)) continue;

        // Get window's root view controller
        uint64_t rootVC = r_msg2_main(win, "rootViewController", 0, 0, 0, 0);
        if (r_is_objc_ptr(rootVC)) {
            // Check if it's SBIconController
            uint64_t className = r_dlsym_call(R_TIMEOUT, "object_getClassName", rootVC, 0, 0, 0, 0, 0, 0, 0);
            if (className) {
                char name[64] = {0};
                r_read_nsstring(className, name, sizeof(name) - 1);
                r_dlsym_call(R_TIMEOUT, "free", className, 0, 0, 0, 0, 0, 0, 0);
                printf("[PICTURE] window%llu rootVC class: %s\n", i, name);
            }

            // Check if this window is visible and on home screen
            uint64_t isKey = r_msg2_main(win, "isKeyWindow", 0, 0, 0, 0);
            if (isKey) {
                // Check if this is a SB window (not app window)
                uint64_t scene = r_msg2_main(win, "windowScene", 0, 0, 0, 0);
                if (r_is_objc_ptr(scene)) {
                    // This looks like a SB window
                    printf("[PICTURE] found SB window=0x%llx (key window)\n", win);
                    return win;
                }
            }
        }
    }

    printf("[PICTURE] no home screen window found, using keyWindow\n");
    return r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
}

// Check if we're on home screen by verifying SBIconController is visible
static BOOL picture_overlay_is_on_home_screen(void)
{
    uint64_t SBIconController = r_class("SBIconController");
    if (!r_is_objc_ptr(SBIconController)) return NO;

    uint64_t shared = r_msg2_main(SBIconController, "sharedInstance", 0, 0, 0, 0);
    if (!r_is_objc_ptr(shared)) return NO;

    uint64_t view = r_msg2_main(shared, "view", 0, 0, 0, 0);
    if (!r_is_objc_ptr(view)) return NO;

    // Check if view is in window hierarchy
    uint64_t window = r_msg2_main(view, "window", 0, 0, 0, 0);
    if (!r_is_objc_ptr(window)) return NO;

    // Check if window is key (active)
    uint64_t isKey = r_msg2_main(window, "isKeyWindow", 0, 0, 0, 0);
    if (!isKey) return NO;

    // Check if view is not hidden and has superview
    uint64_t superview = r_msg2_main(view, "superview", 0, 0, 0, 0);
    if (!r_is_objc_ptr(superview)) return NO;

    // Check hidden state
    uint64_t hidden = r_msg2_main(view, "isHidden", 0, 0, 0, 0);
    if (hidden) return NO;

    // Check alpha
    struct { double a; } alphaStruct = {0};
    r_msg2_main_struct_ret(view, "alpha", &alphaStruct, sizeof(alphaStruct), NULL, 0, NULL, 0, NULL, 0, NULL, 0);
    if (alphaStruct.a < 0.01) return NO;

    return YES;
}

// Check if lock screen is showing
static BOOL picture_overlay_is_on_lock_screen(void)
{
    // Check for SBLockScreenViewController
    uint64_t SBLockScreenViewController = r_class("SBLockScreenViewController");
    if (!r_is_objc_ptr(SBLockScreenViewController)) {
        // Try alternate class name
        SBLockScreenViewController = r_class("SBFLockScreenViewController");
    }
    if (!r_is_objc_ptr(SBLockScreenViewController)) return NO;

    uint64_t shared = r_msg2_main(SBLockScreenViewController, "sharedInstance", 0, 0, 0, 0);
    if (!r_is_objc_ptr(shared)) return NO;

    uint64_t view = r_msg2_main(shared, "view", 0, 0, 0, 0);
    if (!r_is_objc_ptr(view)) return NO;

    uint64_t superview = r_msg2_main(view, "superview", 0, 0, 0, 0);
    return r_is_objc_ptr(superview);
}

// Get appropriate window for overlay (home screen or lock screen)
static uint64_t picture_overlay_get_appropriate_window(void)
{
    // First check if we're on home screen
    if (picture_overlay_is_on_home_screen()) {
        return picture_overlay_find_home_screen_window();
    }

    // Then check lock screen
    if (picture_overlay_is_on_lock_screen()) {
        // Get lock screen window
        uint64_t UIApplication = r_class("UIApplication");
        uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
        uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
        uint64_t count = r_msg2_main(windows, "count", 0, 0, 0, 0);

        for (uint64_t i = 0; i < count && i < 32; i++) {
            uint64_t win = r_msg2_main(windows, "objectAtIndex:", i, 0, 0, 0);
            if (!r_is_objc_ptr(win)) continue;

            uint64_t windowLevel = r_msg2_main(win, "windowLevel", 0, 0, 0, 0);
            // Lock screen windows typically have higher window levels
            if (windowLevel > 1000 && windowLevel < 2000) {
                printf("[PICTURE] found lock screen window=0x%llx\n", win);
                return win;
            }
        }
    }

    return 0;
}

static uint64_t picture_overlay_first_window(void)
{
    return picture_overlay_get_appropriate_window();
}

static uint64_t picture_overlay_existing_view(uint64_t window)
{
    if (!r_is_objc_ptr(window)) return 0;

    uint64_t view = r_msg2_main(window, "viewWithTag:", kPictureOverlayTag, 0, 0, 0);
    if (r_is_objc_ptr(view)) {
        gPictureOverlayImageView = view;
        return view;
    }
    return 0;
}

static void picture_overlay_release_resources(void)
{
    if (r_is_objc_ptr(gPictureOverlayImageView)) {
        r_msg2_main(gPictureOverlayImageView, "release", 0, 0, 0, 0);
        gPictureOverlayImageView = 0;
    }
    if (r_is_objc_ptr(gPictureOverlayWindow)) {
        r_msg2_main(gPictureOverlayWindow, "release", 0, 0, 0, 0);
        gPictureOverlayWindow = 0;
    }
    if (gPictureOverlayLastImagePath) {
        r_free(gPictureOverlayLastImagePath);
        gPictureOverlayLastImagePath = 0;
    }
}

#pragma mark - Image Loading

static uint64_t picture_overlay_load_image(const char *imagePath)
{
    if (!imagePath || !*imagePath) return 0;

    NSData *imageData = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:imagePath]];
    if (!imageData || imageData.length == 0) {
        printf("[PICTURE] failed to load: %s\n", imagePath);
        return 0;
    }

    uint64_t NSData_class = r_class("NSData");
    if (!r_is_objc_ptr(NSData_class)) return 0;

    uint64_t remoteDataAlloc = r_msg2_main(NSData_class, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(remoteDataAlloc)) return 0;

    size_t dataLen = imageData.length;
    uint64_t remoteDataPtr = r_dlsym_call(R_TIMEOUT, "malloc", dataLen, 0, 0, 0, 0, 0, 0, 0);
    if (!remoteDataPtr) {
        r_msg2_main(remoteDataAlloc, "release", 0, 0, 0, 0);
        return 0;
    }

    remote_write(remoteDataPtr, imageData.bytes, dataLen);

    uint64_t bytesSelector = r_sel("initWithBytes:length:");
    if (!bytesSelector) {
        r_dlsym_call(R_TIMEOUT, "free", remoteDataPtr, 0, 0, 0, 0, 0, 0, 0);
        r_msg2_main(remoteDataAlloc, "release", 0, 0, 0, 0);
        return 0;
    }

    uint64_t remoteData = r_msg2_main(remoteDataAlloc, "initWithBytes:length:",
                                       remoteDataPtr, dataLen, 0, 0);

    r_msg2_main(remoteDataAlloc, "release", 0, 0, 0, 0);

    if (!r_is_objc_ptr(remoteData)) {
        r_dlsym_call(R_TIMEOUT, "free", remoteDataPtr, 0, 0, 0, 0, 0, 0, 0);
        return 0;
    }

    uint64_t UIImage_class = r_class("UIImage");
    if (!r_is_objc_ptr(UIImage_class)) {
        r_dlsym_call(R_TIMEOUT, "CFRelease", remoteData, 0, 0, 0, 0, 0, 0, 0);
        return 0;
    }

    uint64_t imageWithData = r_sel("imageWithData:");
    if (!imageWithData) {
        r_dlsym_call(R_TIMEOUT, "CFRelease", remoteData, 0, 0, 0, 0, 0, 0, 0);
        return 0;
    }

    uint64_t remoteImage = r_msg2_main(UIImage_class, "imageWithData:", remoteData, 0, 0, 0);
    r_dlsym_call(R_TIMEOUT, "CFRelease", remoteData, 0, 0, 0, 0, 0, 0, 0);

    return r_is_objc_ptr(remoteImage) ? remoteImage : 0;
}

#pragma mark - Main Apply

bool picture_overlay_apply_in_session(BOOL enabled, const char *imagePath,
                                      int offsetX, int offsetY,
                                      int scalePct, int alphaPct)
{
    // If disabled, stop any existing overlay
    if (!enabled) {
        return picture_overlay_stop_in_session();
    }

    // Need image path for apply
    if (!imagePath || !*imagePath) {
        printf("[PICTURE] no image path specified\n");
        return false;
    }

    // Get home screen or lock screen window
    uint64_t window = picture_overlay_get_appropriate_window();
    if (!r_is_objc_ptr(window)) {
        printf("[PICTURE] could not get appropriate window (not on home screen or lock screen)\n");
        // Don't remove overlay, just skip this apply
        return true;
    }

    // Check for existing view
    uint64_t existingView = picture_overlay_existing_view(window);

    if (r_is_objc_ptr(existingView)) {
        // Update existing view with new image and properties
        printf("[PICTURE] updating existing overlay at window=0x%llx\n", window);

        uint64_t newImage = picture_overlay_load_image(imagePath);
        if (!r_is_objc_ptr(newImage)) {
            return false;
        }

        r_msg2_main(existingView, "setImage:", newImage, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "CFRelease", newImage, 0, 0, 0, 0, 0, 0, 0);

        // Update frame
        struct { double x, y, w, h; } imageSize = {0};
        r_msg2_main_struct_ret(existingView, "bounds", &imageSize, sizeof(imageSize),
                               NULL, 0, NULL, 0, NULL, 0, NULL, 0);
        CGFloat scaleFactor = (CGFloat)scalePct / 100.0;
        CGFloat scaledWidth = imageSize.w * scaleFactor;
        CGFloat scaledHeight = imageSize.h * scaleFactor;
        CGFloat posX = (imageSize.w - scaledWidth) / 2.0 + offsetX;
        CGFloat posY = (imageSize.h - scaledHeight) / 2.0 + offsetY;

        struct { double x, y, w, h; } frame = { posX, posY, scaledWidth, scaledHeight };
        r_msg2_main_raw(existingView, "setFrame:", &frame, sizeof(frame),
                        NULL, 0, NULL, 0, NULL, 0);

        CGFloat alpha = (CGFloat)alphaPct / 100.0;
        r_msg2_main(existingView, "setAlpha:", *(uint64_t *)&alpha, 0, 0, 0);

        r_msg2_main(existingView, "setHidden:", 0, 0, 0, 0);
        r_msg2_main(window, "bringSubviewToFront:", existingView, 0, 0, 0);

        return true;
    }

    // Create new overlay
    printf("[PICTURE] creating new overlay at window=0x%llx\n", window);

    uint64_t image = picture_overlay_load_image(imagePath);
    if (!r_is_objc_ptr(image)) {
        printf("[PICTURE] failed to load image\n");
        return false;
    }

    uint64_t UIImageView_class = r_class("UIImageView");
    if (!r_is_objc_ptr(UIImageView_class)) {
        r_dlsym_call(R_TIMEOUT, "CFRelease", image, 0, 0, 0, 0, 0, 0, 0);
        return false;
    }

    uint64_t imageViewAlloc = r_msg2_main(UIImageView_class, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(imageViewAlloc)) {
        r_dlsym_call(R_TIMEOUT, "CFRelease", image, 0, 0, 0, 0, 0, 0, 0);
        return false;
    }

    uint64_t imageView = r_msg2_main(imageViewAlloc, "initWithImage:", image, 0, 0, 0);
    r_dlsym_call(R_TIMEOUT, "CFRelease", image, 0, 0, 0, 0, 0, 0, 0);
    r_msg2_main(imageViewAlloc, "release", 0, 0, 0, 0);

    if (!r_is_objc_ptr(imageView)) {
        printf("[PICTURE] failed to create UIImageView\n");
        return false;
    }

    // Get bounds and calculate position
    struct { double x, y, w, h; } bounds = {0};
    r_msg2_main_struct_ret(window, "bounds", &bounds, sizeof(bounds),
                           NULL, 0, NULL, 0, NULL, 0, NULL, 0);

    struct { double x, y, w, h; } imageSize = {0};
    r_msg2_main_struct_ret(imageView, "bounds", &imageSize, sizeof(imageSize),
                           NULL, 0, NULL, 0, NULL, 0, NULL, 0);

    CGFloat scaleFactor = (CGFloat)scalePct / 100.0;
    CGFloat scaledWidth = imageSize.w * scaleFactor;
    CGFloat scaledHeight = imageSize.h * scaleFactor;
    CGFloat posX = (bounds.w - scaledWidth) / 2.0 + offsetX;
    CGFloat posY = (bounds.h - scaledHeight) / 2.0 + offsetY;

    struct { double x, y, w, h; } frame = { posX, posY, scaledWidth, scaledHeight };
    r_msg2_main_raw(imageView, "setFrame:", &frame, sizeof(frame),
                    NULL, 0, NULL, 0, NULL, 0);

    CGFloat alpha = (CGFloat)alphaPct / 100.0;
    r_msg2_main(imageView, "setAlpha:", *(uint64_t *)&alpha, 0, 0, 0);

    // Set content mode for better scaling
    uint64_t UIViewContentModeScaleAspectFit = 6;
    r_msg2_main(imageView, "setContentMode:", UIViewContentModeScaleAspectFit, 0, 0, 0);

    // Set tag for idempotent reapply
    r_msg2_main(imageView, "setTag:", kPictureOverlayTag, 0, 0, 0);

    // Add to window
    r_msg2_main(window, "addSubview:", imageView, 0, 0, 0);

    // Cache pointers
    gPictureOverlayWindow = window;
    gPictureOverlayImageView = imageView;

    printf("[PICTURE] overlay created at (%.0f, %.0f) size (%.0f, %.0f)\n",
           posX, posY, scaledWidth, scaledHeight);

    return true;
}

#pragma mark - Stop

bool picture_overlay_stop_in_session(void)
{
    uint64_t window = picture_overlay_first_window();
    uint64_t view = picture_overlay_existing_view(window);

    if (!r_is_objc_ptr(view)) {
        picture_overlay_release_resources();
        return true;
    }

    r_msg2_main(view, "setHidden:", 1, 0, 0, 0);
    r_msg2_main(view, "removeFromSuperview", 0, 0, 0, 0);

    picture_overlay_release_resources();

    printf("[PICTURE] overlay stopped\n");
    return true;
}

#pragma mark - Forget State

void picture_overlay_forget_remote_state(void)
{
    printf("[PICTURE] forgetting remote state\n");
    gPictureOverlayWindow = 0;
    gPictureOverlayImageView = 0;
    if (gPictureOverlayLastImagePath) {
        r_free(gPictureOverlayLastImagePath);
        gPictureOverlayLastImagePath = 0;
    }
}