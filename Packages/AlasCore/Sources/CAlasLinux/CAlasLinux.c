#ifdef __linux__
#define _GNU_SOURCE
#include <sys/syscall.h>
#include <unistd.h>
#include "CAlasLinux.h"

int alas_renameat2(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags) {
    return (int)syscall(SYS_renameat2, olddirfd, oldpath, newdirfd, newpath, flags);
}
#endif
