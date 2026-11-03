#if !__has_include(<openssl/ssl.h>)
#error "OpenSSL headers are required. Enable the OpenSSL trait or supply headers for the target."
#else
// Use the system trust store for the upstream _ssl module on Apple platforms.
#ifdef __APPLE__
#include "system_trust.h"
#define SSL_CTX_set_default_verify_paths CPython_SetDefaultVerifyPaths
#endif
// CPython retains these deprecated OpenSSL APIs for Python compatibility.
#ifdef __clang__
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#endif
#include "../../src/Modules/_ssl.c"
#ifdef __clang__
#pragma clang diagnostic pop
#endif
#endif
