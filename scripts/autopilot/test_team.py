#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Adversarial controller tests; providers and GitHub never receive requests."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("autopilot_team", Path(__file__).with_name("team.py"))
team = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(team)


def issue(number=42, author="gemini"):
    return {"number": number, "state": "open", "title": "Clarify guide",
            "body": "Keep every safety warning; clarify the introductory sentence.",
            "labels": [{"name": label} for label in
                       ("ready", "autonomy:low-risk", "agent:docs-writer", f"model:{author}")]}


def enabled_variables():
    return {"total_count": 2, "variables": [{"name": "AUTOPILOT", "value": "on"},
                                            {"name": "AUTOPILOT_CONTROLLER", "value": "codex-local"}]}


class TeamTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.state = Path(self.temporary.name).resolve()

    def tearDown(self):
        self.temporary.cleanup()

    def test_scope_rejects_traversal_hidden_absolute_and_executables(self):
        for path in ("docs/user/guide.md", "docs/user/nested/guide.md", "CHANGELOG.md"):
            with self.subTest(path=path):
                self.assertTrue(team.allowed(path))
        for path in ("/docs/user/a.md", "docs/user/../a.md", "docs//user/a.md",
                     "docs/user/./a.md", "docs/user/.hidden.md", "docs/user/a.py",
                     "docs/user/a.md/../../security/keys/key.md", "scripts/autopilot/team.py",
                     ".github/workflows/release.yml", "docs/CONVENTIONS.md", "docs/user2/a.md",
                     "docs/user/new\nline.md", "docs/user/null\0.md", "docs/user/a\\b.md"):
            with self.subTest(path=path):
                self.assertFalse(team.allowed(path))

    def test_proposal_rejects_duplicate_empty_oversized_and_secret_content(self):
        file = {"path": "docs/user/guide.md", "content": "Safety warning remains.\n"}
        cases = ({"files": []}, {"files": [file] * 4}, {"files": [file, file]},
                 {"files": [dict(file, content=" ")]}, {"files": [dict(file, content="\0")]},
                 {"files": [dict(file, content="a" * 16001)]},
                 {"files": [dict(file, content="ghp_" + "a" * 35)]},
                 {"files": [dict(file, content="-----BEGIN RSA PRIVATE KEY-----")]},
                 {"files": [dict(file, path="security/a.md")]},
                 {"files": [file], "command": "publish"})
        for raw in cases:
            with self.subTest(raw=str(raw)[:100]), self.assertRaises(team.Stop):
                team.proposal(raw)
        self.assertEqual(team.proposal({"files": [file]}), {"files": [file]})

    def test_non_string_paths_are_rejected_without_type_errors(self):
        for path in (None, 17, [], {}, True):
            with self.subTest(path=path):
                self.assertFalse(team.allowed(path))
                with self.assertRaises(team.Stop):
                    team.proposal({"files": [{"path": path, "content": "new text"}]})

    def test_parse_answer_rejects_error_missing_and_markdown_wrappers(self):
        for raw in ('{"error":"failed","response":"{}"}', '{"result":3}',
                    '{"status":"WAITING","response":"{}"}',
                    '{"status":"CANCELED","response":"{}"}',
                    '{"status":null,"response":"{}"}',
                    '{"response":"```json\\n{}\\n```"}'):
            with self.subTest(raw=raw), self.assertRaises((team.Stop, ValueError)):
                team.parse_answer(raw)
        self.assertEqual(team.parse_answer('{"result":"{\\"files\\":[]}"}'), {"files": []})
        self.assertEqual(team.parse_answer('{"status":"SUCCESS","response":"{}"}'), {})

    def test_malformed_model_objects_hold_with_a_controlled_error(self):
        for raw in (None, 3, [], "unexpected", {"files": [None]}, {"files": [3]}):
            with self.subTest(raw=raw), self.assertRaises(team.Stop):
                team.proposal(raw)
        for text in ("[]", "null", "3", '"unexpected"'):
            with self.subTest(text=text), self.assertRaises(team.Stop):
                team.parse_answer(text)

    def test_eligibility_requires_one_model_and_explicit_scope(self):
        self.assertTrue(team.eligible(issue()))
        for label in ("needs-human", "in-progress", "paused", "installer-disk", "security",
                      "decision", "release", "manual-gate", "needs-decision", "blocked-by:#9",
                      "agent:installer-engineer", "model:claude"):
            candidate = issue()
            candidate["labels"].append({"name": label})
            with self.subTest(label=label):
                self.assertFalse(team.eligible(candidate))
        for removed in ("ready", "autonomy:low-risk", "agent:docs-writer", "model:gemini"):
            candidate = issue()
            candidate["labels"] = [x for x in candidate["labels"] if x["name"] != removed]
            self.assertFalse(team.eligible(candidate))

    def test_apply_does_not_follow_file_or_directory_symlinks(self):
        checkout = self.state / "checkout"
        checkout.mkdir()
        external = self.state / "external"
        external.mkdir()
        original = external / "guide.md"
        original.write_text("must remain intact")
        (checkout / "docs").mkdir()
        (checkout / "docs/user").symlink_to(external, target_is_directory=True)
        changes = {"files": [{"path": "docs/user/guide.md", "content": "replacement"}]}
        with self.assertRaises(team.Stop):
            team.apply(checkout, changes)
        self.assertEqual(original.read_text(), "must remain intact")
        (checkout / "docs/user").unlink()
        (checkout / "docs/user").mkdir()
        (checkout / "docs/user/guide.md").symlink_to(original)
        with self.assertRaises(team.Stop):
            team.apply(checkout, changes)
        self.assertEqual(original.read_text(), "must remain intact")

    def test_audit_detects_tampering_before_append(self):
        team.audit(self.state, "first", issue=42)
        team.audit(self.state, "second", issue=42)
        log = self.state / "audit.jsonl"
        original = log.read_text()
        log.write_text(original.replace('"issue": 42', '"issue": 99', 1))
        changed = log.read_text()
        with self.assertRaises(team.Stop):
            team.audit(self.state, "third")
        self.assertEqual(log.read_text(), changed)

    def test_subprocess_output_and_time_budgets_are_enforced(self):
        with patch.object(team, "MAX_OUTPUT", 1024):
            with self.assertRaises(team.Stop):
                team.run([sys.executable, "-c", "print('a'*2048)"], cwd=self.state)
        with self.assertRaises(team.Stop):
            team.run([sys.executable, "-c", "import time; time.sleep(10)"],
                     cwd=self.state, timeout=.05)

    def test_child_failure_does_not_expose_diagnostics(self):
        with self.assertRaises(team.Stop) as raised:
            team.run([sys.executable, "-c",
                      "import sys; sys.stderr.write('SENSITIVE_PROVIDER_DIAGNOSTIC'); sys.exit(2)"],
                     cwd=self.state)
        self.assertNotIn("SENSITIVE", str(raised.exception))

    def test_interrupt_and_unexpected_error_terminate_child_group(self):
        for error in (KeyboardInterrupt(), OSError("polling failed")):
            process = unittest.mock.Mock()
            process.pid = 12345
            process.poll.return_value = None
            with self.subTest(error=type(error).__name__), patch.object(team.subprocess, "Popen", return_value=process), \
                    patch.object(team.time, "sleep", side_effect=error), patch.object(team.os, "killpg") as kill:
                with self.assertRaises(type(error)):
                    team.run(["fixture-child"], cwd=self.state)
                kill.assert_called_once_with(12345, team.signal.SIGKILL)
                process.wait.assert_called_once()

    def test_model_launch_denies_tools_and_excludes_github_signing_credentials(self):
        calls = []

        def capture(args, **kwargs):
            calls.append((args, kwargs))
            if args[0] == "gemini":
                policy = Path(args[args.index("--admin-policy") + 1]).read_text()
                self.assertIn('toolName = "*"', policy)
                self.assertIn('decision = "deny"', policy)
                config = Path(kwargs["env"]["GEMINI_CLI_SYSTEM_SETTINGS_PATH"])
                settings = json.loads(config.read_text())
                self.assertFalse(settings["hooksConfig"]["enabled"])
                self.assertFalse(settings["admin"]["mcp"]["enabled"])
                self.assertFalse(settings["admin"]["extensions"]["enabled"])
                self.assertEqual(settings["security"]["auth"]["selectedType"], "gemini-api-key")
                self.assertFalse((config.parent / "home/.gemini/oauth_creds.json").exists())
            return json.dumps({"result": '{"verdict":"pass","findings":[]}'})

        fake_env = {"PATH": os.environ["PATH"], "HOME": str(self.state), "USER": "fixture-user", "GH_TOKEN": "github-secret",
                    "GITHUB_TOKEN": "github-secret", "MINISIGN_SECRET_KEY": "signing-secret",
                    "ANTHROPIC_API_KEY": "claude-secret", "GEMINI_API_KEY": "gemini-secret"}
        with patch.dict(os.environ, fake_env, clear=True), patch.object(team, "run", side_effect=capture):
            for provider in ("claude", "gemini"):
                self.assertEqual(team.model(provider, "Return a verdict.", self.state),
                                 {"verdict": "pass", "findings": []})
        for args, kwargs in calls:
            self.assertLessEqual(kwargs["timeout"], team.TIMEOUT)
            self.assertNotIn("GH_TOKEN", kwargs["env"])
            self.assertNotIn("GITHUB_TOKEN", kwargs["env"])
            self.assertNotIn("MINISIGN_SECRET_KEY", kwargs["env"])
            self.assertTrue(str(kwargs["cwd"]).startswith(str(self.state)))
            if args[0] == "claude":
                self.assertEqual(args[args.index("--tools") + 1], "")
                self.assertIn("--safe-mode", args)
                self.assertIn("--disable-slash-commands", args)
                self.assertIn("--strict-mcp-config", args)
                self.assertIn("--max-budget-usd", args)
                self.assertNotIn("--dangerously-skip-permissions", args)
                self.assertNotIn("GEMINI_API_KEY", kwargs["env"])
                self.assertEqual(kwargs["env"]["USER"], "fixture-user")
            else:
                self.assertNotIn("ANTHROPIC_API_KEY", kwargs["env"])
                self.assertNotIn("USER", kwargs["env"])

    def test_retired_personal_login_holds_without_launch_or_credential_copy(self):
        for key in (None, "", "   "):
            env = {"HOME": str(self.state), "PATH": os.environ["PATH"]}
            if key is not None:
                env["GEMINI_API_KEY"] = key
            with self.subTest(key=key), patch.dict(os.environ, env, clear=True), \
                    patch.object(team, "run") as launch, patch.object(team.tempfile, "TemporaryDirectory") as scratch:
                with self.assertRaisesRegex(team.Stop, "Antigravity autonomous adapter is not approved"):
                    team.model("gemini", "Return a verdict.", self.state)
                launch.assert_not_called()
                scratch.assert_not_called()

    def test_input_budget_and_secret_checks_happen_before_model_execution(self):
        with patch.object(team, "run") as mocked:
            for name, prompt in (("unknown", "hello"), ("claude", "x" * (team.MAX_INPUT + 1)),
                                 ("gemini", "github_pat_" + "a" * 25)):
                with self.assertRaises(team.Stop):
                    team.model(name, prompt, self.state)
            mocked.assert_not_called()

    def test_retry_exhaustion_makes_no_network_or_model_calls(self):
        attempts = {"42": team.MAX_ATTEMPTS}
        with patch.object(team, "api") as api, patch.object(team, "model") as model:
            team.attempt(self.state, issue(), attempts)
            api.assert_not_called()
            model.assert_not_called()

    def test_existing_branch_or_pr_preserves_work_and_consumes_retry(self):
        for count, responses in enumerate((([{"number": 1}], []), ([], [{"ref": "existing"}])), start=1):
            attempts = {}
            with patch.object(team, "api", side_effect=responses), patch.object(team, "run") as run:
                with self.assertRaises(team.Stop):
                    team.attempt(self.state, issue(), attempts)
                run.assert_not_called()
            self.assertEqual(attempts, {"42": count})
            self.assertEqual(json.loads((self.state / "attempts.json").read_text()), {"42": count})

    def test_failed_review_preserves_checkout_and_never_pushes(self):
        commands = []
        attempts = {}

        def execute(args, **kwargs):
            commands.append(args)
            if args[:2] == ["git", "clone"]:
                Path(args[-1]).mkdir()
            return "a" * 40

        with patch.object(team, "api", side_effect=[[], []]), \
                patch.object(team, "run", side_effect=execute), \
                patch.object(team, "documents", return_value={}), \
                patch.object(team, "model", side_effect=[
                    {"files": [{"path": "docs/user/guide.md", "content": "new text"}]},
                    {"verdict": "fail", "findings": ["unsupported instruction"]}]):
            with self.assertRaises(team.Stop):
                team.attempt(self.state, issue(), attempts)
        self.assertTrue(list(self.state.glob("issue-42-*")))
        self.assertFalse(any(args[:2] == ["git", "push"] for args in commands))
        self.assertEqual(attempts["42"], 1)

    def test_issue_or_main_changes_prevent_publication(self):
        candidate = issue()
        changes = {"files": [{"path": "docs/user/guide.md", "content": "retained warning"}]}
        for condition in ("issue-changed", "main-advanced"):
            commands = []
            fresh = copy.deepcopy(candidate)
            if condition == "issue-changed":
                fresh["body"] = "A changed task that was not reviewed."

            def execute(args, **kwargs):
                commands.append(args)
                if args[:2] == ["git", "clone"]:
                    Path(args[-1]).mkdir()
                return "base-sha"

            responses = [[], [], fresh]
            if condition == "main-advanced":
                responses.append({"object": {"sha": "new-main-sha"}})
            with self.subTest(condition=condition), patch.object(team, "api", side_effect=responses), \
                    patch.object(team, "run", side_effect=execute), patch.object(team, "documents", return_value={}), \
                    patch.object(team, "apply"), patch.object(team, "model", side_effect=[
                        changes, {"verdict": "pass", "findings": []}]), patch.object(team, "gh") as gh:
                with self.assertRaises(team.Stop):
                    team.attempt(self.state, candidate, {})
                gh.assert_not_called()
            self.assertFalse(any(args[:2] == ["git", "push"] for args in commands))

    def test_real_git_fixture_proposal_review_commit_and_pr(self):
        """Real isolated Git diff/commit; fake provider replies and GitHub boundary only."""
        source = self.state / "source"
        source.mkdir()
        subprocess.run(["git", "init", "-b", "main", str(source)], check=True, capture_output=True)
        (source / "docs/user").mkdir(parents=True)
        (source / "docs/user/guide.md").write_text("Keep a backup before installing.\nOriginal introduction.\n")
        subprocess.run(["git", "-C", str(source), "add", "."], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(source), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                        "commit", "-m", "docs(user): initial fixture"], check=True, capture_output=True)
        base = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
        original_run = team.run
        publication = []
        model_roles = []
        candidate = issue()

        def execute(args, **kwargs):
            if args[:2] == ["git", "clone"]:
                args = [*args[:-2], str(source), args[-1]]
            if args[:2] == ["git", "push"]:
                publication.append(("push", args))
                return ""
            return original_run(args, **kwargs)

        def endpoint(path, *args):
            if "actions/variables" in path:
                return enabled_variables()
            if "pulls?state=all" in path or "matching-refs" in path:
                return []
            if path.endswith("/issues/42"):
                return copy.deepcopy(candidate)
            if path.endswith("/git/ref/heads/main"):
                return {"object": {"sha": base}}
            if path.endswith("/pulls"):
                publication.append(("pr", args))
                return {"number": 91}
            self.fail(f"unexpected API: {path}")

        def provider(name, prompt, parent):
            model_roles.append(name)
            if len(model_roles) == 1:
                return {"files": [{"path": "docs/user/guide.md",
                                   "content": "Keep a backup before installing.\nClearer introduction.\n"}]}
            self.assertIn("Keep a backup", prompt)
            return {"verdict": "pass", "findings": []}

        with patch.object(team, "run", side_effect=execute), patch.object(team, "api", side_effect=endpoint), \
                patch.object(team, "model", side_effect=provider), patch.object(team, "gh") as gh:
            team.attempt(self.state, candidate, {})
        self.assertEqual(model_roles, ["gemini", "claude"])
        self.assertEqual([x[0] for x in publication], ["push", "pr"])
        checkout, = self.state.glob("issue-42-*")
        self.assertIn("Clearer introduction", (checkout / "docs/user/guide.md").read_text())
        self.assertIn("Original introduction", (source / "docs/user/guide.md").read_text())
        self.assertEqual(original_run(["git", "status", "--porcelain"], cwd=checkout), "")
        events = [json.loads(line)["event"] for line in (self.state / "audit.jsonl").read_text().splitlines()]
        self.assertEqual(events, ["attempt-reserved", "attempt-start", "proposal-reviewed", "branch-published", "pr-opened"])
        self.assertFalse(any("approve" in str(call).lower() or "merge" in str(call).lower()
                             for call in gh.call_args_list))

    def cycle_fixture(self, *, active=False, collision=False, lease_owner="lease-owned", candidates=None,
                      legacy_tasks=None):
        calls = []

        def execute(args, **kwargs):
            if args == ["git", "status", "--porcelain"]:
                return ""
            if args == ["git", "rev-parse", "HEAD"]:
                return "main-sha"
            self.fail(f"unexpected child process: {args}")

        def endpoint(path, *args):
            calls.append((path, args))
            if path.endswith("/git/ref/heads/main"):
                return {"object": {"sha": "main-sha"}}
            if "actions/variables" in path:
                return enabled_variables()
            if "agent-dispatch.yml/runs?" in path:
                return {"total_count": int(active), "workflow_runs": []}
            if path.endswith("/git/commits/main-sha"):
                return {"tree": {"sha": "tree-sha"}}
            if path.endswith("/git/commits"):
                return {"sha": "lease-owned"}
            if path.endswith("/git/refs"):
                if collision:
                    raise team.Stop("existing lease")
                return {"ref": team.LEASE}
            if path.endswith("/git/ref/" + team.LEASE):
                return {"object": {"sha": lease_owner}}
            if "pulls?state=open" in path:
                return []
            if "labels=in-progress" in path:
                return legacy_tasks or []
            if "issues?state=open" in path:
                return candidates or []
            self.fail(f"unexpected API: {path}")
        return execute, endpoint, calls

    def test_lease_collision_and_running_worker_prevent_work(self):
        for options in ({"active": True}, {"collision": True}):
            execute, endpoint, calls = self.cycle_fixture(**options)
            with patch.object(team, "run", side_effect=execute), patch.object(team, "api", side_effect=endpoint), \
                    patch.object(team, "attempt") as attempt, patch.object(team, "gh") as gh:
                with self.assertRaises(team.Stop):
                    team.cycle(self.state)
                attempt.assert_not_called()
                gh.assert_not_called()
            self.assertFalse(any("pulls?state=open" in path for path, _ in calls))

    def test_cycle_releases_only_its_own_lease(self):
        for owner in ("lease-owned", "someone-elses-lease"):
            execute, endpoint, _ = self.cycle_fixture(lease_owner=owner)
            with patch.object(team, "run", side_effect=execute), patch.object(team, "api", side_effect=endpoint), \
                    patch.object(team, "gh") as gh:
                team.cycle(self.state)
            if owner == "lease-owned":
                gh.assert_called_once_with("api", f"repos/{team.REPO}/git/refs/{team.LEASE}", "-X", "DELETE")
            else:
                gh.assert_not_called()

    def test_cycle_caps_work_at_two_issues_and_staggers(self):
        candidates = [issue(n) for n in (44, 43, 42)]
        execute, endpoint, _ = self.cycle_fixture(candidates=candidates)
        with patch.object(team, "run", side_effect=execute), patch.object(team, "api", side_effect=endpoint), \
                patch.object(team, "attempt") as attempt, patch.object(team, "gh"), \
                patch.object(team.time, "sleep") as sleep:
            team.cycle(self.state)
        self.assertEqual([call.args[1]["number"] for call in attempt.call_args_list], [42, 43])
        sleep.assert_called_once_with(300)

    def test_controller_entrypoint_rejects_state_file_symlink(self):
        outside = self.state / "do-not-truncate"
        outside.write_text("original")
        (self.state / "controller.lock").symlink_to(outside)
        with patch.object(sys, "argv", ["team.py", "canary", "--state", str(self.state)]), \
                patch.object(team, "model") as model:
            with self.assertRaises(team.Stop):
                team.main()
            model.assert_not_called()
        self.assertEqual(outside.read_text(), "original")

    def test_legacy_cloud_issue_blocks_after_actions_complete(self):
        legacy = issue(7, "claude")
        legacy["labels"] = [{"name": "in-progress"}, {"name": "model:codex"}, {"name": "agent:installer-engineer"}]
        execute, endpoint, calls = self.cycle_fixture(legacy_tasks=[legacy])
        with patch.object(team, "run", side_effect=execute), patch.object(team, "api", side_effect=endpoint), \
                patch.object(team, "attempt") as attempt, patch.object(team, "gh") as gh:
            with self.assertRaisesRegex(team.Stop, "legacy cloud agent"):
                team.cycle(self.state)
            attempt.assert_not_called()
            gh.assert_not_called()
        self.assertFalse(any(path.endswith("/git/refs") for path, _ in calls))

    def test_only_journaled_published_tasks_are_exempt_from_legacy_drain(self):
        task = issue(7)
        task["labels"] = [{"name": "in-progress"}, {"name": "model:gemini"}, {"name": "agent:docs-writer"}]
        team.audit(self.state, "attempt-start", issue=7)
        with patch.object(team, "api", side_effect=lambda path: {"total_count": 0} if "runs?" in path else [task]):
            with self.assertRaises(team.Stop):
                team.workers_drained(self.state)
            team.audit(self.state, "pr-opened", issue=7, pr=10, head="fixture")
            team.workers_drained(self.state)

    def test_legacy_issue_listing_paginates_and_fails_closed_at_budget(self):
        non_agents = [{"number": n, "labels": [{"name": "in-progress"}]} for n in range(100)]
        legacy = {"number": 201, "labels": [{"name": "model:codex"}]}
        calls = []

        def endpoint(path):
            calls.append(path)
            if "runs?" in path:
                return {"total_count": 0}
            return non_agents if "&page=1" in path else [legacy]
        with patch.object(team, "api", side_effect=endpoint), self.assertRaisesRegex(team.Stop, "legacy cloud"):
            team.workers_drained(self.state)
        self.assertTrue(any("page=2" in path for path in calls))
        with patch.object(team, "api", side_effect=lambda path: {"total_count": 0} if "runs?" in path else non_agents):
            with self.assertRaisesRegex(team.Stop, "evidence budget"):
                team.workers_drained(self.state)

    def test_daily_attempt_budget_survives_retry_snapshot_reset(self):
        for number in range(1, 5):
            with patch.object(team, "api", side_effect=[[{"ref": "exists"}], []]), self.assertRaises(team.Stop):
                team.attempt(self.state, issue(number), {})
        self.assertEqual(team.reserved_attempts(self.state)[0], 4)
        with patch.object(team, "api") as api, patch.object(team, "model") as model:
            with self.assertRaisesRegex(team.Stop, "daily task attempt budget"):
                team.attempt(self.state, issue(5), {})
            api.assert_not_called()
            model.assert_not_called()

    def test_journaled_issue_retry_limit_survives_snapshot_reset(self):
        for _ in range(2):
            with patch.object(team, "api", side_effect=[[{"ref": "exists"}], []]), self.assertRaises(team.Stop):
                team.attempt(self.state, issue(), {})
        with patch.object(team, "api") as api:
            team.attempt(self.state, issue(), {})
            api.assert_not_called()
        self.assertEqual(team.reserved_attempts(self.state)[1], {"42": 2})

    def test_cycle_with_exhausted_daily_budget_still_checks_merges_but_spawns_nothing(self):
        for number in range(4):
            team.audit(self.state, "attempt-reserved", issue=number, attempt=1)
        execute, endpoint, _ = self.cycle_fixture(candidates=[issue()])
        with patch.object(team, "run", side_effect=execute), patch.object(team, "api", side_effect=endpoint), \
                patch.object(team, "attempt") as attempt, patch.object(team, "gh"):
            team.cycle(self.state)
            attempt.assert_not_called()

    def test_daily_budget_uses_utc_day_without_resetting_issue_retries(self):
        yesterday = team.time.struct_time((2026, 10, 28, 23, 59, 0, 2, 301, 0))
        today = team.time.struct_time((2026, 10, 29, 0, 1, 0, 3, 302, 0))
        with patch.object(team.time, "gmtime", return_value=yesterday):
            team.audit(self.state, "attempt-reserved", issue=42, attempt=1)
            self.assertEqual(team.reserved_attempts(self.state), (1, {"42": 1}))
        with patch.object(team.time, "gmtime", return_value=today):
            self.assertEqual(team.reserved_attempts(self.state), (0, {"42": 1}))

    def test_snapshot_write_failure_still_consumes_reserved_budget(self):
        original_open = Path.open

        def interrupted_open(path, *args, **kwargs):
            if path.name == "attempts.next":
                raise OSError("interrupted snapshot")
            return original_open(path, *args, **kwargs)
        with patch.object(Path, "open", interrupted_open), patch.object(team, "api") as api:
            with self.assertRaises(OSError):
                team.attempt(self.state, issue(), {})
            api.assert_not_called()
        self.assertEqual(team.reserved_attempts(self.state), (1, {"42": 1}))

    def test_new_worker_during_stagger_prevents_second_task(self):
        execute, endpoint, _ = self.cycle_fixture(candidates=[issue(42), issue(43)])
        with patch.object(team, "run", side_effect=execute), patch.object(team, "api", side_effect=endpoint), \
                patch.object(team, "attempt") as attempt, patch.object(team, "gh") as gh, \
                patch.object(team.time, "sleep"), patch.object(team, "workers_drained", side_effect=[
                    None, None, team.Stop("legacy worker started")]):
            with self.assertRaisesRegex(team.Stop, "legacy worker started"):
                team.cycle(self.state)
        self.assertEqual([call.args[1]["number"] for call in attempt.call_args_list], [42])
        gh.assert_called_once_with("api", f"repos/{team.REPO}/git/refs/{team.LEASE}", "-X", "DELETE")

    def test_oversized_context_file_is_rejected_before_reading(self):
        checkout = self.state / "checkout"
        (checkout / "docs/user").mkdir(parents=True)
        (checkout / "docs/user/guide.md").write_text("a" * 32001)
        with patch.object(team, "run", return_value="docs/user/guide.md\n"), patch.object(Path, "read_text") as read:
            with self.assertRaisesRegex(team.Stop, "context budget"):
                team.documents(checkout)
            read.assert_not_called()

    def test_incomplete_paginated_or_duplicate_switch_evidence_holds(self):
        for evidence in ({"total_count": 101, "variables": enabled_variables()["variables"]},
                         {"total_count": 3, "variables": enabled_variables()["variables"]},
                         {"total_count": 2, "variables": [{"name": "AUTOPILOT", "value": "on"}] * 2},
                         {"variables": []}, []):
            with self.subTest(evidence=evidence), patch.object(team, "api", return_value=evidence):
                with self.assertRaises(team.Stop):
                    team.controller_enabled()

    def test_each_live_switch_is_required(self):
        for index in (0, 1):
            data = enabled_variables()
            data["variables"][index]["value"] = "disabled"
            with self.subTest(index=index), patch.object(team, "api", return_value=data):
                with self.assertRaises(team.Disabled):
                    team.controller_enabled()

    def test_disabled_attempt_exits_without_issue_relabeling(self):
        execute, endpoint, _ = self.cycle_fixture(candidates=[issue()])
        with patch.object(team, "run", side_effect=execute), patch.object(team, "api", side_effect=endpoint), \
                patch.object(team, "attempt", side_effect=team.Disabled("owner stopped controller")), \
                patch.object(team, "gh") as gh:
            with self.assertRaises(team.Disabled):
                team.cycle(self.state)
        gh.assert_called_once_with("api", f"repos/{team.REPO}/git/refs/{team.LEASE}", "-X", "DELETE")
        self.assertEqual(team.audit_rows(self.state)[-1]["event"], "attempt-disabled")

    def test_kill_switch_changed_during_models_prevents_push_or_pr(self):
        self.publication_switch_fixture(before_push=True)

    def test_kill_switch_changed_after_push_preserves_branch_without_pr(self):
        self.publication_switch_fixture(before_push=False)

    def publication_switch_fixture(self, *, before_push):
        commands = []
        api_calls = []
        checks = []
        candidate = issue()

        def execute(args, **kwargs):
            commands.append(args)
            if args[:2] == ["git", "clone"]:
                Path(args[-1]).mkdir()
            return "base-sha"

        def endpoint(path, *args):
            api_calls.append(path)
            if "matching-refs" in path or "pulls?state=all" in path:
                return []
            if path.endswith("/issues/42"):
                return copy.deepcopy(candidate)
            if path.endswith("/git/ref/heads/main"):
                return {"object": {"sha": "base-sha"}}
            if "actions/variables" in path:
                checks.append(True)
                data = enabled_variables()
                if before_push or len(checks) == 2:
                    data["variables"][0]["value"] = "off"
                return data
            self.fail(f"unexpected publication: {path}")

        with patch.object(team, "api", side_effect=endpoint), patch.object(team, "run", side_effect=execute), \
                patch.object(team, "documents", return_value={}), patch.object(team, "apply"), \
                patch.object(team, "model", side_effect=[
                    {"files": [{"path": "docs/user/guide.md", "content": "retained warning"}]},
                    {"verdict": "pass", "findings": []}]):
            with self.assertRaises(team.Disabled):
                team.attempt(self.state, candidate, {})
        self.assertEqual(sum(args[:2] == ["git", "push"] for args in commands), 0 if before_push else 1)
        self.assertFalse(any(path.endswith("/pulls") for path in api_calls))
        self.assertTrue(list(self.state.glob("issue-42-*")))
        events = [row["event"] for row in team.audit_rows(self.state)]
        self.assertEqual("branch-published" in events, not before_push)


if __name__ == "__main__":
    unittest.main()
