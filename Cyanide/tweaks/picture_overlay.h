//
//  picture_overlay.h
//
//  Picture Overlay tweak — displays images/GIFs on SpringBoard home screen
//  and lock screen. Supports multiple overlays, each with own settings.
//

#ifndef picture_overlay_h
#define picture_overlay_h

#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>

// Apply all enabled overlays from defaults (reads array of PictureOverlay_* keys)
bool picture_overlay_apply_all_in_session(void);
// Stop all overlays
bool picture_overlay_stop_all_in_session(void);
// Apply a specific overlay by ID.
// zIndex: 1–9999; used directly as UIWindowLevel float.
//   Useful landmarks:
//     UIWindowLevelNormal    =    0  (below status bar)
//     UIWindowLevelStatusBar = 1000  (status bar)
//     UIWindowLevelAlert     = 2000  (system alerts)
//   Default / recommended value: 1050 (above icons, below Control Center).
bool picture_overlay_apply_in_session(uint64_t overlayId, BOOL enabled, const char *imagePath,
                                      int offsetX, int offsetY,
                                      int scalePct, int alphaPct,
                                      int zIndex);
// Stop a specific overlay
bool picture_overlay_stop_in_session(uint64_t overlayId);
// Remove all overlays (full cleanup)
bool picture_overlay_remove_all_in_session(void);

void picture_overlay_forget_remote_state(void);

#endif