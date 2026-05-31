#ifndef rssidisplay_h
#define rssidisplay_h
#include <stdbool.h>
void rssidisplay_forget_remote_state(void);
bool rssidisplay_stop_in_session(void);
bool rssidisplay_apply_in_session(bool wifi, bool cell);
#endif
