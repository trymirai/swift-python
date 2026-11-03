// Keep sys.implementation and extension discovery aligned with the selected ABI.
#include "abi.h"
#define MULTIARCH CPYTHON_MULTIARCH
#define VPATH ""
#define ABIFLAGS ""
#include "../src/Python/sysmodule.c"
