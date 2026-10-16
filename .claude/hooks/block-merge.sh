#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 ZeeOS contributors
# PreToolUse hook (Bash): stop Claude sessions from merging PRs or pushing to main.
# GitHub branch protection isn't available on this plan, so this is the guard.
# Only the owner merges (GitHub UI); autopilot merges via scripts/autopilot/gates.sh,
# which checks CI, cross-review and owner-gate itself.
#
# It parses the command into simple commands and looks at the operation, not at words in
# arguments: `gh pr merge`, `gh api` merge endpoints, and `git push` whose destination is
# main, including implicit pushes (`git push`, `git push origin`) from a main checkout.
# If the command can't be parsed it falls back to a conservative text match.
set -euo pipefail

prog="$(cat <<'PY'
import json, os, re, shlex, subprocess, sys

PROTECTED = {"main"}
REASON = ("ZeeOS rule: Claude sessions never merge PRs or push to main. Branch protection "
          "is unavailable, so this hook enforces it. Ask the owner to merge in the GitHub UI, "
          "or let autopilot merge via scripts/autopilot/gates.sh merge <pr>.")
SEPARATORS = {";", "&", "&&", "|", "||", "|&", "(", ")", "\n"}
WRAPPERS = {"command", "env", "exec", "nohup", "sudo", "time", "builtin"}

def deny(why):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
          "permissionDecision": "deny", "permissionDecisionReason": f"{REASON} ({why})"}}))
    sys.exit(0)

def strip_heredocs(cmd):
    out, lines, i = [], cmd.split("\n"), 0
    while i < len(lines):
        out.append(lines[i])
        tags = re.findall(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", lines[i])
        i += 1
        for _, tag in tags:  # drop each heredoc body: it is data, not commands
            while i < len(lines) and lines[i].strip() != tag:
                i += 1
            i += 1
    return "\n".join(out)

def segments(cmd):
    lex = shlex.shlex(strip_heredocs(cmd), posix=True, punctuation_chars=";&|()<>")
    lex.whitespace = " \t\r"  # newline stays a token: it separates commands
    seg, redirect = [], False
    for tok in lex:
        if redirect:  # the redirection target (file or fd) is not an argument
            redirect = False
            if tok not in SEPARATORS:
                continue
        if re.fullmatch(r"[<>&]*[<>][<>&|]*", tok):  # >, 2>&1, &>, <<<, >|
            if seg and seg[-1].isdigit():
                seg.pop()  # fd number in front of it, as in 2>
            redirect = True
        elif tok in SEPARATORS or tok == "\n":
            if seg: yield seg
            seg = []
        else:
            seg.append(tok)
    if seg: yield seg

def git(cwd, *args):
    try:
        return subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True,
                              timeout=5).stdout.strip()
    except Exception:
        return ""

def branch_ref(name):
    name = name.lstrip("+")
    return name[len("refs/heads/"):] if name.startswith("refs/heads/") else name

def check_gh(args):
    words, i = [], 0
    while i < len(args):
        if args[i] in ("-R", "--repo", "--hostname"):  # options that take a value
            i += 2; continue
        if not args[i].startswith("-"):
            words.append(args[i])
        i += 1
    if words[:2] == ["pr", "merge"]:
        deny("gh pr merge")
    if words[:1] == ["api"]:
        for a in args:
            if re.search(r"pulls/\d+/merge\b", a) or "mergePullRequest" in a \
                    or "enablePullRequestAutoMerge" in a:
                deny("merge via gh api")

VALUE_OPTS = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}

def check_push(args, cwd):
    positional, i = [], 0
    while i < len(args):
        a = args[i]
        if a in ("--all", "--mirror", "--branches"):
            deny(f"git push {a} includes main")
        if a in VALUE_OPTS:
            i += 2; continue
        if a.startswith("-"):
            i += 1; continue
        positional.append(a); i += 1
    current = git(cwd, "symbolic-ref", "--quiet", "--short", "HEAD")
    refspecs = positional[1:]
    if not refspecs:  # implicit: pushes the current branch (to its upstream)
        upstream = git(cwd, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
        if current in PROTECTED or upstream.split("/", 1)[-1] in PROTECTED:
            deny("implicit git push from main")
        return
    for spec in refspecs:
        if spec in (":", "--tags"):
            continue
        src, _, dst = spec.partition(":")
        dst = branch_ref(dst or src)
        if dst == "HEAD":
            dst = current
        if dst in PROTECTED:
            deny("git push to main")

def check(cmd, cwd):
    for seg in segments(cmd):
        while seg and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", seg[0]) or seg[0] in WRAPPERS):
            seg = seg[1:]
        if not seg:
            continue
        prog, args = os.path.basename(seg[0]), seg[1:]
        if prog == "cd" and args:
            cwd = os.path.join(cwd, os.path.expanduser(args[0]))
        elif prog == "gh":
            check_gh(args)
        elif prog == "git":
            gcwd = cwd
            while args and args[0] in ("-C", "-c") and len(args) > 1:
                if args[0] == "-C":
                    gcwd = os.path.join(gcwd, os.path.expanduser(args[1]))
                args = args[2:]
            if args and args[0] == "push":
                check_push(args[1:], gcwd)

def fallback(cmd):
    ws = r"[ \t]"
    if re.search(rf"gh{ws}+pr{ws}+merge|pulls/[0-9]+/merge|mergePullRequest|enablePullRequestAutoMerge"
                 rf"|git{ws}+push(?:{ws}+[^\n;&|]*)?(?:{ws}|:|\+)(?:refs/heads/)?main(?:{ws}|$)"
                 rf"|git{ws}+push{ws}*(?:$|[;&|\n])", cmd, re.M):
        deny("couldn't parse the command; matched a merge or push pattern")

data = json.load(sys.stdin)
cmd = (data.get("tool_input") or {}).get("command") or ""
cwd = data.get("cwd") or os.getcwd()
try:
    check(cmd, cwd)
except ValueError:  # unbalanced quotes etc.
    fallback(cmd)
PY
)"
exec python3 -c "$prog"
