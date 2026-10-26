#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Stand-in for qemu-system-* in tests/selftest.sh: copies $FAKE_SERIAL to the -serial file and answers QMP.

install-test (tests/install-selftest.sh): the boot with the ISO attached uses $FAKE_SERIAL_INSTALL and the
installed-system boot $FAKE_SERIAL_INSTALLED. During the install boot, $FAKE_FLIP=<offset> flips one byte of
disk.img, $FAKE_GPT=<op> rewrites its partition table (tests/gpt-fixture.py mutate) and $FAKE_POWEROFF=1 exits
right away, as the guest powers off, and $FAKE_NVRAM=<op>[,<op>...] edits the JSON "VARS file" (see
tests/fake-virt-fw-vars.py): zeeos-first / zeeos-last add a ZeeOS entry, drop-windows removes the Windows Boot
Manager entry, noise adds a firmware entry and puts it last.
A fixture line "@@UNLOCK" holds back the rest of the serial log until a line written to the serial chardev socket
(-chardev socket,...,path=,logfile=, as vm/qmp.py serial-type writes it) equals the luks_passphrase in
OUT/preset.conf, or $FAKE_EXPECT_PASSPHRASE if set. The log goes to the chardev's logfile= like real QEMU.
"""
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import threading

sys.dont_write_bytecode = True  # importing vm/install-nvram.py must not leave a __pycache__ there
args = sys.argv[1:]
serial_sock = None
serial_arg = next(a for i, a in enumerate(args) if args[i - 1] == "-serial")
if serial_arg.startswith("file:"):
    serial = serial_arg[len("file:"):]
else:  # chardev:ser0 -> the -chardev socket,id=ser0,path=...,logfile=... argument
    opts = dict(kv.split("=", 1) for a in args if a.startswith("socket,") for kv in a.split(",")[1:] if "=" in kv)
    assert serial_arg == "chardev:" + opts["id"], serial_arg
    serial, serial_sock = opts["logfile"], opts["path"]
qmp = next(a for i, a in enumerate(args) if args[i - 1] == "-qmp")[len("unix:"):].split(",")[0]
installing = any("media=cdrom" in a for a in args)
fixture = os.environ.get("FAKE_SERIAL")
if installing and os.environ.get("FAKE_SERIAL_INSTALL"):
    fixture = os.environ["FAKE_SERIAL_INSTALL"]
elif not installing and os.environ.get("FAKE_SERIAL_INSTALLED"):
    fixture = os.environ["FAKE_SERIAL_INSTALLED"]
text = open(fixture, "rb").read()
head, sep, tail = text.partition(b"@@UNLOCK\n")
with open(serial, "wb") as f:
    f.write(head)
here = os.path.dirname(os.path.abspath(__file__))
disk = next((a.split("file=", 1)[1].split(",")[0] for a in args if "disk.img" in a), None)
if installing and os.environ.get("FAKE_GPT"):
    fixture_py = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gpt-fixture.py")
    subprocess.run([sys.executable, "-I", fixture_py, "mutate", disk, os.environ["FAKE_GPT"]], check=True)
if installing and os.environ.get("FAKE_FLIP"):
    with open(disk, "r+b") as d:
        d.seek(int(os.environ["FAKE_FLIP"]))
        b = d.read(1)
        d.seek(-1, os.SEEK_CUR)
        d.write(bytes([b[0] ^ 0xFF]))
if installing and os.environ.get("FAKE_NVRAM"):
    vars_fd = next(a.split("file=", 1)[1] for a in args if a.endswith("vars.fd"))
    spec = importlib.util.spec_from_file_location("install_nvram", os.path.join(here, "..", "vm", "install-nvram.py"))
    nv = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(nv)
    raw = open(vars_fd, "rb").read()
    doc = json.loads(raw)
    var = {v["name"]: v for v in doc["variables"]}
    order = [int.from_bytes(bytes.fromhex(var["BootOrder"]["data"])[i:i + 2], "little")
             for i in range(0, len(bytes.fromhex(var["BootOrder"]["data"])), 2)] if "BootOrder" in var else []

    def add(title, path, front):
        n = max([int(k[4:], 16) for k in var if k.startswith("Boot") and k != "BootOrder"] + [-1]) + 1
        var["Boot%04X" % n] = {"name": "Boot%04X" % n, "guid": nv.GLOBAL_GUID, "attr": 7,
                               "data": nv.load_option(title, path).hex()}
        order.insert(0, n) if front else order.append(n)
    for op in os.environ["FAKE_NVRAM"].split(","):
        if op in ("zeeos-first", "zeeos-last"):
            add("ZeeOS", nv.file_node("\\EFI\\fedora\\shimx64.efi"), op == "zeeos-first")
        elif op == "noise":
            add("UEFI PXEv4 (MAC:525400123456)", bytes.fromhex("02010c00d041030a00000000"), False)
        elif op == "drop-windows":
            for k in [k for k, v in var.items() if k != "BootOrder" and k.startswith("Boot")
                      and nv.parse_boot(v["data"])[0] == nv.WINDOWS]:
                del var[k]
                order = [x for x in order if x != int(k[4:], 16)]
        else:
            sys.exit("fake-qemu: bad FAKE_NVRAM op " + op)
    var["BootOrder"] = {"name": "BootOrder", "guid": nv.GLOBAL_GUID, "attr": 7,
                        "data": b"".join(x.to_bytes(2, "little") for x in order).hex()}
    out = json.dumps({"version": 2, "variables": list(var.values())}).encode()
    open(vars_fd, "wb").write(out + b" " * (len(raw) - len(out)))
if installing and os.environ.get("FAKE_POWEROFF"):
    sys.exit(0)
passphrase = os.environ.get("FAKE_EXPECT_PASSPHRASE")
if passphrase is None:
    preset = os.path.join(os.path.dirname(qmp), "preset.conf")
    passphrase = next((l.split("=", 1)[1].rstrip("\n") for l in open(preset) if l.startswith("luks_passphrase=")), "") \
        if os.path.exists(preset) else ""


def serve_serial():
    """The guest's serial port: input lines are the prompt answers; the right one releases the rest of the log."""
    global sep
    ssrv = socket.socket(socket.AF_UNIX)
    ssrv.bind(serial_sock)
    ssrv.listen(4)
    while True:
        conn, _ = ssrv.accept()
        buf = b""
        while chunk := conn.recv(256):
            buf += chunk
            while b"\r" in buf or b"\n" in buf:
                line, buf = buf.replace(b"\r", b"\n").split(b"\n", 1)
                if sep and line.decode() == passphrase:
                    with open(serial, "ab") as out:
                        out.write(tail)
                    sep = b""
        conn.close()


if serial_sock:
    threading.Thread(target=serve_serial, daemon=True).start()
srv = socket.socket(socket.AF_UNIX)
srv.bind(qmp)
srv.listen(4)
while True:
    conn, _ = srv.accept()
    f = conn.makefile("rw")
    f.write(json.dumps({"QMP": {}}) + "\n")
    f.flush()
    for line in f:
        req = json.loads(line)
        if req["execute"] == "screendump":
            with open(req["arguments"]["filename"], "w") as img:
                img.write("P6\n1 1\n255\n\0\0\0")
        f.write(json.dumps({"return": {}}) + "\n")
        f.flush()
        if req["execute"] == "quit":
            sys.exit(0)
