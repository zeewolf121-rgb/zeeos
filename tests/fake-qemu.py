#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Stand-in for qemu-system-* in tests/selftest.sh: copies $FAKE_SERIAL to the -serial file and answers QMP."""
import json
import os
import shutil
import socket
import sys

args = sys.argv[1:]
serial = next(a for i, a in enumerate(args) if args[i - 1] == "-serial")[len("file:"):]
qmp = next(a for i, a in enumerate(args) if args[i - 1] == "-qmp")[len("unix:"):].split(",")[0]
shutil.copy(os.environ["FAKE_SERIAL"], serial)
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
