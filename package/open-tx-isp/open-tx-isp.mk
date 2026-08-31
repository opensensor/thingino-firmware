################################################################################
#
# open-tx-isp
#
################################################################################

OPEN_TX_ISP_SITE_METHOD = git
OPEN_TX_ISP_SITE = https://github.com/opensensor/open-tx-isp
OPEN_TX_ISP_SITE_BRANCH = main
OPEN_TX_ISP_VERSION = 686d23216d06e09c076ae61ba4e7e6d8734f46b0

# Upstream identifies the project as GPLv3 but does not currently ship a
# top-level license file for legal-info to collect.
OPEN_TX_ISP_LICENSE = GPL-3.0

OPEN_TX_ISP_DEPENDENCIES = ingenic-sdk linux

# Build as out-of-tree kernel module
OPEN_TX_ISP_MODULE_SUBDIRS = driver/$(SOC_FAMILY)

OPEN_TX_ISP_MODULE_MAKE_OPTS = \
	KDIR=$(LINUX_DIR) \
	INSTALL_MOD_PATH=$(TARGET_DIR) \
	INSTALL_MOD_DIR=ingenic \
	DIR=.

# Add XBurst platform include paths for soc headers
OPEN_TX_ISP_MODULE_MAKE_OPTS += \
	EXTRA_CFLAGS="-I$(LINUX_DIR)/arch/mips/xburst/soc-$(SOC_FAMILY)/include \
	-I$(LINUX_DIR)/arch/mips/xburst/core/include \
	-I$(LINUX_DIR)/arch/mips/xburst/common/include"

# Keep the public capture adapter optional: the open driver also supports the
# legacy IMP ABI, while direct V4L2 users require both the adapter and DMA-BUF.
ifeq ($(BR2_PACKAGE_OPEN_TX_ISP_V4L2),y)
ifeq ($(SOC_FAMILY),t31)
OPEN_TX_ISP_MODULE_MAKE_OPTS += CONFIG_TX_ISP_T31_V4L2=y
else ifeq ($(SOC_FAMILY),t41)
OPEN_TX_ISP_MODULE_MAKE_OPTS += CONFIG_TX_ISP_T41_V4L2=y
endif

ifeq ($(KERNEL_VERSION_4),y)
OPEN_TX_ISP_DMA_CONFIG = CONFIG_THINGINO_VIDEOBUF2_DMA_CONTIG
else
OPEN_TX_ISP_DMA_CONFIG = CONFIG_THINGINO_DMA_SHARED_BUFFER
endif

define OPEN_TX_ISP_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_MEDIA_SUPPORT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MEDIA_CAMERA_SUPPORT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_VIDEO_DEV)
	$(call KCONFIG_ENABLE_OPT,CONFIG_VIDEO_V4L2)
	$(call KCONFIG_ENABLE_OPT,CONFIG_THINGINO_EXTERNAL_SENSOR_MCLK)
	$(call KCONFIG_ENABLE_OPT,$(OPEN_TX_ISP_DMA_CONFIG))
endef
endif

$(eval $(kernel-module))
$(eval $(generic-package))
