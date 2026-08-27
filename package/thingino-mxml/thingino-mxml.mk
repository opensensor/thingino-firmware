################################################################################
#
# thingino-mxml - shadow package to bump mxml
#
################################################################################

# Actual overrides live in mxml-override.mk.
THINGINO_MXML_DEPENDENCIES = mxml

# This is a selected meta-package that applies the mxml override above.  It is
# not a Buildroot virtual package: those use BR2_PACKAGE_HAS_* plus a provider,
# which makes the dependency checker ignore BR2_PACKAGE_THINGINO_MXML.
$(eval $(generic-package))
