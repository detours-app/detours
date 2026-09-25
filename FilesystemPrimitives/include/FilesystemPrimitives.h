#ifndef DETOURS_FILESYSTEM_PRIMITIVES_H
#define DETOURS_FILESYSTEM_PRIMITIVES_H

int detours_rename_exclusive(int source_directory, const char *source,
                             int destination_directory, const char *destination);

#endif
