#import "rssidisplay.h"
void rssidisplay_forget_remote_state(void) {}
bool rssidisplay_stop_in_session(void) { return false; }
bool rssidisplay_apply_in_session(bool wifi, bool cell) { (void)wifi; (void)cell; return false; }
