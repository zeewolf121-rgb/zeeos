#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Execute the real trusted workflow steps with offline GitHub responses."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/agent-dispatch.yml"
HEAD = "a" * 40


def step_lines(name):
    lines = WORKFLOW.read_text().splitlines()
    start = lines.index("      - name: " + name)
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("      - ")), len(lines))
    return lines[start:end]


def step_script(name):
    lines = step_lines(name)
    run = lines.index("        run: |")
    block = []
    for line in lines[run + 1:]:
        if line and not line.startswith("          "):
            break
        block.append(line[10:])
    return "\n".join(block) + "\n"


class ReceiptWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        binary = self.root / "bin"
        binary.mkdir()
        gh = binary / "gh"
        gh.write_text('#!/bin/bash\nset -eu\n'
                      'if [[ "$1 $2" == "pr view" ]]; then echo "$CURRENT_HEAD"; '
                      'elif [[ "$1 $2" == "pr comment" ]]; then cat >"$COMMENT"; '
                      'else exit 97; fi\n')
        gh.chmod(0o755)
        self.env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                        SHA=HEAD, CURRENT_HEAD=HEAD, PR="7", GITHUB_REPOSITORY="o/r",
                        GITHUB_RUN_ID="33", GITHUB_RUN_ATTEMPT="2", REVIEW_OUTCOME="success", INPUT_OUTCOME="success",
                        RUNNER_TEMP=str(self.root), GITHUB_OUTPUT=str(self.root / "output"),
                        COMMENT=str(self.root / "comment"), RECEIPT_OUTCOME="success")
        (self.root / "claude-review.md").write_text("verdict: pass\nNo blocking findings.\n")

    def execute(self, name):
        subprocess.run(["bash", "-eo", "pipefail", "-c", step_script(name)],
                       cwd=self.root, env=self.env, check=True, capture_output=True)

    def prepare(self):
        (self.root / "output").write_text("")
        self.execute("Prepare trusted review receipt")
        self.env["VERDICT"] = (self.root / "output").read_text().strip().split("=", 1)[1]

    def post(self):
        self.execute("Post the verdict marker (cross-review reads it)")
        return (self.root / "comment").read_text().splitlines()[0]

    def test_success_records_fixed_metadata_before_pass_marker(self):
        self.prepare()
        self.assertEqual((self.root / "claude-review-receipt.txt").read_text(),
                         f"pr=7\nsha={HEAD}\nrun=33\nattempt=2\nverdict=pass\n")
        self.assertEqual(self.post(), f"<!-- claude-review sha={HEAD} verdict=pass run=33 attempt=2 -->")

    def test_artifact_uploader_contract_binds_trusted_metadata(self):
        # These values form the trust boundary between the executed shell and
        # policy.py's REST evidence. Model-written text must not choose them.
        lines = {line.strip() for line in step_lines("Store immutable PR/head/attempt review receipt")}
        self.assertIn("if: steps.verdict.outputs.verdict == 'pass'", lines)
        self.assertIn("uses: actions/upload-artifact@v4", lines)
        self.assertIn("name: claude-review-v1-pr-${{ inputs.pr }}-sha-${{ steps.pr.outputs.sha }}-run-${{ github.run_id }}-attempt-${{ github.run_attempt }}-pass", lines)
        self.assertIn("path: ${{ runner.temp }}/claude-review-receipt.txt", lines)
        self.assertIn("if-no-files-found: error", lines)

    def test_failed_or_unfinished_action_cannot_create_receipt(self):
        for outcome in ("failure", "cancelled", "skipped", ""):
            with self.subTest(outcome=outcome):
                self.env["REVIEW_OUTCOME"] = outcome
                self.prepare()
                self.assertEqual(self.env["VERDICT"], "error")
                self.assertFalse((self.root / "claude-review-receipt.txt").exists())

    def test_missing_malformed_or_failed_verdict_has_no_receipt(self):
        for text in (None, "verdict: fail\nBlocking finding.\n", "summary\nverdict: pass\n", "verdict: pass extra\n"):
            with self.subTest(text=text):
                file = self.root / "claude-review.md"
                if text is None:
                    file.unlink(missing_ok=True)
                else:
                    file.write_text(text)
                self.prepare()
                self.assertNotEqual(self.env["VERDICT"], "pass")
                self.assertFalse((self.root / "claude-review-receipt.txt").exists())

    def test_failed_or_unfinished_input_cannot_create_receipt(self):
        for outcome in ("failure", "cancelled", "skipped", ""):
            with self.subTest(outcome=outcome):
                self.env["INPUT_OUTCOME"] = outcome
                self.prepare()
                self.assertEqual(self.env["VERDICT"], "error")
                self.assertFalse((self.root / "claude-review-receipt.txt").exists())

    def test_head_change_before_receipt_blocks(self):
        self.env["CURRENT_HEAD"] = "b" * 40
        self.prepare()
        self.assertEqual(self.env["VERDICT"], "error")
        self.assertFalse((self.root / "claude-review-receipt.txt").exists())

    def test_head_change_after_upload_blocks_pass_marker(self):
        self.prepare()
        self.env["CURRENT_HEAD"] = "b" * 40
        self.assertIn("verdict=error", self.post())

    def test_upload_failure_or_skip_blocks_pass_marker(self):
        self.prepare()
        for outcome in ("failure", "cancelled", "skipped", ""):
            with self.subTest(outcome=outcome):
                self.env["RECEIPT_OUTCOME"] = outcome
                self.assertIn("verdict=error", self.post())

    def test_summary_cannot_change_receipt_metadata(self):
        (self.root / "claude-review.md").write_text("verdict: pass\npr=99\nsha=attacker\nrun=42\n")
        self.prepare()
        receipt = (self.root / "claude-review-receipt.txt").read_text()
        self.assertIn("pr=7\n", receipt)
        self.assertNotIn("attacker", receipt)


class CompleteDiffWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, PR="7", GITHUB_REPOSITORY="o/r", RUNNER_TEMP=str(self.root),
                        GITHUB_OUTPUT=str(self.root / "output"), HEAD_COUNT=str(self.root / "head-count"))
        self.git("init", "--quiet")
        (self.root / "guide.txt").write_text("Existing data-loss warning.\n")
        self.commit("base")
        self.base = self.git("rev-parse", "HEAD").strip()
        (self.root / "guide.txt").write_text("Existing data-loss warning.\nNew instructions.\n")
        self.commit("head")
        self.head = self.git("rev-parse", "HEAD").strip()
        self.git("remote", "add", "origin", str(self.root))
        self.env.update(BASE=self.base, INITIAL_HEAD=self.head, CURRENT_HEAD=self.head)
        binary = self.root / "bin"
        binary.mkdir()
        gh = binary / "gh"
        gh.write_text('#!/bin/bash\nset -eu\n'
                      '[[ "$1 $2" == "pr view" ]] || exit 97\n'
                      'if [[ "$*" == *baseRefOid* ]]; then echo "$BASE"; '
                      'elif [[ ! -f "$HEAD_COUNT" ]]; then touch "$HEAD_COUNT"; echo "$INITIAL_HEAD"; '
                      'else echo "$CURRENT_HEAD"; fi\n')
        gh.chmod(0o755)
        self.env["PATH"] = str(binary) + os.pathsep + os.environ["PATH"]
        gate = self.root / "scripts/autopilot/gates.sh"
        gate.parent.mkdir(parents=True)
        gate.write_text('#!/bin/bash\n[[ "$1" == review-model ]] || exit 98\necho test-model\n')
        gate.chmod(0o755)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, env=self.env, check=True,
                              capture_output=True, text=True).stdout

    def commit(self, message):
        self.git("add", "--all")
        self.git("-c", "user.name=Offline test", "-c", "user.email=test@example.invalid",
                 "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", message)

    def prepare(self, success):
        result = subprocess.run(["bash", "-eo", "pipefail", "-c",
                                 step_script("Prepare complete immutable review diff")],
                                cwd=self.root, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        output = self.root / "output"
        if success:
            self.assertEqual(output.read_text(), f"sha={self.head}\nllm=test-model\n")
        else:
            self.assertFalse(output.exists(), "Failed input must not authorize a review head")
        return result

    def test_complete_diff_uses_merge_base_and_never_checks_out_pr(self):
        # Advance base independently: its unrelated change must not appear in the PR diff.
        self.git("checkout", "--quiet", self.base)
        (self.root / "base-only.txt").write_text("Unrelated main change.\n")
        self.commit("base advanced")
        self.env["BASE"] = self.git("rev-parse", "HEAD").strip()
        before = self.git("rev-parse", "HEAD")
        self.prepare(True)
        expected = self.git("-c", "core.quotePath=true", "diff", "--no-ext-diff", "--no-textconv",
                            "--no-renames", "--ignore-submodules=none", "--binary", "--full-index",
                            self.base, self.head)
        self.assertEqual((self.root / "review.diff").read_text(), expected)
        self.assertNotIn("base-only.txt", expected)
        self.assertEqual(self.git("rev-parse", "HEAD"), before)

    def test_more_than_300_files_fails_without_partial_diff(self):
        # Commit only fixture files; shell mocks stay untracked.
        for number in range(300):
            (self.root / f"file-{number}.txt").write_text("New content.\n")
        self.git("add", "--", "guide.txt", *[f"file-{number}.txt" for number in range(300)])
        self.git("-c", "user.name=Offline test", "-c", "user.email=test@example.invalid",
                 "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "large file count")
        self.head = self.git("rev-parse", "HEAD").strip()
        self.env.update(INITIAL_HEAD=self.head, CURRENT_HEAD=self.head)
        self.prepare(False)
        self.assertFalse((self.root / "review.diff").exists())

    def test_oversize_diff_fails_instead_of_truncating(self):
        (self.root / "guide.txt").write_text("New large line " + "x" * 1048576 + "\n")
        self.git("add", "guide.txt")
        self.git("-c", "user.name=Offline test", "-c", "user.email=test@example.invalid",
                 "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "large diff")
        self.head = self.git("rev-parse", "HEAD").strip()
        self.env.update(INITIAL_HEAD=self.head, CURRENT_HEAD=self.head)
        self.prepare(False)
        self.assertGreater((self.root / "review.diff").stat().st_size, 1048576)

    def test_malformed_head_and_missing_commit_fail_closed(self):
        for head in ("bad\nsha=attacker", "c" * 40):
            with self.subTest(head=head):
                (self.root / "head-count").unlink(missing_ok=True)
                self.env["INITIAL_HEAD"] = head
                self.prepare(False)

    def test_head_change_during_preparation_fails_closed(self):
        self.env["CURRENT_HEAD"] = self.base
        self.prepare(False)

    def test_empty_diff_fails_closed(self):
        self.env.update(INITIAL_HEAD=self.base, CURRENT_HEAD=self.base)
        self.prepare(False)

    def test_malformed_base_fails_before_fetch(self):
        self.env["BASE"] = "bad\nllm=attacker"
        self.prepare(False)

    def test_incomplete_shallow_history_fails_closed(self):
        (self.root / ".git/shallow").write_text(self.base + "\n")
        self.prepare(False)

    def test_multiple_merge_bases_fail_closed(self):
        # A criss-cross graph has two equally valid merge bases. Never select one silently.
        tree = self.git("rev-parse", "HEAD^{tree}").strip()

        def node(message, parents):
            flags = ["-p", parents[0]]
            for parent in parents[1:]:
                flags.extend(["-p", parent])
            return self.git("-c", "user.name=Offline test", "-c", "user.email=test@example.invalid",
                            "commit-tree", tree, *flags, "-m", message).strip()

        left = node("left", [self.base])
        right = node("right", [self.base])
        one = node("one", [left, right])
        two = node("two", [right, left])
        self.env.update(BASE=one, INITIAL_HEAD=two, CURRENT_HEAD=two)
        self.prepare(False)

    def test_binary_diff_contains_full_data(self):
        (self.root / "guide.txt").write_bytes(bytes(range(256)) * 4)
        self.git("add", "guide.txt")
        self.git("-c", "user.name=Offline test", "-c", "user.email=test@example.invalid",
                 "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "binary diff")
        self.head = self.git("rev-parse", "HEAD").strip()
        self.env.update(INITIAL_HEAD=self.head, CURRENT_HEAD=self.head)
        self.prepare(True)
        self.assertIn("GIT binary patch", (self.root / "review.diff").read_text())


if __name__ == "__main__":
    unittest.main()
