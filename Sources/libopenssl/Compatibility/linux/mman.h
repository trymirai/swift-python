/* Modern libc SDKs expose these Linux flags without shipping kernel headers. */
#ifndef SWIFT_PYTHON_LIBOPENSSL_LINUX_MMAN_H
#define SWIFT_PYTHON_LIBOPENSSL_LINUX_MMAN_H

#if __has_include_next(<linux/mman.h>)
#include_next <linux/mman.h>
#else
#include <sys/mman.h>
#endif

#endif /* SWIFT_PYTHON_LIBOPENSSL_LINUX_MMAN_H */
