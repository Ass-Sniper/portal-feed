#
# Copyright (C) 2025
#
# Portal Gateway for ImmortalWrt / OpenWrt
#

include $(TOPDIR)/rules.mk

PKG_NAME:=portal-gateway
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=Portal Gateway Team

include $(INCLUDE_DIR)/package.mk

define Package/portal-gateway
  SECTION:=network
  CATEGORY:=Network
  SUBMENU:=Captive Portals
  TITLE:=Portal Gateway (nginx-based captive portal gateway)
  DEPENDS:= \
    +nginx-all-module \
    +nginx-util \
    +nginx-ssl-util \
    +iptables \
    +ipset \
    +curl \
    +ca-bundle \
    +libpcre
endef

define Package/portal-gateway/description
 Portal Gateway based on nginx for ImmortalWrt / OpenWrt.

 This package provides:
  - nginx-based HTTP portal gateway
  - iptables DNAT integration
  - OS captive probe handling
  - Header injection (MAC / SSID / Radio)
  - auth_request + HMAC signer support
  - Multi-SSID / Multi-Radio support

 It is designed to work with external Portal Server
 and Controller (AC-style architecture).
endef

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR)/src/portal-signer \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" \
		LDFLAGS="$(TARGET_LDFLAGS)"
endef

define Package/portal-gateway/install
	# init script
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/portal-gateway \
		$(1)/etc/init.d/portal-gateway

	# UCI config
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/portal \
		$(1)/etc/config/portal

	# portal runtime scripts
	$(INSTALL_DIR) $(1)/usr/libexec/portal
	$(INSTALL_BIN) ./files/usr/libexec/portal/portal-fw.sh \
		$(1)/usr/libexec/portal/portal-fw.sh
	$(INSTALL_BIN) ./files/usr/libexec/portal/portal-agent.sh \
		$(1)/usr/libexec/portal/portal-agent.sh
	$(INSTALL_BIN) ./files/usr/libexec/portal/portal-context.sh \
		$(1)/usr/libexec/portal/portal-context.sh
	$(INSTALL_BIN) ./files/usr/libexec/portal/portal-runtime-init.sh \
		$(1)/usr/libexec/portal/portal-runtime-init.sh
	$(INSTALL_BIN) ./files/usr/libexec/portal/check-nginx.sh \
		$(1)/usr/libexec/portal/check-nginx.sh

	# native nginx.conf for portal gateway
	$(INSTALL_DIR) $(1)/etc/nginx
	$(INSTALL_CONF) ./files/etc/nginx/nginx.conf \
		$(1)/etc/nginx/nginx.conf

	# nginx portal configuration
	$(INSTALL_DIR) $(1)/etc/nginx/conf.d/portal
	$(INSTALL_CONF) ./files/etc/nginx/conf.d/portal/*.conf \
		$(1)/etc/nginx/conf.d/portal/

	# -----------------------------------------------------
	# Install portal-signer daemon
	# This is the local auth_request signer service
	# listening on 127.0.0.1:9000 for nginx
	# -----------------------------------------------------
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) \
		$(PKG_BUILD_DIR)/src/portal-signer/portal-signer \
		$(1)/usr/sbin/portal-signer

endef

define Package/portal-gateway/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

# =========================================================
# Portal signer key initialization
# =========================================================
KEY_FILE="/etc/portal/portal.signing.key"

mkdir -p /etc/portal

if [ ! -f "$$KEY_FILE" ]; then
    echo "[portal-gateway] Generating portal signing key"

    head -c 32 /dev/urandom | \
        hexdump -e '32/1 "%02x"' > "$$KEY_FILE"

    chmod 600 "$$KEY_FILE"
fi

# =========================================================
# Existing nginx capability check (unchanged)
# =========================================================
CHECKER="/usr/libexec/portal/check-nginx.sh"

if [ -x "$$CHECKER" ]; then
    if ! QUIET=1 "$$CHECKER"; then
        echo "[portal-gateway] WARNING: nginx capability check failed"
        echo "[portal-gateway] Portal Gateway may not function correctly"
        echo "[portal-gateway] See logread for details"
    fi
else
    echo "[portal-gateway] NOTE: nginx checker not found: $$CHECKER"
fi

echo "[portal-gateway] postinst done"
exit 0
endef

$(eval $(call BuildPackage,portal-gateway))