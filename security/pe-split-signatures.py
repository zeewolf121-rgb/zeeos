#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ZeeOS contributors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write one copy of a PE/COFF image per Authenticode signature it carries.

UEFI binaries can carry several signatures in their certificate table: Fedora's GRUB is signed
by both the 2025 and the older Fedora CA, and shim by both the 2011 and the 2023 Microsoft UEFI
CA. `sbverify` only checks the first one. The Authenticode digest excludes the certificate table,
so a copy whose table holds a single signature still verifies with that signature.

Usage: pe-split-signatures.py <image> <out-prefix>
Writes <out-prefix>.sig1, <out-prefix>.sig2, ... and prints how many it wrote (0 = unsigned).
Standard library only.
"""
import struct
import sys

IMAGE_DIRECTORY_ENTRY_SECURITY = 4


def security_directory(img):
    """Return (offset of the security data-directory entry, cert-table offset, cert-table size)."""
    if img[:2] != b"MZ":
        raise ValueError("not a PE image (no MZ header)")
    pe = struct.unpack_from("<I", img, 0x3C)[0]
    if img[pe:pe + 4] != b"PE\0\0":
        raise ValueError("not a PE image (no PE signature)")
    opt = pe + 24
    magic = struct.unpack_from("<H", img, opt)[0]
    if magic == 0x10B:      # PE32
        dirs = opt + 96
    elif magic == 0x20B:    # PE32+
        dirs = opt + 112
    else:
        raise ValueError(f"unknown optional header magic {magic:#x}")
    entry = dirs + 8 * IMAGE_DIRECTORY_ENTRY_SECURITY
    offset, size = struct.unpack_from("<II", img, entry)
    return entry, offset, size


def certificates(img, offset, size):
    """Yield each WIN_CERTIFICATE (header + data) in the certificate table, 8-byte aligned."""
    pos, end = offset, offset + size
    while pos + 8 <= end:
        length = struct.unpack_from("<I", img, pos)[0]
        if length < 8 or pos + length > end:
            raise ValueError(f"bad WIN_CERTIFICATE length {length} at {pos:#x}")
        yield img[pos:pos + length]
        pos += (length + 7) & ~7


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[-3])
    path, prefix = sys.argv[1], sys.argv[2]
    img = bytearray(open(path, "rb").read())
    entry, offset, size = security_directory(img)
    if not offset or not size:
        print(0)
        return
    certs = list(certificates(img, offset, size))
    body = img[:offset]
    for i, cert in enumerate(certs, 1):
        padded = cert + b"\0" * (-len(cert) % 8)
        out = bytearray(body) + padded
        struct.pack_into("<II", out, entry, offset, len(padded))
        with open(f"{prefix}.sig{i}", "wb") as f:
            f.write(out)
    print(len(certs))


if __name__ == "__main__":
    main()
