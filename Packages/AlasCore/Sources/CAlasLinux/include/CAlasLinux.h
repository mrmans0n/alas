#pragma once

// Linux calls Swift can't reach through Glibc: they need _GNU_SOURCE or are
// raw syscalls. Empty on other platforms.

#define ALAS_RENAME_NOREPLACE 1
#define ALAS_RENAME_EXCHANGE 2

int alas_renameat2(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags);
