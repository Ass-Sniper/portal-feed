#!/bin/sh
# =========================================================
# ImmortalWrt Portal Agent (runtime bootstrapper + nginx context generator)
#
# Runs on ImmortalWrt (data-plane).
# - Fetches policy/runtime from ap-controller (control-plane)
# - Generates /tmp/portal-runtime.env (atomic)
# - Generates nginx include files that derive client context (MAC/SSID/radio/VLAN)
# - Optionally triggers portal-fw.sh to apply dataplane rules
#
# Requirements (ImmortalWrt): curl, jsonfilter, logger, ip, iw (or iwinfo)
# Optional: /etc/portal/portal-agent.conf for overrides (shell format)
# =========================================================

# shellcheck source=/dev/null
. /usr/libexec/portal/lib/http.sh

set -eu

TAG="portal-agent"

# -------- user-tunable defaults (can be overridden by env or /etc/portal/portal-agent.conf) --------
CTRL_HOST="${CTRL_HOST:-192.168.16.118}"
CTRL_PORT="${CTRL_PORT:-8443}"
CTRL_BASE="${CTRL_BASE:-http://${CTRL_HOST}:${CTRL_PORT}}"
# ---------------- HMAC (for protected APIs) ----------------
PORTAL_HMAC_KEY_FILE="${PORTAL_HMAC_KEY_FILE:-/run/secrets/portal_hmac_v1}"
PORTAL_HMAC_KID="${PORTAL_HMAC_KID:-v1}"

# ---------------- Auth state ----------------
AUTH_MODE="none"         # none | jwt | hmac
JWT_TOKEN=""
JWT_EXPIRES_AT=0

# signer service (C portal-signer)
PORTAL_SIGNER_URL="http://127.0.0.1:9000/sign"
PORTAL_SIGNER_KID="v1"


# Runtime endpoint (Go controller). We keep a fallback to legacy paths.
RUNTIME_PATH="${RUNTIME_PATH:-/api/v1/policy/runtime}"
RUNTIME_LEGACY_PATH="${RUNTIME_LEGACY_PATH:-/policy/runtime}"

# Identify this AP (optional but recommended)
AP_ID="${AP_ID:-$(cat /proc/sys/kernel/hostname 2>/dev/null || echo ap-unknown)}"
SITE_ID="${SITE_ID:-default}"

# Radio discovery:
# - If RADIO_IDS is set, use it (space-separated ifnames, e.g. "ra0 rax0")
# - Else auto-detect AP interfaces via `iw dev` or `iwinfo`
RADIO_IDS="${RADIO_IDS:-}"

# Where to write runtime env
RUNTIME_ENV="${RUNTIME_ENV:-/tmp/portal-runtime.env}"

# If set to 1, apply dataplane right after refreshing runtime
APPLY_FW="${APPLY_FW:-1}"
PORTAL_FW="${PORTAL_FW:-/usr/libexec/portal/portal-fw.sh}"

# nginx integration (client-context maps)
NGINX_PORTAL_DIR="${NGINX_PORTAL_DIR:-/etc/nginx/conf.d/portal}"
NGINX_CLIENT_MAP_FILE="${NGINX_CLIENT_MAP_FILE:-${NGINX_PORTAL_DIR}/portal-client-maps.conf}"
NGINX_RELOAD="${NGINX_RELOAD:-1}"

# VLAN discovery:
BRIDGE_NAME="${BRIDGE_NAME:-br-lan}"
# VLANs that should NOT be captive-portal'd (space-separated IDs)
TRUST_VLANS="${TRUST_VLANS:-1}"
# If CAPTIVE_VLANS is set, portal-fw should only apply to these VLANs
CAPTIVE_VLANS="${CAPTIVE_VLANS:-}"

# If you want to fully control which L3 interfaces are captive, set CAPTIVE_IFS
# Example: CAPTIVE_IFS="br-lan.10 br-guest.20"
CAPTIVE_IFS="${CAPTIVE_IFS:-}"

# Optional: include local overrides
CONF_FILE="${CONF_FILE:-/etc/portal/portal-agent.conf}"
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

log() { logger -t "$TAG" "$*"; }

# ---------------------------------------------------------
# Health check mode: portal-agent --check
# ---------------------------------------------------------
if [ "${1:-}" = "--check" ]; then
  BASEDIR="$(cd "$(dirname "$0")" && pwd)"
  SELFTEST="${BASEDIR}/portal-dnsmasq-ipset-selftest.sh"

  log "event=healthcheck_start basedir=${BASEDIR}"

  if [ ! -x "$SELFTEST" ]; then
    log "level=error event=healthcheck_selftest_missing path=${SELFTEST}"
    echo "portal-agent: selftest not found or not executable (${SELFTEST})" >&2
    exit 2
  fi

  log "event=healthcheck_selftest_exec path=${SELFTEST}"

  if "$SELFTEST"; then
    log "event=healthcheck_ok"
    echo "portal-agent: dataplane healthy"
    exit 0
  else
    log "level=error event=healthcheck_failed"
    echo "portal-agent: dataplane unhealthy" >&2
    exit 1
  fi
fi

# 业务分组初始化打印（每组一行）
log "event=init_ctrl ctrl_host='${CTRL_HOST}' ctrl_port='${CTRL_PORT}' ctrl_base='${CTRL_BASE}' runtime_path='${RUNTIME_PATH}' runtime_legacy_path='${RUNTIME_LEGACY_PATH}'"
log "event=init_identity ap_id='${AP_ID}' site_id='${SITE_ID}'"
log "event=init_radio radio_ids_env='${RADIO_IDS}'"
log "event=init_runtime runtime_env='${RUNTIME_ENV}'"
log "event=init_fw apply_fw='${APPLY_FW}' portal_fw='${PORTAL_FW}'"
log "event=init_nginx portal_dir='${NGINX_PORTAL_DIR}' client_map_file='${NGINX_CLIENT_MAP_FILE}' nginx_reload='${NGINX_RELOAD}'"
log "event=init_vlan bridge_name='${BRIDGE_NAME}' trust_vlans='${TRUST_VLANS}' captive_vlans='${CAPTIVE_VLANS}' captive_ifs_explicit='${CAPTIVE_IFS}'"
log "event=init_conf conf_file='${CONF_FILE}'"

# Write env file atomically
write_env_atomic() {
  tmp="${RUNTIME_ENV}.tmp.$$"
  umask 077
  cat >"$tmp"
  mv -f "$tmp" "$RUNTIME_ENV"
}

# Best-effort fetch helper (returns body on stdout, non-zero on error)
http_get() {
  url="$1"
  curl -fsS --max-time 3 "$url"
}

hmac_sign_headers() {
  method="$1"
  path_query="$2"
  body="$3"

  ts="$(date +%s)"
  nonce="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"

  body_hash="$(printf "%s" "$body" | sha256sum | awk '{print $1}')"

  canonical="${ts}\n${nonce}\n${method}\n${path_query}\n\n${body_hash}\n"

  key="$(cat "$PORTAL_HMAC_KEY_FILE")"
  sign="$(printf "%s" "$canonical" \
    | openssl dgst -sha256 -hmac "$key" -binary \
    | base64)"

  echo \
    -H "X-Portal-Kid: ${PORTAL_HMAC_KID}" \
    -H "X-Portal-Timestamp: ${ts}" \
    -H "X-Portal-Nonce : ${nonce}" \
    -H "X-Portal-Signature: ${sign}"
}

http_get_signed() {
  url="$1"

  # split path+query (for canonical)
  path_query="$(printf "%s" "$url" | sed "s#^${CTRL_BASE}##")"

  headers="$(hmac_sign_headers GET "$path_query" "")"

  portal_http_request GET "$url" "$headers"
}

jwt_auth_header() {
  now="$(date +%s)"
  [ "$now" -lt "$JWT_EXPIRES_AT" ] || return 1
  echo "-H" "Authorization: Bearer ${JWT_TOKEN}"
}

portal_get() {
  url="$1"

  case "$AUTH_MODE" in
    jwt)
      hdr="$(jwt_auth_header || true)"
      if [ -n "$hdr" ]; then
        portal_http_request GET "$url" "$hdr"
        return $?
      fi
      log "event=jwt_expired fallback=hmac"
      AUTH_MODE="hmac"
      ;;
  esac

  if [ "$AUTH_MODE" = "hmac" ]; then
    http_get_signed "$url"
  else
    http_get "$url"
  fi
}

portal_sign_request() {
    local method="$1"
    local path="$2"
    local raw_query="$3"
    local body="$4"

    local req
    req="$(cat <<EOF
{
  "method": "$method",
  "path": "$path",
  "raw_query": "$raw_query",
  "body": $(printf '%s' "$body" | jq -Rs .)
}
EOF
)"

    local resp
    resp="$(curl -fsS \
        -X POST "$PORTAL_SIGNER_URL" \
        -H "Content-Type: application/json" \
        -d "$req")" || return 1

    SIGN_KID="$(echo "$resp" | jsonfilter -e '@.kid')"
    SIGN_TS="$(echo "$resp" | jsonfilter -e '@.timestamp')"
    SIGN_NONCE="$(echo "$resp" | jsonfilter -e '@.nonce')"
    SIGN_SIG="$(echo "$resp" | jsonfilter -e '@.signature')"

    [ -n "$SIGN_TS" ] && [ -n "$SIGN_NONCE" ] && [ -n "$SIGN_SIG" ]
}


# ---------------------------------------------------------
# Radio discovery
# ---------------------------------------------------------
discover_radios() {
  # 1) Explicit
  if [ -n "$RADIO_IDS" ]; then
    echo "$RADIO_IDS"
    return 0
  fi

  # 2) iw dev (preferred)
  if command -v iw >/dev/null 2>&1; then
    iw dev 2>/dev/null \
      | awk '
          $1=="Interface"{iface=$2}
          $1=="type" && $2=="AP"{print iface}
        ' \
      | tr '\n' ' '
    return 0
  fi

  # 3) iwinfo fallback (OpenWrt common)
  if command -v iwinfo >/dev/null 2>&1; then
    # iwinfo output format varies; we use assoclist enumeration to detect usable AP ifaces
    # If iface is an AP, `iwinfo <iface> assoclist` usually returns 0 even if empty.
    for i in $(iwinfo 2>/dev/null | awk '/^[a-zA-Z0-9_.-]+/{print $1}' | sort -u); do
      iwinfo "$i" assoclist >/dev/null 2>&1 && printf '%s ' "$i"
    done
    return 0
  fi

  # None found
  return 1
}

RADIOS="$(discover_radios 2>/dev/null || true)"
if [ -n "$RADIOS" ]; then
  log "event=radios_discovered value='${RADIOS}'"
else
  RADIOS="radio0"   # keep legacy default
  log "level=warn event=radios_defaulted legacy_default='radio0'"
fi

# ---------------------------------------------------------
# VLAN & captive interface discovery (for portal-fw.sh)
# ---------------------------------------------------------
is_in_list() {
  item="$1"; shift
  for x in "$@"; do
    [ "$x" = "$item" ] && return 0
  done
  return 1
}

discover_vlan_ifs() {
  # Prefer L3 subinterfaces like br-lan.10 that have IPv4
  if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show 2>/dev/null | awk '{print $2}' | grep -E "^${BRIDGE_NAME}\.[0-9]+$" | sort -u
  fi
}

discover_captive_ifs() {
  # 1) Explicit override
  if [ -n "${CAPTIVE_IFS:-}" ]; then
    echo "$CAPTIVE_IFS"
    return 0
  fi

  # 2) Discover vlan subinterfaces (space or newline separated)
  vlanifs="$(discover_vlan_ifs 2>/dev/null || true)"

  # 3) If we have VLAN subinterfaces, filter them
  if [ -n "$vlanifs" ]; then
    # Use positional params as an array-like accumulator
    set --

    # Iterate line-by-line safely (handles spaces/newlines predictably)
    # Note: if discover_vlan_ifs outputs space-separated items, consider making it output newline-separated.
    while IFS= read -r ifn; do
      [ -n "$ifn" ] || continue

      vid="${ifn##*.}"

      # Skip trusted VLANs
      if is_in_list "$vid" "${TRUST_VLANS:-}"; then
        continue
      fi

      # If CAPTIVE_VLANS is set, only keep those VLANs
      if [ -n "${CAPTIVE_VLANS:-}" ] && ! is_in_list "$vid" "$CAPTIVE_VLANS"; then
        continue
      fi

      # Keep this interface
      set -- "$@" "$ifn"
    done <<EOF
$vlanifs
EOF

    # Join by space for downstream compatibility
    echo "$*"
    return 0
  fi

  # 4) No VLAN subinterfaces: fall back to bridge itself
  echo "${BRIDGE_NAME:-br-lan}"
}

# Resolve captive interfaces and log details
CAPTIVE_IFS_RESOLVED="$(discover_captive_ifs)"
log "event=captive_ifs_resolved bridge=${BRIDGE_NAME} trust_vlans='${TRUST_VLANS}' captive_vlans='${CAPTIVE_VLANS}' explicit_captive_ifs='${CAPTIVE_IFS}' result='${CAPTIVE_IFS_RESOLVED}'"

# ---------------------------------------------------------
# Fetch runtime (per radio) and merge (union) the dataplane ipset names
# NOTE: ipset names are global — we keep first non-empty.
# ---------------------------------------------------------
POLICY_VERSION="0"
LAN_IF=""
PORTAL_IP=""
DNS_PORT=""
IPSET_GUEST=""
IPSET_STAFF=""
BYPASS_MACS=""
BYPASS_IPS=""
BYPASS_DOMAINS=""
BYPASS_ENABLED="true"

fetch_once() {
  radio_id="$1"
  log "event=runtime_fetch_start ctrl=${CTRL_BASE} ap_id=${AP_ID} site=${SITE_ID} radio=${radio_id}"

  resp="$(portal_get "${CTRL_BASE}${RUNTIME_PATH}?site=${SITE_ID}&ap_id=${AP_ID}&radio_id=${radio_id}" 2>/dev/null || true)"
  if [ -z "$resp" ]; then
    resp="$(portal_get "${CTRL_BASE}${RUNTIME_LEGACY_PATH}?site=${SITE_ID}&ap_id=${AP_ID}&radio_id=${radio_id}" 2>/dev/null || true)"
  fi
  [ -n "$resp" ] || return 1

  # dataplane.policy_version (authoritative)
  pv="$(printf '%s' "$resp" | jsonfilter -e '@.dataplane.policy_version' 2>/dev/null || true)"
  [ -n "$pv" ] && POLICY_VERSION="$pv"

  # dataplane.lan_if (legacy single IF, we keep for backward compat but also export CAPTIVE_IFS)
  li="$(printf '%s' "$resp" | jsonfilter -e '@.dataplane.lan_if' 2>/dev/null || true)"
  [ -n "$li" ] && LAN_IF="$li"

  pi="$(printf '%s' "$resp" | jsonfilter -e '@.dataplane.portal_ip' 2>/dev/null || true)"
  [ -n "$pi" ] && PORTAL_IP="$pi"

  dp="$(printf '%s' "$resp" | jsonfilter -e '@.dataplane.dns_port' 2>/dev/null || true)"
  [ -n "$dp" ] && DNS_PORT="$dp"

  ig="$(printf '%s' "$resp" | jsonfilter -e '@.dataplane.ipsets.allow.guest' 2>/dev/null || true)"
  is="$(printf '%s' "$resp" | jsonfilter -e '@.dataplane.ipsets.allow.staff' 2>/dev/null || true)"
  [ -n "$IPSET_GUEST" ] || IPSET_GUEST="$ig"
  [ -n "$IPSET_STAFF" ] || IPSET_STAFF="$is"

  # bypass lists (take from first successful response)
  if [ -z "$BYPASS_MACS" ]; then
    BYPASS_MACS="$(printf '%s' "$resp" | jsonfilter -e '@.bypass.mac_whitelist' 2>/dev/null || true)"
    BYPASS_IPS="$(printf '%s' "$resp" | jsonfilter -e '@.bypass.ip_whitelist' 2>/dev/null || true)"
    BYPASS_DOMAINS="$(printf '%s' "$resp" | jsonfilter -e '@.bypass.domains' 2>/dev/null || true)"
    be="$(printf '%s' "$resp" | jsonfilter -e '@.bypass.enabled' 2>/dev/null || true)"
    [ -n "$be" ] && BYPASS_ENABLED="$be"
  fi

  return 0
}

login_body="$(cat <<EOF
{
  "ap_id": "${AP_ID}",
  "site_id": "${SITE_ID}"
}
EOF
)"

log "event=portal_login_start"
login_resp="$(http_post_plain "/portal/login" "$login_body" 2>/dev/null || true)"

token="$(printf '%s' "$login_resp" | jsonfilter -e '@.data.access_token' 2>/dev/null || true)"
expires="$(printf '%s' "$login_resp" | jsonfilter -e '@.data.expires_in' 2>/dev/null || true)"

if [ -n "$token" ] && [ -n "$expires" ]; then
  JWT_TOKEN="$token"
  JWT_EXPIRES_AT="$(($(date +%s) + expires - 5))"
  AUTH_MODE="jwt"
  log "event=portal_login_ok auth=jwt expires_in=${expires}"
else
  AUTH_MODE="hmac"
  log "event=portal_login_fallback auth=hmac"
fi

ok=0
for r in $RADIOS; do
  if fetch_once "$r"; then
    ok=1
  fi
done
[ "$ok" -eq 1 ] || { log "event=runtime_fetch_failed reason=curl"; exit 1; }

# Fill defaults
[ -n "$LAN_IF" ] || LAN_IF="$BRIDGE_NAME"
[ -n "$PORTAL_IP" ] || PORTAL_IP="$CTRL_HOST"
[ -n "$DNS_PORT" ] || DNS_PORT="53"
[ -n "$IPSET_GUEST" ] || IPSET_GUEST="portal_allow_guest"
[ -n "$IPSET_STAFF" ] || IPSET_STAFF="portal_allow_staff"
[ -n "$BYPASS_ENABLED" ] || BYPASS_ENABLED="true"

# policy version must be numeric
case "$POLICY_VERSION" in
  ''|*[!0-9]*)
    log "level=warn event=invalid_policy_version raw_value='${POLICY_VERSION}' fallback=0"
    POLICY_VERSION="0"
    ;;
esac
log "event=policy_version_resolved value=${POLICY_VERSION}"

FORCE_APPLY=0
if [ "$POLICY_VERSION" -eq 0 ]; then
  log "level=info event=policy_version_unknown force_apply=true"
  FORCE_APPLY=1
fi

# Persist runtime env (shell-friendly exports)
write_env_atomic <<EOF
# Auto-generated by portal-agent.sh at $(date -Iseconds)
export CTRL_BASE='${CTRL_BASE}'
export POLICY_VERSION='${POLICY_VERSION}'
export AP_ID='${AP_ID}'
export SITE_ID='${SITE_ID}'
export RADIO_IDS='${RADIOS}'

# Dataplane
export LAN_IF='${LAN_IF}'              # legacy
export BRIDGE_NAME='${BRIDGE_NAME}'
export TRUST_VLANS='${TRUST_VLANS}'
export CAPTIVE_VLANS='${CAPTIVE_VLANS}'
export CAPTIVE_IFS='${CAPTIVE_IFS_RESOLVED}'
export PORTAL_IP='${PORTAL_IP}'
export DNS_PORT='${DNS_PORT}'

# ipsets (roles -> allow sets)
export IPSET_GUEST='${IPSET_GUEST}'
export IPSET_STAFF='${IPSET_STAFF}'

# bypass (raw JSON arrays as strings; scripts may parse further)
export BYPASS_ENABLED='${BYPASS_ENABLED}'
export BYPASS_MACS='${BYPASS_MACS}'
export BYPASS_IPS='${BYPASS_IPS}'
export BYPASS_DOMAINS='${BYPASS_DOMAINS}'
EOF

log "event=runtime_fetch_done policy_version=${POLICY_VERSION} captive_ifs='${CAPTIVE_IFS_RESOLVED}' ipset_guest=${IPSET_GUEST} ipset_staff=${IPSET_STAFF}"

# ---------------------------------------------------------
# Build nginx client-context maps for signer and portal upstream headers
# This solves: nginx cannot see client MAC/SSID/radio/VLAN from L3 alone.
#
# Strategy:
# - Collect IP<->MAC from `ip neigh show` (per VLAN L3 if)
# - Collect MAC<->(ssid,radio) from `iw dev ... station dump` (per AP iface)
# - Generate nginx "map" blocks:
#   map $remote_addr $portal_mac { default ""; 172.16.10.2 "aa:bb:cc:dd:ee:ff"; }
#   map $remote_addr $portal_ssid { default ""; 172.16.10.2 "Guest-5G"; }
#   map $remote_addr $portal_radio_id { default ""; 172.16.10.2 "rax0"; }
#   map $remote_addr $portal_vlan_id { default 0; 172.16.10.2 10; }
#
# Nginx configs should then use:
#   proxy_set_header X-Client-MAC $portal_mac;
#   proxy_set_header X-Client-SSID $portal_ssid;
#   proxy_set_header X-Client-Radio-ID $portal_radio_id;
#   proxy_set_header X-Client-VLAN-ID $portal_vlan_id;
#   proxy_set_header X-Client-AP-ID $ap_id;  (see below)
# ---------------------------------------------------------
escape_nginx_str() {
  # escape backslash and double quote
  echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

build_mac_radio_map() {
  # Output: "mac iface ssid"
  if command -v iw >/dev/null 2>&1; then
    for ifn in $RADIOS; do
      ssid="$(iwinfo "$ifn" info 2>/dev/null | awk -F': ' '/ESSID/ {gsub(/"/,"",$2); print $2}' | head -n1)"
      [ -n "$ssid" ] || ssid="$ifn"
      iw dev "$ifn" station dump 2>/dev/null \
        | awk -v IFN="$ifn" -v SSID="$ssid" '
            $1=="Station"{print tolower($2), IFN, SSID}
          '
    done
    return 0
  fi

  # iwinfo fallback
  if command -v iwinfo >/dev/null 2>&1; then
    for ifn in $RADIOS; do
      ssid="$(iwinfo "$ifn" info 2>/dev/null | awk -F': ' '/ESSID/ {gsub(/"/,"",$2); print $2}' | head -n1)"
      [ -n "$ssid" ] || ssid="$ifn"
      iwinfo "$ifn" assoclist 2>/dev/null \
        | awk -v IFN="$ifn" -v SSID="$ssid" '/^[0-9A-Fa-f:]{17}/ {print tolower($1), IFN, SSID}'
    done
    return 0
  fi

  return 1
}

build_ip_mac_vlan() {
  # Output: "ip mac vlan"
  # We only use neighbor entries on CAPTIVE_IFS_RESOLVED (guest VLANs) + BRIDGE_NAME subifs.
  for ifn in $CAPTIVE_IFS_RESOLVED; do
    vid="0"
    case "$ifn" in
      ${BRIDGE_NAME}.*) vid="${ifn##*.}" ;;
    esac

    ip neigh show dev "$ifn" 2>/dev/null \
      | awk -v VID="$vid" '
          $0 ~ /lladdr/ {
            ip=$1;
            for (i=1;i<=NF;i++) if ($i=="lladdr") mac=$(i+1);
            if (ip!="" && mac!="") print ip, tolower(mac), VID;
          }
        '
  done
}

generate_nginx_maps() {
  tmp="${NGINX_CLIENT_MAP_FILE}.tmp.$$"
  umask 077

  # MAC -> radio/ssid
  mac_radio="$(build_mac_radio_map 2>/dev/null || true)"

  # Build associative maps via awk (busybox awk ok)
  # ip->(mac,vid) from neigh; mac->(radio,ssid) from wifi
  ip_mac_vlan="$(build_ip_mac_vlan 2>/dev/null || true)"

  {
    echo "# Auto-generated by portal-agent.sh at $(date -Iseconds)"
    echo "# Client context maps (remote_addr -> MAC/SSID/radio/VLAN)"
    echo ""
    echo "map \$remote_addr \$portal_mac {"
    echo "    default \"\";"
    echo "$ip_mac_vlan" | awk '{printf("    %s \"%s\";\n",$1,$2)}'
    echo "}"
    echo ""
    echo "map \$remote_addr \$portal_vlan_id {"
    echo "    default 0;"
    echo "$ip_mac_vlan" | awk '{printf("    %s %s;\n",$1,$3)}'
    echo "}"
    echo ""
    echo "map \$portal_mac \$portal_radio_id {"
    echo "    default \"\";"
    echo "$mac_radio" | awk '{printf("    %s \"%s\";\n",$1,$2)}'
    echo "}"
    echo ""
    echo "map \$portal_mac \$portal_ssid {"
    echo "    default \"\";"
    echo "$mac_radio" | awk '{ssid=$3; for(i=4;i<=NF;i++) ssid=ssid" "$i; gsub(/\\/,"\\\\",ssid); gsub(/"/,"\\\"",ssid); printf("    %s \"%s\";\n",$1,ssid)}'
    echo "}"
    echo ""
    echo "map \"\" \$portal_ap_id {"
    echo "    default \"$(escape_nginx_str "$AP_ID")\";"
    echo "}"
  } >"$tmp"

  mv -f "$tmp" "$NGINX_CLIENT_MAP_FILE"
}

maybe_reload_nginx() {
  [ "$NGINX_RELOAD" = "1" ] || return 0
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      /etc/init.d/nginx reload >/dev/null 2>&1 || /etc/init.d/nginx restart >/dev/null 2>&1 || true
    else
      log "level=warn event=nginx_config_test_failed skip_reload=1"
    fi
  fi
}

# Ensure portal dir exists before writing map
if [ -d "$NGINX_PORTAL_DIR" ]; then
  generate_nginx_maps || true
  maybe_reload_nginx || true
else
  log "level=warn event=nginx_portal_dir_missing path=${NGINX_PORTAL_DIR} skip_nginx_maps=1"
fi

# ---------------------------
# Apply dataplane rules
# ---------------------------
if [ "$APPLY_FW" = "1" ] && [ -x "$PORTAL_FW" ]; then
  if [ "$FORCE_APPLY" = "1" ]; then
    log "event=apply_fw_force reason=policy_version_unknown script=${PORTAL_FW}"
  else
    log "event=apply_fw_conditional script=${PORTAL_FW}"
  fi

  if "$PORTAL_FW"; then
    log "event=apply_fw_done"
  else
    log "event=apply_fw_failed"
    exit 2
  fi
fi

exit 0
