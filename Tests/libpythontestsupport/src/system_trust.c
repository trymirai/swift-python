#include "pythontestsupport.h"

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && TARGET_OS_OSX
#include "../../../Sources/libcpython/Compatibility/tls/system_trust.h"
#include <Security/Security.h>
#include <stdbool.h>

static bool
rejects_wrong_hostname(X509_STORE_CTX *context, X509_STORE *store, X509 *certificate)
{
    // Even after Security trusts the root, OpenSSL must enforce the caller's hostname.
    X509_STORE_CTX_cleanup(context);
    return X509_STORE_CTX_init(context, store, certificate, NULL) == 1 &&
           X509_VERIFY_PARAM_set1_host(X509_STORE_CTX_get0_param(context), "invalid.test", 0) == 1 &&
           CPython_VerifySystemTrust(context, NULL) == 0 &&
           X509_STORE_CTX_get_error(context) == X509_V_ERR_HOSTNAME_MISMATCH;
}

static bool
checks_root(SecCertificateRef root)
{
    X509 *certificate = CPython_CopyX509Certificate(root);
    if (certificate == NULL) {
        return false;
    }

    X509_STORE *store = X509_STORE_new();
    X509_STORE_CTX *context = X509_STORE_CTX_new();

    bool initialized = store != NULL && context != NULL &&
                       X509_STORE_CTX_init(context, store, certificate, NULL) == 1;

    bool verified = initialized && CPython_VerifySystemTrust(context, NULL) == 1 &&
                    rejects_wrong_hostname(context, store, certificate);

    X509_STORE_CTX_free(context);
    X509_STORE_free(store);
    X509_free(certificate);
    return verified;
}

int
CPython_CheckSystemTrust(void)
{
    CFArrayRef roots = NULL;
    if (SecTrustCopyAnchorCertificates(&roots) != errSecSuccess || roots == NULL) {
        return -1;
    }

    int result = -1;
    CFIndex count = CFArrayGetCount(roots);
    for (CFIndex index = 0; index < count; index++) {
        SecCertificateRef root = (SecCertificateRef)CFArrayGetValueAtIndex(roots, index);
        if (checks_root(root)) {
            result = 0;
            break;
        }
    }
    CFRelease(roots);
    return result;
}
#else
int
CPython_CheckSystemTrust(void)
{
    return -1;
}
#endif
