#ifndef typebanner_h
#define typebanner_h
#include <stdbool.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
@class RemoteCallSession;
#define TYPEBANNER_RC_FIRST_EXCEPTION_TIMEOUT_MS 3000
void typebanner_forget_remote_state(void);
bool typebanner_has_remote_state(void);
bool typebanner_release_mobilesms_keepalive_in_springboard_session(void);
bool typebanner_hide_in_springboard_session(void);
bool typebanner_run_once_with_mobile_session_and_current_springboard(RemoteCallSession * _Nullable * _Nullable session, bool springboardReady);
void typebanner_release_mobilesms_keepalive_in_springboard_remote_session(RemoteCallSession * _Nonnull session);
void typebanner_hide_in_springboard_remote_session(RemoteCallSession * _Nonnull session);
#endif
#endif
