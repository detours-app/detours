#define _GNU_SOURCE
#include "FilesystemPrimitives.h"
#include <errno.h>
#include <stdio.h>
#include <fcntl.h>

int detours_rename_exclusive(int source_directory, const char *source,
                             int destination_directory, const char *destination) {
#if defined(__APPLE__)
    return renameatx_np(source_directory, source, destination_directory, destination, RENAME_EXCL);
#elif defined(__linux__)
    return renameat2(source_directory, source, destination_directory, destination, RENAME_NOREPLACE);
#else
    errno = ENOTSUP;
    return -1;
#endif
}
