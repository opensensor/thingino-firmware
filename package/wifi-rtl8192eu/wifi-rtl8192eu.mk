WIFI_RTL8192EU_SITE_METHOD = git
WIFI_RTL8192EU_SITE = https://github.com/mange/rtl8192eu-linux-driver
WIFI_RTL8192EU_SITE_BRANCH = realtek-4.4.x
WIFI_RTL8192EU_VERSION = $(shell git ls-remote $(WIFI_RTL8192EU_SITE) $(WIFI_RTL8192EU_SITE_BRANCH) | head -1 | cut -f1)

WIFI_RTL8192EU_LICENSE = GPL-2.0
WIFI_RTL8192EU_LICENSE_FILES = COPYING
WIFI_RTL8192EU_MODULE_MAKE_OPTS = CONFIG_RTL8192EU=m

define WIFI_RTL8192EU_INSTALL_FIRMWARE
	$(INSTALL) -D -m 644 $(WIFI_RTL8192EU_PKGDIR)/rtl8192her.bin \
		$(TARGET_DIR)/lib/firmware/rtlwifi/rtl8192her.bin
endef

# WIFI_RTL8192EU_POST_INSTALL_TARGET_HOOKS += WIFI_RTL8192EU_INSTALL_FIRMWARE

$(eval $(kernel-module))
$(eval $(generic-package))
