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

// Window level: above icon content (1000-1100 range), below control center (~1200)
// iOS uses: UIWindowLevelNormal = 0, UIWindowLevelAlert = 1000,
// UIWindowLevelStatusBar = 1100, UIWindowLevelNotificationAlert = 1500
static const CGFloat kPictureOverlayWindowLevel = 1050.0;

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

// Get the SpringBoard scene to create our overlay window
static uint64_t picture_overlay_get_scene(void)
{
    if (gPictureOverlayScene && r_is_objc_ptr(gPictureOverlayScene)) {
        return gPictureOverlayScene;
    }

    uint64_t UIApplication = r_class("UIApplication");
    if (!r_is_objc_ptr(UIApplication)) return 0;

    uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) return 0;

    uint64_t keyWin = r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    if (!r_is_objc_ptr(keyWin)) return 0;

    uint64_t scene = r_msg2_main(keyWin, "windowScene", 0, 0, 0, 0);
    if (r_is_objc_ptr(scene)) {
        gPictureOverlayScene = scene;
    }
    return scene;
}

// Create a dedicated overlay window at the right level
static uint64_t picture_overlay_create_window(uint64_t scene, uint64_t overlayId)
{
    uint64_t UIWindow = r_class("UIWindow");
    if (!r_is_objc_ptr(UIWindow)) return 0;

    uint64_t winAlloc = r_msg2_main(UIWindow, "alloc", 0, 0, 0, 0);
    if (!r_is_objc_ptr(winAlloc)) return 0;

    uint64_t win = r_msg2_main(winAlloc, "initWithWindowScene:", scene, 0, 0, 0);
    r_msg2_main(winAlloc, "release", 0, 0, 0, 0);
    if (!r_is_objc_ptr(win)) return 0;

    // Set window level above icon layer, below control center
    r_msg2_main(win, "setWindowLevel:", *(uint64_t *)&kPictureOverlayWindowLevel, 0, 0, 0);

    // Make it non-interactive (let touches pass through)
    uint64_t NSNumber_class = r_class("NSNumber");
    uint64_t one = r_msg2_main(NSNumber_class, "numberWithBool:", 0, 0, 0, 0);
    if (r_is_objc_ptr(one)) {
        r_msg2_main(win, "setUserInteractionEnabled:", 0, 0, 0, 0); // false
    }

    // Set hidden = NO initially
    r_msg2_main(win, "setHidden:", 0, 0, 0, 0);

    printf("[PICTURE] created overlay window=0x%llx for id=%llu\n", win, overlayId);
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

    uint64_t win = picture_overlay_create_window(scene, overlayId);
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
    r_msg2_main(images, "release", 0, 0, 0, 0);

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
    if (!imageData || imageData.length == 0) return 0;

    uint64_t NSData_class = r_class("NSData");
    if (!r_is_objc_ptr(NSData_class)) return 0;

    size_t dataLen = imageData.length;
    uint64_t remoteDataPtr = r_dlsym_call(5, "malloc", dataLen, 0, 0, 0, 0, 0, 0, 0);
    if (!remoteDataPtr) return 0;

    remote_write(remoteDataPtr, imageData.bytes, dataLen);

    uint64_t NSDataAlloc = r_msg2_main(NSData_class, "alloc", 0, 0, 0, 0);
    uint64_t remoteData = r_msg2_main(NSDataAlloc, "initWithBytes:length:", remoteDataPtr, dataLen, 0, 0);
    r_msg2_main(NSDataAlloc, "release", 0, 0, 0, 0);

    if (!r_is_objc_ptr(remoteData)) {
        r_dlsym_call(5, "free", remoteDataPtr, 0, 0, 0, 0, 0, 0, 0);
        return 0;
    }

    uint64_t UIImage_class = r_class("UIImage");
    if (!r_is_objc_ptr(UIImage_class)) {
        r_dlsym_call(5, "CFRelease", remoteData, 0, 0, 0, 0, 0, 0, 0);
        return 0;
    }

    uint64_t imageWithDataSel = r_sel("imageWithData:");
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
                                      int scalePct, int alphaPct)
{
    if (!enabled) {
        return picture_overlay_stop_in_session(overlayId);
    }

    if (!imagePath || !*imagePath) {
        printf("[PICTURE] no image path for id=%llu\n", overlayId);
        return false;
    }

    // Get or create overlay window
    uint64_t window = picture_overlay_get_window(overlayId);
    if (!r_is_objc_ptr(window)) {
        printf("[PICTURE] could not get overlay window for id=%llu\n", overlayId);
        return false;
    }

    // Load image
    uint64_t image = picture_overlay_load_image(imagePath);
    if (!r_is_objc_ptr(image)) {
        printf("[PICTURE] failed to load image for id=%llu: %s\n", overlayId, imagePath);
        return false;
    }

    // Find existing image view in this window
    uint64_t tag = picture_overlay_tag_for_id(overlayId);
    uint64_t existingView = r_msg2_main(window, "viewWithTag:", tag, 0, 0, 0);

    if (r_is_objc_ptr(existingView)) {
        // Update existing view
        r_msg2_main(existingView, "setImage:", image, 0, 0, 0);
        r_dlsym_call(5, "CFRelease", image, 0, 0, 0, 0, 0, 0, 0);

        // Update frame
        struct { double x, y, w, h; } bounds = {0};
        r_msg2_main_struct_ret(window, "bounds", &bounds, sizeof(bounds),
                               NULL, 0, NULL, 0, NULL, 0, NULL, 0);

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
        r_msg2_main(window, "makeKeyAndVisible:", 0, 0, 0, 0);

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
    r_msg2_main(ivAlloc, "release", 0, 0, 0, 0);

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

    CGFloat scaleFactor = (CGFloat)scalePct / 100.0;
    CGFloat scaledW = bounds.w * 0.3 * scaleFactor;
    CGFloat scaledH = bounds.h * 0.3 * scaleFactor;
    CGFloat posX = bounds.x + (bounds.w - scaledW) / 2.0 + offsetX;
    CGFloat posY = bounds.y + (bounds.h - scaledH) / 2.0 + offsetY;

    struct { double x, y, w, h; } frame = { posX, posY, scaledW, scaledH };
    r_msg2_main_raw(imageView, "setFrame:", &frame, sizeof(frame),
                    NULL, 0, NULL, 0, NULL, 0);

    // Add to window
    r_msg2_main(window, "addSubview:", imageView, 0, 0, 0);
    r_msg2_main(window, "makeKeyAndVisible:", 0, 0, 0, 0);

    printf("[PICTURE] created overlay id=%llu tag=0x%llx at (%.0f, %.0f) size (%.0f, %.0f)\n",
           overlayId, tag, posX, posY, scaledW, scaledH);

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

    uint64_t tag = picture_overlay_tag_for_id(overlayId);
    uint64_t view = r_msg2_main(window, "viewWithTag:", tag, 0, 0, 0);

    if (r_is_objc_ptr(view)) {
        r_msg2_main(view, "removeFromSuperview", 0, 0, 0, 0);
        r_msg2_main(view, "release", 0, 0, 0, 0);
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
    }
}