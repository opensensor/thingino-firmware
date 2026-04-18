OPEN_TX_ISP_SITE_METHOD = git
OPEN_TX_ISP_SITE = https://github.com/opensensor/open-tx-isp
OPEN_TX_ISP_SITE_BRANCH = main
OPEN_TX_ISP_VERSION = bde9e3e6

OPEN_TX_ISP_LICENSE = GPL-2.0
OPEN_TX_ISP_LICENSE_FILES = LICENSE

OPEN_TX_ISP_DEPENDENCIES = ingenic-sdk linux

# Build as out-of-tree kernel module
OPEN_TX_ISP_MODULE_SUBDIRS = driver

OPEN_TX_ISP_MODULE_MAKE_OPTS = \
	KDIR=$(LINUX_DIR) \
	INSTALL_MOD_PATH=$(TARGET_DIR) \
	INSTALL_MOD_DIR=ingenic

# No DIR= — objs sit at M= root. Setting DIR=. made Kbuild map each source's
# KBUILD_MODNAME to its own filename (e.g. tx_isp_module) instead of tx_isp_t31,
# breaking modpost's MODULE_LICENSE check on the linked module.

# Add XBurst platform include paths for soc headers
OPEN_TX_ISP_MODULE_MAKE_OPTS += \
	EXTRA_CFLAGS="-I$(LINUX_DIR)/arch/mips/xburst/soc-$(SOC_FAMILY)/include \
	-I$(LINUX_DIR)/arch/mips/xburst/core/include \
	-I$(LINUX_DIR)/arch/mips/xburst/common/include"

$(eval $(kernel-module))
$(eval $(generic-package))
