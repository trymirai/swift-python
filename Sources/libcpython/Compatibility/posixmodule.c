// The Static Linux SDK's limits.h omits these xattr limits.
#ifdef __linux__
#include <linux/limits.h>
#ifndef XATTR_SIZE_MAX
#define XATTR_SIZE_MAX 65536
#endif
#ifndef XATTR_LIST_MAX
#define XATTR_LIST_MAX 65536
#endif
#endif
#include "../src/Modules/posixmodule.c"
