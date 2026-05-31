#import "location_sim.h"
bool locationsim_apply_static(const LocationSimConfig *config) { (void)config; return false; }
bool locationsim_stop(const char *hostProcess, bool wait) { (void)hostProcess; (void)wait; return false; }
bool locationsim_apply_strict_hosts(const LocationSimConfig *config) { (void)config; return false; }
bool locationsim_stop_strict_hosts(const char *hostProcess, bool wait) { (void)hostProcess; (void)wait; return false; }
