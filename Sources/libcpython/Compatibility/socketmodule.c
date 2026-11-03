#ifdef __APPLE__
// Import inet_aton before CPython's weak pragma so Clang modules see the declaration.
#define __APPLE_USE_RFC_3542 1
#include "pyconfig.h"
#include <arpa/inet.h>
#endif
#include "../src/Modules/socketmodule.c"
