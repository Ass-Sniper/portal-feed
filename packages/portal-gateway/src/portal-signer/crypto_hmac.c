#include "crypto_hmac.h"

#include <openssl/sha.h>
#include <openssl/hmac.h>
#include <openssl/evp.h>

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void bytes_to_hex_lower(const unsigned char *in, size_t in_len, char out_hex[65]) {
    static const char *hex = "0123456789abcdef";
    for (size_t i = 0; i < in_len; i++) {
        out_hex[i * 2]     = hex[(in[i] >> 4) & 0xF];
        out_hex[i * 2 + 1] = hex[in[i] & 0xF];
    }
    out_hex[in_len * 2] = '\0';
}

static void sha256_hex_lower(const unsigned char *data, size_t len, char out_hex[65]) {
    unsigned char hash[SHA256_DIGEST_LENGTH];
    if (!data) {
        data = (const unsigned char *)"";
        len = 0;
    }
    SHA256(data, len, hash);
    bytes_to_hex_lower(hash, SHA256_DIGEST_LENGTH, out_hex);
}

/* Read key material from a file. Treat as raw bytes of the trimmed first line (common for HMAC secrets). */
static int read_key_file(const char *path, unsigned char **out_key, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;

    char buf[4096];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    if (n == 0) return -2;

    buf[n] = '\0';

    /* Trim leading/trailing whitespace/newlines */
    size_t start = 0;
    while (start < n && isspace((unsigned char)buf[start])) start++;

    size_t end = n;
    while (end > start && isspace((unsigned char)buf[end - 1])) end--;

    size_t len = end - start;
    if (len == 0) return -3;

    unsigned char *key = (unsigned char *)malloc(len);
    if (!key) return -4;

    memcpy(key, buf + start, len);
    *out_key = key;
    *out_len = len;
    return 0;
}

static void gen_timestamp(char out[32]) {
    snprintf(out, 32, "%ld", (long)time(NULL));
}

/* Not cryptographically strong; good enough for replay token uniqueness in local signer. */
static void gen_nonce(char out[64]) {
    unsigned long r1 = (unsigned long)rand();
    unsigned long r2 = (unsigned long)rand();
    snprintf(out, 64, "%ld-%08lx%08lx", (long)time(NULL), r1, r2);
}

static char *build_canonical_v1(
    const char *ts,
    const char *nonce,
    const char *method,
    const char *path,
    const char *raw_query,
    const unsigned char *body,
    size_t body_len
) {
    char body_hash[65];
    sha256_hex_lower(body, body_len, body_hash);

    if (!raw_query) raw_query = "";

    /* length of: each field + '\n', plus final '\0' */
    size_t len =
        strlen(ts) + 1 +
        strlen(nonce) + 1 +
        strlen(method) + 1 +
        strlen(path) + 1 +
        strlen(raw_query) + 1 +
        strlen(body_hash) + 1;

    char *canonical = (char *)malloc(len + 1);
    if (!canonical) return NULL;

    snprintf(canonical, len + 1,
        "%s\n%s\n%s\n%s\n%s\n%s\n",
        ts, nonce, method, path, raw_query, body_hash
    );
    return canonical;
}

static int hmac_sha256_base64(
    const unsigned char *key, size_t key_len,
    const char *msg,
    char out_b64[128]
) {
    unsigned char mac[EVP_MAX_MD_SIZE];
    unsigned int mac_len = 0;

    if (!HMAC(EVP_sha256(), key, (int)key_len,
              (const unsigned char *)msg, (int)strlen(msg),
              mac, &mac_len) || mac_len == 0) {
        return -1;
    }

    /* base64 output length for mac_len bytes */
    int b64_len = 4 * ((mac_len + 2) / 3);
    if (b64_len + 1 > 128) return -2;

    EVP_EncodeBlock((unsigned char *)out_b64, mac, mac_len);
    out_b64[b64_len] = '\0';
    return 0;
}

static void split_uri(const char *uri, char *out_path, size_t out_path_sz, char *out_query, size_t out_query_sz) {
    if (!uri) {
        snprintf(out_path, out_path_sz, "/");
        if (out_query_sz) out_query[0] = '\0';
        return;
    }

    const char *q = strchr(uri, '?');
    if (!q) {
        snprintf(out_path, out_path_sz, "%s", uri);
        if (out_query_sz) out_query[0] = '\0';
        return;
    }

    size_t plen = (size_t)(q - uri);
    if (plen >= out_path_sz) plen = out_path_sz - 1;
    memcpy(out_path, uri, plen);
    out_path[plen] = '\0';

    snprintf(out_query, out_query_sz, "%s", q + 1);
}

int portal_sign_v1_hmac_sha256_base64(
    const char *key_file,
    const char *method,
    const char *path,
    const char *raw_query,
    const unsigned char *body,
    size_t body_len,
    portal_sig_t *out_sig
) {
    if (!key_file || !method || !path || !out_sig) return -1;

    unsigned char *key = NULL;
    size_t key_len = 0;
    int rc = read_key_file(key_file, &key, &key_len);
    if (rc != 0) return -2;

    gen_timestamp(out_sig->timestamp);
    gen_nonce(out_sig->nonce);

    char *canonical = build_canonical_v1(out_sig->timestamp, out_sig->nonce, method, path, raw_query, body, body_len);
    if (!canonical) {
        free(key);
        return -3;
    }

    rc = hmac_sha256_base64(key, key_len, canonical, out_sig->signature);

    free(canonical);
    free(key);
    return rc;
}

int portal_sign_v0_hmac_sha256(
    const char *key_file,
    const char *method,
    const char *uri,
    const char *body_hash_ignored,
    portal_sig_t *out_sig
) {
    (void)body_hash_ignored;

    char path[512];
    char query[512];
    split_uri(uri ? uri : "/", path, sizeof(path), query, sizeof(query));

    return portal_sign_v1_hmac_sha256_base64(
        key_file,
        method,
        path,
        query,
        (const unsigned char *)"",
        0,
        out_sig
    );
}