#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""UTM bundle helper (stdlib only, run with -I).

  utm-config.py render TEMPLATE OUT NAME DISK_IMAGE_NAME [--cpus 4] [--memory 4096]
  utm-config.py show   CONFIG.plist      print KEY=VALUE lines utm-test.sh turns into QEMU arguments
  utm-config.py zip    BUNDLE_DIR ZIP    reproducible zip (sorted, fixed timestamps, top directory kept)
  utm-config.py unzip  ZIP DEST          safe extract (no absolute paths, no ..)
"""
import os
import plistlib
import sys
import uuid
import zipfile

EPOCH = (2026, 1, 1, 0, 0, 0)


def render(template, out, name, disk, cpus="4", memory="4096"):
    text = open(template, encoding="utf-8").read()
    ident = str(uuid.uuid5(uuid.NAMESPACE_DNS, "zeeos.invalid/" + name)).upper()
    for key, val in (("NAME", name), ("UUID", ident), ("DISK", disk), ("CPUS", cpus), ("MEMORY", memory)):
        text = text.replace("@%s@" % key, val.replace("&", "&amp;").replace("<", "&lt;"))
    plistlib.loads(text.encode())  # must parse
    with open(out, "w", encoding="utf-8") as f:
        f.write(text)


def show(path):
    with open(path, "rb") as f:
        p = plistlib.load(f)
    sysd = p["System"]
    assert p["Backend"] == "QEMU" and sysd["Architecture"] == "aarch64" and sysd["Target"] == "virt", "not an aarch64 QEMU virt VM"
    assert sysd["Boot"]["UEFIBoot"] is True, "UEFI boot is required"
    drive = p["Drive"][0]
    image = drive["ImageName"]
    assert "/" not in image and not image.startswith("."), "unsafe ImageName"
    assert drive["Interface"] == "VirtIO", "only a VirtIO disk is supported"
    gpu = p["Display"][0]["Hardware"]
    nic = p["Network"][0]["Hardware"]
    assert gpu == "virtio-gpu-pci" and nic == "virtio-net-pci", (gpu, nic)
    for k, v in (("CPUS", sysd["CPUCount"]), ("MEMORY", sysd["MemorySize"]), ("TARGET", sysd["Target"]), ("DISK", image),
                 ("GPU", gpu), ("NIC", nic), ("HYPERVISOR", int(bool(p["QEMU"]["Hypervisor"]))),
                 ("RNG", int(bool(p["QEMU"]["RNGDevice"]))), ("CLIPBOARD", int(bool(p["Sharing"]["ClipboardSharing"]))),
                 ("NAME", p["Information"]["Name"])):
        print("%s=%s" % (k, v))


def zip_dir(src, dest):
    src = os.path.abspath(src)
    top = os.path.basename(src)
    files = sorted(os.path.join(root, n) for root, _, names in os.walk(src) for n in names)
    with zipfile.ZipFile(dest, "w") as z:
        for f in files:
            info = zipfile.ZipInfo(os.path.join(top, os.path.relpath(f, src)), EPOCH)
            info.external_attr = 0o644 << 16
            # qcow2 is already compressed: store it
            info.compress_type = zipfile.ZIP_STORED if f.endswith(".qcow2") else zipfile.ZIP_DEFLATED
            with open(f, "rb") as fh, z.open(info, "w", force_zip64=True) as w:
                while chunk := fh.read(1 << 20):
                    w.write(chunk)


def unzip(src, dest):
    root = os.path.realpath(dest)
    with zipfile.ZipFile(src) as z:
        for m in z.infolist():
            target = os.path.realpath(os.path.join(root, m.filename))
            if not (target == root or target.startswith(root + os.sep)):
                sys.exit("unsafe path in zip: " + m.filename)
        z.extractall(root)


if __name__ == "__main__":
    a = sys.argv[1:]
    cmd = a[0] if a else ""
    if cmd == "render" and len(a) >= 5:
        opts = dict(zip(a[5::2], a[6::2]))
        render(a[1], a[2], a[3], a[4], opts.get("--cpus", "4"), opts.get("--memory", "4096"))
    elif cmd == "show" and len(a) == 2:
        show(a[1])
    elif cmd == "zip" and len(a) == 3:
        zip_dir(a[1], a[2])
    elif cmd == "unzip" and len(a) == 3:
        unzip(a[1], a[2])
    else:
        sys.exit(__doc__)
