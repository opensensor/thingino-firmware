################################################################################
#
# live555
#
################################################################################

THINGINO_LIVE555_SOURCE = live555-latest.tar.gz
THINGINO_LIVE555_SITE = http://www.live555.com/liveMedia/public
# There is a COPYING file with the GPL-3.0 license text, but none of
# the source files appear to be released under GPL-3.0, and the
# project web site says it's licensed under the LGPL:
# http://live555.com/liveMedia/faq.html#copyright-and-license
THINGINO_LIVE555_LICENSE = LGPL-3.0+
THINGINO_LIVE555_LICENSE_FILES = COPYING.LESSER
THINGINO_LIVE555_CPE_ID_VENDOR = live555
THINGINO_LIVE555_CPE_ID_PRODUCT = streaming_media
THINGINO_LIVE555_INSTALL_STAGING = YES

THINGINO_LIVE555_CFLAGS = $(TARGET_CFLAGS)

ifeq ($(BR2_STATIC_LIBS),y)
THINGINO_LIVE555_CONFIG_TARGET = linux
THINGINO_LIVE555_LIBRARY_LINK = $(TARGET_AR) cr
else
THINGINO_LIVE555_CONFIG_TARGET = linux-with-shared-libraries
THINGINO_LIVE555_LIBRARY_LINK = $(TARGET_CC) -o
THINGINO_LIVE555_CFLAGS += -fPIC
endif

ifeq ($(BR2_PACKAGE_OPENSSL),y)
THINGINO_LIVE555_DEPENDENCIES += host-pkgconf openssl
THINGINO_LIVE555_CONSOLE_LIBS = `$(PKG_CONFIG_HOST_BINARY) --libs openssl`
# passed to ar for static linking, which gets confused by -L<dir>
ifneq ($(BR2_STATIC_LIBS),y)
THINGINO_LIVE555_LIVEMEDIA_LIBS = $(THINGINO_LIVE555_CONSOLE_LIBS)
endif
else
THINGINO_LIVE555_CFLAGS += -DNO_OPENSSL
endif

ifneq ($(BR2_ENABLE_LOCALE),y)
THINGINO_LIVE555_CFLAGS += -DLOCALE_NOT_USED
endif

define THINGINO_LIVE555_CONFIGURE_CMDS
	echo 'COMPILE_OPTS = $$(INCLUDES) -I. -DSOCKLEN_T=socklen_t -DALLOW_RTSP_SERVER_PORT_REUSE -DNO_STD_LIB $(THINGINO_LIVE555_CFLAGS)' >> $(@D)/config.$(THINGINO_LIVE555_CONFIG_TARGET)
	echo 'C_COMPILER = $(TARGET_CC)' >> $(@D)/config.$(THINGINO_LIVE555_CONFIG_TARGET)
	echo 'CPLUSPLUS_COMPILER = $(TARGET_CXX)' >> $(@D)/config.$(THINGINO_LIVE555_CONFIG_TARGET)

	echo 'LINK = $(TARGET_CXX) -o' >> $(@D)/config.$(THINGINO_LIVE555_CONFIG_TARGET)
	echo 'LINK_OPTS = -L. $(TARGET_LDFLAGS)' >> $(@D)/config.$(THINGINO_LIVE555_CONFIG_TARGET)
	echo 'PREFIX = /usr' >> $(@D)/config.$(THINGINO_LIVE555_CONFIG_TARGET)
	# Must have a whitespace at the end of LIBRARY_LINK, otherwise static link
	# fails
	echo 'LIBRARY_LINK = $(THINGINO_LIVE555_LIBRARY_LINK) ' >> $(@D)/config.$(THINGINO_LIVE555_CONFIG_TARGET)
	echo 'LIBS_FOR_CONSOLE_APPLICATION = $(THINGINO_LIVE555_CONSOLE_LIBS)' >> $(@D)/config.$(THINGINO_LIVE555_CONFIG_TARGET)
	echo 'LIBS_FOR_LIVEMEDIA_LIB = $(THINGINO_LIVE555_LIVEMEDIA_LIBS)' >> $(@D)/config.$(THINGINO_LIVE555_CONFIG_TARGET)
	(cd $(@D); ./genMakefiles $(THINGINO_LIVE555_CONFIG_TARGET))
endef

define THINGINO_LIVE555_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) all
endef

define THINGINO_LIVE555_INSTALL_STAGING_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) DESTDIR=$(STAGING_DIR) -C $(@D) install
endef

define THINGINO_LIVE555_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) DESTDIR=$(TARGET_DIR) PREFIX=/usr -C $(@D) install
	cp $(@D)/testProgs/openRTSP $(TARGET_DIR)/usr/bin/
endef

$(eval $(generic-package))