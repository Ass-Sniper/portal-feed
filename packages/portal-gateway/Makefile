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
    +nginx-ssl \
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

# No build step (pure scripts + configs)
define Build/Compile
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

	# native nginx.conf for portal gateway
	$(INSTALL_DIR) $(1)/etc/nginx
	$(INSTALL_CONF) ./files/etc/nginx/nginx.conf \
		$(1)/etc/nginx/nginx.conf

	# nginx portal configuration
	$(INSTALL_DIR) $(1)/etc/nginx/conf.d/portal
	$(INSTALL_CONF) ./files/etc/nginx/conf.d/portal/*.conf \
		$(1)/etc/nginx/conf.d/portal/

	# signer placeholder (future C/C++ binary)
	$(INSTALL_DIR) $(1)/usr/libexec/portal/signer

	# documentation
	$(INSTALL_DIR) $(1)/usr/share/doc/portal-gateway
	$(INSTALL_CONF) ./README.md \
		$(1)/usr/share/doc/portal-gateway/README.md
endef

define Package/portal-gateway/postinst
#!/bin/sh
# postinst is executed by opkg after package installation
# IPKG_INSTROOT is set during image build, skip runtime actions then
[ -n "$$IPKG_INSTROOT" ] && exit 0

echo "[portal-gateway] postinst start"

# ------------------------------------------------
# nginx capability check (non-fatal)
# ------------------------------------------------
CHECKER="/usr/libexec/portal/check-nginx.sh"

if [ -x "$CHECKER" ]; then
    if ! QUIET=1 "$CHECKER"; then
        echo "[portal-gateway] WARNING: nginx capability check failed"
        echo "[portal-gateway] Portal Gateway may not function correctly"
        echo "[portal-gateway] See logread for details"
    fi
else
    echo "[portal-gateway] NOTE: nginx checker not found: $CHECKER"
fi

# ------------------------------------------------
# enable & start service
# ------------------------------------------------
if [ -x /etc/init.d/portal-gateway ]; then
    /etc/init.d/portal-gateway enable
    /etc/init.d/portal-gateway restart || true
fi

echo "[portal-gateway] postinst done"
exit 0
endef

$(eval $(call BuildPackage,portal-gateway))