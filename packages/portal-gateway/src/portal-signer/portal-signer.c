#include "config.h"
#include "signer.h"

#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>   // srand
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* Global runtime config */
static signer_config_t g_cfg;

/* Reload flag (signal-safe) */
static volatile sig_atomic_t g_reload = 0;
static volatile sig_atomic_t g_stop = 0;

static void on_sighup(int sig) { (void)sig; g_reload = 1; }
static void on_sigint(int sig) { (void)sig; g_stop = 1; }
static void on_sigterm(int sig) { (void)sig; g_stop = 1; }

static void reload_config(void) {
    signer_config_t new_cfg;

    signer_config_defaults(&new_cfg);
    signer_config_load_file(&new_cfg, "/etc/portal/portal-signer.conf");

    /* NOTE: cmdline overrides are not re-parsed on reload */
    g_cfg = new_cfg;

    fprintf(stderr,
        "[portal-signer] reloaded: listen=%s:%d controller=%s:%d path=%s key=%s\n",
        g_cfg.listen_addr, g_cfg.listen_port,
        g_cfg.controller_addr, g_cfg.controller_port,
        g_cfg.controller_path,
        g_cfg.key_file);
}

static int create_listener(const char *addr, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, addr, &sa.sin_addr) != 1) {
        close(fd);
        return -2;
    }

    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        close(fd);
        return -3;
    }
    if (listen(fd, 128) != 0) {
        close(fd);
        return -4;
    }
    return fd;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;

    /* Seed rand for nonce */
    srand((unsigned int)getpid());

    /* Signals */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sighup;
    sigaction(SIGHUP, &sa, NULL);

    sa.sa_handler = on_sigint;
    sigaction(SIGINT, &sa, NULL);

    sa.sa_handler = on_sigterm;
    sigaction(SIGTERM, &sa, NULL);

    reload_config();

    int sfd = create_listener(g_cfg.listen_addr, g_cfg.listen_port);
    if (sfd < 0) {
        fprintf(stderr, "[portal-signer] failed to listen on %s:%d\n",
                g_cfg.listen_addr, g_cfg.listen_port);
        return 1;
    }

    fprintf(stderr, "[portal-signer] listening on %s:%d\n", g_cfg.listen_addr, g_cfg.listen_port);

    while (!g_stop) {
        if (g_reload) {
            g_reload = 0;
            reload_config();
        }

        int cfd = accept(sfd, NULL, NULL);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            break;
        }

        portal_signer_handle_client(cfd, &g_cfg);
        close(cfd);
    }

    close(sfd);
    return 0;
}
