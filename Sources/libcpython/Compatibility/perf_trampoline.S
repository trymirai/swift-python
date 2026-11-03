#include "pyconfig.h"

#ifdef PY_HAVE_PERF_TRAMPOLINE
#if defined(__aarch64__)
#include "../src/Python/asm_trampoline_aarch64.S"
#elif defined(__x86_64__)
#include "../src/Python/asm_trampoline_x86_64.S"
#endif
#endif
