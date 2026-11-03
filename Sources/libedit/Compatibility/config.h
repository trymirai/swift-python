#ifndef SWIFT_PYTHON_LIBEDIT_CONFIG_H
#define SWIFT_PYTHON_LIBEDIT_CONFIG_H

#include <stddef.h>
#include <stdint.h>

/* Clang with musl can omit this macro even though wchar_t is UTF-32. */
#ifndef __STDC_ISO_10646__
#define __STDC_ISO_10646__ 201103L
_Static_assert(
    sizeof(wchar_t) == 4 && L'\U0001F600' == 0x1F600,
    "libedit requires UTF-32 wchar_t"
);
#endif

/* Reuse the limit from stdint.h when libedit's fallback checks for it. */
#ifdef SIZE_MAX
#define HAVE_SIZE_MAX 1
#endif

#include "../Generated/config.h"

#endif /* SWIFT_PYTHON_LIBEDIT_CONFIG_H */
