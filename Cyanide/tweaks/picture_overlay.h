//
//  picture_overlay.h
//
//  Picture Overlay tweak — displays an image/GIF on SpringBoard.
//  Only visible on home screen and lock screen, freezes when screen is off.
//

#ifndef picture_overlay_h
#define picture_overlay_h

#include <stdbool.h>

bool picture_overlay_apply_in_session(BOOL enabled, const char *imagePath,
                                      int offsetX, int offsetY,
                                      int scalePct, int alphaPct);
bool picture_overlay_stop_in_session(void);
void picture_overlay_forget_remote_state(void);

#endif