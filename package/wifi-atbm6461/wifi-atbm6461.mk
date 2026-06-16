WIFI_ATBM6461_SITE_METHOD = local
WIFI_ATBM6461_SITE = $(BR2_EXTERNAL_THINGINO_PATH)/package/wifi-atbm6461
WIFI_ATBM6461_VERSION = local

WIFI_ATBM6461_LICENSE = Proprietary
WIFI_ATBM6461_REDISTRIBUTE = NO

# linux must be built first (we read LINUX_DIR/.config and install into the module tree)
WIFI_ATBM6461_DEPENDENCIES = linux

# Module filename kept as vendor name (atbm6461_wifi_sdio) since the binary
# is not built from source and cannot be renamed without modifying ELF metadata.
ATBM6461_MODULE_NAME = atbm6461_wifi_sdio
ATBM6461_MODULE_OPTS = atbm_printk_mask=0

# Read CONFIG_LOCALVERSION from the final merged kernel .config ($(LINUX_DIR)/.config).
# Must use a package-specific variable name: other wifi packages all define
# LINUX_CONFIG_LOCALVERSION (reading the base board config), and whichever is
# included last by Make wins.  Using WIFI_ATBM6461_KERN_LOCALVER avoids the clobber.
WIFI_ATBM6461_KERN_LOCALVER = $(call qstrip,$(shell \
	awk -F= '/^CONFIG_LOCALVERSION=/ {v=$$2} END {print v}' \
		$(LINUX_DIR)/.config 2>/dev/null))

# Patch vermagic in the binary .ko from "-Immortal" to the build kernel version.
# The original slot is 52 bytes.  The new vermagic must fit within those 52
# bytes (null-padded), meaning kernel localversion ≤ 9 chars (e.g. "-Archon").
define WIFI_ATBM6461_BUILD_CMDS
	python3 -c "\
import sys, shutil; \
src = '$(@D)/files/atbm6461_wifi_sdio.ko'; \
d = bytearray(open(src,'rb').read()); \
old = b'3.10.14-Immortal preempt mod_unload MIPS32_R1 32BIT '; \
kern = '3.10.14$(WIFI_ATBM6461_KERN_LOCALVER)'; \
new_v = (kern + ' preempt mod_unload MIPS32_R1 32BIT ').encode(); \
sys.exit('ATBM6461: vermagic too long (got %d, max %d): %s' % (len(new_v), len(old), kern)) if len(new_v) > len(old) else None; \
new_v = new_v.ljust(len(old), b'\x00'); \
idx = d.find(old); \
sys.exit('ATBM6461: vermagic not found in .ko (pre-patched?)') if idx < 0 else None; \
d[idx:idx+len(old)] = new_v; \
open('$(@D)/atbm6461_wifi_sdio_patched.ko','wb').write(bytes(d)); \
print('ATBM6461: vermagic patched -> ' + kern); \
"
	$(TARGET_CC) $(TARGET_CFLAGS) -o $(@D)/z7682_disable_wdt \
		$(@D)/files/z7682_disable_wdt.c \
		-L$(@D)/files -lrtos \
		$(TARGET_LDFLAGS)
endef

define WIFI_ATBM6461_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_JZMMC_V12_MMC1)
	$(call KCONFIG_ENABLE_OPT,CONFIG_JZMMC_V12_MMC1_PB_4BIT)
	$(call KCONFIG_SET_OPT,CONFIG_MMC1_MAX_FREQ,48000000)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WLAN)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS_EXT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_CORE)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_PROC)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_PRIV)
	$(call KCONFIG_SET_OPT,CONFIG_CFG80211,y)
	$(call KCONFIG_SET_OPT,CONFIG_MAC80211,y)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_MINSTREL)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_MINSTREL_HT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_DEFAULT_MINSTREL)
	$(call KCONFIG_SET_OPT,CONFIG_MAC80211_RC_DEFAULT,"minstrel_ht")
endef

define WIFI_ATBM6461_INSTALL_CONFIGS
	$(INSTALL) -m 0755 -d \
		$(TARGET_DIR)/usr/lib/modules/3.10.14$(WIFI_ATBM6461_KERN_LOCALVER)
	touch \
		$(TARGET_DIR)/usr/lib/modules/3.10.14$(WIFI_ATBM6461_KERN_LOCALVER)/modules.builtin.modinfo

	$(INSTALL) -D -m 0755 $(@D)/files/librtos.so \
		$(TARGET_DIR)/usr/lib/librtos.so

	$(INSTALL) -D -m 0755 $(@D)/z7682_disable_wdt \
		$(TARGET_DIR)/usr/bin/z7682_disable_wdt

	$(INSTALL) -D -m 0755 $(@D)/files/F00atbm-wdt \
		$(TARGET_DIR)/etc/init.d/F00atbm-wdt
endef

WIFI_ATBM6461_POST_INSTALL_TARGET_HOOKS += WIFI_ATBM6461_INSTALL_CONFIGS

define WIFI_ATBM6461_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(@D)/atbm6461_wifi_sdio_patched.ko \
		$(TARGET_DIR)/usr/lib/modules/3.10.14$(WIFI_ATBM6461_KERN_LOCALVER)/extra/atbm6461_wifi_sdio.ko
endef

$(eval $(generic-package))
