/*
 * Copyright 2014-2025 The OpenSSL Project Authors. All Rights Reserved.
 *
 * Licensed under the Apache License 2.0 (the "License").  You may not use
 * this file except in compliance with the License.  You can obtain a copy
 * in the file LICENSE in the source distribution or at
 * https://www.openssl.org/source/license.html
 */

/* Reproducible metadata for the portable C source configuration. */
#ifndef SWIFT_PYTHON_LIBOPENSSL_BUILDINF_H
#define SWIFT_PYTHON_LIBOPENSSL_BUILDINF_H

#if defined(__APPLE__)
#define PLATFORM "platform: Apple, portable 64-bit C"
#elif defined(__linux__)
#define PLATFORM "platform: Linux, portable 64-bit C"
#endif
#define DATE "built on: reproducible source build"
static const char compiler_flags[] = "compiler: SwiftPM C toolchain";

#endif /* SWIFT_PYTHON_LIBOPENSSL_BUILDINF_H */
