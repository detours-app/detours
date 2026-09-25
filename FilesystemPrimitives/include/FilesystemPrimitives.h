#ifndef DETOURS_FILESYSTEM_PRIMITIVES_H
#define DETOURS_FILESYSTEM_PRIMITIVES_H
#include <time.h>

int detours_rename_exclusive(int source_directory, const char *source,
                             int destination_directory, const char *destination);
int detours_open_symlink(int directory, const char *name);
int detours_set_symlink_times(int descriptor, const struct timespec times[2]);

#endif
