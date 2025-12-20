#include "signer.h"
#include "crypto_hmac.h"

#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAX_LINE 1024
#define MAX_BODY (64 * 1024)

static ssize_t read_line(int fd, char *buf, size_t cap) {
    size_t n = 0;
    while (n + 1 < cap) {
        char c;
        ssize_t r = read(fd, &c, 1);
        if (r == 0) break;
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        buf[n++] = c;
        if (c == '\n') break;
    }
    buf[n] = '\0';
    return (ssize_t)n;
}

static void rstrip_crlf(char *s) {
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r')) {
        s[n - 1] = '\0';
        n--;
    }
}

static void http_reply(int fd, int code, const char *msg) {
    char buf[256];
    int n = snprintf(buf, sizeof(buf),
        "HTTP/1.1 %d %s\r\n"
        "Content-Length: 0\r\n"
        "\r\n",
        code, msg ? msg : "");
    (void)write(fd, buf, (size_t)n);
}

static void http_reply_json(int fd, int code, const char *json) {
    if (!json) json = "{}";
    char hdr[256];
    int body_len = (int)strlen(json);
    int n = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %d OK\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "\r\n",
        code, body_len);
    (void)write(fd, hdr, (size_t)n);
    (void)write(fd, json, (size_t)body_len);
}

static int parse_request_line(const char *line, char method[16], char path[512]) {
    /* "METHOD SP PATH SP HTTP/1.1" */
    if (sscanf(line, "%15s %511s", method, path) != 2) return -1;
    return 0;
}

static int header_get_int(const char *value, int *out) {
    if (!value || !*value) return -1;
    char *end = NULL;
    long v = strtol(value, &end, 10);
    if (end == value) return -1;
    *out = (int)v;
    return 0;
}

/* Minimal JSON string extractor: {"key":"value"} (handles basic escapes \" and \\) */
static int json_get_string(const char *json, const char *key, char *out, size_t out_sz) {
    if (!json || !key || !out || out_sz == 0) return -1;

    char pat[128];
    snprintf(pat, sizeof(pat), "\"%s\"", key);

    const char *p = strstr(json, pat);
    if (!p) return -2;
    p += strlen(pat);

    /* skip whitespace and ':' */
    while (*p && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
    if (*p != ':') return -3;
    p++;
    while (*p && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;

    if (*p != '"') return -4;
    p++;

    size_t n = 0;
    while (*p && n + 1 < out_sz) {
        if (*p == '"') break;
        if (*p == '\\') {
            p++;
            if (!*p) break;
            /* handle \" and \\ and \/ and \n \r \t minimally */
            char c = *p;
            switch (c) {
                case '"': out[n++] = '"'; break;
                case '\\': out[n++] = '\\'; break;
                case '/': out[n++] = '/'; break;
                case 'n': out[n++] = '\n'; break;
                case 'r': out[n++] = '\r'; break;
                case 't': out[n++] = '\t'; break;
                default:
                    /* unsupported escape, copy as-is */
                    out[n++] = c;
                    break;
            }
            p++;
            continue;
        }
        out[n++] = *p++;
    }

    out[n] = '\0';
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

/* Very small controller verify call:
 * POST cfg->controller_path to cfg->controller_addr:cfg->controller_port
 * with JSON body containing original request + security fields.
 *
 * Controller returns 2xx/204 for allow; otherwise deny.
 */
static int controller_verify(
    const signer_config_t *cfg,
    const char *orig_method,
    const char *orig_uri,
    const portal_sig_t *sig
) {
    if (!cfg ||
        cfg->controller_addr[0] == '\0' ||
        cfg->controller_path[0] == '\0') {
        return -1;
    }

    char body[1024];
    int blen = snprintf(body, sizeof(body),
        "{"
          "\"method\":\"%s\","
          "\"uri\":\"%s\","
          "\"security\":{"
            "\"kid\":\"%s\","
            "\"timestamp\":\"%s\","
            "\"nonce\":\"%s\","
            "\"signature\":\"%s\""
          "}"
        "}",
        orig_method ? orig_method : "",
        orig_uri ? orig_uri : "",
        "v1",
        sig->timestamp,
        sig->nonce,
        sig->signature
    );
    if (blen <= 0 || blen >= (int)sizeof(body)) return -2;

    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -3;

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(cfg->controller_port);
    if (inet_pton(AF_INET, cfg->controller_addr, &sa.sin_addr) != 1) {
        close(s);
        return -4;
    }

    if (connect(s, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        close(s);
        return -5;
    }

    char req[2048];
    int rlen = snprintf(req, sizeof(req),
        "POST %s HTTP/1.1\r\n"
        "Host: %s:%d\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n"
        "\r\n"
        "%s",
        cfg->controller_path,
        cfg->controller_addr,
        cfg->controller_port,
        blen,
        body
    );
    if (rlen <= 0 || rlen >= (int)sizeof(req)) {
        close(s);
        return -6;
    }

    if (write(s, req, (size_t)rlen) != rlen) {
        close(s);
        return -7;
    }

    /* Read status line */
    char line[MAX_LINE];
    ssize_t n = read_line(s, line, sizeof(line));
    close(s);
    if (n <= 0) return -8;

    /* HTTP/1.1 204 No Content */
    int code = 0;
    if (sscanf(line, "HTTP/%*s %d", &code) != 1) return -9;

    if (code >= 200 && code < 300) return 0;
    return -10;
}

static void handle_sign_endpoint(int cfd, const signer_config_t *cfg, const char *req_body, size_t req_body_len) {
    (void)req_body_len;

    /* Parse JSON input */
    char method[16] = {0};
    char path[512] = {0};
    char raw_query[512] = {0};
    char body_str[MAX_BODY] = {0};

    if (json_get_string(req_body, "method", method, sizeof(method)) != 0 ||
        json_get_string(req_body, "path", path, sizeof(path)) != 0) {
        http_reply(cfd, 400, "Bad Request");
        return;
    }
    /* raw_query and body may be empty */
    if (json_get_string(req_body, "raw_query", raw_query, sizeof(raw_query)) != 0) {
        raw_query[0] = '\0';
    }
    if (json_get_string(req_body, "body", body_str, sizeof(body_str)) != 0) {
        body_str[0] = '\0';
    }

    portal_sig_t sig;
    memset(&sig, 0, sizeof(sig));

    if (portal_sign_v1_hmac_sha256_base64(
            cfg->key_file,
            method,
            path,
            raw_query,
            (const unsigned char *)body_str,
            strlen(body_str),
            &sig) != 0) {
        http_reply(cfd, 500, "Internal Server Error");
        return;
    }

    char resp[512];
    snprintf(resp, sizeof(resp),
        "{"
          "\"kid\":\"%s\","
          "\"timestamp\":\"%s\","
          "\"nonce\":\"%s\","
          "\"signature\":\"%s\""
        "}",
        "v1",
        sig.timestamp,
        sig.nonce,
        sig.signature
    );

    http_reply_json(cfd, 200, resp);
}

void portal_signer_handle_client(int cfd, const signer_config_t *cfg) {
    char line[MAX_LINE];

    /* ---- Read request line ---- */
    ssize_t n = read_line(cfd, line, sizeof(line));
    if (n <= 0) return;
    rstrip_crlf(line);

    char req_method[16] = {0};
    char req_path[512] = {0};
    if (parse_request_line(line, req_method, req_path) != 0) {
        http_reply(cfd, 400, "Bad Request");
        return;
    }

    /* ---- Read headers ---- */
    char orig_method[64] = {0};
    char orig_uri[512] = {0};
    int content_len = 0;

    while (1) {
        n = read_line(cfd, line, sizeof(line));
        if (n < 0) return;
        if (n == 0) break;
        rstrip_crlf(line);
        if (line[0] == '\0') break; /* end of headers */

        if (strncasecmp(line, "X-Original-Method:", 18) == 0) {
            const char *v = line + 18;
            while (*v == ' ' || *v == '\t') v++;
            snprintf(orig_method, sizeof(orig_method), "%s", v);
        } else if (strncasecmp(line, "X-Original-URI:", 15) == 0) {
            const char *v = line + 15;
            while (*v == ' ' || *v == '\t') v++;
            snprintf(orig_uri, sizeof(orig_uri), "%s", v);
        } else if (strncasecmp(line, "Content-Length:", 15) == 0) {
            const char *v = line + 15;
            while (*v == ' ' || *v == '\t') v++;
            (void)header_get_int(v, &content_len);
            if (content_len < 0) content_len = 0;
            if (content_len > MAX_BODY) {
                http_reply(cfd, 413, "Payload Too Large");
                return;
            }
        }
    }

    /* ---- Read body if any ---- */
    char *body = NULL;
    if (content_len > 0) {
        body = (char *)malloc((size_t)content_len + 1);
        if (!body) {
            http_reply(cfd, 500, "Internal Server Error");
            return;
        }
        size_t got = 0;
        while (got < (size_t)content_len) {
            ssize_t r = read(cfd, body + got, (size_t)content_len - got);
            if (r < 0) {
                if (errno == EINTR) continue;
                free(body);
                return;
            }
            if (r == 0) break;
            got += (size_t)r;
        }
        body[got] = '\0';
    }

    /* ---- Route: /sign ---- */
    if (strcmp(req_method, "POST") == 0 && strcmp(req_path, "/sign") == 0) {
        if (!body) {
            http_reply(cfd, 400, "Bad Request");
            return;
        }
        handle_sign_endpoint(cfd, cfg, body, strlen(body));
        free(body);
        return;
    }

    free(body);

    /* ---- Default: nginx auth_request verify path (legacy behavior) ----
     * Uses X-Original-Method and X-Original-URI provided by nginx.
     */
    if (orig_method[0] == '\0' || orig_uri[0] == '\0') {
        http_reply(cfd, 400, "Bad Request");
        return;
    }

    /* Build v1 signature over original request with empty body */
    char path[512], query[512];
    split_uri(orig_uri, path, sizeof(path), query, sizeof(query));

    portal_sig_t sig;
    memset(&sig, 0, sizeof(sig));

    if (portal_sign_v1_hmac_sha256_base64(
            cfg->key_file,
            orig_method,
            path,
            query,
            (const unsigned char *)"",
            0,
            &sig) != 0) {
        http_reply(cfd, 500, "Internal Server Error");
        return;
    }

    /* Verify with controller */
    if (controller_verify(cfg, orig_method, orig_uri, &sig) == 0) {
        http_reply(cfd, 204, "No Content");   /* allow */
    } else {
        http_reply(cfd, 401, "Unauthorized"); /* deny */
    }
}
