#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Signature fields returned to callers.
 *
 * NOTE: buffers are sized for typical usage:
 * - timestamp: unix seconds string
 * - nonce: uuid-ish string
 * - signature: Base64(HMAC-SHA256(...))
 */
typedef struct {
    char timestamp[32];
    char nonce[64];
    char signature[128];
} portal_sig_t;

/**
 * v1 canonical string (must match Go implementation exactly):
 *
 *   canonical =
 *     timestamp + "\n" +
 *     nonce + "\n" +
 *     method + "\n" +
 *     path + "\n" +
 *     raw_query + "\n" +
 *     sha256_hex(body) + "\n"
 *
 * - raw_query may be empty string.
 * - body may be NULL when body_len == 0 (treated as empty).
 *
 * Returns 0 on success.
 */
int portal_sign_v1_hmac_sha256_base64(
    const char *key_file,
    const char *method,
    const char *path,
    const char *raw_query,
    const unsigned char *body,
    size_t body_len,
    portal_sig_t *out_sig
);

/**
 * v0 legacy API kept for compatibility with existing code.
 * It is implemented as v1 with:
 *   - path/raw_query parsed from `uri`
 *   - body = empty
 * The `body_hash` parameter is ignored (kept only for old callers).
 */
int portal_sign_v0_hmac_sha256(
    const char *key_file,
    const char *method,
    const char *uri,
    const char *body_hash_ignored,
    portal_sig_t *out_sig
);

#ifdef __cplusplus
}
#endif
