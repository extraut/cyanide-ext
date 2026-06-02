//
//  picture_overlay.m
//
//  Picture Overlay tweak — displays an image/GIF on SpringBoard.
//  Only visible on home screen and lock screen.
//  Freezes animation when screen is off to save battery.
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

// Forward declaration
static uint64_t picture_overlay_first_window(void);
static uint64_t picture_overlay_existing_view(uint64_t window);

#pragma mark - Helpers

static uint64_t picture_overlay_first_window(void)
{
    uint64_t UIApplication = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApplication)) return 0;

    uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) return 0;

    // Try keyWindow first
    uint64_t keyWindow = r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    if (r_is_objc_ptr(keyWindow)) return keyWindow;

    // Fall back to first window in windows array
    uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
    if (!r_is_objc_ptr(windows)) return 0;

    uint64_t count = r_msg2_main(windows, "count", 0, 0, 0, 0);
    if (count == 0 || count > 64) return 0;

    for (uint64_t i = 0; i < count; i++) {
        uint64_t window = r_msg2_main(windows, "objectAtIndex:", i, 0, 0, 0);
        if (r_is_objc_ptr(window)) return window;
    }

    return 0;
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
}

#pragma mark - Image Loading

// Load image from local path and send to SpringBoard as UIImage
// Returns remote UIImage pointer, or 0 on failure
static uint64_t picture_overlay_load_image(const char *imagePath)
{
    if (!imagePath || !*imagePath) return 0;

    // Load image data from local file
    NSData *imageData = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:imagePath]];
    if (!imageData || imageData.length == 0) {
        printf("[PICTURE] failed to load: %s\n", imagePath);
        return 0;
    }

    // Create remote NSData
    uint64_t NSData_class = r_class("NSData");
    if (!r_is_objc_ptr(NSData_class)) return 0;

    // Allocate remote NSData
    uint64_t remoteDataAlloc = r_msg2_main(NSData_class, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(remoteDataAlloc)) return 0;

    // Write image data to remote memory
    size_t dataLen = imageData.length;
    uint64_t remoteDataPtr = r_dlsym_call(R_TIMEOUT, "malloc", dataLen, 0, 0, 0, 0, 0, 0, 0);
    if (!remoteDataPtr) {
        r_msg2_main(remoteDataAlloc, "release", 0, 0, 0, 0);
        return 0;
    }

    remote_write(remoteDataPtr, imageData.bytes, dataLen);

    // Create remote NSData with bytes
    uint64_t bytesSelector = r_sel("initWithBytes:length:");
    if (!bytesSelector) {
        r_dlsym_call(R_TIMEOUT, "free", remoteDataPtr, 0, 0, 0, 0, 0, 0, 0);
        r_msg2_main(remoteDataAlloc, "release", 0, 0, 0, 0);
        return 0;
    }

    uint64_t remoteData = r_msg2_main(remoteDataAlloc, "initWithBytes:length:",
                                       remoteDataPtr, dataLen, 0, 0);
    // Remote now owns the allocation, don't free local copy

    r_msg2_main(remoteDataAlloc, "release", 0, 0, 0, 0);

    if (!r_is_objc_ptr(remoteData)) {
        r_dlsym_call(R_TIMEOUT, "free", remoteDataPtr, 0, 0, 0, 0, 0, 0, 0);
        return 0;
    }

    // Create UIImage from data
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

    // Get window
    uint64_t window = picture_overlay_first_window();
    if (!r_is_objc_ptr(window)) {
        printf("[PICTURE] could not get window\n");
        return false;
    }

    // Check for existing view
    uint64_t existingView = picture_overlay_existing_view(window);

    if (r_is_objc_ptr(existingView)) {
        // Update existing view with new image and properties
        printf("[PICTURE] updating existing overlay\n");

        // Load new image
        uint64_t newImage = picture_overlay_load_image(imagePath);
        if (!r_is_objc_ptr(newImage)) {
            return false;
        }

        // Set image on existing view
        r_msg2_main(existingView, "setImage:", newImage, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "CFRelease", newImage, 0, 0, 0, 0, 0, 0, 0);

        // Update alpha
        CGFloat alpha = (CGFloat)alphaPct / 100.0;
        r_msg2_main(existingView, "setAlpha:", *(uint64_t *)&alpha, 0, 0, 0);

        // Show and bring to front
        r_msg2_main(existingView, "setHidden:", 0, 0, 0, 0);
        r_msg2_main(window, "bringSubviewToFront:", existingView, 0, 0, 0);

        return true;
    }

    // Create new overlay
    printf("[PICTURE] creating new overlay\n");

    // Load image
    uint64_t image = picture_overlay_load_image(imagePath);
    if (!r_is_objc_ptr(image)) {
        printf("[PICTURE] failed to load image\n");
        return false;
    }

    // Create UIImageView
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

    // Get screen bounds for positioning
    struct { double x, y, w, h; } bounds = {0};
    r_msg2_main_struct_ret(window, "bounds",
                           &bounds, sizeof(bounds),
                           NULL, 0, NULL, 0, NULL, 0, NULL, 0);

    // Get image size
    struct { double x, y, w, h; } imageSize = {0};
    r_msg2_main_struct_ret(imageView, "bounds",
                           &imageSize, sizeof(imageSize),
                           NULL, 0, NULL, 0, NULL, 0, NULL, 0);

    // Calculate scaled size
    CGFloat scaleFactor = (CGFloat)scalePct / 100.0;
    CGFloat scaledWidth = imageSize.w * scaleFactor;
    CGFloat scaledHeight = imageSize.h * scaleFactor;

    // Calculate position with offset (centered by default, offset applied)
    CGFloat posX = (bounds.w - scaledWidth) / 2.0 + offsetX;
    CGFloat posY = (bounds.h - scaledHeight) / 2.0 + offsetY;

    // Set frame
    struct { double x, y, w, h; } frame = { posX, posY, scaledWidth, scaledHeight };
    r_msg2_main_raw(imageView, "setFrame:",
                    &frame, sizeof(frame),
                    NULL, 0, NULL, 0, NULL, 0);

    // Set alpha
    CGFloat alpha = (CGFloat)alphaPct / 100.0;
    r_msg2_main(imageView, "setAlpha:", *(uint64_t *)&alpha, 0, 0, 0);

    // Set content mode for better scaling
    uint64_t UIViewContentModeScaleAspectFit = 6; // UIViewContentModeScaleAspectFit
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
        // Nothing to stop
        picture_overlay_release_resources();
        return true;
    }

    // Hide and remove from superview
    r_msg2_main(view, "setHidden:", 1, 0, 0, 0);
    r_msg2_main(view, "removeFromSuperview", 0, 0, 0, 0);

    // Release and clear cache
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
}