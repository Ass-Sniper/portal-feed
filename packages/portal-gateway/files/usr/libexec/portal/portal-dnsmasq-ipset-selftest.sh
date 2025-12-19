#!/bin/sh
# =============================================================================
# portal-dnsmasq-ipset-selftest.sh
#
# Purpose:
#   Non-destructive health check for DNS-based domain bypass using
#   dnsmasq + ipset on OpenWrt / ImmortalWrt.
#
# What this script verifies:
#   - dnsmasq is running and compiled with ipset support
#   - dnsmasq conf-dir is enabled (default: /tmp/dnsmasq.d)
#   - target ipset exists and is of type hash:ip
#   - dnsmasq → ipset integration has been proven to work
#     (either already populated or can be populated on demand)
#
# Design principles:
#   - Cache-safe (does not rely on cache misses)
#   - Non-destructive (no cache flush, no service restart)
#   - Idempotent (safe to run repeatedly)
#   - Health-check oriented (not a functional stress test)
#
# Usage:
#   portal-dnsmasq-ipset-selftest.sh \
#     [IPSET_NAME] \
#     [TEST_DOMAIN] \
#     [DNSMASQ_CONF_DIR]
#
# Defaults:
#   IPSET_NAME        = portal_bypass_dns
#   TEST_DOMAIN       = www.microsoft.com
#   DNSMASQ_CONF_DIR  = /tmp/dnsmasq.d
#
# Exit codes:
#   0  - healthy
#   1  - unhealthy (dataplane issue detected)
#   2  - invalid environment (missing tools or permissions)
#
# Intended integration:
#   - portal-agent --check
#   - procd healthcheck
#   - controller / CI / Prometheus (via JSON wrapper)
# =============================================================================


set -e

# ------------------------------------------------------------
# Arguments (with safe defaults)
# ------------------------------------------------------------
IPSET_NAME="${1:-portal_bypass_dns}"
TEST_DOMAIN="${2:-www.microsoft.com}"
CONF_DIR="${3:-/tmp/dnsmasq.d}"

log() {
  echo "[SELFTEST] $*"
}

fail() {
  echo "[SELFTEST][FAIL] $*" >&2
  exit 1
}

log "starting self-test for dnsmasq + ipset domain bypass"

# ------------------------------------------------------------
# 1. dnsmasq running?
# ------------------------------------------------------------
if ! pidof dnsmasq >/dev/null; then
  fail "dnsmasq is not running"
fi
log "dnsmasq is running"

# ------------------------------------------------------------
# 2. dnsmasq supports ipset?
# ------------------------------------------------------------
if ! dnsmasq --version | grep -q ipset; then
  fail "dnsmasq was not compiled with ipset support"
fi
log "dnsmasq supports ipset"

# ------------------------------------------------------------
# 3. dnsmasq conf-dir enabled?
# ------------------------------------------------------------
DNSMASQ_CFG="$(ps w | grep '[d]nsmasq' | sed -n 's/.*-C \([^ ]*\).*/\1/p')"

[ -n "$DNSMASQ_CFG" ] || fail "cannot determine dnsmasq config file"

if ! grep -q "conf-dir=${CONF_DIR}" "$DNSMASQ_CFG"; then
  fail "dnsmasq conf-dir ${CONF_DIR} not enabled"
fi
log "dnsmasq conf-dir ${CONF_DIR} enabled"

# ------------------------------------------------------------
# 4. ipset exists?
# ------------------------------------------------------------
if ! ipset list "$IPSET_NAME" >/dev/null 2>&1; then
  fail "ipset ${IPSET_NAME} does not exist"
fi
log "ipset ${IPSET_NAME} exists"

# ------------------------------------------------------------
# 5. ipset type must be hash:ip
# ------------------------------------------------------------
if ! ipset list "$IPSET_NAME" | grep -q "Type: hash:ip"; then
  fail "ipset ${IPSET_NAME} is not hash:ip"
fi
log "ipset ${IPSET_NAME} type is hash:ip"

# ------------------------------------------------------------
# 6. runtime DNS -> ipset verification (cache-safe)
# ------------------------------------------------------------

count="$(ipset list "$IPSET_NAME" | awk '/Members:/ {f=1;next} f {print}' | wc -l)"

if [ "$count" -gt 0 ]; then
  log "ipset ${IPSET_NAME} already populated (${count} entries), dnsmasq-ipset path verified"
  log "self-test passed (cached)"
  exit 0
fi

log "ipset ${IPSET_NAME} empty, triggering DNS lookup: ${TEST_DOMAIN}"
nslookup "$TEST_DOMAIN" >/dev/null 2>&1 || true

sleep 1

count2="$(ipset list "$IPSET_NAME" | awk '/Members:/ {f=1;next} f {print}' | wc -l)"

if [ "$count2" -gt 0 ]; then
  log "dnsmasq populated ipset ${IPSET_NAME} after lookup (${count2} entries)"
  log "self-test passed"
  exit 0
else
  fail "dnsmasq did not populate ipset ${IPSET_NAME} after lookup of ${TEST_DOMAIN}"
fi
