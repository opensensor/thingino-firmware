LOGCAT_MINI_SITE_METHOD = git
LOGCAT_MINI_SITE = https://github.com/wltechblog/logcat-mini
LOGCAT_MINI_VERSION = $(shell git ls-remote $(LOGCAT_MINI_SITE) HEAD | head -1 | cut -f1)

LOGCAT_MINI_LICENSE = GPL-2.0
LOGCAT_MINI_LICENSE_FILES = COPYING

LOGCAT_MINI_INSTALL_STAGING = YES

LOGCAT_MINI_DEPENDENCIES = host-upx
define LOGCAT_MINI_INSTALL_STAGING_CMDS
        $(HOST_DIR)/bin/upx --best $(@D)/logcat
endef

$(eval $(cmake-package))
