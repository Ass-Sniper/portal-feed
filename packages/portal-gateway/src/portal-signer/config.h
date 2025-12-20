#pragma once

/*
 * signer_config_t
 *
 * Runtime configuration for portal-signer daemon.
 *
 * Configuration precedence:
 *   1. Command-line arguments
 *   2. Configuration file (/etc/portal/portal-signer.conf)
 *   3. Built-in defaults
 *
 * This struct is intentionally flat and POD-style
 * to keep parsing simple and OpenWrt-friendly.
 */
 typedef struct {
    /* --------------------------------------------------
     * Local listen address for nginx auth_request
     * Example: 127.0.0.1
     * -------------------------------------------------- */
    char listen_addr[64];

    /* Local listen port for signer HTTP service
     * Must match nginx upstream portal_signer
     * Example: 9000
     */
    int  listen_port;

    /* --------------------------------------------------
     * Controller service address
     * Example: 127.0.0.1
     * -------------------------------------------------- */
    char controller_addr[64];

    /* Controller service port
     * Example: 9090
     */
    int  controller_port;

    /* HTTP path for controller verify endpoint
     * Example: /portal/context/verify
     */
    char controller_path[128];

    /* --------------------------------------------------
     * Path to shared signing key file
     * Used for HMAC / signature generation
     * Example: /etc/portal/portal.signing.key
     * -------------------------------------------------- */
    char key_file[256];

} signer_config_t;


/* Load built-in defaults */
void signer_config_defaults(signer_config_t *cfg);

/* Load from config file (key=value) */
int signer_config_load_file(signer_config_t *cfg, const char *path);

/* Override by command line arguments */
int signer_config_parse_args(signer_config_t *cfg, int argc, char **argv);
