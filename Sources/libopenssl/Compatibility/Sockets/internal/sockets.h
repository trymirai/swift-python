#ifndef SWIFT_PYTHON_OPENSSL_SOCKETS_H
#define SWIFT_PYTHON_OPENSSL_SOCKETS_H

#include_next <internal/sockets.h>

/* A TLS read can send an alert after the peer closes. Report EPIPE to OpenSSL. */
#ifdef MSG_NOSIGNAL
#undef writesocket
#define writesocket(fd, buffer, size) send((fd), (buffer), (size), MSG_NOSIGNAL)
#endif

#endif
