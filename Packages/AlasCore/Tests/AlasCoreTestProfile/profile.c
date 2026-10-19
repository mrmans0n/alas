// Points the core tests at a scratch profile, so no test reads or writes the
// everyday one under ~/Library/Application Support/Alas. The profile is
// resolved once, from the environment, the first time any code asks, so the
// override is set here, before any Swift code runs. A profile already set in
// the environment is kept; a blank one, which means the everyday profile, is
// not.

#include <CommonCrypto/CommonDigest.h>
#include <ctype.h>
#include <limits.h>
#include <removefile.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char scratch[PATH_MAX];

static int is_blank(const char *value) {
    for (; *value != '\0'; value++) {
        if (!isspace((unsigned char)*value)) return 0;
    }
    return 1;
}

// Removes the profile and the runtime directory derived from it, named as
// `AlasProfile.runtimeDirectory(for:uid:)` names it: the first four bytes of
// the SHA-256 of the profile's canonical path, standardized as Foundation
// does, which drops `/private` before `/var`, `/tmp` and `/etc`.
static void remove_scratch_profile(void) {
    char canonical[PATH_MAX];
    if (realpath(scratch, canonical) != NULL) {
        const char *path = canonical;
        if (strncmp(path, "/private/", 9) == 0
            && (strncmp(path + 8, "/var/", 5) == 0 || strncmp(path + 8, "/tmp/", 5) == 0 || strncmp(path + 8, "/etc/", 5) == 0)) {
            path += 8;
        }
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(path, (CC_LONG)strlen(path), digest);
        char runtime[64];
        snprintf(runtime, sizeof runtime, "/tmp/alas-%u-%02x%02x%02x%02x",
                 (unsigned)getuid(), digest[0], digest[1], digest[2], digest[3]);
        removefile(runtime, NULL, REMOVEFILE_RECURSIVE);
    }
    removefile(scratch, NULL, REMOVEFILE_RECURSIVE);
}

__attribute__((constructor)) static void use_scratch_profile(void) {
    const char *set = getenv("ALAS_APP_SUPPORT_DIR");
    if (set != NULL && !is_blank(set)) return;
    const char *tmp = getenv("TMPDIR");
    if (tmp == NULL || tmp[0] != '/') tmp = "/tmp";
    snprintf(scratch, sizeof scratch, "%s/alas-core-tests-XXXXXX", tmp);
    if (mkdtemp(scratch) == NULL) {
        perror("AlasCoreTests: cannot create a scratch profile");
        abort();
    }
    setenv("ALAS_APP_SUPPORT_DIR", scratch, 1);
    atexit(remove_scratch_profile);
}
