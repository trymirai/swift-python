#ifdef __APPLE__
#include "system_trust.h"

#include <stdbool.h>
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

// Encode directly into CF-owned storage; no temporary DER buffer crosses the FFI boundary.
static SecCertificateRef
copy_sec_certificate(X509 *certificate)
{
    int size = i2d_X509(certificate, NULL);
    if (size <= 0) {
        return NULL;
    }

    CFMutableDataRef data = CFDataCreateMutable(NULL, size);
    if (data == NULL) {
        return NULL;
    }
    CFDataSetLength(data, size);
    unsigned char *bytes = CFDataGetMutableBytePtr(data);
    SecCertificateRef result = NULL;
    if (i2d_X509(certificate, &bytes) == size) {
        result = SecCertificateCreateWithData(NULL, data);
    }
    CFRelease(data);
    return result;
}

static int
append_sec_certificate(CFMutableArrayRef certificates, X509 *certificate)
{
    SecCertificateRef value = copy_sec_certificate(certificate);
    if (value == NULL) {
        return 0;
    }
    CFArrayAppendValue(certificates, value);
    CFRelease(value);
    return 1;
}

static SecTrustRef
create_system_trust(X509_STORE_CTX *context, X509 *leaf)
{
    CFMutableArrayRef certificates = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (certificates == NULL) {
        return NULL;
    }
    if (!append_sec_certificate(certificates, leaf)) {
        CFRelease(certificates);
        return NULL;
    }

    STACK_OF(X509) *untrusted = X509_STORE_CTX_get0_untrusted(context);
    for (int index = 0; index < sk_X509_num(untrusted); index++) {
        // A TLS peer's untrusted chain can include the same leaf.
        X509 *certificate = sk_X509_value(untrusted, index);
        if (certificate != leaf && !append_sec_certificate(certificates, certificate)) {
            CFRelease(certificates);
            return NULL;
        }
    }

    SSL *connection = X509_STORE_CTX_get_ex_data(context, SSL_get_ex_data_X509_STORE_CTX_idx());
    // OpenSSL still checks hostnames and its configured verification flags below.
    SecPolicyRef policy = connection == NULL ? SecPolicyCreateBasicX509()
                                             : SecPolicyCreateSSL(!SSL_is_server(connection), NULL);
    SecTrustRef trust = NULL;
    if (policy != NULL) {
        if (SecTrustCreateWithCertificates(certificates, policy, &trust) != errSecSuccess &&
            trust != NULL) {
            CFRelease(trust);
            trust = NULL;
        }
        CFRelease(policy);
    }
    CFRelease(certificates);
    return trust;
}

static X509 *
copy_x509_certificate(SecCertificateRef certificate)
{
    CFDataRef data = SecCertificateCopyData(certificate);
    if (data == NULL) {
        return NULL;
    }
    const unsigned char *bytes = CFDataGetBytePtr(data);
    X509 *result = d2i_X509(NULL, &bytes, CFDataGetLength(data));
    CFRelease(data);
    return result;
}

static STACK_OF(X509) * copy_x509_chain(CFArrayRef certificates, CFIndex first, CFIndex end)
{
    STACK_OF(X509) *result = sk_X509_new_null();
    if (result == NULL) {
        return NULL;
    }
    for (CFIndex index = first; index < end; index++) {
        X509 *certificate =
            copy_x509_certificate((SecCertificateRef)CFArrayGetValueAtIndex(certificates, index));
        if (certificate == NULL || !sk_X509_push(result, certificate)) {
            X509_free(certificate);
            sk_X509_pop_free(result, X509_free);
            return NULL;
        }
    }
    return result;
}

int
CPython_VerifySystemTrust(X509_STORE_CTX *context, void *argument)
{
    (void)argument;
    X509 *leaf = X509_STORE_CTX_get0_cert(context);
    if (leaf == NULL) {
        return X509_verify_cert(context);
    }

    SecTrustRef trust = create_system_trust(context, leaf);
    if (trust == NULL) {
        X509_STORE_CTX_set_error(context, X509_V_ERR_UNSPECIFIED);
        return 0;
    }

    // Verification must not introduce hidden network requests. The peer chain and system cache suffice.
    OSStatus status = SecTrustSetNetworkFetchAllowed(trust, false);
    X509_VERIFY_PARAM *parameters = X509_STORE_CTX_get0_param(context);
    if (status == errSecSuccess &&
        (X509_VERIFY_PARAM_get_flags(parameters) & X509_V_FLAG_USE_CHECK_TIME) != 0) {
        CFAbsoluteTime time = (CFAbsoluteTime)X509_VERIFY_PARAM_get_time(parameters) -
                              kCFAbsoluteTimeIntervalSince1970;
        CFDateRef date = CFDateCreate(NULL, time);
        if (date == NULL) {
            CFRelease(trust);
            X509_STORE_CTX_set_error(context, X509_V_ERR_OUT_OF_MEM);
            return 0;
        }
        status = SecTrustSetVerifyDate(trust, date);
        CFRelease(date);
    }

    CFArrayRef chain = NULL;
    if (status == errSecSuccess && SecTrustEvaluateWithError(trust, NULL)) {
        chain = SecTrustCopyCertificateChain(trust);
    }
    CFRelease(trust);
    if (chain == NULL || CFArrayGetCount(chain) == 0) {
        if (chain != NULL) {
            CFRelease(chain);
        }
        // Only explicitly loaded CAs live in this store; Apple's roots are never copied into it.
        return X509_verify_cert(context);
    }

    CFIndex count = CFArrayGetCount(chain);
    STACK_OF(X509) *anchors = copy_x509_chain(chain, count - 1, count);
    STACK_OF(X509) *intermediates = copy_x509_chain(chain, 1, count - 1);
    CFRelease(chain);
    if (anchors == NULL || intermediates == NULL) {
        sk_X509_pop_free(anchors, X509_free);
        sk_X509_pop_free(intermediates, X509_free);
        X509_STORE_CTX_set_error(context, X509_V_ERR_OUT_OF_MEM);
        return 0;
    }

    /* Security chooses the trusted path. OpenSSL enforces the caller's verification parameters.
     * This context is used for one verification and retains the verified certificates. */
    STACK_OF(X509) *original = X509_STORE_CTX_get0_untrusted(context);
    X509_STORE_CTX_set0_untrusted(context, intermediates);
    X509_STORE_CTX_set0_trusted_stack(context, anchors);
    int result = X509_verify_cert(context);
    X509_STORE_CTX_set0_trusted_stack(context, NULL);
    X509_STORE_CTX_set0_untrusted(context, original);
    sk_X509_pop_free(intermediates, X509_free);
    sk_X509_pop_free(anchors, X509_free);
    return result;
}

int
CPython_SetDefaultVerifyPaths(SSL_CTX *context)
{
    SSL_CTX_set_cert_verify_callback(context, NULL, NULL);
    if (getenv(X509_get_default_cert_file_env()) == NULL &&
        getenv(X509_get_default_cert_dir_env()) == NULL) {
        SSL_CTX_set_cert_verify_callback(context, CPython_VerifySystemTrust, NULL);
        return 1;
    }
    return SSL_CTX_set_default_verify_paths(context);
}
#endif
