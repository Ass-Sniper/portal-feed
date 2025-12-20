#include "config.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>

/* --------------------------------------------------
 * Defaults (equivalent to old #define values)
 * -------------------------------------------------- */
void signer_config_defaults(signer_config_t *cfg)
{
    strcpy(cfg->listen_addr, "127.0.0.1");
    cfg->listen_port = 9000;

    strcpy(cfg->controller_addr, "127.0.0.1");
    cfg->controller_port = 9090;
    strcpy(cfg->controller_path, "/portal/context/verify");

    strcpy(cfg->key_file, "/etc/portal/portal.signing.key");
}

/* --------------------------------------------------
 * Helpers
 * -------------------------------------------------- */
static char *trim(char *s)
{
    while (isspace((unsigned char)*s))
        s++;

    if (*s == '\0')
        return s;

    char *end = s + strlen(s) - 1;
    while (end > s && isspace((unsigned char)*end))
        end--;

    end[1] = '\0';
    return s;
}

static void parse_host_port(const char *s,
                            char *host, size_t host_sz,
                            int *port)
{
    const char *p = strchr(s, ':');
    if (!p)
        return;

    size_t len = (size_t)(p - s);
    if (len >= host_sz)
        len = host_sz - 1;

    memcpy(host, s, len);
    host[len] = '\0';

    *port = atoi(p + 1);
}

/* --------------------------------------------------
 * Load config file: key=value
 * -------------------------------------------------- */
int signer_config_load_file(signer_config_t *cfg, const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;

    char line[512];

    while (fgets(line, sizeof(line), f)) {
        char *s = trim(line);

        /* Skip comments and empty lines */
        if (*s == '#' || *s == '\0')
            continue;

        char *eq = strchr(s, '=');
        if (!eq)
            continue;

        *eq = '\0';
        char *key = trim(s);
        char *val = trim(eq + 1);

        if (!strcmp(key, "listen.addr")) {
            strncpy(cfg->listen_addr, val,
                    sizeof(cfg->listen_addr) - 1);
        } else if (!strcmp(key, "listen.port")) {
            cfg->listen_port = atoi(val);
        } else if (!strcmp(key, "controller.addr")) {
            strncpy(cfg->controller_addr, val,
                    sizeof(cfg->controller_addr) - 1);
        } else if (!strcmp(key, "controller.port")) {
            cfg->controller_port = atoi(val);
        } else if (!strcmp(key, "controller.path")) {
            strncpy(cfg->controller_path, val,
                    sizeof(cfg->controller_path) - 1);
        } else if (!strcmp(key, "key.file")) {
            strncpy(cfg->key_file, val,
                    sizeof(cfg->key_file) - 1);
        }
        /* Unknown keys are silently ignored */
    }

    fclose(f);
    return 0;
}

/* --------------------------------------------------
 * Parse command line arguments (override config)
 * -------------------------------------------------- */
int signer_config_parse_args(signer_config_t *cfg, int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--listen") && i + 1 < argc) {
            parse_host_port(argv[++i],
                            cfg->listen_addr,
                            sizeof(cfg->listen_addr),
                            &cfg->listen_port);
        } else if (!strcmp(argv[i], "--controller") && i + 1 < argc) {
            parse_host_port(argv[++i],
                            cfg->controller_addr,
                            sizeof(cfg->controller_addr),
                            &cfg->controller_port);
        } else if (!strcmp(argv[i], "--controller-path") && i + 1 < argc) {
            strncpy(cfg->controller_path, argv[++i],
                    sizeof(cfg->controller_path) - 1);
        } else if (!strcmp(argv[i], "--key") && i + 1 < argc) {
            strncpy(cfg->key_file, argv[++i],
                    sizeof(cfg->key_file) - 1);
        } else if (!strcmp(argv[i], "--help")) {
            printf(
                "portal-signer options:\n"
                "  --listen ip:port\n"
                "  --controller ip:port\n"
                "  --controller-path /path\n"
                "  --key /path/to/key\n"
            );
            exit(0);
        }
    }
    return 0;
}