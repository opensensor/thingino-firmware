WIFI_ATBM6062S_SITE_METHOD = git
WIFI_ATBM6062S_SITE = https://github.com/gtxaspec/atbm-wifi
WIFI_ATBM6062S_SITE_BRANCH = atbm-606x
WIFI_ATBM6062S_VERSION = 4164499b15fb28d1f1fa694088f42dc2493f377e

WIFI_ATBM6062S_LICENSE = GPL-2.0

ATBM6062S_MODULE_NAME = atbm6062s
ATBM6062S_MODULE_OPTS = atbm_printk_mask=0

WIFI_ATBM6062S_MODULE_MAKE_OPTS = \
	KDIR=$(LINUX_DIR)

ATBM6062S_VENDOR_PLATFORM_OPTS = \
	PLAT=PLATFORM_INGENICT41 \
	ATBM_WIFI__EXT_CCFLAGS="-DATBM_WIFI_PLATFORM=23" \
	SDIO_HOST=mmc1

define WIFI_ATBM6062S_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_WLAN)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS_EXT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_CORE)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_PROC)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_PRIV)
	# Must disable kernel's CFG80211, driver provides it's own.
	$(call KCONFIG_DISABLE_OPT,CONFIG_CFG80211)
	$(call KCONFIG_SET_OPT,CONFIG_MAC80211,y)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_MINSTREL)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_MINSTREL_HT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_DEFAULT_MINSTREL)
	$(call KCONFIG_SET_OPT,CONFIG_MAC80211_RC_DEFAULT,"minstrel_ht")
endef

LINUX_CONFIG_LOCALVERSION = $(shell awk -F "=" '/^CONFIG_LOCALVERSION=/ {print $$2}' $(BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE))

define WIFI_ATBM6062S_INSTALL_CONFIGS
	$(INSTALL) -m 0755 -d $(TARGET_DIR)/lib/modules/3.10.14$(LINUX_CONFIG_LOCALVERSION)
	touch $(TARGET_DIR)/lib/modules/3.10.14$(LINUX_CONFIG_LOCALVERSION)/modules.builtin.modinfo

	$(INSTALL) -m 0755 -d $(TARGET_DIR)/usr/share/wifi
	$(INSTALL) -m 0644 -t $(TARGET_DIR)/usr/share/wifi \
		$(WIFI_ATBM_WIFI_PKGDIR)/files/*.txt

	$(INSTALL) -D -m 0644 $(@D)/firmware/cronus_SDIO_NoBLE_SDIO_svn19514_24M_wifi6phy_DCDC.bin \
		$(TARGET_DIR)/lib/firmware/$(call qstrip,$(ATBM6062S_MODULE_NAME))_fw.bin
endef

WIFI_ATBM6062S_POST_INSTALL_TARGET_HOOKS += WIFI_ATBM6062S_INSTALL_CONFIGS

define WIFI_ATBM6062S_COPY_CONFIG
	$(INSTALL) -D -m 0644 $(@D)/configs/atbm6062u.config \
		$(@D)/.config
	sed -i 's/CONFIG_ATBM_USB_BUS_WIFI6=y/# CONFIG_ATBM_USB_BUS_WIFI6 is not set/' $(@D)/.config
	sed -i 's/# CONFIG_ATBM_SDIO_BUS_WIFI6 is not set/CONFIG_ATBM_SDIO_BUS_WIFI6=y/' $(@D)/.config
	grep -q '^CONFIG_ATBM_SDIO_MMCx_WIFI6=' $(@D)/.config \
		&& sed -i 's/^CONFIG_ATBM_SDIO_MMCx_WIFI6=.*/CONFIG_ATBM_SDIO_MMCx_WIFI6="mmc1"/' $(@D)/.config \
		|| echo 'CONFIG_ATBM_SDIO_MMCx_WIFI6="mmc1"' >> $(@D)/.config
	sed -i 's/CONFIG_ATBM_MODULE_NAME_WIFI6="atbm6062u"/CONFIG_ATBM_MODULE_NAME_WIFI6="atbm6062s"/' $(@D)/.config
	sed -i 's/CONFIG_ATBM_FW_NAME_WIFI6="atbm6062u_fw.bin"/CONFIG_ATBM_FW_NAME_WIFI6="atbm6062s_fw.bin"/' $(@D)/.config
	sed -i 's/CONFIG_CPTCFG_CFG80211_WEXT=y/# CONFIG_CPTCFG_CFG80211_WEXT is not set/' $(@D)/.config
endef

WIFI_ATBM6062S_PRE_CONFIGURE_HOOKS += WIFI_ATBM6062S_COPY_CONFIG

# Custom build command using the driver's own Makefile.build.customer.
# That file does "-include .config" and exports all CONFIG_* / bus / module
# name variables before recursing into the kernel kbuild for each subdir.
# Calling the kernel kbuild directly (M=wireless / M=hal_apollo) without
# those variables causes obj-$(CONFIG_ATBM_APOLLO_WIFI6) etc. to be empty
# and no .ko files are produced.
define WIFI_ATBM6062S_BUILD_CMDS
	@echo "Preparing kernel for module build..."
	$(LINUX_MAKE_ENV) $(MAKE) $(LINUX_MAKE_FLAGS) -C $(LINUX_DIR) modules_prepare
	@echo "Building atbm6062s modules via Makefile.build.customer..."
	$(LINUX_MAKE_ENV) $(MAKE) \
		-C $(@D) \
		-f Makefile.build.customer \
		KDIR=$(LINUX_DIR) \
		ARCH=$(KERNEL_ARCH) \
		CROSS_COMPILE="$(TARGET_CROSS)" \
		$(ATBM6062S_VENDOR_PLATFORM_OPTS) \
		SYS=Linux \
		modules
endef

# Custom install command to install both modules
define WIFI_ATBM6062S_INSTALL_TARGET_CMDS
	$(LINUX_MAKE_ENV) $(MAKE) $(LINUX_MAKE_FLAGS) \
		-C $(LINUX_DIR) \
		M=$(@D)/wireless \
		modules_install
	$(LINUX_MAKE_ENV) $(MAKE) $(LINUX_MAKE_FLAGS) \
		-C $(LINUX_DIR) \
		M=$(@D)/hal_apollo \
		modules_install
endef

$(eval $(generic-package))
