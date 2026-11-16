#ifdef __linux__
#define _GNU_SOURCE
#include <errno.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>
#include "CAlasLinux.h"

int alas_peer_uid(int fd, unsigned int *uid) {
    struct ucred credentials;
    socklen_t length = sizeof(credentials);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) != 0) return -1;
    *uid = credentials.uid;
    return 0;
}

int alas_spawn_add_closefrom(void *actions, int from) {
#if __GLIBC_PREREQ(2, 34)
    return posix_spawn_file_actions_addclosefrom_np((posix_spawn_file_actions_t *)actions, from);
#else
    (void)actions; (void)from;
    return ENOSYS;
#endif
}

int alas_spawn_add_chdir(void *actions, const char *path) {
#if __GLIBC_PREREQ(2, 29)
    return posix_spawn_file_actions_addchdir_np((posix_spawn_file_actions_t *)actions, path);
#else
    (void)actions; (void)path;
    return ENOSYS;
#endif
}

int alas_renameat2(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags) {
    return (int)syscall(SYS_renameat2, olddirfd, oldpath, newdirfd, newpath, flags);
}
#endif
