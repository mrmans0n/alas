#pragma once

// Linux calls Swift can't reach through Glibc: they need _GNU_SOURCE or are
// raw syscalls. Empty on other platforms.

#define ALAS_RENAME_NOREPLACE 1
#define ALAS_RENAME_EXCHANGE 2

// The uid of a Unix socket's peer (SO_PEERCRED); 0 on success, -1 with errno.
int alas_peer_uid(int fd, unsigned int *uid);

// posix_spawn_file_actions_addclosefrom_np, a GNU extension older glibc
// headers only declare under _GNU_SOURCE; `actions` is a posix_spawn_file_actions_t.
int alas_spawn_add_closefrom(void *actions, int from);

// posix_spawn_file_actions_addchdir_np, likewise a GNU extension.
int alas_spawn_add_chdir(void *actions, const char *path);

// Replace an unpublished pipe's endpoints using pipe2/dup3 with O_CLOEXEC.
// Needs two temporary descriptors. Returns 0, or -1 preserving errno; targets
// may be partially replaced on failure, so the caller must not use them then.
int alas_replace_pipe_cloexec(int read_fd, int write_fd);

int alas_renameat2(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags);
