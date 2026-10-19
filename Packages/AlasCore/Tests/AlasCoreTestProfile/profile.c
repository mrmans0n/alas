// Points the core tests at a scratch profile, so no test reads or writes the
// everyday one under ~/Library/Application Support/Alas. The profile is
// resolved once, from the environment, the first time any code asks, so the
// override is set here, before any Swift code runs. A profile already set in
// the environment is kept; a blank one, which means the everyday profile, is
// not.

#include <ctype.h>
#include <limits.h>
#include <removefile.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char scratch[PATH_MAX];

static void remove_scratch_profile(void) {
    removefile(scratch, NULL, REMOVEFILE_RECURSIVE);
}

static int is_blank(const char *value) {
    for (; *value != '\0'; value++) {
        if (!isspace((unsigned char)*value)) return 0;
    }
    return 1;
}

__attribute__((constructor)) static void use_scratch_profile(void) {
    const char *set = getenv("ALAS_APP_SUPPORT_DIR");
    if (set != NULL && !is_blank(set)) return;
    const char *tmp = getenv("TMPDIR");
    snprintf(scratch, sizeof scratch, "%s/alas-core-tests-XXXXXX", tmp != NULL ? tmp : "/tmp");
    if (mkdtemp(scratch) == NULL) {
        perror("AlasCoreTests: cannot create a scratch profile");
        abort();
    }
    setenv("ALAS_APP_SUPPORT_DIR", scratch, 1);
    atexit(remove_scratch_profile);
}
