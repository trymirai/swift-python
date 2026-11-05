// Apple provides libuuid in the SDK; Linux uses the Python fallback.
#ifdef __APPLE__
#include "../../src/Modules/_uuidmodule.c"
#endif
