#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Stand-in for virt-fw-vars in tests/install-selftest.sh. The "VARS file" is the JSON dump itself, space-padded
to its original size (the real tool keeps the edk2 store the same size too). Handles only what
vm/install-nvram.py uses: -i F --output-json O, and --inplace F --set-json J.
"""
import json
import sys

a = sys.argv[1:]


def opt(name):
    return a[a.index(name) + 1] if name in a else None


def load(path):
    raw = open(path, "rb").read()
    return json.loads(raw) if raw.strip() else {"version": 2, "variables": []}


def save(path, doc, size):
    raw = json.dumps(doc).encode()
    if len(raw) > size:
        sys.exit("fake-virt-fw-vars: store full")
    open(path, "wb").write(raw + b" " * (size - len(raw)))


if opt("--inplace") and opt("--set-json"):
    path = opt("--inplace")
    size = len(open(path, "rb").read())
    doc = load(path)
    new = {v["name"]: v for v in load(opt("--set-json"))["variables"]}
    doc["variables"] = [new.pop(v["name"], v) for v in doc["variables"]] + list(new.values())
    save(path, doc, size)
elif opt("-i") and opt("--output-json"):
    json.dump(load(opt("-i")), open(opt("--output-json"), "w"))
else:
    sys.exit("fake-virt-fw-vars: unsupported arguments %s" % a)
