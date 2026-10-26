#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Package CVE scan (P5-8, #274): packages.lock against Fedora's updateinfo.

  cve_scan.py --updateinfo FILE [--allowlist FILE] [--today YYYY-MM-DD] LOCK [LOCK...]

A finding is a security advisory of severity Critical or Important whose package list has a build
of a locked package (same name and arch) newer than the locked one: the lock is missing that fix.
Each finding fails the scan unless security/cve-allowlist.yaml lists its advisory and package with
a reason and an `expires` date still in the future (UTC). A malformed, expired or reason-less
allowlist entry fails the scan too. Prints one line per finding:
  FAIL|ALLOWED <advisory> <severity> <name>.<arch> <locked-evr> < <fixed-evr>
Exit 0 clean, 1 findings or a bad allowlist, 2 bad input. Pure Python: no rpm or yaml module, so
the self-test runs anywhere; cve-scan.sh fetches the updateinfo in the build container.
"""
import bz2
import datetime
import gzip
import lzma
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

SEVERITIES = ("Critical", "Important")
ENTRY_KEYS = ("advisory", "package", "reason", "expires")


class InputError(Exception):
    pass


# rpmvercmp (rpm's lib/rpmvercmp.c): alternating digit / alpha segments, ~ sorts before anything,
# ^ after the end but before any other segment.
def _segments_cmp(a, b):
    if a == b:
        return 0
    i = j = 0
    while i < len(a) or j < len(b):
        while i < len(a) and not a[i].isalnum() and a[i] not in "~^":
            i += 1
        while j < len(b) and not b[j].isalnum() and b[j] not in "~^":
            j += 1
        ta = a[i] if i < len(a) else ""
        tb = b[j] if j < len(b) else ""
        if ta == "~" or tb == "~":
            if ta != "~":
                return 1
            if tb != "~":
                return -1
            i += 1
            j += 1
            continue
        if ta == "^" or tb == "^":
            if i >= len(a):
                return -1
            if j >= len(b):
                return 1
            if ta != "^":
                return 1
            if tb != "^":
                return -1
            i += 1
            j += 1
            continue
        if not (i < len(a) and j < len(b)):
            break
        if a[i].isdigit():
            m = re.match(r"\d+", a[i:]).group()
            n = re.match(r"\d+", b[j:])
            if not n:
                return 1  # numeric beats alpha
            n = n.group()
            i += len(m)
            j += len(n)
            m, n = m.lstrip("0"), n.lstrip("0")
            if len(m) != len(n):
                return 1 if len(m) > len(n) else -1
        else:
            m = re.match(r"[A-Za-z]+", a[i:]).group()
            n = re.match(r"[A-Za-z]+", b[j:])
            if not n:
                return -1
            n = n.group()
            i += len(m)
            j += len(n)
        if m != n:
            return 1 if m > n else -1
    if i >= len(a) and j >= len(b):
        return 0
    return -1 if i >= len(a) else 1


def evr_cmp(x, y):
    """Compare (epoch, version, release) tuples like rpm's labelCompare."""
    ex, ey = int(x[0] or 0), int(y[0] or 0)
    if ex != ey:
        return 1 if ex > ey else -1
    return _segments_cmp(x[1], y[1]) or _segments_cmp(x[2], y[2])


def evr_str(e):
    return f"{e[0] or 0}:{e[1]}-{e[2]}"


def read_lock(path):
    """{(name, arch): (epoch, version, release)} from a packages.lock."""
    out = {}
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        f = line.split()
        if len(f) < 2:
            raise InputError(f"{path}:{n}: expected 'name epoch:version-release.arch ...'")
        m = re.fullmatch(r"(\d+):(.+)-([^-]+)\.([^.]+)", f[1])
        if not m:
            raise InputError(f"{path}:{n}: bad EVRA {f[1]!r}")
        out[(f[0], m.group(4))] = (m.group(1), m.group(2), m.group(3))
    return out


def open_maybe_compressed(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rb")
    if path.endswith(".xz"):
        return lzma.open(path, "rb")
    if path.endswith(".bz2"):
        return bz2.open(path, "rb")
    if path.endswith(".zst"):
        try:
            from compression import zstd  # Python 3.14+
            return zstd.open(path, "rb")
        except ImportError:
            if not shutil.which("zstd"):
                raise InputError(f"{path}: needs Python 3.14 or the zstd tool")
            data = subprocess.run(["zstd", "-dc", path], check=True, capture_output=True).stdout
            import io
            return io.BytesIO(data)
    return open(path, "rb")


def read_updateinfo(path):
    """Yield (advisory, severity, name, arch, evr) for Critical/Important security updates."""
    with open_maybe_compressed(path) as f:
        for _, el in ET.iterparse(f, events=("end",)):
            if el.tag != "update":
                continue
            if el.get("type") == "security":
                sev = (el.findtext("severity") or "").strip()
                adv = (el.findtext("id") or "").strip()
                if sev in SEVERITIES and adv:
                    for p in el.iter("package"):
                        yield adv, sev, p.get("name"), p.get("arch"), \
                            (p.get("epoch") or "0", p.get("version"), p.get("release"))
            el.clear()


def _scalar(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def read_allowlist(path, today):
    """(entries, errors). The documented subset: `[]`, or a sequence of flat mappings."""
    entries, errors, cur = [], [], None
    try:
        text = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        return [], []  # treated as empty (P5-9 ships the file)
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split(" #", 1)[0].rstrip() if not raw.lstrip().startswith("#") else ""
        if not line.strip() or line.strip() == "---" or line.strip() == "[]":
            continue
        m = re.fullmatch(r"(- |  )([a-z]+):\s*(.*)", line)
        if not m:
            errors.append(f"{path}:{n}: not an allowlist line: {raw!r}")
            continue
        if m.group(1) == "- ":
            cur = {"_line": n}
            entries.append(cur)
        elif cur is None:
            errors.append(f"{path}:{n}: key outside an entry")
            continue
        key, val = m.group(2), _scalar(m.group(3))
        if key not in ENTRY_KEYS:
            errors.append(f"{path}:{n}: unknown key {key!r}")
        elif key in cur:
            errors.append(f"{path}:{n}: {key} given twice")
        else:
            cur[key] = val
    good = []
    for e in entries:
        where = f"{path}:{e['_line']}"
        missing = [k for k in ENTRY_KEYS if not e.get(k)]
        if missing:
            errors.append(f"{where}: missing or empty {', '.join(missing)}")
            continue
        try:
            exp = datetime.date.fromisoformat(e["expires"])
        except ValueError:
            errors.append(f"{where}: expires {e['expires']!r} is not YYYY-MM-DD")
            continue
        if today >= exp:
            errors.append(f"{where}: {e['advisory']} {e['package']} expired on {exp}")
            continue
        good.append(e)
    return good, errors


def main(argv):
    args = list(argv)
    opts = {"--updateinfo": None, "--allowlist": "security/cve-allowlist.yaml", "--today": None,
            "--min-advisories": "0"}
    for k in list(opts):
        if k in args:
            i = args.index(k)
            if i + 1 >= len(args):
                print(f"{k} needs a value", file=sys.stderr)
                return 2
            opts[k] = args[i + 1]
            del args[i : i + 2]
    if not opts["--updateinfo"] or not args:
        print(__doc__, file=sys.stderr)
        return 2
    today = (datetime.date.fromisoformat(opts["--today"]) if opts["--today"]
             else datetime.datetime.now(datetime.timezone.utc).date())
    try:
        locked = {}
        for path in args:
            locked.update(read_lock(path))
        allowed, errors = read_allowlist(opts["--allowlist"], today)
        findings, advisories = {}, set()
        for adv, sev, name, arch, fixed in read_updateinfo(opts["--updateinfo"]):
            advisories.add(adv)
            have = locked.get((name, arch))
            if have and evr_cmp(have, fixed) < 0:
                key = (adv, name, arch)
                if key not in findings or evr_cmp(findings[key][2], fixed) < 0:
                    findings[key] = (sev, have, fixed)
    except (InputError, OSError, ET.ParseError) as e:
        print(f"cve-scan: {e}", file=sys.stderr)
        return 2
    # A real Fedora updates repo always carries security advisories: none read means the
    # metadata wasn't parsed, and "0 findings" would be a false pass.
    if len(advisories) < int(opts["--min-advisories"]):
        print(f"cve-scan: only {len(advisories)} Critical/Important security advisories in "
              f"{opts['--updateinfo']}; is this really the updates repo's updateinfo?", file=sys.stderr)
        return 2
    for err in errors:
        print(f"BAD-ALLOWLIST {err}")
    ok = {(e["advisory"], e["package"]) for e in allowed}
    failed = bool(errors)
    for (adv, name, arch), (sev, have, fixed) in sorted(findings.items()):
        status = "ALLOWED" if (adv, name) in ok else "FAIL"
        failed |= status == "FAIL"
        print(f"{status} {adv} {sev} {name}.{arch} {evr_str(have)} < {evr_str(fixed)}")
    print(f"cve-scan: {len(locked)} locked packages, {len(advisories)} Critical/Important advisories, "
          f"{len(findings)} findings, "
          f"{'FAILED' if failed else 'ok'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
