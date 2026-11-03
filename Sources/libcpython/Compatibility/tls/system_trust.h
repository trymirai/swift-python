// Trust policy shared by the SSL adapter and its package-internal integration tests.
#ifndef SWIFT_PYTHON_LIBCPYTHON_SYSTEM_TRUST_H
#define SWIFT_PYTHON_LIBCPYTHON_SYSTEM_TRUST_H

#ifdef __APPLE__
#include <openssl/ssl.h>

// Explicit SSL_CERT_FILE/SSL_CERT_DIR settings keep OpenSSL's normal behavior.
int CPython_SetDefaultVerifyPaths(SSL_CTX *context);

/* The context is borrowed for one verification. Reinitialize it before reuse. */
int CPython_VerifySystemTrust(X509_STORE_CTX *context, void *argument);
#endif

#endif /* SWIFT_PYTHON_LIBCPYTHON_SYSTEM_TRUST_H */
