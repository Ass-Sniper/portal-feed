#!/bin/sh
#
# portal-context.sh
#
# Portal Context Inspection Tool
#
# 设计定位：
# - 只读调试 / 自检工具
# - 用于观测 portal 数据面与运行时状态
# - 不参与生产链路、不修改系统状态
#
# ❌ 不做：
#   - Header 注入
#   - 鉴权 / 授权
#   - 签名 / 策略决策
#
# 使用方式：
#   portal-context.sh dump
#   portal-context.sh help
#

set -e

CMD="$1"

log() {
    echo "[portal][context] $*"
}

die() {
    echo "[portal][context][error] $*" >&2
    exit 1
}

# -------------------------------------------------------------------
# Help
# -------------------------------------------------------------------

cmd_help() {
    cat <<'EOF'
portal-context.sh - Portal Context Inspection Tool

USAGE:
  portal-context.sh <command>

COMMANDS:
  dump        Dump current portal / data-plane context (read-only)
  help        Show this help message

DESCRIPTION:
  This tool inspects observable portal-related runtime context
  from the data plane. It is intended for:

    - Debugging portal-fw / portal-agent behavior
    - Inspecting ipset / ARP / conntrack state (if available)
    - Local verification without nginx / HTTP involved

  This tool DOES NOT:
    - Modify system state
    - Inject HTTP headers
    - Perform authentication / authorization
    - Generate or verify signatures

EXAMPLES:
  portal-context.sh dump
  portal-context.sh help

EOF
}

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

dump_kv() {
    key="$1"
    val="$2"
    printf "%-20s : %s\n" "$key" "$val"
}

cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

# -------------------------------------------------------------------
# Context Collectors（只读、允许降级）
# -------------------------------------------------------------------

get_client_ip() {
    ip neigh 2>/dev/null | awk 'NR==1 {print $1}'
}

get_client_mac() {
    ip neigh 2>/dev/null | awk 'NR==1 {print $5}'
}

get_ssid() {
    [ -n "$portal_ssid" ] && echo "$portal_ssid" || echo "unknown"
}

get_vlan() {
    [ -n "$portal_vlan_id" ] && echo "$portal_vlan_id" || echo "unknown"
}

get_ap_id() {
    [ -n "$portal_ap_id" ] && echo "$portal_ap_id" || echo "unknown"
}

# -------------------------------------------------------------------
# Optional Inspectors（无强依赖）
# -------------------------------------------------------------------

dump_ipset() {
    log "ipset (portal related)"

    if cmd_exists ipset; then
        ipset list 2>/dev/null | sed 's/^/  /'
    else
        echo "  [ipset unavailable]"
    fi
}

dump_conntrack() {
    log "conntrack (portal related)"

    if cmd_exists conntrack; then
        conntrack -L 2>/dev/null | sed 's/^/  /' | head -n 20
        return
    fi

    if [ -r /proc/net/nf_conntrack ]; then
        sed 's/^/  /' /proc/net/nf_conntrack | head -n 20
        return
    fi

    echo "  [conntrack unavailable]"
}

# -------------------------------------------------------------------
# Commands
# -------------------------------------------------------------------

cmd_dump() {
    log "dump portal context (read-only)"

    dump_kv "Client-IP"   "$(get_client_ip)"
    dump_kv "Client-MAC"  "$(get_client_mac)"
    dump_kv "SSID"        "$(get_ssid)"
    dump_kv "VLAN-ID"     "$(get_vlan)"
    dump_kv "AP-ID"       "$(get_ap_id)"

    echo
    dump_ipset

    echo
    dump_conntrack

    echo
    log "dump done"
}

# -------------------------------------------------------------------
# Entry
# -------------------------------------------------------------------

case "$CMD" in
    dump)
        cmd_dump
        ;;
    help|-h|--help|"")
        cmd_help
        ;;
    *)
        die "unknown command: $CMD (use 'help')"
        ;;
esac