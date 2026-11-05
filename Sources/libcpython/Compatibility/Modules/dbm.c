// Use SDK NDBM on Apple; SQLite and the Python fallback remain portable.
#ifdef __APPLE__
#define USE_NDBM 1
#include "../../src/Modules/_dbmmodule.c"
#endif
