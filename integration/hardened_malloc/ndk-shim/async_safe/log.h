/*
 * Anvil NDK-standalone shim for AOSP's <async_safe/log.h>.
 *
 * Upstream hardened_malloc includes this header only under __ANDROID__
 * (integration/hardened_malloc: util.c calls async_safe_fatal() once, for
 * fatal allocator errors). In an AOSP tree the header and implementation
 * come from AOSP's libasyncsafe; the NDK sysroot does not ship them, which
 * is the one thing preventing a standalone `make CC=<$NDK-clang>` build.
 *
 * This shim implements the single call upstream makes, writing the message
 * to stderr (fd 2) before aborting. AOSP builds use the real libasyncsafe,
 * not this file; NDK-built artifacts log fatal allocator errors to stderr
 * instead of the Android log buffer. Shims are passed via -I, upstream
 * sources stay unmodified.
 */
#ifndef ANVIL_ASYNC_SAFE_LOG_SHIM_H
#define ANVIL_ASYNC_SAFE_LOG_SHIM_H

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

__attribute__((noreturn, format(printf, 1, 2)))
static inline void async_safe_fatal(const char *fmt, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    ssize_t written = write(2, buf, strnlen(buf, sizeof(buf)));
    (void)written;
    abort();
}

#endif /* ANVIL_ASYNC_SAFE_LOG_SHIM_H */
