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
    uint32_t user_id;
    uint32_t group_id;
    const char *hard_link;
} detours_archive_entry;

typedef int (*detours_archive_progress)(void *context, uint64_t bytes);
typedef int (*detours_archive_input)(void *context, uint32_t index);
typedef int (*detours_archive_volume)(void *context, const char *name);

/* Entry storage and output are borrowed for this synchronous call.
   open_input transfers a readable descriptor, closed after that member.
   Output must be an empty regular file exclusively created by the caller. */
enum detours_archive_format {
    DETOURS_ARCHIVE_SEVEN_Z = 0, DETOURS_ARCHIVE_ZIP = 1, DETOURS_ARCHIVE_TAR = 2,
    DETOURS_ARCHIVE_GZIP = 3, DETOURS_ARCHIVE_BZIP2 = 4, DETOURS_ARCHIVE_XZ = 5,
    DETOURS_ARCHIVE_RAR = 6, DETOURS_ARCHIVE_RAR5 = 7
};

int32_t detours_archive_create(int32_t format, int output, const detours_archive_entry *entries,
                               uint32_t count, const char *password,
                               detours_archive_input open_input,
                               detours_archive_progress progress, void *context);

typedef struct {
    const char *name;
    const char *symbolic_link;
    const char *hard_link;
    uint64_t size;
    uint64_t modified_filetime;
    uint32_t mode;
    int is_directory;
    int has_size;
    int has_modified;
    int is_encrypted;
    int split_before;
    int split_after;
} detours_archive_member;
typedef int (*detours_archive_visit)(void *context, uint32_t index, const detours_archive_member *member);
typedef struct {
    int is_volume;
    int has_index;
    uint32_t index;
} detours_rar_volume_info;
/* Inspects one volume without following siblings or allocating output. A complete
   archive read remains mandatory before accepting or extracting a volume set. */
int32_t detours_rar_inspect(int32_t format, int input, const char *password,
                           detours_rar_volume_info *info, detours_archive_visit visit,
                           detours_archive_progress progress, void *context);
/* All members are visited before output is requested. Metadata strings are borrowed
   only for the visit. A null output callback lists without extracting. Otherwise
   output transfers an empty regular-file descriptor, which this call closes.
   The archive descriptor is borrowed and its seek offset is never changed. */
int32_t detours_archive_read(int32_t format, int input, const char *password,
                            const char *input_name, detours_archive_volume open_volume,
                            detours_archive_visit visit, detours_archive_input output,
                            detours_archive_progress progress, void *context);

#ifdef __cplusplus
}
#endif
#endif
