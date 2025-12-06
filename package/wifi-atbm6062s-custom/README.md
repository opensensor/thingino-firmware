# ATBM6062S Custom WiFi Driver for Kernel 4.4

This package provides a local build of the ATBM6062S WiFi driver with kernel 4.4.94 compatibility for Ingenic T41 SoCs.

## Overview

The standard `wifi-atbm6062s` package pulls from a remote git repository. This custom package uses a local clone of the driver source, allowing for easier patching and modification to ensure compatibility with kernel 4.4.94.

## Structure

```
package/wifi-atbm6062s-custom/
├── Config.in                    # Buildroot configuration
├── wifi-atbm6062s-custom.mk     # Package makefile
├── README.md                    # This file
└── atbm-wifi-local/             # Local clone of atbm-wifi driver
    ├── configs/
    │   └── atbm6062s.config     # SDIO configuration for ATBM6062S
    ├── wireless/                # cfg80211 wireless subsystem
    ├── hal_apollo/              # Hardware abstraction layer
    ├── firmware/                # Firmware binaries
    └── Makefile                 # Driver build system
```

## Kernel 4.4 Compatibility

The driver already includes kernel 4.4 compatibility features:

1. **multi_depend function**: `wireless/Makefile` defines this function for kernel 4.4 (lines 3-9)
2. **Backport files**: Compatibility shims for older kernel APIs
3. **Version checks**: Code uses `LINUX_VERSION_CODE` to handle API differences

## Configuration

The package is configured for SDIO interface (ATBM6062S) with the following settings:

- **Module name**: `atbm6062s`
- **Firmware**: `cronus_SDIO_NoBLE_SDIO_svn19514_24M_wifi6phy_DCDC.bin`
- **Interface**: SDIO (not USB)
- **Features**: Bridge support, monitor mode, SAE authentication, AMPDU setup

## Usage

### Building

To use this package instead of the standard one:

1. Select `BR2_PACKAGE_WIFI_ATBM6062S_CUSTOM=y` in your defconfig
2. Deselect `BR2_PACKAGE_WIFI_ATBM6062S` if it was previously enabled
3. Build as normal: `make`

### Test Configuration

A test configuration is provided:
```
configs/cameras/wyze_camv4_t41nq_gc4653_atbm6062_custom/
```

To build with this configuration:
```bash
make wyze_camv4_t41nq_gc4653_atbm6062_custom_defconfig
make
```

## Making Changes

Since this uses a local source directory, you can make changes directly:

1. Edit files in `package/wifi-atbm6062s-custom/atbm-wifi-local/`
2. Changes will be picked up on next build
3. No need to modify git commits or create patch files

## Differences from Standard Package

| Feature | Standard (wifi-atbm6062s) | Custom (wifi-atbm6062s-custom) |
|---------|---------------------------|--------------------------------|
| Source | Remote git (gtxaspec/atbm-wifi) | Local directory |
| Patching | Requires patch files | Direct source edits |
| Kernel version | Hardcoded 3.10.14 paths | Dynamic kernel version |
| Build method | kernel-module + generic-package | kernel-module + generic-package |

## Troubleshooting

### Build Errors

If you encounter build errors:

1. Check kernel version: `grep KERNEL_VERSION output-*/build/linux-*/include/generated/uapi/linux/version.h`
2. Verify wireless config: `grep CONFIG_WIRELESS output-*/build/linux-*/.config`
3. Check module build log: `output-*/build/wifi-atbm6062s-custom-*/build.log`

### Module Loading

If the module fails to load:

1. Check kernel messages: `dmesg | grep atbm`
2. Verify firmware: `ls -la /lib/firmware/atbm6062s_fw.bin`
3. Check module dependencies: `modinfo atbm6062s`

## Future Improvements

- Add support for different firmware variants
- Create automated compatibility testing
- Document platform-specific configurations
- Add debug build options

## References

- Original driver: https://github.com/gtxaspec/atbm-wifi (atbm-606x branch)
- Kernel 4.4 docs: https://www.kernel.org/doc/html/v4.4/
- cfg80211 subsystem: https://wireless.wiki.kernel.org/en/developers/documentation/cfg80211

