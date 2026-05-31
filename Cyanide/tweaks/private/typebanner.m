#import "typebanner.h"
#import "../../TaskRop/RemoteCall.h"
void typebanner_forget_remote_state(void) {}
bool typebanner_has_remote_state(void) { return false; }
bool typebanner_release_mobilesms_keepalive_in_springboard_session(void) { return false; }
bool typebanner_hide_in_springboard_session(void) { return false; }
bool typebanner_run_once_with_mobile_session_and_current_springboard(RemoteCallSession **session, bool springboardReady) { (void)session; (void)springboardReady; return false; }
void typebanner_release_mobilesms_keepalive_in_springboard_remote_session(RemoteCallSession *session) { (void)session; }
void typebanner_hide_in_springboard_remote_session(RemoteCallSession *session) { (void)session; }
