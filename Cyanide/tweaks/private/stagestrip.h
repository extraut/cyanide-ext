#ifndef stagestrip_h
#define stagestrip_h
#include <stdbool.h>
void stagestrip_forget_remote_state(void);
bool stagestrip_stop_in_session(void);
void stagestrip_stop_control_loop(void);
bool stagestrip_apply_in_session(int argc);
void stagestrip_start_control_loop(void);
#endif
