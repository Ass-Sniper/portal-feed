#!/bin/sh

set -e

echo "[portal] init runtime directories"

mkdir -p /tmp/portal
mkdir -p /tmp/portal-signer
mkdir -p /var/log/portal

# Runtime context files
touch /tmp/portal-client.ctx
touch /tmp/portal-runtime.env

chmod 600 /tmp/portal-client.ctx
chmod 600 /tmp/portal-runtime.env

echo "[portal] runtime init done"