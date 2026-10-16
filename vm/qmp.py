#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Minimal QMP client: qmp.py SOCKET CMD [JSON_ARGS]  (e.g. screendump with a filename argument)."""
import json
import socket
import sys
import time


def main():
    path, cmd = sys.argv[1], sys.argv[2]
    args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
    s = socket.socket(socket.AF_UNIX)
    for _ in range(50):
        try:
            s.connect(path)
            break
        except OSError:
            time.sleep(0.2)
    else:
        sys.exit("qmp: cannot connect to " + path)
    f = s.makefile("rw")
    f.readline()  # greeting

    def call(c, a=None):
        f.write(json.dumps({"execute": c, "arguments": a or {}}) + "\n")
        f.flush()
        while True:
            r = json.loads(f.readline())
            if "return" in r or "error" in r:
                return r

    call("qmp_capabilities")
    r = call(cmd, args)
    print(json.dumps(r))
    sys.exit(1 if "error" in r else 0)


main()
