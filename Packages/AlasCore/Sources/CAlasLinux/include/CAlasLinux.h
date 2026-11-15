#pragma once

// Linux calls Swift can't reach through Glibc: they need _GNU_SOURCE or are
// raw syscalls. Empty on other platforms.

#define ALAS_RENAME_NOREPLACE 1
#define ALAS_RENAME_EXCHANGE 2

// The uid of a Unix socket's peer (SO_PEERCRED); 0 on success, -1 with errno.
int alas_peer_uid(int fd, unsigned int *uid);

int alas_renameat2(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags);
