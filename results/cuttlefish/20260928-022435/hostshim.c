/* Rootless cuttlefish host shim (see evidence notes):
 * 1. getgrnam_r("cvdnetwork") -> "docker" (member group), so assemble_cvd's
 *    chgrp succeeds without the cuttlefish-base deb.
 * 2. exec* of /usr/lib/cuttlefish-common/bin/capability_query.py -> /bin/true,
 *    so HostSupportsQemuCli() treats the deb-only probe as supported.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <grp.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <spawn.h>

static const char *kDebProbe = "/usr/lib/cuttlefish-common/bin/capability_query.py";

int getgrnam_r(const char *name, struct group *grp, char *buf, size_t buflen,
               struct group **result) {
    static int (*real)(const char *, struct group *, char *, size_t, struct group **);
    if (!real) real = dlsym(RTLD_NEXT, "getgrnam_r");
    if (name && strcmp(name, "cvdnetwork") == 0) name = "docker";
    return real(name, grp, buf, buflen, result);
}

int execve(const char *path, char *const argv[], char *const envp[]) {
    static int (*real)(const char *, char *const[], char *const[]);
    if (!real) real = dlsym(RTLD_NEXT, "execve");
    if (path && strcmp(path, kDebProbe) == 0) return real("/bin/true", argv, envp);
    return real(path, argv, envp);
}
int execv(const char *path, char *const argv[]) {
    static int (*real)(const char *, char *const[]);
    if (!real) real = dlsym(RTLD_NEXT, "execv");
    if (path && strcmp(path, kDebProbe) == 0) return real("/bin/true", argv);
    return real(path, argv);
}
int execvp(const char *file, char *const argv[]) {
    static int (*real)(const char *, char *const[]);
    if (!real) real = dlsym(RTLD_NEXT, "execvp");
    if (file && strcmp(file, kDebProbe) == 0) return real("/bin/true", argv);
    return real(file, argv);
}
int execvpe(const char *file, char *const argv[], char *const envp[]) {
    static int (*real)(const char *, char *const[], char *const[]);
    if (!real) real = dlsym(RTLD_NEXT, "execvpe");
    if (file && strcmp(file, kDebProbe) == 0) return real("/bin/true", argv, envp);
    return real(file, argv, envp);
}
int execveat(int dirfd, const char *path, char *const argv[], char *const envp[], int flags) {
    static int (*real)(int, const char *, char *const[], char *const[], int);
    if (!real) real = dlsym(RTLD_NEXT, "execveat");
    if (path && strcmp(path, kDebProbe) == 0) return real(dirfd, "/bin/true", argv, envp, flags);
    return real(dirfd, path, argv, envp, flags);
}
