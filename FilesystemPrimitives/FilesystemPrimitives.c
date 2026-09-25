#define _GNU_SOURCE
#include "FilesystemPrimitives.h"
#include <errno.h>
#include <stdio.h>
#include <fcntl.h>
#include <sys/stat.h>

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

int detours_open_symlink(int directory, const char *name) {
#if defined(__APPLE__)
    return openat(directory, name, O_RDONLY | O_SYMLINK | O_CLOEXEC | O_NONBLOCK);
#elif defined(__linux__)
    return openat(directory, name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
#else
    errno = ENOTSUP;
    return -1;
#endif
}

int detours_set_symlink_times(int descriptor, const struct timespec times[2]) {
#if defined(__APPLE__)
    return futimens(descriptor, times);
#elif defined(__linux__)
    return utimensat(descriptor, "", times, AT_EMPTY_PATH | AT_SYMLINK_NOFOLLOW);
#else
    errno = ENOTSUP;
    return -1;
#endif
}
