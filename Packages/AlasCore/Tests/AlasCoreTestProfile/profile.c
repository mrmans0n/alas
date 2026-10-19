// Points the core tests at a scratch profile, so no test reads or writes the
// everyday one under ~/Library/Application Support/Alas. The profile is
// resolved once, from the environment, the first time any code asks, so the
// override is set here, before any Swift code runs. A profile already set in
// the environment is kept.

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

__attribute__((constructor)) static void use_scratch_profile(void) {
    if (getenv("ALAS_APP_SUPPORT_DIR") != NULL) return;
    const char *tmp = getenv("TMPDIR");
    snprintf(scratch, sizeof scratch, "%s/alas-core-tests-XXXXXX", tmp != NULL ? tmp : "/tmp");
    if (mkdtemp(scratch) == NULL) {
        perror("AlasCoreTests: cannot create a scratch profile");
        abort();
    }
    setenv("ALAS_APP_SUPPORT_DIR", scratch, 1);
    atexit(remove_scratch_profile);
}
