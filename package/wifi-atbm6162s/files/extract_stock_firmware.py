#!/usr/bin/env python3
import argparse
import struct
import sys
from pathlib import Path


MAGIC_V2 = 0x34353678
COMBO_VERSION = 0x5878


def find_combo_header(data):
    for off in range(0, len(data) - 32):
        if data[off : off + 4] != struct.pack("<I", MAGIC_V2):
            continue
        flags, version, iccm_len, dccm_len, sram_len, sram_addr, _, _ = struct.unpack_from(
            "<8I", data, off
        )
        if (
            flags == MAGIC_V2
            and version == COMBO_VERSION
            and iccm_len == 0x20000
            and dccm_len == 0x9000
            and sram_len == 0x7A64
            and sram_addr != 0
        ):
            return off
    raise SystemExit("could not find ATBM6162S stock DPLL40M+BLE firmware header")


def slice_checked(data, off, size, name):
    if off < 0 or off + size > len(data):
        raise SystemExit(f"{name} slice is outside input file")
    return data[off : off + size]


def main():
    parser = argparse.ArgumentParser(
        description="Extract ATBM6162S DPLL40M+BLE firmware embedded in Wyze stock module"
    )
    parser.add_argument("stock_module", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    data = args.stock_module.read_bytes()
    header_off = find_combo_header(data)
    header = slice_checked(data, header_off, 32, "header")

    _, version, iccm_len, dccm_len, sram_len, sram_addr, _, _ = struct.unpack_from(
        "<8I", header
    )
    iccm_off = header_off - iccm_len
    dccm_off = iccm_off - dccm_len
    sram_off = dccm_off - sram_len

    iccm = slice_checked(data, iccm_off, iccm_len, "ICCM")
    dccm = slice_checked(data, dccm_off, dccm_len, "DCCM")
    sram = slice_checked(data, sram_off, sram_len, "BLE SRAM")
    firmware = header + iccm + dccm + sram

    if b"DPLL40M+BLE" not in firmware:
        raise SystemExit("extracted firmware does not contain DPLL40M+BLE signature")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(firmware)
    print(
        f"extracted ATBM6162S stock firmware: version={version} "
        f"iccm={iccm_len} dccm={dccm_len} sram={sram_len} "
        f"sram_addr=0x{sram_addr:x} size={len(firmware)}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
