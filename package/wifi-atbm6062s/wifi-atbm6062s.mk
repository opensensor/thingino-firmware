WIFI_ATBM6062S_SITE = $(BR2_EXTERNAL_THINGINO_PATH)/package/wifi-atbm6062s-custom/atbm-wifi-local
WIFI_ATBM6062S_SITE_METHOD = local

WIFI_ATBM6062S_LICENSE = GPL-2.0

# Build using the driver's custom build system (Makefile.build.customer)
# This provides WPA3 support via backported cfg80211/mac80211
define WIFI_ATBM6062S_BUILD_CMDS
	$(MAKE) -C $(@D) \
		KERDIR=$(LINUX_DIR) \
		arch=$(KERNEL_ARCH) \
		CROSS_COMPILE=$(TARGET_CROSS) \
		install
endef

define WIFI_ATBM6062S_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(@D)/driver_install/cfg80211.ko \
		$(TARGET_DIR)/lib/modules/$(LINUX_VERSION_PROBED)/extra/cfg80211.ko
	$(INSTALL) -D -m 0644 $(@D)/driver_install/atbm6062s.ko \
		$(TARGET_DIR)/lib/modules/$(LINUX_VERSION_PROBED)/extra/atbm6062s.ko
endef

define WIFI_ATBM6062S_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_WLAN)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS_EXT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_CORE)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_PROC)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_PRIV)
	# Disable kernel's CFG80211/MAC80211 - driver provides its own with WPA3 support
	$(call KCONFIG_DISABLE_OPT,CONFIG_CFG80211)
	$(call KCONFIG_DISABLE_OPT,CONFIG_MAC80211)
endef

LINUX_CONFIG_LOCALVERSION = $(shell awk -F "=" '/^CONFIG_LOCALVERSION=/ {print $$2}' $(BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE))

define WIFI_ATBM6062S_INSTALL_CONFIGS
	$(INSTALL) -m 0755 -d $(TARGET_DIR)/lib/modules/3.10.14$(LINUX_CONFIG_LOCALVERSION)
	touch $(TARGET_DIR)/lib/modules/3.10.14$(LINUX_CONFIG_LOCALVERSION)/modules.builtin.modinfo

	$(INSTALL) -m 0755 -d $(TARGET_DIR)/usr/share/wifi
	$(INSTALL) -m 0644 -t $(TARGET_DIR)/usr/share/wifi \
		$(WIFI_ATBM_WIFI_PKGDIR)/files/*.txt

	$(INSTALL) -D -m 0644 $(@D)/firmware/cronus_SDIO_NoBLE_SDIO_svn19514_24M_wifi6phy_DCDC.bin \
		$(TARGET_DIR)/lib/firmware/atbm6062s_fw.bin
endef

WIFI_ATBM6062S_POST_INSTALL_TARGET_HOOKS += WIFI_ATBM6062S_INSTALL_CONFIGS

define WIFI_ATBM6062S_COPY_CONFIG
	$(INSTALL) -D -m 0644 $(@D)/configs/atbm6062s.config \
		$(@D)/.config
endef

WIFI_ATBM6062S_PRE_BUILD_HOOKS += WIFI_ATBM6062S_COPY_CONFIG

$(eval $(generic-package))
