#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 ZeeOS contributors
# SPDX-License-Identifier: GPL-3.0-or-later
# Verify the Secure Boot chain inside a built ZeeOS ISO (ADR-0004, #9), the way firmware and shim
# do. See security/SECURE-BOOT.md.
#   1. shim (EFI/BOOT/BOOT<arch>.EFI) is signed by a Microsoft UEFI CA (2011 or 2023).
#   2. The Fedora CA that shim trusts is its embedded .vendor_cert.
#   3. GRUB and the kernel each carry a signature that chains to that vendor cert.
# A binary passes if ANY of its signatures verifies, as in firmware. Binaries carry several:
# shim has a 2011 and a 2023 Microsoft signature, and GRUB a 2025 and an older Fedora one.
# With --tamper-test it also checks that a GRUB copy with one flipped byte is rejected.
# Usage: security/verify-secureboot-chain.sh <iso> [--tamper-test]
# Needs: xorriso or bsdtar, sbverify (sbsigntools), openssl, curl, python3.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
iso="${1:?usage: verify-secureboot-chain.sh <iso> [--tamper-test]}"
tamper="${2:-}"
[[ -f "$iso" ]] || { echo "no such ISO: $iso" >&2; exit 2; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# Microsoft UEFI CAs: public certificates, fetched at run time and pinned by SHA-256.
# The 2011 CA expired on 2026-06-27. Firmware ignores certificate expiry; if sbverify rejects the
# 2011 signature for that reason, shim still passes on its 2023 one (any-signature rule).
ms_cas=(
  "2011 https://go.microsoft.com/fwlink/p/?linkid=321194 48e99b991f57fc52f76149599bff0a58c47154229b9f8d603ac40d3500248507"
  "2023 https://go.microsoft.com/fwlink/?linkid=2239872 f6124e34125bee3fe6d79a574eaa7b91c0e7bd9d929c1a321178efd611dad901"
)

extract() { # iso-path -> $work/iso/<path>; empty result if absent
  mkdir -p "$work/iso"
  if command -v xorriso >/dev/null; then
    xorriso -osirrox on -indev "$iso" -extract "/$1" "$work/iso/$1" >/dev/null 2>&1 || true
  else
    bsdtar -xf "$iso" -C "$work/iso" "$1" 2>/dev/null || true
  fi
  [[ -s "$work/iso/$1" ]] && echo "$work/iso/$1"
}
listing() {
  if command -v xorriso >/dev/null; then xorriso -indev "$iso" -find / -type f 2>/dev/null | tr -d "'" | sed 's#^/##'
  else bsdtar -tf "$iso"; fi
}

files="$(listing)"
case "$files" in
  *EFI/BOOT/BOOTX64.EFI*) arch=x86_64 efi=x64 ;;
  *EFI/BOOT/BOOTAA64.EFI*) arch=aarch64 efi=aa64 ;;
  *) echo "FAIL: no EFI/BOOT/BOOTX64.EFI or BOOTAA64.EFI in $iso" >&2; exit 1 ;;
esac
EFI_UPPER="$(tr '[:lower:]' '[:upper:]' <<<"$efi")"
shim="$(extract "EFI/BOOT/BOOT$EFI_UPPER.EFI")"
grub="$(extract "EFI/BOOT/grub$efi.efi")"
kernel="$(extract "boot/$arch/loader/linux")"
for v in shim grub kernel; do [[ -n "${!v}" ]] || { echo "FAIL: $v not found in the ISO" >&2; exit 1; }; done

# Trust anchors: Microsoft CAs (pinned), then the vendor cert out of shim.
anchors_ms=()
for line in "${ms_cas[@]}"; do
  read -r name url sum <<<"$line"
  curl -fsSL --retry 3 -o "$work/ms-$name.der" "$url"
  got="$(sha256sum "$work/ms-$name.der" | cut -d' ' -f1)"
  [[ "$got" == "$sum" ]] || { echo "FAIL: Microsoft UEFI CA $name has sha256 $got, expected $sum" >&2; exit 1; }
  openssl x509 -inform DER -in "$work/ms-$name.der" -out "$work/ms-$name.pem"
  anchors_ms+=("$work/ms-$name.pem")
done
# Read the section with a PE parser: GNU objcopy on x86_64 runners cannot open AArch64 PE images.
python3 -I - "$shim" "$work/vendor_cert.bin" <<'EOF'
import struct, sys
d = open(sys.argv[1], "rb").read()
pe = struct.unpack_from("<I", d, 0x3C)[0]
if d[pe:pe + 4] != b"PE\0\0": sys.exit("FAIL: shim is not a PE image")
nsec, = struct.unpack_from("<H", d, pe + 6)
optsz, = struct.unpack_from("<H", d, pe + 20)
symptr, nsyms = struct.unpack_from("<II", d, pe + 12)
strtab = symptr + 18 * nsyms
out = b""
for i in range(nsec):
    name, vsize, _, rawsize, rawptr = struct.unpack_from("<8sIIII", d, pe + 24 + optsz + 40 * i)
    name = name.rstrip(b"\0")
    if name.startswith(b"/") and name[1:].isdigit() and symptr:  # long name: offset into the COFF string table
        start = strtab + int(name[1:])
        name = d[start:d.index(b"\0", start)]
    if name == b".vendor_cert":
        out = d[rawptr:rawptr + min(rawsize, vsize) if vsize else rawptr + rawsize]
open(sys.argv[2], "wb").write(out)
EOF
python3 -I - "$work/vendor_cert.bin" "$work/vendor.der" <<'EOF'
import struct, sys
d = open(sys.argv[1], "rb").read()
if len(d) < 16: sys.exit("FAIL: shim has no .vendor_cert section")
size, _, offset, _ = struct.unpack_from("<IIII", d)
der = d[offset:offset + size]
if der[:1] != b"\x30": sys.exit("FAIL: shim's vendor cert is not a DER certificate (vendor_db is not supported)")
open(sys.argv[2], "wb").write(der)
EOF
openssl x509 -inform DER -in "$work/vendor.der" -out "$work/vendor.pem"
vendor_subject="$(openssl x509 -in "$work/vendor.pem" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"

verify_any() { # label image anchor-pem... ; prints one line per signature, returns 0 if any verifies
  local label="$1" img="$2" n i a ok=1 line
  shift 2
  n="$(python3 -I "$here/pe-split-signatures.py" "$img" "$work/split-$label")"
  (( n > 0 )) || { echo "  $label: UNSIGNED"; return 1; }
  for ((i = 1; i <= n; i++)); do
    line="  $label signature $i/$n: no trusted chain"
    for a in "$@"; do
      if sbverify --cert "$a" "$work/split-$label.sig$i" >/dev/null 2>&1; then
        line="  $label signature $i/$n: OK ($(openssl x509 -in "$a" -noout -subject -nameopt RFC2253 | sed 's/^subject=//'))"
        ok=0; break
      fi
    done
    echo "$line"
  done
  return "$ok"
}

echo "Secure Boot chain for $(basename "$iso") ($arch)"
echo "  shim's vendor cert: $vendor_subject"
fail=0
verify_any shim "$shim" "${anchors_ms[@]}" || { echo "FAIL: shim has no signature from a Microsoft UEFI CA"; fail=1; }
verify_any grub "$grub" "$work/vendor.pem" || { echo "FAIL: GRUB has no signature from shim's vendor cert"; fail=1; }
verify_any kernel "$kernel" "$work/vendor.pem" || { echo "FAIL: the kernel has no signature from shim's vendor cert"; fail=1; }

if [[ "$tamper" == --tamper-test ]]; then
  cp "$grub" "$work/grub-tampered.efi"
  python3 -I -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); b[0x1000]^=0xFF; open(p,"wb").write(b)' "$work/grub-tampered.efi"
  if verify_any grub-tampered "$work/grub-tampered.efi" "$work/vendor.pem" >/dev/null; then
    echo "FAIL: a GRUB with one flipped byte still verifies (the check is not working)"; fail=1
  else
    echo "  tamper test: a GRUB with one flipped byte is rejected (OK)"
  fi
fi

(( fail == 0 )) && echo "PASS: Microsoft UEFI CA -> shim -> $vendor_subject -> GRUB, kernel"
exit "$fail"
