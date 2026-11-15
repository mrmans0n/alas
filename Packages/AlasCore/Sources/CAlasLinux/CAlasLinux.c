#ifdef __linux__
#define _GNU_SOURCE
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

int alas_renameat2(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags) {
    return (int)syscall(SYS_renameat2, olddirfd, oldpath, newdirfd, newpath, flags);
}
#endif
