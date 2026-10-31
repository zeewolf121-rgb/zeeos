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
                        GITHUB_RUN_ID="33", GITHUB_RUN_ATTEMPT="2", REVIEW_OUTCOME="success",
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


if __name__ == "__main__":
    unittest.main()
