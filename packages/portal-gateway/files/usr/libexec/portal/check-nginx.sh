#!/bin/sh
#
# check-nginx.sh
#
# Shared nginx capability checker for Portal Gateway
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

# ---------------------------------------------------------
# Capability checks
# ---------------------------------------------------------

missing=0

# Check that a module is NOT explicitly disabled
# nginx default modules do NOT appear as --with-xxx
require_http_module() {
    name="$1"
    without_flag="--without-http_${name}_module"

    if echo "$NGINX_BUILD" | grep -q "$without_flag"; then
        log "ERROR: nginx missing required capability: http_${name}"
        missing=1
    fi
}

# Check third-party / optional modules by presence
require_feature() {
    name="$1"
    pattern="$2"

    if ! echo "$NGINX_BUILD" | grep -q "$pattern"; then
        log "ERROR: nginx missing required capability: $name"
        missing=1
    fi
}

# ---------------------------------------------------------
# Required nginx capabilities for Portal Gateway
# ---------------------------------------------------------

# Core HTTP modules (default-enabled)
require_http_module proxy
require_http_module map
require_http_module rewrite
require_http_module limit_conn
require_http_module limit_req

# Optional / external modules
require_feature "http_auth_request" "http_auth_request"
require_feature "headers_more"      "headers-more"

# ---------------------------------------------------------
# Final result
# ---------------------------------------------------------
if [ "$missing" -eq 1 ]; then
    log "nginx capability check failed"
    exit 1
fi

exit 0