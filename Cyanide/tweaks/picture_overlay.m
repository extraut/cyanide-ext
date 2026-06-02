//
//  picture_overlay.m
//
//  Picture Overlay tweak — displays images/GIFs on SpringBoard home screen
//  and lock screen. Each overlay is identified by a unique tag derived from
//  the overlay ID. Visibility is gated by home-screen / lock-screen state.
//

#import "picture_overlay.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <stdint.h>

// Cached remote pointers — reset on SpringBoard restart
static uint64_t gPictureOverlayHomeWindow = 0;
static uint64_t gPictureOverlayLockWindow = 0;

#pragma mark - Window Detection

// Check if we're on home screen by verifying SBIconController is visible
static BOOL picture_overlay_is_on_home_screen(void)
{
    uint64_t SBIconController = r_class("SBIconController");
    if (!r_is_objc_ptr(SBIconController)) return NO;

    uint64_t shared = r_msg2_main(SBIconController, "sharedInstance", 0, 0, 0, 0);
    if (!r_is_objc_ptr(shared)) return NO;

    uint64_t view = r_msg2_main(shared, "view", 0, 0, 0, 0);
    if (!r_is_objc_ptr(view)) return NO;

    uint64_t window = r_msg2_main(view, "window", 0, 0, 0, 0);
    if (!r_is_objc_ptr(window)) return NO;

    uint64_t isKey = r_msg2_main(window, "isKeyWindow", 0, 0, 0, 0);
    return isKey != 0;
}

// Check if lock screen is showing
static BOOL picture_overlay_is_on_lock_screen(void)
{
    uint64_t cls = r_class("SBLockScreenViewController");
    if (!r_is_objc_ptr(cls)) {
        cls = r_class("SBFLockScreenViewController");
    }
    if (!r_is_objc_ptr(cls)) return NO;

    uint64_t shared = r_msg2_main(cls, "sharedInstance", 0, 0, 0, 0);
    if (!r_is_objc_ptr(shared)) return NO;

    uint64_t view = r_msg2_main(shared, "view", 0, 0, 0, 0);
    if (!r_is_objc_ptr(view)) return NO;

    uint64_t superview = r_msg2_main(view, "superview", 0, 0, 0, 0);
    return r_is_objc_ptr(superview);
}

// Get SpringBoard's main window (used for overlay attachment)
static uint64_t picture_overlay_get_springboard_window(void)
{
    // Try SBIconController's view window first
    uint64_t SBIconController = r_class("SBIconController");
    if (r_is_objc_ptr(SBIconController)) {
        uint64_t shared = r_msg2_main(SBIconController, "sharedInstance", 0, 0, 0, 0);
        if (r_is_objc_ptr(shared)) {
            uint64_t view = r_msg2_main(shared, "view", 0, 0, 0, 0);
            if (r_is_objc_ptr(view)) {
                uint64_t window = r_msg2_main(view, "window", 0, 0, 0, 0);
                if (r_is_objc_ptr(window)) {
                    gPictureOverlayHomeWindow = window;
                    return window;
                }
            }
        }
    }

    // Fall back to keyWindow
    uint64_t UIApplication = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApplication)) return 0;

    uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) return 0;

    uint64_t keyWin = r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    if (r_is_objc_ptr(keyWin)) {
        gPictureOverlayHomeWindow = keyWin;
    }
    return keyWin;
}

#pragma mark - Visibility Check

// Returns YES if overlay should be visible RIGHT NOW
// (either on home screen or lock screen)
static BOOL picture_overlay_should_be_visible(void)
{
    return picture_overlay_is_on_home_screen() || picture_overlay_is_on_lock_screen();
}

#pragma mark - Image Loading

static uint64_t picture_overlay_load_image(const char *imagePath)
{
    if (!imagePath || !*imagePath) return 0;

    NSData *imageData = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:imagePath]];
    if (!imageData || imageData.length == 0) return 0;

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

    uint64_t remoteImage = r_msg2_main(UIImage_class, "imageWithData:", remoteData, 0, 0, 0);
    r_dlsym_call(R_TIMEOUT, "CFRelease", remoteData, 0, 0, 0, 0, 0, 0, 0);

    return r_is_objc_ptr(remoteImage) ? remoteImage : 0;
}

#pragma mark - View Management

// Tag = base + overlayId (ensures unique tags per overlay)
static const uint64_t kPictureOverlayTagBase = 0xC0A15000;
static const uint64_t kPictureOverlayTagMax = 0xC0A15FFF;
static const uint64_t kPictureOverlayTagMask = 0x0000FFFF;

static uint64_t picture_overlay_tag_for_id(uint64_t overlayId)
{
    return kPictureOverlayTagBase | (overlayId & kPictureOverlayTagMask);
}

static uint64_t picture_overlay_existing_view(uint64_t window, uint64_t overlayId)
{
    if (!r_is_objc_ptr(window)) return 0;
    uint64_t tag = picture_overlay_tag_for_id(overlayId);
    uint64_t view = r_msg2_main(window, "viewWithTag:", tag, 0, 0, 0);
    return r_is_objc_ptr(view) ? view : 0;
}

// Remove all overlay views from the window
static void picture_overlay_remove_all_views_from_window(uint64_t window)
{
    if (!r_is_objc_ptr(window)) return;

    for (uint64_t tag = kPictureOverlayTagBase; tag <= kPictureOverlayTagMax; tag++) {
        uint64_t view = r_msg2_main(window, "viewWithTag:", tag, 0, 0, 0);
        if (r_is_objc_ptr(view)) {
            r_msg2_main(view, "removeFromSuperview", 0, 0, 0, 0);
            r_msg2_main(view, "release", 0, 0, 0, 0);
        }
    }
}

#pragma mark - Apply Single Overlay

bool picture_overlay_apply_in_session(uint64_t overlayId, BOOL enabled, const char *imagePath,
                                      int offsetX, int offsetY,
                                      int scalePct, int alphaPct)
{
    if (!enabled) {
        return picture_overlay_stop_in_session(overlayId);
    }

    if (!imagePath || !*imagePath) return false;

    // Check visibility — if not on home screen or lock screen, hide overlay
    BOOL shouldBeVisible = picture_overlay_should_be_visible();

    // Get window
    uint64_t window = picture_overlay_get_springboard_window();
    if (!r_is_objc_ptr(window)) {
        printf("[PICTURE] no SpringBoard window available\n");
        return false;
    }

    // Find existing view
    uint64_t existingView = picture_overlay_existing_view(window, overlayId);

    if (!shouldBeVisible) {
        // Not on home/lock screen — just hide any existing view
        if (r_is_objc_ptr(existingView)) {
            r_msg2_main(existingView, "setHidden:", 1, 0, 0, 0);
        }
        return true; // Not an error, just nothing to do right now
    }

    // We're on home screen or lock screen — show or create overlay

    if (r_is_objc_ptr(existingView)) {
        // Update existing
        uint64_t newImage = picture_overlay_load_image(imagePath);
        if (!r_is_objc_ptr(newImage)) return false;

        r_msg2_main(existingView, "setImage:", newImage, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "CFRelease", newImage, 0, 0, 0, 0, 0, 0, 0);

        // Get window bounds
        struct { double x, y, w, h; } bounds = {0};
        r_msg2_main_struct_ret(window, "bounds", &bounds, sizeof(bounds),
                               NULL, 0, NULL, 0, NULL, 0, NULL, 0);

        // Get current image size
        struct { double x, y, w, h; } imageSize = {0};
        r_msg2_main_struct_ret(existingView, "bounds", &imageSize, sizeof(imageSize),
                               NULL, 0, NULL, 0, NULL, 0, NULL, 0);

        CGFloat scaleFactor = (CGFloat)scalePct / 100.0;
        CGFloat scaledWidth = imageSize.w * scaleFactor;
        CGFloat scaledHeight = imageSize.h * scaleFactor;
        CGFloat posX = (bounds.w - scaledWidth) / 2.0 + offsetX;
        CGFloat posY = (bounds.h - scaledHeight) / 2.0 + offsetY;

        struct { double x, y, w, h; } frame = { posX, posY, scaledWidth, scaledHeight };
        r_msg2_main_raw(existingView, "setFrame:", &frame, sizeof(frame),
                        NULL, 0, NULL, 0, NULL, 0);

        CGFloat alpha = (CGFloat)alphaPct / 100.0;
        r_msg2_main(existingView, "setAlpha:", *(uint64_t *)&alpha, 0, 0, 0);

        r_msg2_main(existingView, "setHidden:", 0, 0, 0, 0);
        r_msg2_main(window, "bringSubviewToFront:", existingView, 0, 0, 0);

        printf("[PICTURE] updated overlay id=%llu at (%.0f, %.0f)\n", overlayId, posX, posY);
        return true;
    }

    // Create new overlay
    uint64_t image = picture_overlay_load_image(imagePath);
    if (!r_is_objc_ptr(image)) {
        printf("[PICTURE] failed to load image: %s\n", imagePath);
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

    // Get bounds
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

    // Content mode scale aspect fit
    uint64_t UIViewContentModeScaleAspectFit = 6;
    r_msg2_main(imageView, "setContentMode:", UIViewContentModeScaleAspectFit, 0, 0, 0);

    // Set unique tag for this overlay
    uint64_t tag = picture_overlay_tag_for_id(overlayId);
    r_msg2_main(imageView, "setTag:", tag, 0, 0, 0);

    // Add to window
    r_msg2_main(window, "addSubview:", imageView, 0, 0, 0);

    printf("[PICTURE] created overlay id=%llu tag=0x%llx at (%.0f, %.0f) size (%.0f, %.0f)\n",
           overlayId, tag, posX, posY, scaledWidth, scaledHeight);

    return true;
}

#pragma mark - Stop

bool picture_overlay_stop_in_session(uint64_t overlayId)
{
    uint64_t window = picture_overlay_get_springboard_window();
    if (!r_is_objc_ptr(window)) return false;

    uint64_t view = picture_overlay_existing_view(window, overlayId);
    if (r_is_objc_ptr(view)) {
        r_msg2_main(view, "setHidden:", 1, 0, 0, 0);
        r_msg2_main(view, "removeFromSuperview", 0, 0, 0, 0);
        r_msg2_main(view, "release", 0, 0, 0, 0);
        printf("[PICTURE] stopped overlay id=%llu\n", overlayId);
    }
    return true;
}

#pragma mark - Apply All (from defaults)

bool picture_overlay_apply_all_in_session(void)
{
    // Use apply_single API for the legacy single-overlay key
    // Real multi-overlay support lives in SettingsViewController
    return true;
}

bool picture_overlay_stop_all_in_session(void)
{
    uint64_t window = picture_overlay_get_springboard_window();
    if (r_is_objc_ptr(window)) {
        picture_overlay_remove_all_views_from_window(window);
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
    gPictureOverlayHomeWindow = 0;
    gPictureOverlayLockWindow = 0;
}