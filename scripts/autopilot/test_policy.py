#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline adversarial policy tests. All GitHub mutations are mocked."""
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("policy", Path(__file__).with_name("policy.py"))
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)
HEAD = "a" * 40
BASE = "b" * 40
REPO = "zeewolf121-rgb/zeeos"
ACTIONS = {"login": "github-actions[bot]", "id": 41898282, "type": "Bot"}


def protection():
    return {"enforce_admins": {"enabled": True},
            "required_conversation_resolution": {"enabled": True},
            "allow_force_pushes": {"enabled": False}, "allow_deletions": {"enabled": False},
            "required_pull_request_reviews": {"required_approving_review_count": 0},
            "required_status_checks": {"contexts": list(policy.BASELINE), "strict": True,
                                       "checks": [{"context": name, "app_id": app}
                                                  for name, app in policy.BASELINE.items()]}}


def run(name="lint", run_id=1, conclusion="success", status="completed", app=15368):
    return {"id": run_id, "name": name, "app": {"id": app}, "head_sha": HEAD,
            "status": status, "conclusion": conclusion}


def review(state="APPROVED", review_id=1, user="independent", head=HEAD):
    return {"id": review_id, "state": state, "user": {"login": user}, "commit_id": head,
            "author_association": "COLLABORATOR"}


class FakeGitHub(policy.GitHub):
    def __init__(self):
        super().__init__(REPO)
        root = self.root
        self.pr = {"number": 7, "state": "open", "draft": False, "merged": False,
                   "mergeable": True, "changed_files": 1, "labels": [], "body": "Closes #9",
                   "user": {"login": "author"},
                   "head": {"sha": HEAD, "ref": "agent/docs-writer/9-autonomy-gemini", "repo": {"full_name": REPO}},
                   "base": {"sha": BASE, "ref": "main", "repo": {"full_name": REPO}}}
        tree = {"truncated": False, "tree": [{"path": "docs/user/readme.md", "mode": "100644", "type": "blob"}]}
        self.data = {
            f"{root}/pulls/7": self.pr,
            f"{root}/issues/9": {"state": "open", "labels": [{"name": "model:gemini"}]},
            f"{root}/git/ref/heads/main": {"object": {"sha": BASE}},
            f"{root}/compare/{BASE}...{HEAD}": {"status": "ahead", "behind_by": 0},
            f"{root}/branches/main/protection": protection(),
            f"{root}/rules/branches/main": [],
            f"{root}/git/trees/{HEAD}?recursive=1": copy.deepcopy(tree),
            f"{root}/git/trees/{BASE}?recursive=1": copy.deepcopy(tree),
            f"{root}/actions/runs/33": {"path": ".github/workflows/agent-dispatch.yml", "head_branch": "main",
                                       "head_sha": BASE, "event": "workflow_dispatch", "status": "completed",
                                       "conclusion": "success"},
            f"{root}/actions/variables/AUTOPILOT": {"value": "on"},
        }
        self.lists = {
            f"{root}/issues/7/events": [],
            f"{root}/issues/9/events": [],
            f"{root}/pulls/7/files": [{"filename": "docs/user/readme.md", "status": "modified", "changes": 2,
                                      "patch": "@@ -1 +1 @@\n-before\n+after"}],
            f"{root}/pulls/7/reviews": [],
            f"{root}/issues/7/comments": [{"id": 1, "user": ACTIONS,
                                         "body": f"<!-- claude-review sha={HEAD} verdict=pass run=33 -->"}],
            f"{root}/actions/runs/33/jobs?filter=latest": [{"id": 1, "name": "claude-review", "status": "completed", "conclusion": "success"}],
            f"{root}/commits/{HEAD}/check-runs?filter=all": [run(name, index) for index, name in enumerate(policy.BASELINE, 1)],
            f"{root}/commits/{HEAD}/statuses": [],
        }
        self.review_threads = []
        self.commands = []

    def api(self, endpoint, fields=None):
        if endpoint not in self.data:
            raise policy.Blocked(f"unexpected API read: {endpoint}")
        return copy.deepcopy(self.data[endpoint])

    def pages(self, endpoint, key=None):
        return copy.deepcopy(self.lists[endpoint])

    def threads(self, number):
        return copy.deepcopy(self.review_threads)

    def command(self, args):
        self.commands.append(args)
        if args[:2] == ["pr", "merge"]:
            self.pr["merged"] = True
            self.pr["merge_commit_sha"] = "c" * 40
        return ""


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.gh = FakeGitHub()

    def test_eligible_complete_snapshot(self):
        result = policy.evaluate(self.gh, 7)
        self.assertTrue(result["allowed"])
        self.assertEqual(result["review"]["reviewer_model"], "claude")
        self.assertEqual(result["required_checks"], policy.BASELINE)
        self.assertFalse(self.gh.commands)

    def test_current_protection_mandatory(self):
        for mutate in (lambda p: p.pop("required_status_checks"),
                       lambda p: p["enforce_admins"].update(enabled=False),
                       lambda p: p["required_status_checks"]["checks"].pop(),
                       lambda p: p["required_status_checks"]["checks"][0].update(app_id=None),
                       lambda p: p["allow_force_pushes"].update(enabled=True)):
            value = protection()
            mutate(value)
            with self.subTest(value=value), self.assertRaises(policy.Blocked):
                policy.requirements(value, [])

    def test_non_strict_protection_blocks_base_race(self):
        value = protection()
        value["required_status_checks"]["strict"] = False
        with self.assertRaisesRegex(policy.Blocked, "owner must enable.*strict=true"):
            policy.requirements(value, [])
        # Effective constraints combine: a strict branch remains stronger than an
        # additional ruleset whose corresponding option is false.
        required, _ = policy.requirements(protection(), [{
            "type": "required_status_checks", "parameters": {
                "strict_required_status_checks_policy": False,
                "required_status_checks": [{"context": "lint", "integration_id": 15368}]}}])
        self.assertEqual(required, policy.BASELINE)

    def test_dynamic_protection_and_rules_union(self):
        value = protection()
        value["required_status_checks"]["checks"].append({"context": "extra", "app_id": 42})
        required, count = policy.requirements(value, [{"type": "required_status_checks", "parameters": {
            "required_status_checks": [{"context": "rules-check", "integration_id": 99}]}},
            {"type": "pull_request", "parameters": {"required_approving_review_count": 2}}])
        self.assertEqual(required["extra"], 42)
        self.assertEqual(required["rules-check"], 99)
        self.assertEqual(count, 2)
        with self.assertRaises(policy.Blocked):
            policy.checks_green(required, [run(name, i) for i, name in enumerate(policy.BASELINE, 1)], [], HEAD)

    def test_unknown_rules_and_app_conflicts_fail_closed(self):
        for rule in ({"type": "required_signatures"}, {"type": "required_workflows"},
                     {"type": "required_status_checks", "parameters": {"required_status_checks": [
                         {"context": "lint", "integration_id": 99}]}}):
            with self.subTest(rule=rule), self.assertRaises(policy.Blocked):
                policy.requirements(protection(), [rule])

    def test_pending_newer_attempt_blocks_old_success(self):
        for newer in (run(run_id=2, status="in_progress", conclusion=None),
                      run(run_id=2, conclusion="failure")):
            with self.subTest(newer=newer), self.assertRaises(policy.Blocked):
                policy.checks_green({"lint": 15368}, [newer, run(run_id=1)], [], HEAD)

    def test_other_app_cannot_satisfy_required_check(self):
        with self.assertRaises(policy.Blocked):
            policy.checks_green({"lint": 15368}, [run(app=44)], [], HEAD)

    def test_status_actor_and_latest_attempt(self):
        state = {"id": 2, "context": "cross-review", "sha": HEAD, "state": "success", "creator": ACTIONS}
        self.assertTrue(policy.checks_green({"cross-review": 15368}, [], [state], HEAD))
        for extra in (dict(state, id=3, state="pending"), dict(state, creator={"login": "github-actions-evil"})):
            with self.subTest(extra=extra), self.assertRaises(policy.Blocked):
                policy.checks_green({"cross-review": 15368}, [], [extra], HEAD)
        with self.assertRaises(policy.Blocked):
            policy.checks_green({"cross-review": 15368}, [run("cross-review")], [state], HEAD)

    def test_required_review_exact_head_independent_and_latest(self):
        self.assertEqual(policy.review_approvals([review()], "author", HEAD, 1), ["independent"])
        bad_sets = ([review(user="author")], [review(head="c" * 40)],
                    [review(), review("CHANGES_REQUESTED", 2)],
                    [review(), review("DISMISSED", 2)])
        for values in bad_sets:
            with self.subTest(values=values), self.assertRaises(policy.Blocked):
                policy.review_approvals(values, "author", HEAD, 1)
        with self.assertRaises(policy.Blocked):
            policy.review_approvals([review("CHANGES_REQUESTED", head=BASE)], "author", HEAD, 0)

    def test_files_deny_executable_symlink_rename_binary_and_scope(self):
        root = self.gh.root
        for path in (".github/workflows/lint.yml", "docs/agent-context.md", "docs/user/../policy.md", "docs/user/a.sh"):
            self.assertFalse(policy.low_risk_path(path))
        self.assertTrue(policy.low_risk_path("CHANGELOG.md"))
        self.assertTrue(policy.low_risk_path("docs/user/sub/page.md"))
        files = self.gh.lists[f"{root}/pulls/7/files"]
        tree = self.gh.data[f"{root}/git/trees/{HEAD}?recursive=1"]
        for mode in ("120000", "100755", "160000"):
            changed = copy.deepcopy(tree)
            changed["tree"][0]["mode"] = mode
            with self.subTest(mode=mode), self.assertRaises(policy.Blocked):
                policy.verify_files(files, 1, changed, tree)
        for extra in ({"status": "renamed", "previous_filename": "security/keys/private.key"},
                      {"patch": None}, {"changes": 2001}):
            with self.subTest(extra=extra), self.assertRaises(policy.Blocked):
                policy.verify_files([dict(files[0], **extra)], 1, tree, tree)
        with self.assertRaises(policy.Blocked):
            policy.verify_files(files, 2, tree, tree)

    def test_unresolved_outdated_or_new_threads_block(self):
        self.gh.review_threads = [{"id": "thread", "isResolved": False, "isOutdated": True}]
        with self.assertRaisesRegex(policy.Blocked, "unresolved"):
            policy.evaluate(self.gh, 7)

    def test_stale_main_and_forks_block(self):
        self.gh.pr["base"]["sha"] = "c" * 40
        with self.assertRaises(policy.Blocked):
            policy.evaluate(self.gh, 7)
        self.gh = FakeGitHub()
        self.gh.pr["head"]["repo"]["full_name"] = "fork/repo"
        with self.assertRaises(policy.Blocked):
            policy.evaluate(self.gh, 7)
        self.gh = FakeGitHub()
        self.gh.data[f"{self.gh.root}/compare/{BASE}...{HEAD}"]["behind_by"] = 1
        with self.assertRaises(policy.Blocked):
            policy.evaluate(self.gh, 7)

    def test_model_review_requires_real_successful_trusted_job(self):
        root = self.gh.root
        for extra in ({"status": "in_progress"}, {"conclusion": "failure"},
                      {"head_branch": "attacker"}, {"head_sha": "c" * 40},
                      {"path": ".github/workflows/fake.yml"}):
            gh = FakeGitHub()
            gh.data[f"{root}/actions/runs/33"].update(extra)
            with self.subTest(extra=extra), self.assertRaises(policy.Blocked):
                policy.evaluate(gh, 7)
        self.gh.lists[f"{root}/issues/7/comments"][0]["user"] = {"login": "github-actions-spoof", "type": "Bot"}
        with self.assertRaises(policy.Blocked):
            policy.evaluate(self.gh, 7)

    def test_abbreviated_codex_receipt_rejected_and_full_receipt_accepted(self):
        gh = self.gh
        gh.pr["head"]["ref"] = "agent/docs-writer/9-autonomy-claude"
        gh.data[f"{gh.root}/issues/9"]["labels"] = [{"name": "model:claude"}]
        comment = {"id": 3, "user": {"login": policy.CODEX, "type": "Bot"},
                   "body": f"codex-review-receipt:v1 Reviewed commit:** `{HEAD[:7]}`"}
        gh.lists[f"{gh.root}/issues/7/comments"] = [comment]
        with self.assertRaises(policy.Blocked):
            policy.evaluate(gh, 7)
        comment["body"] = f"codex-review-receipt:v1 Reviewed commit:** `{HEAD}`"
        self.assertTrue(policy.evaluate(gh, 7)["allowed"])

    def test_linked_issue_historical_sensitive_label_and_mismatch_block(self):
        self.gh.lists[f"{self.gh.root}/issues/9/events"] = [
            {"event": "labeled", "label": {"name": "installer-disk"}}]
        with self.assertRaisesRegex(policy.Blocked, "historical"):
            policy.evaluate(self.gh, 7)
        self.gh = FakeGitHub()
        self.gh.pr["body"] = "Closes #10"
        with self.assertRaisesRegex(policy.Blocked, "disagree"):
            policy.evaluate(self.gh, 7)

    def test_branch_and_model_label_must_agree(self):
        self.gh.data[f"{self.gh.root}/issues/9"]["labels"] = [{"name": "model:claude"}]
        with self.assertRaisesRegex(policy.Blocked, "model label disagree"):
            policy.evaluate(self.gh, 7)

    def test_manual_gate_and_decision_labels_block_current_or_historical(self):
        for label in ("manual-gate", "decision"):
            for historical in (False, True):
                gh = FakeGitHub()
                if historical:
                    gh.lists[f"{gh.root}/issues/9/events"] = [
                        {"event": "labeled", "label": {"name": label}}]
                else:
                    gh.pr["labels"] = [{"name": label}]
                with self.subTest(label=label, historical=historical), self.assertRaises(policy.Blocked):
                    policy.evaluate(gh, 7)

    def test_latest_failed_claude_marker_blocks_old_pass(self):
        self.gh.lists[f"{self.gh.root}/issues/7/comments"].append({
            "id": 2, "user": ACTIONS, "body": f"<!-- claude-review sha={HEAD} verdict=fail run=34 -->"})
        with self.assertRaises(policy.Blocked):
            policy.evaluate(self.gh, 7)

    @patch.object(policy.subprocess, "run")
    def test_exact_head_merge_no_admin_auto_or_branch_deletion(self, legacy):
        legacy.return_value = subprocess.CompletedProcess([], 0)
        result = policy.merge(self.gh, 7)
        self.assertTrue(result["merged"])
        self.assertEqual(self.gh.commands, [["pr", "merge", "7", "--repo", REPO,
                                           "--squash", "--match-head-commit", HEAD]])
        self.assertEqual(legacy.call_args.args[0][1:], ["cross-review", "7"])

    @patch.object(policy.subprocess, "run")
    def test_merge_race_and_failed_legacy_gate_never_mutate(self, legacy):
        legacy.side_effect = subprocess.CalledProcessError(1, "gates.sh")
        with self.assertRaises(policy.Blocked):
            policy.merge(self.gh, 7)
        self.assertFalse(self.gh.commands)
        def change(*args, **kwargs):
            self.gh.pr["head"]["sha"] = "d" * 40
            return subprocess.CompletedProcess([], 0)
        legacy.side_effect = change
        with self.assertRaises(policy.Blocked):
            policy.merge(self.gh, 7)
        self.assertFalse(self.gh.commands)

    def test_kill_switch_blocks_mutation(self):
        self.gh.data[f"{self.gh.root}/actions/variables/AUTOPILOT"]["value"] = "off"
        with self.assertRaisesRegex(policy.Blocked, "kill switch"):
            policy.merge(self.gh, 7)
        self.assertFalse(self.gh.commands)

    def test_rest_pagination_reads_later_pages_and_fails_on_limit(self):
        gh = policy.GitHub(REPO)
        with patch.object(gh, "api", side_effect=[[{}] * 100, [{"last": True}]]) as api:
            self.assertEqual(len(gh.pages("endpoint")), 101)
            self.assertIn("page=2", api.call_args.args[0])
        with patch.object(gh, "api", return_value=[{}] * 100):
            with self.assertRaisesRegex(policy.Blocked, "pagination"):
                gh.pages("endpoint")

    def test_graphql_thread_pagination_reads_second_page(self):
        gh = policy.GitHub(REPO)
        def page(nodes, more, cursor):
            return json.dumps({"data": {"repository": {"pullRequest": {"reviewThreads": {
                "nodes": nodes, "pageInfo": {"hasNextPage": more, "endCursor": cursor}}}}}})
        with patch.object(gh, "command", side_effect=[page([{"isResolved": True}], True, "next"),
                                                     page([{"isResolved": False}], False, None)]) as command:
            self.assertEqual(gh.threads(7), [{"isResolved": True}, {"isResolved": False}])
            self.assertIn("cursor=next", command.call_args.args[0])
        with patch.object(gh, "command", return_value=page([], True, "same")):
            with self.assertRaises(policy.Blocked):
                gh.threads(7)


if __name__ == "__main__":
    unittest.main()
