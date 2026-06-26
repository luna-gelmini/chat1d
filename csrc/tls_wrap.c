#include <openssl/err.h>
#include <openssl/ssl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static SSL_CTX *g_server_ctx = NULL;

int chat1_tls_init(void) {
    SSL_library_init();
    SSL_load_error_strings();
    if (OPENSSL_init_ssl(0, NULL) != 1) {
        return -1;
    }
    return 0;
}

int chat1_tls_server_config(const char *cert_path, const char *key_path) {
    SSL_CTX *ctx;

    if (!cert_path || !key_path || !*cert_path || !*key_path) {
        return 0;
    }

    ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx) {
        return -1;
    }

    if (SSL_CTX_use_certificate_file(ctx, cert_path, SSL_FILETYPE_PEM) != 1) {
        SSL_CTX_free(ctx);
        return -1;
    }

    if (SSL_CTX_use_PrivateKey_file(ctx, key_path, SSL_FILETYPE_PEM) != 1) {
        SSL_CTX_free(ctx);
        return -1;
    }

    if (g_server_ctx) {
        SSL_CTX_free(g_server_ctx);
    }
    g_server_ctx = ctx;
    return 0;
}

int chat1_tls_server_config_from_env(void) {
    const char *cert = getenv("CHAT1_TLS_CERT");
    const char *key = getenv("CHAT1_TLS_KEY");
    if ((!cert || !*cert) && (!key || !*key)) {
        return 0;
    }
    if (!cert || !*cert || !key || !*key) {
        return -1;
    }
    return chat1_tls_server_config(cert, key);
}

int chat1_tls_accept_fd(int fd, void **tls_out) {
    SSL *ssl;

    if (!tls_out) {
        return -1;
    }

    *tls_out = NULL;
    if (!g_server_ctx) {
        return 0;
    }

    ssl = SSL_new(g_server_ctx);
    if (!ssl) {
        return -1;
    }

    if (SSL_set_fd(ssl, fd) != 1) {
        SSL_free(ssl);
        return -1;
    }

    if (SSL_accept(ssl) != 1) {
        SSL_free(ssl);
        return -1;
    }

    *tls_out = ssl;
    return 0;
}

int chat1_tls_server_enabled(void) {
    return g_server_ctx != NULL;
}

ssize_t chat1_tls_read(void *tls_ctx, int fd, void *buf, size_t len) {
    if (tls_ctx) {
        return (ssize_t)SSL_read((SSL *)tls_ctx, buf, (int)len);
    }
    return read(fd, buf, len);
}

ssize_t chat1_tls_write(void *tls_ctx, int fd, const void *buf, size_t len) {
    if (tls_ctx) {
        return (ssize_t)SSL_write((SSL *)tls_ctx, buf, (int)len);
    }
    return write(fd, buf, len);
}

void chat1_tls_close(void *tls_ctx) {
    if (!tls_ctx) {
        return;
    }
    SSL_shutdown((SSL *)tls_ctx);
    SSL_free((SSL *)tls_ctx);
}
