#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <openssl/evp.h>
#include <openssl/sha.h>

#include "chat1_ffi.h"

#define CHAT1_MAX_AUTH_KEYS 8192

typedef struct {
    int in_use;
    char author_id[CHAT1_SHA256_HEX_LEN + 1];
    char pubkey_b64[CHAT1_PUBKEY_B64_LEN + 1];
} chat1_auth_slot;

static chat1_auth_slot g_slots[CHAT1_MAX_AUTH_KEYS];
static pthread_mutex_t g_auth_mu = PTHREAD_MUTEX_INITIALIZER;

static int b64url_decode(const char *in, uint8_t *out, size_t out_cap, size_t *out_len) {
    size_t n = strlen(in);
    char tmp[128];
    uint8_t buf[128];
    int decoded;
    if (n + 4 >= sizeof(tmp)) return -1;
    for (size_t i = 0; i < n; ++i) {
        char c = in[i];
        tmp[i] = (c == '-') ? '+' : (c == '_') ? '/' : c;
    }
    size_t pad = (4 - (n % 4)) % 4;
    for (size_t i = 0; i < pad; ++i) tmp[n + i] = '=';
    tmp[n + pad] = '\0';
    decoded = EVP_DecodeBlock(buf, (const unsigned char *)tmp, (int)(n + pad));
    if (decoded < 0) return -1;
    while (pad > 0 && decoded > 0 && buf[decoded - 1] == 0) {
        decoded--;
        pad--;
    }
    if ((size_t)decoded > out_cap) return -1;
    memcpy(out, buf, (size_t)decoded);
    *out_len = (size_t)decoded;
    return 0;
}

void chat1_auth_keys_init(void) {
    pthread_mutex_lock(&g_auth_mu);
    memset(g_slots, 0, sizeof(g_slots));
    pthread_mutex_unlock(&g_auth_mu);
}

int chat1_auth_key_put(const char *author_id_hex, const char *pubkey_b64) {
    if (!author_id_hex || !pubkey_b64) return CHAT1_ROUTE_ERR_INVALID;
    pthread_mutex_lock(&g_auth_mu);
    for (uint32_t i = 0; i < CHAT1_MAX_AUTH_KEYS; ++i) {
        if (g_slots[i].in_use && strcmp(g_slots[i].author_id, author_id_hex) == 0) {
            strncpy(g_slots[i].pubkey_b64, pubkey_b64, CHAT1_PUBKEY_B64_LEN);
            g_slots[i].pubkey_b64[CHAT1_PUBKEY_B64_LEN] = '\0';
            pthread_mutex_unlock(&g_auth_mu);
            return CHAT1_ROUTE_OK;
        }
    }
    for (uint32_t i = 0; i < CHAT1_MAX_AUTH_KEYS; ++i) {
        if (!g_slots[i].in_use) {
            g_slots[i].in_use = 1;
            strncpy(g_slots[i].author_id, author_id_hex, CHAT1_SHA256_HEX_LEN);
            g_slots[i].author_id[CHAT1_SHA256_HEX_LEN] = '\0';
            strncpy(g_slots[i].pubkey_b64, pubkey_b64, CHAT1_PUBKEY_B64_LEN);
            g_slots[i].pubkey_b64[CHAT1_PUBKEY_B64_LEN] = '\0';
            pthread_mutex_unlock(&g_auth_mu);
            return CHAT1_ROUTE_OK;
        }
    }
    pthread_mutex_unlock(&g_auth_mu);
    return CHAT1_ROUTE_ERR_INVALID;
}

int chat1_auth_key_get(const char *author_id_hex, char *pubkey_b64_out, uint32_t out_len) {
    if (!author_id_hex || !pubkey_b64_out || out_len < CHAT1_PUBKEY_B64_LEN + 1) return CHAT1_ROUTE_ERR_INVALID;
    pthread_mutex_lock(&g_auth_mu);
    for (uint32_t i = 0; i < CHAT1_MAX_AUTH_KEYS; ++i) {
        if (g_slots[i].in_use && strcmp(g_slots[i].author_id, author_id_hex) == 0) {
            strncpy(pubkey_b64_out, g_slots[i].pubkey_b64, out_len - 1);
            pubkey_b64_out[out_len - 1] = '\0';
            pthread_mutex_unlock(&g_auth_mu);
            return CHAT1_ROUTE_OK;
        }
    }
    pthread_mutex_unlock(&g_auth_mu);
    return CHAT1_ROUTE_ERR_INVALID;
}

int chat1_verify_msg_signature(const chat1_ingress_event *ev) {
    char pubkey_b64[CHAT1_PUBKEY_B64_LEN + 1];
    uint8_t pubkey_raw[64], sig_raw[128];
    size_t pubkey_len = 0, sig_len = 0;
    char canonical[CHAT1_WIRE_MAX_LINE + 128];
    int canon_len;
    unsigned char hash[SHA256_DIGEST_LENGTH];
    char hash_hex[CHAT1_SHA256_HEX_LEN + 1];
    EVP_PKEY *pkey = NULL;
    EVP_MD_CTX *mdctx = NULL;
    int ok = 0;

    if (!ev) return CHAT1_ROUTE_ERR_INVALID;
    if (chat1_auth_key_get(ev->author_id, pubkey_b64, sizeof(pubkey_b64)) != CHAT1_ROUTE_OK) return CHAT1_ROUTE_ERR_INVALID;
    if (b64url_decode(pubkey_b64, pubkey_raw, sizeof(pubkey_raw), &pubkey_len) != 0 || pubkey_len != 32) return CHAT1_ROUTE_ERR_INVALID;
    if (b64url_decode(ev->sig_b64, sig_raw, sizeof(sig_raw), &sig_len) != 0 || sig_len != 64) return CHAT1_ROUTE_ERR_INVALID;

    canon_len = snprintf(canonical, sizeof(canonical), "msg\n%s\n%s\n%llu\n%s\n",
                         ev->room_id, ev->author_id, (unsigned long long)ev->ts_ms, ev->body_b64);
    if (canon_len <= 0 || (size_t)canon_len >= sizeof(canonical)) return CHAT1_ROUTE_ERR_INVALID;

    SHA256((const unsigned char *)canonical, (size_t)canon_len, hash);
    for (int i = 0; i < SHA256_DIGEST_LENGTH; ++i) {
        static const char *hx = "0123456789abcdef";
        hash_hex[i * 2] = hx[(hash[i] >> 4) & 0xF];
        hash_hex[i * 2 + 1] = hx[hash[i] & 0xF];
    }
    hash_hex[CHAT1_SHA256_HEX_LEN] = '\0';
    if (strncmp(hash_hex, ev->msg_id, CHAT1_SHA256_HEX_LEN) != 0) return CHAT1_ROUTE_ERR_INVALID;

    pkey = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, NULL, pubkey_raw, pubkey_len);
    if (!pkey) goto done;
    mdctx = EVP_MD_CTX_new();
    if (!mdctx) goto done;
    if (EVP_DigestVerifyInit(mdctx, NULL, NULL, NULL, pkey) != 1) goto done;
    if (EVP_DigestVerify(mdctx, sig_raw, sig_len, (const unsigned char *)canonical, (size_t)canon_len) != 1) goto done;
    ok = 1;
done:
    if (mdctx) EVP_MD_CTX_free(mdctx);
    if (pkey) EVP_PKEY_free(pkey);
    return ok ? CHAT1_ROUTE_OK : CHAT1_ROUTE_ERR_INVALID;
}

int chat1_verify_attach_signature(const chat1_attach_event *ev) {
    char pubkey_b64[CHAT1_PUBKEY_B64_LEN + 1];
    uint8_t pubkey_raw[64], sig_raw[128];
    size_t pubkey_len = 0, sig_len = 0;
    char canonical[CHAT1_WIRE_MAX_LINE + 128];
    int canon_len;
    unsigned char hash[SHA256_DIGEST_LENGTH];
    char hash_hex[CHAT1_SHA256_HEX_LEN + 1];
    EVP_PKEY *pkey = NULL;
    EVP_MD_CTX *mdctx = NULL;
    int ok = 0;

    if (!ev) return CHAT1_ROUTE_ERR_INVALID;
    if (chat1_auth_key_get(ev->author_id, pubkey_b64, sizeof(pubkey_b64)) != CHAT1_ROUTE_OK) return CHAT1_ROUTE_ERR_INVALID;
    if (b64url_decode(pubkey_b64, pubkey_raw, sizeof(pubkey_raw), &pubkey_len) != 0 || pubkey_len != 32) return CHAT1_ROUTE_ERR_INVALID;
    if (b64url_decode(ev->sig_b64, sig_raw, sizeof(sig_raw), &sig_len) != 0 || sig_len != 64) return CHAT1_ROUTE_ERR_INVALID;

    canon_len = snprintf(canonical, sizeof(canonical),
                         "attach\n%s\n%s\n%llu\n%s\n%llu\n%s\n%s\n",
                         ev->room_id,
                         ev->author_id,
                         (unsigned long long)ev->ts_ms,
                         ev->cid_hex,
                         (unsigned long long)ev->byte_len,
                         ev->mime,
                         ev->filename);
    if (canon_len <= 0 || (size_t)canon_len >= sizeof(canonical)) return CHAT1_ROUTE_ERR_INVALID;

    SHA256((const unsigned char *)canonical, (size_t)canon_len, hash);
    for (int i = 0; i < SHA256_DIGEST_LENGTH; ++i) {
        static const char *hx = "0123456789abcdef";
        hash_hex[i * 2] = hx[(hash[i] >> 4) & 0xF];
        hash_hex[i * 2 + 1] = hx[hash[i] & 0xF];
    }
    hash_hex[CHAT1_SHA256_HEX_LEN] = '\0';
    if (strncmp(hash_hex, ev->msg_id, CHAT1_SHA256_HEX_LEN) != 0) return CHAT1_ROUTE_ERR_INVALID;

    pkey = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, NULL, pubkey_raw, pubkey_len);
    if (!pkey) goto done_attach;
    mdctx = EVP_MD_CTX_new();
    if (!mdctx) goto done_attach;
    if (EVP_DigestVerifyInit(mdctx, NULL, NULL, NULL, pkey) != 1) goto done_attach;
    if (EVP_DigestVerify(mdctx, sig_raw, sig_len, (const unsigned char *)canonical, (size_t)canon_len) != 1) goto done_attach;
    ok = 1;
done_attach:
    if (mdctx) EVP_MD_CTX_free(mdctx);
    if (pkey) EVP_PKEY_free(pkey);
    return ok ? CHAT1_ROUTE_OK : CHAT1_ROUTE_ERR_INVALID;
}
