WIFI_ATBM6162S_SITE_METHOD = git
WIFI_ATBM6162S_SITE = https://github.com/gtxaspec/atbm-wifi
WIFI_ATBM6162S_SITE_BRANCH = atbm-606x
WIFI_ATBM6162S_VERSION = 3de8e9e8a32a912c8e26f40f47110199643b2417

WIFI_ATBM6162S_LICENSE = GPL-2.0

ATBM6162S_MODULE_NAME = atbm6162s
ATBM6162S_MODULE_OPTS = "wifi_bt_comb=1 WL_REG_EN=47"
ATBM6162S_FIRMWARE = atbm6162s_stock_dpll40_ble.bin
ATBM6162S_FALLBACK_FIRMWARE = cronus_SDIO_24M_SDIO_svn19514_WiFiBLEComb_DCDC.bin
ATBM6162S_STOCK_MODULE = $(BR2_EXTERNAL_THINGINO_PATH)/stock/wyze_panv4/rootfs/lib/modules/ATBM6x6x_wifi_sdio.ko

WIFI_ATBM6162S_MODULE_MAKE_OPTS = \
	KDIR=$(LINUX_DIR)

define WIFI_ATBM6162S_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_WLAN)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS_EXT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_CORE)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_PROC)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_PRIV)
	$(call KCONFIG_SET_OPT,CONFIG_FW_LOADER,m)
	$(call KCONFIG_SET_OPT,CONFIG_CFG80211,m)
	$(call KCONFIG_ENABLE_OPT,CONFIG_CFG80211_WEXT)
	$(call KCONFIG_SET_OPT,CONFIG_MAC80211,m)
	$(call KCONFIG_SET_OPT,CONFIG_CRYPTO_LIB_ARC4,m)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_MINSTREL)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_MINSTREL_HT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_DEFAULT_MINSTREL)
	$(call KCONFIG_SET_OPT,CONFIG_MAC80211_RC_DEFAULT,"minstrel_ht")
endef

LINUX_CONFIG_LOCALVERSION = $(shell awk -F "=" '/^CONFIG_LOCALVERSION=/ {print $$2}' $(BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE))

define WIFI_ATBM6162S_INSTALL_CONFIGS
	$(INSTALL) -m 0755 -d $(TARGET_DIR)/usr/lib/modules/$(KERNEL_VERSION)$(LINUX_CONFIG_LOCALVERSION)
	touch $(TARGET_DIR)/usr/lib/modules/$(KERNEL_VERSION)$(LINUX_CONFIG_LOCALVERSION)/modules.builtin.modinfo

	$(INSTALL) -m 0755 -d $(TARGET_DIR)/usr/share/wifi
	$(INSTALL) -m 0644 -t $(TARGET_DIR)/usr/share/wifi \
		$(WIFI_ATBM_WIFI_PKGDIR)/files/*.txt

	$(INSTALL) -D -m 0644 $(@D)/firmware/$(ATBM6162S_FIRMWARE) \
		$(TARGET_DIR)/usr/lib/firmware/$(call qstrip,$(ATBM6162S_MODULE_NAME))_fw.bin
endef

WIFI_ATBM6162S_POST_INSTALL_TARGET_HOOKS += WIFI_ATBM6162S_INSTALL_CONFIGS

define WIFI_ATBM6162S_COPY_CONFIG
	if [ -r "$(ATBM6162S_STOCK_MODULE)" ]; then \
		python3 $(WIFI_ATBM6162S_PKGDIR)/files/extract_stock_firmware.py \
			"$(ATBM6162S_STOCK_MODULE)" \
			$(@D)/firmware/$(ATBM6162S_FIRMWARE); \
	else \
		echo "ATBM6162S stock module not found; using bundled fallback firmware"; \
		cp $(@D)/firmware/$(ATBM6162S_FALLBACK_FIRMWARE) \
			$(@D)/firmware/$(ATBM6162S_FIRMWARE); \
	fi
	sed -i '/#include <net\/ipx.h>/d' \
		$(@D)/hal_apollo/mac80211/bridge.c
	sed -i \
		-e 's|cfg80211_tx_mlme_mgmt(sdata->dev, (u8\*)mgmt, skb->len);|cfg80211_tx_mlme_mgmt(sdata->dev, (u8*)mgmt, skb->len, false);|g' \
		$(@D)/hal_apollo/mac80211/mlme.c
	$(INSTALL) -D -m 0644 $(@D)/configs/atbm6062s.config \
		$(@D)/.config
	sed -i \
		-e 's|^CONFIG_ATBM_MODULE_NAME_WIFI6=.*|CONFIG_ATBM_MODULE_NAME_WIFI6="$(call qstrip,$(ATBM6162S_MODULE_NAME))"|' \
		-e 's|^CONFIG_ATBM_FW_NAME_WIFI6=.*|CONFIG_ATBM_FW_NAME_WIFI6="$(call qstrip,$(ATBM6162S_MODULE_NAME))_fw.bin"|' \
		-e 's|^# CONFIG_ATBM_BLE_WIFI6 is not set|CONFIG_ATBM_BLE_WIFI6=y|' \
		$(@D)/.config
	sed -i \
		-e '/^CONFIG_ATBM_SDIO_MMCx_WIFI6=/d' \
		-e '/^CONFIG_ATBM_BLE_WIFI_PLATFORM_WIFI6=/d' \
		-e '/^# CONFIG_ATBM_BLE_WIFI_PLATFORM_WIFI6 is not set/d' \
		-e '/^CONFIG_ATBM_BLE_ADV_COEXIST_WIFI6=/d' \
		-e '/^# CONFIG_ATBM_BLE_ADV_COEXIST_WIFI6 is not set/d' \
		$(@D)/.config
	printf '%s\n' \
		'CONFIG_ATBM_SDIO_MMCx_WIFI6="mmc1"' \
		'CONFIG_ATBM_BLE_WIFI_PLATFORM_WIFI6=y' \
		'# CONFIG_ATBM_BLE_ADV_COEXIST_WIFI6 is not set' \
		>> $(@D)/.config
	sed -i \
		-e 's|static int WL_REG_EN = .*;|static int WL_REG_EN = 47;|g' \
		-e 's|GPIO_PC(12)|76|g' \
		-e 's|^[[:space:]]*\.power_ctrl = NULL,.*||' \
		$(@D)/hal_apollo/atbm_platform.c
	sed -i 's|^\(#define PLATFORM_SUN8I[[:space:]]*\)(23)|\1(5)|' \
		$(@D)/hal_apollo/apollo_plat.h
	grep -q 'module_param(WL_REG_EN' $(@D)/hal_apollo/atbm_platform.c || \
		sed -i '/static int WL_REG_EN = 47;/a module_param(WL_REG_EN, int, 0644);' \
			$(@D)/hal_apollo/atbm_platform.c
	sed -i \
		-e 's|\.power_ctrl   = atbm_power_ctrl,|.power_ctrl   = NULL,|g' \
		-e 's|\.insert_ctrl  = atbm_insert_crtl,|.insert_ctrl  = NULL,|g' \
		$(@D)/hal_apollo/atbm_platform.c
	sed -i \
		's|^\([[:space:]]*\)ret = atbm_sdio_on(pdata);|\1if (ATBM_WIFI_PLATFORM != PLATFORM_INGENICT41)\n\1\tret = atbm_sdio_on(pdata);|' \
		$(@D)/hal_apollo/apollo_sdio.c
	sed -i 's|-DDPLL_CLOCK=DPLL_CLOCK_24M|-DDPLL_CLOCK=DPLL_CLOCK_40M|g' \
		$(@D)/hal_apollo/Makefile
	$(INSTALL) -D -m 0644 $(WIFI_ATBM6162S_PKGDIR)/files/Kbuild.5.15 \
		$(@D)/Kbuild
endef

WIFI_ATBM6162S_PRE_CONFIGURE_HOOKS += WIFI_ATBM6162S_COPY_CONFIG

$(eval $(kernel-module))
$(eval $(generic-package))
