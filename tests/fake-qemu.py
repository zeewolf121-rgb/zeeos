#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Stand-in for qemu-system-* in tests/selftest.sh: copies $FAKE_SERIAL to the -serial file and answers QMP.

install-test (tests/install-selftest.sh): the boot with the ISO attached uses $FAKE_SERIAL_INSTALL and the
installed-system boot $FAKE_SERIAL_INSTALLED. During the install boot, $FAKE_FLIP=<offset> flips one byte of
disk.img and $FAKE_POWEROFF=1 exits right away, as the guest powers off.
"""
import json
import os
import shutil
import socket
import sys

args = sys.argv[1:]
serial = next(a for i, a in enumerate(args) if args[i - 1] == "-serial")[len("file:"):]
qmp = next(a for i, a in enumerate(args) if args[i - 1] == "-qmp")[len("unix:"):].split(",")[0]
installing = any("media=cdrom" in a for a in args)
fixture = os.environ.get("FAKE_SERIAL")
if installing and os.environ.get("FAKE_SERIAL_INSTALL"):
    fixture = os.environ["FAKE_SERIAL_INSTALL"]
elif not installing and os.environ.get("FAKE_SERIAL_INSTALLED"):
    fixture = os.environ["FAKE_SERIAL_INSTALLED"]
shutil.copy(fixture, serial)
if installing and os.environ.get("FAKE_FLIP"):
    disk = next(a.split("file=", 1)[1].split(",")[0] for a in args if "disk.img" in a)
    with open(disk, "r+b") as d:
        d.seek(int(os.environ["FAKE_FLIP"]))
        b = d.read(1)
        d.seek(-1, os.SEEK_CUR)
        d.write(bytes([b[0] ^ 0xFF]))
if installing and os.environ.get("FAKE_POWEROFF"):
    sys.exit(0)
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
