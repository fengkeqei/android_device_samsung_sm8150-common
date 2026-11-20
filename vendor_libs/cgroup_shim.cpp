/*
 * v124: libprocessgroup ABI shim for the Samsung composer@2.4 service.
 *
 * The stock composer@2.4 binary was compiled against an older
 * libprocessgroup that exported plain C entry points:
 *
 *   extern "C" int CgroupGetAttributePath(const char*, char*, size_t);
 *   extern "C" bool SetTaskProfiles(int, const char* const[], size_t, bool);
 *
 * A16's libprocessgroup only exports the C++ overloads (e.g.
 * _Z22CgroupGetAttributePathRKNSt3__112basic_string...). The unmangled names
 * are gone, so the binary cannot be linked and dies with
 *
 *   cannot locate symbol "CgroupGetAttributePath" ...
 *   cannot locate symbol "SetTaskProfiles" ...
 *
 * This shim re-exports both C symbols. The composer only uses them to put
 * itself into the "HighPerformance" task profile, which is a scheduling
 * hint -- the display pipeline works without it. Both are implemented as
 * best-effort no-ops that report success, which is what the old API did for
 * an unknown/unavailable profile.
 */

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

extern "C" int CgroupGetAttributePath(const char* attr, char* path, size_t size) {
    if (attr == nullptr || path == nullptr || size == 0) {
        errno = EINVAL;
        return -1;
    }
    // Old contract: write the cgroup attribute path for `attr` into `path`.
    // Compose "<cgroup root>/<attr>" so callers that just open() the result
    // get a well-formed path.
    const char* root = "/sys/fs/cgroup/";
    size_t rootLen = strlen(root);
    size_t attrLen = strlen(attr);
    if (rootLen + attrLen + 1 > size) {
        errno = ENOSPC;
        return -1;
    }
    memcpy(path, root, rootLen);
    memcpy(path + rootLen, attr, attrLen);
    path[rootLen + attrLen] = '\0';
    return 0;
}

// Old signature: SetTaskProfiles(tid, profiles, count, use_aggregate).
// Returning true means "profiles applied"; the composer treats false as a
// warning only.
extern "C" bool SetTaskProfiles(int /*tid*/, const char* const* /*profiles*/,
                                size_t /*count*/, bool /*use_aggregate*/) {
    return true;
}
