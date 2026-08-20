################################################################################
#
# libaudioprocess-neo
#
################################################################################

LIBAUDIOPROCESS_NEO_SITE_METHOD = git
LIBAUDIOPROCESS_NEO_SITE = https://github.com/matteius/libaudioProcess-neo
LIBAUDIOPROCESS_NEO_SITE_BRANCH = feature/music-video-noise-suppression
LIBAUDIOPROCESS_NEO_VERSION = 7d84cf3d45247d5ee917bf470e8f4c3c9d0d63b7
LIBAUDIOPROCESS_NEO_INSTALL_STAGING = YES

LIBAUDIOPROCESS_NEO_LICENSE = MIT
LIBAUDIOPROCESS_NEO_LICENSE_FILES = LICENSE

ifeq ($(BR2_PACKAGE_INGENIC_LIB),y)
LIBAUDIOPROCESS_NEO_DEPENDENCIES += ingenic-lib
endif

define LIBAUDIOPROCESS_NEO_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) CROSS_COMPILE=$(TARGET_CROSS)
endef

define LIBAUDIOPROCESS_NEO_INSTALL_STAGING_CMDS
	$(INSTALL) -D -m 0755 $(@D)/libaudioProcess.so $(STAGING_DIR)/usr/lib/libaudioProcess.so
	$(INSTALL) -D -m 0644 $(@D)/libaudioProcess.a $(STAGING_DIR)/usr/lib/libaudioProcess.a
	$(INSTALL) -D -m 0644 $(@D)/src/audio_process.h $(STAGING_DIR)/usr/include/audio_process.h
endef

define LIBAUDIOPROCESS_NEO_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/libaudioProcess.so $(TARGET_DIR)/usr/lib/libaudioProcess.so
endef

define LIBAUDIOPROCESS_NEO_FINALIZE_TARGET
	$(INSTALL) -D -m 0755 \
		$(BUILD_DIR)/libaudioprocess-neo-$(LIBAUDIOPROCESS_NEO_VERSION)/libaudioProcess.so \
		$(TARGET_DIR)/usr/lib/libaudioProcess.so
endef
LIBAUDIOPROCESS_NEO_TARGET_FINALIZE_HOOKS += LIBAUDIOPROCESS_NEO_FINALIZE_TARGET

$(eval $(generic-package))
