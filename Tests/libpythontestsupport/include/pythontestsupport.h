#ifndef SWIFT_PYTHON_LIBPYTHONTESTSUPPORT_H
#define SWIFT_PYTHON_LIBPYTHONTESTSUPPORT_H

int CPython_CheckEmbedding(const char *code);

// macOS-only integration check against the current system root store.
int CPython_CheckSystemTrust(void);

#endif /* SWIFT_PYTHON_LIBPYTHONTESTSUPPORT_H */
