/* Upstream emits AArch64 GNU property notes outside its architecture guard. */
#if defined(__aarch64__)
#include "../src/aarch64/sysv.S"
#endif
