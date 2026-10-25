#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""NVRAM (UEFI VARS file) checks for the install test (#248). Only ever writes the VARS copy under OUT.

  install-nvram.py version                      -> the virt-fw-vars version (or exit 3: tool missing)
  install-nvram.py seed-windows VARS SEED_JSON  -> add Boot#### "Windows Boot Manager" (HD(ESP) +
                                                   \\EFI\\Microsoft\\Boot\\bootmgfw.efi) and put it in BootOrder
  install-nvram.py dump VARS                    -> {"entries": {"0000": {"title", "path"}}, "order": ["0000"]}
  install-nvram.py check CASE BEFORE AFTER      -> exit 1 and list every problem (BEFORE/AFTER are dump outputs)

The tool is python `virt-firmware` (pinned 26.9: https://pypi.org/project/virt-firmware/26.9/, also
python3-virt-firmware-26.9 in Fedora 44). $VIRT_FW_VARS overrides the command. A missing tool is exit 3, never
a pass and never a skip.

What "unchanged" means (OVMF/AAVMF add and reorder their own entries on every boot, e.g. for the DVD, so
byte equality of the whole store would fail a correct run): every entry that was there before still has the
same title and device path; the entries keep their relative order in BootOrder; and (refuse cases) nothing
named ZeeOS and nothing booting \\EFI\\fedora has appeared. Alongside also needs ZeeOS first in BootOrder.
"""
import json
import os
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid

WINDOWS = "Windows Boot Manager"
ZEEOS = "ZeeOS"
GLOBAL_GUID = "8be4df61-93ca-11d2-aa0d-00e098032b8c"
NV_BS_RT = 7


def tool():
    cmd = shlex.split(os.environ.get("VIRT_FW_VARS", ""))
    if not cmd and shutil.which("virt-fw-vars"):
        cmd = [shutil.which("virt-fw-vars")]
    if cmd and not shutil.which(cmd[0]):
        print(f"{cmd[0]}: VIRT_FW_VARS does not exist", file=sys.stderr)
        sys.exit(3)
    if not cmd:  # the module (virt/firmware/vars.py) still works where only the library is installed
        probe = subprocess.run([sys.executable, "-c", "import virt.firmware.vars"], capture_output=True)
        if probe.returncode == 0:
            cmd = [sys.executable, "-m", "virt.firmware.vars"]
    if not cmd:
        print("virt-fw-vars not found: install python3-virt-firmware (Fedora) or `pip install virt-firmware==26.9`, "
              "or set VIRT_FW_VARS", file=sys.stderr)
        sys.exit(3)
    return cmd


def run(*args):
    r = subprocess.run(tool() + list(args), capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"virt-fw-vars {' '.join(args)}: {r.stderr.strip() or r.stdout.strip()}")
    return r


def load_json(vars_fd):
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "vars.json")
        run("-i", vars_fd, "--output-json", out)
        with open(out) as f:
            return json.load(f)


def parse_boot(data):
    """EFI_LOAD_OPTION: u32 attributes, u16 path-list length, UCS-2 description, device path list."""
    raw = bytes.fromhex(data)
    plen = struct.unpack_from("<H", raw, 4)[0]
    i = 6
    while raw[i:i + 2] != b"\0\0":
        i += 2
    title = raw[6:i].decode("utf-16-le", "replace")
    path = raw[i + 2:i + 2 + plen]
    return title, path.hex()


def dump(vars_fd):
    entries, order = {}, []
    for v in load_json(vars_fd)["variables"]:
        n = v["name"]
        if n == "BootOrder":
            raw = bytes.fromhex(v["data"])
            order = [f"{x:04X}" for x in struct.unpack(f"<{len(raw) // 2}H", raw[:len(raw) // 2 * 2])]
        elif len(n) == 8 and n.startswith("Boot") and all(c in "0123456789ABCDEFabcdef" for c in n[4:]):
            title, path = parse_boot(v["data"])
            entries[n[4:].upper()] = {"title": title, "path": path}
    return {"entries": entries, "order": order}


def file_node(path):
    f = (path + "\0").encode("utf-16-le")
    return struct.pack("<BBH", 4, 4, 4 + len(f)) + f


def load_option(title, devpath):
    """EFI_LOAD_OPTION (active) for a device path (bytes, without the end node)."""
    path = devpath + bytes([0x7F, 0xFF, 4, 0])
    return struct.pack("<IH", 1, len(path)) + (title + "\0").encode("utf-16-le") + path


def windows_entry(seed):
    """Device path HD(<esp>,GPT,...)/File(\\EFI\\Microsoft\\Boot\\bootmgfw.efi) from the seed's GPT record."""
    path = b""
    esp = next((p for p in seed.get("gpt", {}).get("partitions", []) if p["name"] == "esp"), None)
    if esp:
        hd = struct.pack("<IQQ16sBB", 1, esp["first"], esp["last"] - esp["first"] + 1,
                         uuid.UUID(esp["guid"]).bytes_le, 2, 2)
        path += struct.pack("<BBH", 4, 1, 4 + len(hd)) + hd
    return load_option(WINDOWS, path + file_node("\\EFI\\Microsoft\\Boot\\bootmgfw.efi"))


def seed_windows(vars_fd, seed_json):
    with open(seed_json) as f:
        seed = json.load(f)
    before = dump(vars_fd)
    free = next(f"{i:04X}" for i in range(0x10000) if f"{i:04X}" not in before["entries"])
    order = [int(x, 16) for x in before["order"]]
    order.append(int(free, 16))  # Windows boot manager was there first: it is the default until ZeeOS goes first
    doc = {"version": 2, "variables": [
        {"name": "Boot" + free, "guid": GLOBAL_GUID, "attr": NV_BS_RT, "data": windows_entry(seed).hex()},
        {"name": "BootOrder", "guid": GLOBAL_GUID, "attr": NV_BS_RT, "data": struct.pack(f"<{len(order)}H", *order).hex()},
    ]}
    size = os.path.getsize(vars_fd)
    with tempfile.TemporaryDirectory() as d:
        j = os.path.join(d, "set.json")
        with open(j, "w") as f:
            json.dump(doc, f)
        run("--inplace", vars_fd, "--set-json", j)
    if os.path.getsize(vars_fd) != size:
        sys.exit(f"{vars_fd} changed size; pflash would refuse it")
    after = dump(vars_fd)
    if after["entries"].get(free, {}).get("title") != WINDOWS or after["order"][-1:] != [free]:
        sys.exit("seeding the Windows Boot Manager entry did not take")
    print(f"seeded Boot{free} {WINDOWS}; BootOrder {','.join(after['order'])}")


def check(case, before, after):
    bad = []
    be, ae = before["entries"], after["entries"]
    if not any(e["title"] == WINDOWS for e in be.values()):
        bad.append(f"the seeded NVRAM has no {WINDOWS} entry, so the check proves nothing")
    for n, e in sorted(be.items()):
        if n not in ae:
            bad.append(f"Boot{n} {e['title']} is gone")
        elif ae[n] != e:
            bad.append(f"Boot{n} {e['title']} changed" + (f" (now {ae[n]['title']})" if ae[n]["title"] != e["title"] else ""))
    if not any(e["title"] == WINDOWS for e in ae.values()):
        bad.append(f"no {WINDOWS} entry")
    kept = [n for n in before["order"] if n in after["order"]]
    if [n for n in after["order"] if n in kept] != kept:
        bad.append(f"BootOrder reordered the old entries: {','.join(before['order'])} -> {','.join(after['order'])}")
    added = {n: e for n, e in ae.items() if n not in be}
    if case == "alongside":
        first = ae.get(after["order"][0], {}).get("title") if after["order"] else None
        if first != ZEEOS:
            bad.append(f"first in BootOrder is {first or 'nothing'}, want {ZEEOS} (BootOrder {','.join(after['order'])})")
        if not any(e["title"] == ZEEOS for e in added.values()):
            bad.append(f"no new {ZEEOS} entry")
    elif case.startswith("refuse"):
        for n, e in added.items():
            if e["title"] == ZEEOS or "fedora" in bytes.fromhex(e["path"]).decode("utf-16-le", "ignore").lower():
                bad.append(f"refused install still added Boot{n} {e['title']}")
        if (after["order"] and ae.get(after["order"][0], {}).get("title") == ZEEOS):
            bad.append(f"{ZEEOS} is first in BootOrder")
    return bad


def main():
    a = sys.argv[1:]
    if a[:1] == ["version"] and len(a) == 1:
        r = subprocess.run(tool() + ["--help"], capture_output=True, text=True)
        v = subprocess.run([sys.executable, "-c", "import importlib.metadata as m; print(m.version('virt-firmware'))"],
                           capture_output=True, text=True).stdout.strip()
        print(v or ("virt-fw-vars" if r.returncode == 0 else "unknown"))
    elif a[:1] == ["seed-windows"] and len(a) == 3:
        seed_windows(a[1], a[2])
    elif a[:1] == ["dump"] and len(a) == 2:
        json.dump(dump(a[1]), sys.stdout, indent=1)
        print()
    elif a[:1] == ["check"] and len(a) == 4:
        with open(a[2]) as f:
            b = json.load(f)
        with open(a[3]) as f:
            c = json.load(f)
        bad = check(a[1], b, c)
        for line in bad:
            print(line)
        sys.exit(1 if bad else 0)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
