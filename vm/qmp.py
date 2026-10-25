#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Minimal QMP client: qmp.py SOCKET CMD [JSON_ARGS]  (e.g. screendump with a filename argument).

The pseudo-command `type` takes {"text": "...", "enter": true|false} and sends it as QMP send-key calls, one key per
call (a multi-key send-key is a chord), shifted characters as a shift chord. Used to answer the LUKS prompt.
"""
import json
import socket
import sys
import time

SHIFTED = {"_": "minus", "+": "equal", ":": "semicolon", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
           "^": "6", "&": "7", "*": "8", "(": "9", ")": "0"}
PLAIN = {"-": "minus", "=": "equal", ".": "dot", ",": "comma", "/": "slash", ";": "semicolon", " ": "spc"}


def keys_for(ch):
    if ch.isascii() and ch.isalpha():
        return ["shift", ch.lower()] if ch.isupper() else [ch]
    if ch.isascii() and ch.isdigit():
        return [ch]
    if ch in PLAIN:
        return [PLAIN[ch]]
    if ch in SHIFTED:
        return ["shift", SHIFTED[ch]]
    sys.exit("qmp: cannot type %r" % ch)


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
    if cmd == "type":
        seq = [keys_for(c) for c in args["text"]] + ([["ret"]] if args.get("enter") else [])
        r = {"return": {}}
        for chord in seq:
            r = call("send-key", {"keys": [{"type": "qcode", "data": k} for k in chord], "hold-time": 40})
            if "error" in r:
                break
            time.sleep(0.08)
        print(json.dumps(r))
        sys.exit(1 if "error" in r else 0)
    r = call(cmd, args)
    print(json.dumps(r))
    sys.exit(1 if "error" in r else 0)


main()
