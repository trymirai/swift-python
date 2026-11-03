#include "pythontestsupport.h"

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && TARGET_OS_OSX
#include "../../../Sources/libcpython/Compatibility/tls/system_trust.h"
#include <Security/Security.h>

int
CPython_CheckSystemTrust(void)
{
    CFArrayRef roots = NULL;
    if (SecTrustCopyAnchorCertificates(&roots) != errSecSuccess || roots == NULL) {
        return -1;
    }
    int result = -1;
    for (CFIndex index = 0; index < CFArrayGetCount(roots); index++) {
        SecCertificateRef root = (SecCertificateRef)CFArrayGetValueAtIndex(roots, index);
        CFDataRef data = SecCertificateCopyData(root);
        if (data == NULL) {
            continue;
        }
        const unsigned char *bytes = CFDataGetBytePtr(data);
        X509 *certificate = d2i_X509(NULL, &bytes, CFDataGetLength(data));
        CFRelease(data);
        X509_STORE *store = X509_STORE_new();
        X509_STORE_CTX *context = X509_STORE_CTX_new();
        if (certificate != NULL && store != NULL && context != NULL &&
            X509_STORE_CTX_init(context, store, certificate, NULL) == 1 &&
            CPython_VerifySystemTrust(context, NULL) == 1) {
            // Even after Security trusts the root, OpenSSL must enforce caller hostname constraints.
            X509_STORE_CTX_cleanup(context);
            if (X509_STORE_CTX_init(context, store, certificate, NULL) == 1 &&
                X509_VERIFY_PARAM_set1_host(X509_STORE_CTX_get0_param(context),
                                            "invalid.test", 0) == 1 &&
                CPython_VerifySystemTrust(context, NULL) == 0 &&
                X509_STORE_CTX_get_error(context) == X509_V_ERR_HOSTNAME_MISMATCH) {
                result = 0;
            }
        }
        X509_STORE_CTX_free(context);
        X509_STORE_free(store);
        X509_free(certificate);
        if (result == 0) {
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
