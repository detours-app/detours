#ifndef DETOURS_ARCHIVE_STREAM_BRIDGE_H
#define DETOURS_ARCHIVE_STREAM_BRIDGE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *name;
    int descriptor;
    int is_directory;
    uint32_t mode;
    uint64_t size;
    uint64_t modified_filetime;
    const void *link_bytes;
} detours_archive_entry;

typedef int (*detours_archive_progress)(void *context, uint64_t bytes);
typedef int (*detours_archive_input)(void *context, uint32_t index);

/* Entry storage and output are borrowed for this synchronous call.
   open_input transfers a readable descriptor, closed after that member.
   Output must be an empty regular file exclusively created by the caller. */
enum detours_archive_format { DETOURS_ARCHIVE_SEVEN_Z = 0, DETOURS_ARCHIVE_ZIP = 1 };

int32_t detours_archive_create(int32_t format, int output, const detours_archive_entry *entries,
                               uint32_t count, const char *password,
                               detours_archive_input open_input,
                               detours_archive_progress progress, void *context);

#ifdef __cplusplus
}
#endif
#endif
