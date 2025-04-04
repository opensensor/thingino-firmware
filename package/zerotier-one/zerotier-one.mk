ZEROTIER_ONE_SITE_METHOD = git
ZEROTIER_ONE_SITE = https://github.com/zerotier/ZeroTierOne
ZEROTIER_ONE_SITE_BRANCH = 1.14.2
ZEROTIER_ONE_VERSION = 3fcef51137ac9d32af951cb856279dcee7f1ce03
# $(shell git ls-remote $(ZEROTIER_ONE_SITE) $(ZEROTIER_ONE_SITE_BRANCH) | head -1 | cut -f1)

ZEROTIER_ONE_LICENSE = BUSL-1.1
ZEROTIER_ONE_LICENSE_FILES = LICENSE.txt

ZEROTIER_ONE_MAKE_OPTS = ZT_SSO_SUPPORTED=0 \
	CC="$(TARGET_CC)" \
	CXX="$(TARGET_CXX)" \
	FLOATABI="$(BR2_GCC_TARGET_FLOAT_ABI)" \
	LDFLAGS="$(TARGET_LDFLAGS)"

ZEROTIER_ONE_DEPENDENCIES = \
	libminiupnpc \
	libnatpmp

define ZEROTIER_ONE_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_SET_OPT,CONFIG_TUN,m)
endef

define ZEROTIER_ONE_BUILD_CMDS
	$(MAKE) $(ZEROTIER_ONE_MAKE_OPTS) -C $(@D) all
endef

define ZEROTIER_ONE_INSTALL_TARGET_CMDS
	$(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install

	$(INSTALL) -D -m 0755 $(ZEROTIER_ONE_PKGDIR)/files/S90zerotier \
		$(TARGET_DIR)/etc/init.d/S90zerotier

	$(INSTALL) -D -m 0755 $(ZEROTIER_ONE_PKGDIR)/files/service-zerotier.cgi \
		$(TARGET_DIR)/var/www/x/service-zerotier.cgi
endef

$(eval $(generic-package))
