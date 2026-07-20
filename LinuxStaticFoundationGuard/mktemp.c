#include <errno.h>
#include <stddef.h>

// Static FoundationEssentials retains a legacy mktemp reference even when the
// executable uses only its own exclusive-file writer. Resolve that symbol to a
// fail-closed implementation so an unexpected call cannot create a racy path.
char *mktemp(char *path_template) {
    errno = ENOTSUP;
    if (path_template != NULL) {
        path_template[0] = '\0';
    }
    return path_template;
}
