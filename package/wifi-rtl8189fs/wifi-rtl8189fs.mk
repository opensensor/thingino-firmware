WIFI_RTL8189FS_SITE_METHOD = git
WIFI_RTL8189FS_SITE = https://github.com/gtxaspec/rtl8189fs-wifi
WIFI_RTL8189FS_SITE_BRANCH = master
WIFI_RTL8189FS_VERSION = e78756219d4d437d8ccb9b9b1db703ac920716ba

WIFI_RTL8189FS_LICENSE = GPL-2.0
WIFI_RTL8189FS_LICENSE_FILES = COPYING

RTL8189FS_MODULE_NAME = 8189fs
RTL8189FS_MODULE_OPTS =

# The vendor firmware's LPS/SmartPS implementation repeatedly enters and
# leaves power-save mode on the mainline Ingenic SDIO host.  Besides flooding
# the log, this produces multi-second latency and heavy TCP retransmission.
# Keep the legacy kernel defaults intact and disable IPS/LPS only for the
# mainline build where the incompatibility is observed.
ifeq ($(KERNEL_VERSION_7),y)
RTL8189FS_MODULE_OPTS = rtw_power_mgnt=0 rtw_ips_mode=0 rtw_lps_chk_by_tp=0
endif

WIFI_RTL8189FS_MODULE_MAKE_OPTS = \
	CONFIG_RTL8189FS=m

# A few source files in the vendor tree use DOS line endings.  Normalize the
# files touched by our compatibility patch so Buildroot's patch helper can
# apply a conventional, reviewable patch on every host.
define WIFI_RTL8189FS_NORMALIZE_PATCHED_SOURCES
	$(SED) 's/\r$$//' $(@D)/core/rtw_br_ext.c
	$(SED) 's/\r$$//' $(@D)/include/osdep_service_linux.h
endef

WIFI_RTL8189FS_POST_EXTRACT_HOOKS += WIFI_RTL8189FS_NORMALIZE_PATCHED_SOURCES

define WIFI_RTL8189FS_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_WLAN)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS)
	$(call KCONFIG_SET_OPT,CONFIG_CFG80211,y)
	$(call KCONFIG_SET_OPT,CONFIG_MAC80211,y)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_MINSTREL)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_MINSTREL_HT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_DEFAULT_MINSTREL)
	$(call KCONFIG_SET_OPT,CONFIG_MAC80211_RC_DEFAULT,"minstrel_ht")
endef

define WIFI_RTL8189FS_INSTALL_CONFIGS
	$(INSTALL) -D -m 0644 $(WIFI_RTL8189FS_PKGDIR)/files/PHY_REG_PG.txt \
		$(TARGET_DIR)/usr/lib/firmware/PHY_REG_PG.txt
endef

WIFI_RTL8189FS_POST_INSTALL_TARGET_HOOKS += WIFI_RTL8189FS_INSTALL_CONFIGS

$(eval $(kernel-module))
$(eval $(generic-package))
