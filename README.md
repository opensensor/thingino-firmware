## Thingino

[![toolchain](https://github.com/themactep/thingino-firmware/actions/workflows/toolchain.yaml/badge.svg)](https://github.com/themactep/thingino-firmware/actions/workflows/toolchain.yaml)
[![firmware](https://github.com/themactep/thingino-firmware/actions/workflows/firmware.yaml/badge.svg)](https://github.com/themactep/thingino-firmware/actions/workflows/firmware.yaml)

![thingino logo](https://thingino.com/a/logo.svg)

IPC firmware, derived from [OpenIPC][1] and focused on Ingenic SoC.

### Usage

```
git clone --recurse-submodules https://github.com/themactep/thingino-firmware
cd thingino-firmware
make
```

### Updating
```
git pull
git submodule update --remote --merge
```

### Resources

- Project [Wiki][0]
- Buildroot Manual [HTML][2] [PDF][3]
- [OpenIPC Firmware][1]

[0]: https://github.com/themactep/thingino-firmware/wiki
[1]: https://github.com/OpenIPC/firmware
[2]: https://buildroot.org/downloads/manual/manual.html
[3]: https://nightly.buildroot.org/manual.pdf
