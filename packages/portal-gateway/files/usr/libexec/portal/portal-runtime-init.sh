#!/bin/sh
#
# portal-runtime-init.sh
#
# Portal Runtime Bootstrap (Frozen Responsibility)
#
# 职责说明：
# - 创建 Portal 运行期所需的目录与文件
# - 处理 tmpfs / overlayfs 重启即丢的问题
# - 设置最小安全权限（600）
#
# ❌ 本脚本不包含任何：
#   - Client / AP / Network 上下文逻辑
#   - 鉴权 / 策略 / 签名逻辑
#   - 业务判断
#
# 本脚本应被：
# - init.d
# - service start
# - container entrypoint
# 调用
#

set -e

log() {
    echo "[portal][runtime-init] $*"
}

log "init runtime directories"

# -------------------------------------------------------------------
# Runtime directories
# -------------------------------------------------------------------
# /tmp/portal
#   - Portal 运行期临时状态
#   - 仅本机有效，重启丢失
#
# /tmp/portal-signer
#   - signer 使用的临时文件 / socket / fifo
#
# /var/log/portal
#   - Portal 相关日志
# -------------------------------------------------------------------

mkdir -p /tmp/portal
mkdir -p /tmp/portal-signer
mkdir -p /var/log/portal

# -------------------------------------------------------------------
# Runtime context files（占位符）
# -------------------------------------------------------------------
# 注意：
# - 这些文件只是“存在性保证”
# - 是否使用、如何使用由其他组件决定
# -------------------------------------------------------------------

touch /tmp/portal-client.ctx
touch /tmp/portal-runtime.env

chmod 600 /tmp/portal-client.ctx
chmod 600 /tmp/portal-runtime.env

log "runtime init done"

exit 0