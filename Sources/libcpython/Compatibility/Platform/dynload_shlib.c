// Use the same ABI suffix as sysconfig when finding external extension modules.
#include "abi.h"
#define SOABI CPYTHON_SOABI
#include "../../src/Python/dynload_shlib.c"
