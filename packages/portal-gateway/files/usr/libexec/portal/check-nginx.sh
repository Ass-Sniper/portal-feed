#!/bin/sh
#
# check-nginx.sh
#
# Shared nginx capability checker for Portal Gateway
#
# This script is used by:
# - postinst (installation-time warnings)
# - init.d/portal-gateway (startup-time hard checks)
# - future CI or diagnostic tools
#

# ---------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------
log() {
    logger -t portal-gateway "$@"
    [ "$QUIET" = "1" ] || echo "[portal-gateway] $@"
}

# ---------------------------------------------------------
# Auto-detect nginx binary
# ---------------------------------------------------------
detect_nginx() {
    if command -v nginx >/dev/null 2>&1; then
        command -v nginx
        return 0
    fi

    for p in /usr/sbin/nginx /usr/bin/nginx; do
        [ -x "$p" ] && {
            echo "$p"
            return 0
        }
    done

    return 1
}

NGINX_BIN="$(detect_nginx)"

if [ -z "$NGINX_BIN" ]; then
    log "ERROR: nginx binary not found"
    exit 1
fi

# ---------------------------------------------------------
# Collect nginx build information
# ---------------------------------------------------------
NGINX_BUILD="$($NGINX_BIN -V 2>&1)"

check_module() {
    echo "$NGINX_BUILD" | grep -q "$1"
}

missing=0

require_module() {
    name="$1"
    pattern="$2"

    if ! check_module "$pattern"; then
        log "ERROR: nginx missing required capability: $name"
        missing=1
    fi
}

# ---------------------------------------------------------
# Required nginx capabilities for Portal Gateway
# ---------------------------------------------------------
require_module "http_auth_request" "http_auth_request"
require_module "http_proxy"        "http_proxy"
require_module "http_map"          "http_map"
require_module "headers_more"      "headers-more"
require_module "http_rewrite"      "http_rewrite"
require_module "limit_conn"        "limit_conn"
require_module "limit_req"         "limit_req"

# ---------------------------------------------------------
# Final result
# ---------------------------------------------------------
if [ "$missing" -eq 1 ]; then
    exit 1
fi

exit 0