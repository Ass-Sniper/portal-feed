#!/bin/sh
# =========================================================
# portal-fw.sh
#
# Captive portal dataplane rules for ImmortalWrt (iptables/ipset).
#
# Goals (nginx-signer scheme):
# - Intercept TCP/80 from captive VLAN interfaces and redirect to local nginx gateway (port 8081)
# - Keep DNS/ipset plumbing compatible with dnsmasq ipset domain-bypass (optional)
# - Support multiple VLAN interfaces (br-lan.<vid>) dynamically
# - Support multi-radio / multi-SSID via portal-agent generated headers (nginx side)
#
# Inputs (from /tmp/portal-runtime.env, exported):
#   CAPTIVE_IFS      space-separated L3 interfaces to captive-portal (recommended)
#   BRIDGE_NAME      bridge base name (default br-lan)
#   TRUST_VLANS      VLAN IDs excluded from captive portal (default "1")
#   CAPTIVE_VLANS    optional VLAN allow-list
#   DNS_PORT         dns port (default 53)
#   IPSET_*          ipset names used by controller policy
#   BYPASS_*         json arrays as strings (optional)
#
# Behavior:
# - Idempotent: safe to run repeatedly
# - Creates:
#   - nat chain: PORTAL_PREROUTING
#   - filter chain: PORTAL_FWD
#   - ipsets: portal_bypass_mac, portal_bypass_ip, portal_bypass_dns
# - Hooks into PREROUTING/FORWARD via jump rules
# =========================================================

set -eu

TAG="portal-fw"

log() { logger -t "$TAG" "$*"; }

# ---------------------------------------------------------
# Load runtime env if exists
# ---------------------------------------------------------
RUNTIME_ENV="${RUNTIME_ENV:-/tmp/portal-runtime.env}"
[ -f "$RUNTIME_ENV" ] && . "$RUNTIME_ENV" || true

# Defaults
BRIDGE_NAME="${BRIDGE_NAME:-br-lan}"
TRUST_VLANS="${TRUST_VLANS:-1}"
CAPTIVE_VLANS="${CAPTIVE_VLANS:-}"
CAPTIVE_IFS="${CAPTIVE_IFS:-}"
DNS_PORT="${DNS_PORT:-53}"

# Nginx gateway local port (listens on all ifs; we REDIRECT)
NGINX_PORT="${NGINX_PORT:-8081}"

# Policy ipsets (roles)
IPSET_GUEST="${IPSET_GUEST:-portal_allow_guest}"
IPSET_STAFF="${IPSET_STAFF:-portal_allow_staff}"

# Bypass ipsets
IPSET_BYPASS_MAC="${IPSET_BYPASS_MAC:-portal_bypass_mac}"
IPSET_BYPASS_IP="${IPSET_BYPASS_IP:-portal_bypass_ip}"
IPSET_BYPASS_DNS="${IPSET_BYPASS_DNS:-portal_bypass_dns}"

# Chains
CHAIN_NAT="${CHAIN_NAT:-PORTAL_PREROUTING}"
CHAIN_FWD="${CHAIN_FWD:-PORTAL_FWD}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { log "level=error missing_cmd=$1"; exit 1; }; }

need_cmd iptables
need_cmd ipset
need_cmd ip

# ---------------------------------------------------------
# Discover captive interfaces if not provided by agent
# ---------------------------------------------------------
is_in_list() {
  item="$1"; shift
  for x in "$@"; do
    [ "$x" = "$item" ] && return 0
  done
  return 1
}

discover_captive_ifs() {
  if [ -n "$CAPTIVE_IFS" ]; then
    echo "$CAPTIVE_IFS"
    return 0
  fi

  vlanifs="$(ip -o -4 addr show 2>/dev/null | awk '{print $2}' | grep -E "^${BRIDGE_NAME}\.[0-9]+$" | sort -u || true)"
  if [ -n "$vlanifs" ]; then
    out=""
    for ifn in $vlanifs; do
      vid="${ifn##*.}"
      is_in_list "$vid" $TRUST_VLANS && continue
      if [ -n "$CAPTIVE_VLANS" ]; then
        is_in_list "$vid" $CAPTIVE_VLANS || continue
      fi
      out="${out}${ifn} "
    done
    echo "$out"
    return 0
  fi

  # No VLAN L3 — fall back to bridge itself
  echo "$BRIDGE_NAME"
}

CAPTIVE_IFS="$(discover_captive_ifs)"

# ---------------------------------------------------------
# Helpers: idempotent iptables / ipset
# ---------------------------------------------------------
ensure_chain() {
  table="$1"
  chain="$2"
  iptables -t "$table" -nL "$chain" >/dev/null 2>&1 || iptables -t "$table" -N "$chain"
}

flush_chain() {
  table="$1"
  chain="$2"
  iptables -t "$table" -F "$chain" >/dev/null 2>&1 || true
}

ensure_jump() {
  table="$1"
  from_chain="$2"
  to_chain="$3"
  # Insert at top to take precedence
  iptables -t "$table" -C "$from_chain" -j "$to_chain" >/dev/null 2>&1 || iptables -t "$table" -I "$from_chain" 1 -j "$to_chain"
}

ensure_ipset() {
  name="$1"
  type="$2"
  ipset list "$name" >/dev/null 2>&1 || ipset create "$name" "$type" -exist
}

# ---------------------------------------------------------
# Build rules
# ---------------------------------------------------------
apply_rules() {
  log "event=apply_start captive_ifs='$CAPTIVE_IFS' nginx_port=$NGINX_PORT"

  # ipsets
  ensure_ipset "$IPSET_BYPASS_MAC" "hash:mac"
  ensure_ipset "$IPSET_BYPASS_IP" "hash:ip"
  ensure_ipset "$IPSET_BYPASS_DNS" "hash:ip"
  # controller role ipsets may be created elsewhere; ensure them to be safe
  ensure_ipset "$IPSET_GUEST" "hash:mac"
  ensure_ipset "$IPSET_STAFF" "hash:mac"

  # chains
  ensure_chain nat "$CHAIN_NAT"
  ensure_chain filter "$CHAIN_FWD"

  # hook points
  ensure_jump nat PREROUTING "$CHAIN_NAT"
  ensure_jump filter FORWARD "$CHAIN_FWD"

  # reset our chains
  flush_chain nat "$CHAIN_NAT"
  flush_chain filter "$CHAIN_FWD"

  # -----------------------------
  # NAT PREROUTING: redirect HTTP to local nginx gateway
  # - Only for captive interfaces
  # - Exclude bypass MAC/IP (optional)
  # -----------------------------
  for ifn in $CAPTIVE_IFS; do
    # Allow bypass MAC/IP first
    iptables -t nat -A "$CHAIN_NAT" -i "$ifn" -m set --match-set "$IPSET_BYPASS_MAC" src -j RETURN
    iptables -t nat -A "$CHAIN_NAT" -i "$ifn" -m set --match-set "$IPSET_BYPASS_IP"  dst -j RETURN

    # Redirect plain HTTP to nginx gateway (local port)
    iptables -t nat -A "$CHAIN_NAT" -i "$ifn" -p tcp --dport 80 -j REDIRECT --to-ports "$NGINX_PORT"
  done

  # -----------------------------
  # FILTER FORWARD:
  # - Permit portal traffic + allowlists
  # - Deny internet forward for unauth (handled by default policy outside)
  # Keep minimal and safe: only add ACCEPT rules for bypass and allow roles.
  # -----------------------------
  # Allow bypass MACs
  iptables -A "$CHAIN_FWD" -m set --match-set "$IPSET_BYPASS_MAC" src -j ACCEPT
  # Allow bypass IPs (dst)
  iptables -A "$CHAIN_FWD" -m set --match-set "$IPSET_BYPASS_IP" dst -j ACCEPT

  # NOTE: Domain-based bypass via DNS->ipset is dangerous for captive portal detection.
  # If you ACCEPT forwarding based on a "bypass domains" ipset, OS connectivity probes
  # (e.g., Windows NCSI) may reach the real internet and will NOT trigger the portal popup.
  # Keep this rule disabled by default; enable only after you fully understand the tradeoff.
  # iptables -A "$CHAIN_FWD" -m set --match-set "$IPSET_BYPASS_DNS" dst -j ACCEPT

  # Allow authenticated roles by MAC (src)
  iptables -A "$CHAIN_FWD" -m set --match-set "$IPSET_STAFF" src -j ACCEPT
  iptables -A "$CHAIN_FWD" -m set --match-set "$IPSET_GUEST" src -j ACCEPT

  log "event=apply_done"
}

# ---------------------------------------------------------
# Entrypoints
# ---------------------------------------------------------
case "${1:-run}" in
  run|start|"")
    apply_rules
    ;;
  stop)
    log "event=stop_start"
    # best-effort cleanup (keep ipsets; they may be used by dnsmasq)
    iptables -t nat -D PREROUTING -j "$CHAIN_NAT" >/dev/null 2>&1 || true
    iptables -D FORWARD -j "$CHAIN_FWD" >/dev/null 2>&1 || true
    flush_chain nat "$CHAIN_NAT"
    flush_chain filter "$CHAIN_FWD"
    log "event=stop_done"
    ;;
  status)
    echo "CAPTIVE_IFS=$CAPTIVE_IFS"
    echo "NGINX_PORT=$NGINX_PORT"
    iptables -t nat -nvL "$CHAIN_NAT" 2>/dev/null || true
    iptables -nvL "$CHAIN_FWD" 2>/dev/null || true
    ;;
  *)
    echo "Usage: $0 {run|start|stop|status}" >&2
    exit 2
    ;;
esac
