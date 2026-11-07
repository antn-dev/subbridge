# SubBridge has two entry points:
#
#   make            build dist/subbridge_<version>-r<release>_all.ipk locally
#   make test       run the ucode unit tests (needs ucode, e.g. on the router)
#
# The same file is a valid OpenWrt package Makefile. Symlink the repository as
#   $(TOPDIR)/package/subbridge
# and the buildroot picks it up (TOPDIR is set by the buildroot).
ifneq ($(TOPDIR),)

include $(TOPDIR)/rules.mk

PKG_NAME:=subbridge
PKG_VERSION:=$(shell cat $(CURDIR)/VERSION)
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=SubBridge contributors

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/subbridge
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=Compact subscription checker written in ucode
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-socket +ucode-mod-uci +ucode-mod-ubus \
	+uclient-fetch +luci-base +ca-bundle
  CONFLICTS:=luci-app-subbridge
  PKGARCH:=all
endef

define Package/subbridge/description
 Downloads a provider subscription with the expected client headers, resolves
 handoff pages, parses JSON profiles or vless:// links and measures every
 endpoint through the installed sing-box. The package is architecture
 independent and never touches routing, DNS, nftables or a running
 Podkop/Forkop service.
endef

define Package/subbridge/conffiles
/etc/config/subbridge
endef

define Package/subbridge/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || { \
	chmod 600 /etc/config/subbridge 2>/dev/null; \
	rm -f /etc/config/subbridge-opkg 2>/dev/null; \
	rm -f /etc/config/subbridge.apk-new 2>/dev/null; \
	mkdir -p /etc/subbridge; \
	chmod 700 /etc/subbridge 2>/dev/null; \
	rm -f /tmp/luci-indexcache.* 2>/dev/null; \
	rm -rf /tmp/luci-modulecache/ 2>/dev/null; \
	[ -x /etc/uci-defaults/90_luci-app-subbridge ] && { \
		/etc/uci-defaults/90_luci-app-subbridge; \
		rm -f /etc/uci-defaults/90_luci-app-subbridge 2>/dev/null; \
	}; \
	if [ "$$(uci -q get subbridge.main.enabled)" != "0" ]; then \
		/etc/init.d/subbridge enable 2>/dev/null; \
		/etc/init.d/subbridge restart 2>/dev/null; \
	fi; \
	/etc/init.d/rpcd reload 2>/dev/null; \
}
exit 0
endef

define Package/subbridge/prerm
#!/bin/sh
[ -s "$${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. "$${IPKG_INSTROOT}/lib/functions.sh"
default_prerm "$$0" "$$@"
exit 0
endef

define Package/subbridge/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || { \
	rm -rf /tmp/subbridge /tmp/subbridge-check.lock 2>/dev/null; \
	rm -rf /tmp/subbridge-check-* /tmp/subbridge-fetch-* /tmp/subbridge-delay-* /tmp/subbridge-probe-* 2>/dev/null; \
	rm -f /tmp/luci-indexcache.* 2>/dev/null; \
	rm -rf /tmp/luci-modulecache/ 2>/dev/null; \
	/etc/init.d/rpcd reload 2>/dev/null; \
}
exit 0
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(CURDIR)/src/*.uc $(PKG_BUILD_DIR)/
endef

define Build/Compile
endef

define Package/subbridge/install
	$(INSTALL_DIR) $(1)/usr/lib/subbridge
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/*.uc $(1)/usr/lib/subbridge/
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(CURDIR)/package/files/usr/bin/subbridge $(1)/usr/bin/subbridge
	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DATA) $(CURDIR)/package/files/usr/share/rpcd/ucode/subbridge $(1)/usr/share/rpcd/ucode/subbridge
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) $(CURDIR)/package/files/usr/share/rpcd/acl.d/luci-app-subbridge.json $(1)/usr/share/rpcd/acl.d/luci-app-subbridge.json
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) $(CURDIR)/package/files/usr/share/luci/menu.d/luci-app-subbridge.json $(1)/usr/share/luci/menu.d/luci-app-subbridge.json
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/subbridge
	$(INSTALL_DATA) $(CURDIR)/package/files/www/luci-static/resources/view/subbridge/main.js $(1)/www/luci-static/resources/view/subbridge/main.js
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/package/files/etc/init.d/subbridge $(1)/etc/init.d/subbridge
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(CURDIR)/package/files/etc/uci-defaults/90_luci-app-subbridge $(1)/etc/uci-defaults/90_luci-app-subbridge
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/package/files/etc/config/subbridge $(1)/etc/config/subbridge
	$(INSTALL_DIR) $(1)/usr/share/subbridge
	printf '%s\n' '$(PKG_VERSION)' > $(1)/usr/share/subbridge/version
	chmod 0644 $(1)/usr/share/subbridge/version
endef

$(eval $(call BuildPackage,subbridge))

else

VERSION := $(shell cat VERSION)

.PHONY: all package apk dist clean test check

all: package

package:
	./scripts/build.sh

apk:
	./scripts/build-apk.sh

dist: package

clean:
	rm -rf dist

# ucode is the OpenWrt interpreter; the test target refuses to run silently
# when it is missing on the host.
test check:
	./scripts/test.sh

endif
