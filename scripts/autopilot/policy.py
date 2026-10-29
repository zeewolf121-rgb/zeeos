#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fail-closed, read-only evidence collection and exact-head low-risk merges.

No approval, branch-protection, review-thread or release mutations are implemented.
The JSON decision is evidence, never an authorization token reusable for another head.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from typing import Any

BASELINE = {name: 15368 for name in
            ("lint", "build-iso", "boot-test", "cross-review", "owner-gate")}
SHA = re.compile(r"[0-9a-f]{40}\Z")
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
BLOCK_LABELS = {"needs-human", "needs-decision", "installer-disk", "security", "signing",
                "release", "manual-gate", "decision"}
MAX_PAGES = 30
MAX_FILES = 100
MAX_LINES = 2000
GH_ACTIONS = ("github-actions[bot]", 41898282, "Bot")
CODEX = "chatgpt-codex-connector[bot]"


class Blocked(Exception):
    """An unsupported or unsatisfied policy condition; never a reason to bypass it."""


def need(condition: Any, reason: str) -> None:
    if not condition:
        raise Blocked(reason)


def low_risk_path(path: str) -> bool:
    parts = PurePosixPath(path).parts
    return bool(path and "\\" not in path and not path.startswith("/")
                and all(p not in (".", "..", "") for p in path.split("/"))
                and (path == "CHANGELOG.md" or
                     (parts[:2] == ("docs", "user") and len(parts) >= 3 and path.endswith(".md"))))


class GitHub:
    def __init__(self, repo: str):
        need(REPO.fullmatch(repo), "invalid repository")
        self.repo = repo
        self.root = f"repos/{repo}"

    def command(self, args: list[str]) -> str:
        try:
            result = subprocess.run(["gh", *args], check=True, capture_output=True,
                                    text=True, timeout=60)
        except (subprocess.SubprocessError, OSError) as exc:
            # gh stderr can include URLs, task text or credential-related diagnostics.
            raise Blocked("GitHub command failed or timed out; no mutation authorized") from exc
        need(len(result.stdout) <= 12_000_000, "GitHub response exceeds evidence budget")
        return result.stdout

    def api(self, endpoint: str, fields: dict[str, str] | None = None) -> Any:
        args = ["api", endpoint]
        for key, value in (fields or {}).items():
            args += ["-f", f"{key}={value}"]
        try:
            return json.loads(self.command(args))
        except (ValueError, TypeError) as exc:
            raise Blocked("GitHub returned invalid JSON") from exc

    def pages(self, endpoint: str, key: str | None = None) -> list[dict]:
        collected = []
        for page in range(1, MAX_PAGES + 1):
            separator = "&" if "?" in endpoint else "?"
            data = self.api(f"{endpoint}{separator}per_page=100&page={page}")
            batch = data[key] if key else data
            need(isinstance(batch, list), "invalid paginated GitHub response")
            collected.extend(batch)
            if len(batch) < 100:
                return collected
        raise Blocked("GitHub pagination exceeds evidence budget")

    def threads(self, number: int) -> list[dict]:
        cursor = None
        threads = []
        for _ in range(MAX_PAGES):
            query = '''query($owner:String!,$name:String!,$pr:Int!,$cursor:String){
              repository(owner:$owner,name:$name){pullRequest(number:$pr){
                reviewThreads(first:100,after:$cursor){nodes{id isResolved}
                pageInfo{hasNextPage endCursor}}}}}'''
            args = ["api", "graphql", "-f", f"query={query}", "-F", f"pr={number}",
                    "-f", f"owner={self.repo.split('/')[0]}",
                    "-f", f"name={self.repo.split('/')[1]}"]
            if cursor:
                args += ["-f", f"cursor={cursor}"]
            try:
                data = json.loads(self.command(args))
                need(not data.get("errors"), "review-thread query failed")
                connection = data["data"]["repository"]["pullRequest"]["reviewThreads"]
                threads.extend(connection["nodes"])
                if connection["pageInfo"]["hasNextPage"] is False:
                    return threads
                next_cursor = connection["pageInfo"]["endCursor"]
                need(next_cursor and next_cursor != cursor, "invalid review-thread cursor")
                cursor = next_cursor
            except (ValueError, KeyError, TypeError) as exc:
                raise Blocked("incomplete review-thread evidence") from exc
        raise Blocked("review-thread pagination exceeds evidence budget")


def requirements(protection: dict, rules: list[dict]) -> tuple[dict[str, int | None], int]:
    need(protection.get("enforce_admins", {}).get("enabled") is True,
         "administrator protection is absent")
    need(protection.get("required_conversation_resolution", {}).get("enabled") is True,
         "conversation-resolution protection is absent")
    for flag in ("allow_force_pushes", "allow_deletions"):
        need(protection.get(flag, {}).get("enabled") is False, f"unsafe protection: {flag}")
    review_policy = protection.get("required_pull_request_reviews")
    need(isinstance(review_policy, dict), "pull-request review protection is absent")
    # A code-owner or latest-pusher requirement needs GitHub-specific reviewer assignment
    # evidence not implemented here. Let the owner handle it instead of approximating it.
    need(not review_policy.get("require_code_owner_reviews"), "code-owner policy requires owner lane")
    need(not review_policy.get("require_last_push_approval"), "last-push approval requires owner lane")
    count = review_policy.get("required_approving_review_count")
    need(type(count) is int and 0 <= count <= 100, "invalid required approval count")
    status = protection.get("required_status_checks")
    need(isinstance(status, dict), "required status protection is absent")
    # --match-head-commit guards the PR head, but cannot pin main. GitHub must
    # enforce the current base atomically; a local ancestry snapshot is insufficient.
    need(status.get("strict") is True,
         "owner must enable required up-to-date branch checks (strict=true); automation cannot change protection")
    checks = status.get("checks")
    need(isinstance(checks, list), "app-bound required-check evidence is absent")
    required: dict[str, int | None] = {}

    def add(context: Any, app: Any) -> None:
        need(isinstance(context, str) and context and (app is None or type(app) is int),
             "invalid required check")
        if context in required:
            need(required[context] == app, f"ambiguous required app: {context}")
        required[context] = app

    for check in checks:
        add(check["context"], check.get("app_id"))
    need(set(status.get("contexts", [])) <= set(required), "incomplete required-check app bindings")
    for name, app in BASELINE.items():
        need(required.get(name) == app, f"baseline protection changed: {name}")
    need(isinstance(rules, list), "effective branch rules are unavailable")
    for rule in rules:
        kind = rule.get("type")
        params = rule.get("parameters", {})
        if kind in ("deletion", "non_fast_forward"):
            continue
        if kind == "required_status_checks":
            for check in params["required_status_checks"]:
                add(check["context"], check.get("integration_id"))
        elif kind == "pull_request":
            need(not params.get("require_code_owner_review"), "ruleset code-owner policy requires owner lane")
            need(not params.get("require_last_push_approval"), "ruleset last-push policy requires owner lane")
            n = params.get("required_approving_review_count")
            need(type(n) is int and 0 <= n <= 100, "invalid ruleset approval count")
            count = max(count, n)
        else:
            raise Blocked(f"unsupported effective branch rule: {kind}")
    return required, count


def trusted_actions(user: dict) -> bool:
    return (user.get("login"), user.get("id"), user.get("type")) == GH_ACTIONS


def checks_green(required: dict[str, int | None], checks: list[dict], statuses: list[dict], head: str) -> dict:
    evidence = {}
    for name, app in required.items():
        runs = [run for run in checks if run.get("name") == name
                and (app is None or run.get("app", {}).get("id") == app)]
        states = [state for state in statuses if state.get("context") == name
                  and (app is None or (app == 15368 and trusted_actions(state.get("creator", {}))))]
        # Mixing API families or apps for one context makes attribution/order ambiguous.
        need(not (runs and states), f"ambiguous check/status context: {name}")
        if runs:
            need(all(type(run.get("id")) is int for run in runs), f"invalid check IDs: {name}")
            if app is None:
                need(len({run.get("app", {}).get("id") for run in runs}) == 1,
                     f"ambiguous check app: {name}")
            latest = max(runs, key=lambda run: run["id"])
            need(latest.get("head_sha") == head, f"check is not at head: {name}")
            need(latest.get("status") == "completed" and latest.get("conclusion") == "success",
                 f"required check not successful: {name}")
            evidence[name] = {"kind": "check", "id": latest["id"], "app": latest["app"]["id"]}
        elif states:
            need(all(type(state.get("id")) is int for state in states), f"invalid status IDs: {name}")
            need(all(trusted_actions(state.get("creator", {})) for state in states),
                 f"untrusted status attribution: {name}")
            latest = max(states, key=lambda state: state["id"])
            # The /commits/{head}/statuses endpoint binds statuses to the SHA;
            # GitHub does not include a sha field in every REST status response.
            need(latest.get("sha", head) == head and latest.get("state") == "success",
                 f"required status not successful: {name}")
            evidence[name] = {"kind": "status", "id": latest["id"], "app": 15368}
        else:
            raise Blocked(f"required check missing or wrong app: {name}")
    return evidence


def review_approvals(reviews: list[dict], author: str, head: str, count: int) -> list[str]:
    latest: dict[str, dict] = {}
    for review in sorted(reviews, key=lambda item: item["id"]):
        state = review["state"]
        need(state in ("APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED", "PENDING"),
             "unknown review state")
        if state in ("COMMENTED", "PENDING"):
            continue
        user = review["user"]["login"]
        latest[user] = review
    need(not any(review["state"] == "CHANGES_REQUESTED" for review in latest.values()),
         "a reviewer requests changes")
    approved = sorted(user for user, review in latest.items()
                      if user != author and review["state"] == "APPROVED"
                      and review.get("commit_id") == head
                      and review.get("author_association") in ("OWNER", "MEMBER", "COLLABORATOR"))
    need(len(approved) >= count, "required independent exact-head approvals are missing")
    return approved


def verify_files(files: list[dict], count: int, head_tree: dict, base_tree: dict) -> list[str]:
    need(0 < len(files) == count <= MAX_FILES, "changed files are empty, truncated or over budget")
    need(sum(item.get("changes", MAX_LINES + 1) for item in files) <= MAX_LINES,
         "change exceeds low-risk line budget")
    need(not head_tree.get("truncated") and not base_tree.get("truncated"), "Git tree is truncated")
    trees = [{item["path"]: item for item in tree["tree"]} for tree in (head_tree, base_tree)]
    paths = []
    for item in files:
        path = item["filename"]
        need(low_risk_path(path), "changed path requires owner/specialist lane")
        need(item.get("status") in ("added", "modified", "removed", "renamed"), "unsupported file change")
        if item["status"] == "renamed":
            need(low_risk_path(item.get("previous_filename", "")), "rename crosses sensitive scope")
        for entries, p in ((trees[0], path),
                           (trees[1], item.get("previous_filename", path))):
            entry = entries.get(p)
            if entry:
                need(entry.get("mode") == "100644" and entry.get("type") == "blob",
                     "executable, symlink or submodule requires owner lane")
        need(path in trees[0] or item["status"] == "removed", "changed file missing from head tree")
        need(item.get("patch") is not None, "binary or missing patch requires owner lane")
        paths.append(path)
    return paths


def linked_issue_number(pr: dict) -> int:
    branch = re.match(r"agent/[^/]+/(\d+)-", pr["head"]["ref"])
    body = {int(n) for n in re.findall(r"(?i)\bcloses\s+#(\d+)\b", pr.get("body") or "")}
    need(len(body) == 1, "exactly one linked issue is required")
    number = next(iter(body))
    need(branch is None or int(branch[1]) == number, "branch and linked issue disagree")
    return number


def independent_review(gh: GitHub, pr: dict, comments: list[dict], reviews: list[dict], base: str) -> dict:
    head = pr["head"]["sha"]
    ref = pr["head"]["ref"]
    issue = gh.api(f"{gh.root}/issues/{linked_issue_number(pr)}")
    models = [label["name"][6:] for label in issue["labels"] if label["name"].startswith("model:")]
    need(len(models) == 1, "authoring model label is missing or ambiguous")
    model = models[0]
    inferred = None
    if ref.endswith("-gemini"):
        inferred = "gemini"
    elif ref.endswith("-claude") or ref.startswith("agent/orchestrator/"):
        inferred = "claude"
    elif ref.startswith("codex/"):
        inferred = "codex"
    need(inferred is None or inferred == model, "branch and model label disagree")
    need(model in ("claude", "codex", "gemini"), "unsupported authoring model")
    if model == "claude":
        trusted = [c for c in comments if c.get("user", {}).get("login") == CODEX
                   and c["user"].get("type") == "Bot" and c["user"]["login"] != pr["user"]["login"]]
        decisions = []
        for comment in trusted:
            body = comment.get("body", "")
            receipt = re.search(r"codex-review-receipt:v1[\s\S]*?Reviewed commit:\*\* `([0-9a-f]{40})`", body)
            if receipt and receipt[1] == head:
                decisions.append((comment["id"], True))
            for block in re.findall(r"codex-review-state:v1 (\{[^\n]+\}) -->", body):
                try:
                    state = json.loads(block)["code_review"]
                except (ValueError, KeyError, TypeError):
                    continue
                if state.get("commit_sha") == head:
                    clean = (state.get("status") == "completed"
                             and type(state.get("has_any_findings")) is bool)
                    if state.get("has_any_findings") is True:
                        clean = clean and any(r.get("user", {}).get("login") == CODEX
                                              and r.get("commit_id") == head
                                              and r.get("state") in ("APPROVED", "COMMENTED") for r in reviews)
                    decisions.append((comment["id"], clean))
        need(decisions, "independent full-head Codex review is missing/incomplete")
        latest_id = max(item[0] for item in decisions)
        need(all(clean for comment_id, clean in decisions if comment_id == latest_id),
             "latest independent Codex review is incomplete or inconsistent")
        return {"author_model": model, "reviewer_model": "codex", "head": head}
    markers = []
    for comment in comments:
        if not trusted_actions(comment.get("user", {})):
            continue
        for verdict, run in re.findall(rf"<!-- claude-review sha={head} verdict=([a-z]+) run=(\d+) -->",
                                       comment.get("body", "")):
            markers.append((comment["id"], verdict, int(run)))
    need(markers, "independent exact-head Claude review is missing")
    _, verdict, run_id = max(markers)
    need(verdict == "pass", "latest independent Claude review did not pass")
    run = gh.api(f"{gh.root}/actions/runs/{run_id}")
    need(run.get("path") == ".github/workflows/agent-dispatch.yml"
         and run.get("head_branch") == "main" and run.get("head_sha") == base
         and run.get("event") == "workflow_dispatch" and run.get("status") == "completed"
         and run.get("conclusion") == "success", "Claude review workflow provenance is unverified")
    jobs = gh.pages(f"{gh.root}/actions/runs/{run_id}/jobs?filter=latest", "jobs")
    review_jobs = [job for job in jobs if job.get("name") == "claude-review"]
    need(len(review_jobs) == 1 and review_jobs[0].get("status") == "completed"
         and review_jobs[0].get("conclusion") == "success", "Claude review job did not complete successfully")
    return {"author_model": model, "reviewer_model": "claude", "head": head, "run": run_id}


def evaluate(gh: GitHub, number: int) -> dict:
    pr = gh.api(f"{gh.root}/pulls/{number}")
    need(pr.get("state") == "open" and pr.get("draft") is False and pr.get("merged") is False,
         "PR is not open and ready")
    need(pr["base"]["repo"]["full_name"] == gh.repo == pr["head"]["repo"]["full_name"],
         "fork or repository mismatch")
    need(pr["base"]["ref"] == "main" and pr.get("mergeable") is True, "PR is not mergeable into main")
    head, base = pr["head"]["sha"], pr["base"]["sha"]
    need(SHA.fullmatch(head) and SHA.fullmatch(base), "invalid full commit SHA")
    current = gh.api(f"{gh.root}/git/ref/heads/main")["object"]["sha"]
    need(current == base, "base moved during evidence collection")
    compare = gh.api(f"{gh.root}/compare/{base}...{head}")
    need(compare.get("status") == "ahead" and compare.get("behind_by") == 0,
         "head must include the current main commit")
    required, count = requirements(gh.api(f"{gh.root}/branches/main/protection"),
                                   gh.api(f"{gh.root}/rules/branches/main"))
    issue_number = linked_issue_number(pr)
    issue = gh.api(f"{gh.root}/issues/{issue_number}")
    need(issue.get("state") == "open", "linked issue is no longer open")
    labels = {label["name"] for obj in (pr, issue) for label in obj["labels"]}
    for item_number in {number, issue_number}:
        events = gh.pages(f"{gh.root}/issues/{item_number}/events")
        labels |= {event["label"]["name"] for event in events if event.get("event") == "labeled"}
    need(not labels & BLOCK_LABELS, "current/historical label requires owner lane")
    files = gh.pages(f"{gh.root}/pulls/{number}/files")
    paths = verify_files(files, pr["changed_files"],
                         gh.api(f"{gh.root}/git/trees/{head}?recursive=1"),
                         gh.api(f"{gh.root}/git/trees/{base}?recursive=1"))
    need(all(thread.get("isResolved") is True for thread in gh.threads(number)),
         "unresolved review threads remain")
    reviews = gh.pages(f"{gh.root}/pulls/{number}/reviews")
    approvals = review_approvals(reviews, pr["user"]["login"], head, count)
    review = independent_review(gh, pr, gh.pages(f"{gh.root}/issues/{number}/comments"), reviews, base)
    evidence = checks_green(required, gh.pages(f"{gh.root}/commits/{head}/check-runs?filter=all", "check_runs"),
                            gh.pages(f"{gh.root}/commits/{head}/statuses"), head)
    return {"allowed": True, "repo": gh.repo, "pr": number, "issue": issue_number, "head": head, "base": base,
            "paths": paths, "required_checks": required, "checks": evidence,
            "required_approvals": count, "independent_approvals": approvals, "review": review}


def merge(gh: GitHub, number: int) -> dict:
    need(gh.api(f"{gh.root}/actions/variables/AUTOPILOT").get("value") == "on",
         "AUTOPILOT kill switch is off or unavailable")
    first = evaluate(gh, number)
    env = dict(os.environ, GITHUB_REPOSITORY=gh.repo)
    try:
        subprocess.run([str(Path(__file__).with_name("gates.sh")), "cross-review", str(number)],
                       env=env, check=True, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        raise Blocked("existing independent cross-review gate did not pass") from exc
    need(gh.api(f"{gh.root}/actions/variables/AUTOPILOT").get("value") == "on",
         "AUTOPILOT kill switch changed before merge")
    second = evaluate(gh, number)
    need(first == second, "evidence changed before merge; wait for a fresh cycle")
    need(not os.environ.get("DRY_RUN"), "DRY_RUN: merge was not attempted")
    gh.command(["pr", "merge", str(number), "--repo", gh.repo,
                "--squash", "--match-head-commit", second["head"]])
    result = gh.api(f"{gh.root}/pulls/{number}")
    need(result.get("merged") is True and result["head"]["sha"] == second["head"],
         "merge command returned without a confirmed exact-head merge")
    second["merged"] = True
    second["merge_commit"] = result["merge_commit_sha"]
    return second


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "merge"))
    parser.add_argument("pr", type=int)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "zeewolf121-rgb/zeeos"))
    args = parser.parse_args()
    try:
        need(args.pr > 0, "invalid PR number")
        gh = GitHub(args.repo)
        result = merge(gh, args.pr) if args.command == "merge" else evaluate(gh, args.pr)
        code = 0
    except Blocked as exc:
        result = {"allowed": False, "repo": args.repo, "pr": args.pr, "reason": str(exc)}
        code = 1
    except (KeyError, TypeError, ValueError, AttributeError) as exc:
        result = {"allowed": False, "repo": args.repo, "pr": args.pr,
                  "reason": f"incomplete or ambiguous GitHub evidence ({type(exc).__name__})"}
        code = 1
    print(json.dumps(result, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
