#include "pythontestsupport.h"

#ifdef SWIFT_PYTHON_BUNDLED_OPENSSL
#include <openssl/crypto.h>
#include <stdlib.h>

static void
fail_on_cleanup(void)
{
    _Exit(EXIT_FAILURE);
}

int
CPython_FailOnOpenSSLCleanup(void)
{
    return OPENSSL_atexit(fail_on_cleanup);
}
#endif
