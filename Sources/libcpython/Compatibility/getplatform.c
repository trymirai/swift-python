// Report the destination OS rather than the machine that generated the sources.
#include "abi.h"
#define PLATFORM CPYTHON_PLATFORM
#include "../src/Python/getplatform.c"
