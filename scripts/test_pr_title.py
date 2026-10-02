#!/usr/bin/env python3
"""Offline, standard-library-only tests; run with python3 scripts/test_pr_title.py."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


VALIDATOR = Path(__file__).with_name("check-pr-title.py")


class PRTitleTest(unittest.TestCase):
    def run_validator(self, event):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "event.json"
            path.write_text(json.dumps(event), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(VALIDATOR), str(path)],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_valid_titles(self):
        titles = [
            "fix: handle errors",
            "feat(core): add cancellation",
            "feat!: change API",
            "feat(core)!: change API",
            "docs: explain setup",
            "custom(integrations/codex): update behavior",
            "fix(deps): allow core 0.7 in CLI adapters and Ensemble",
            "chore(main): release 0.6.2",
            "chore(main): release gen_agent_claude 0.2.2",
            "chore(main): release gen_agent_codex 0.4.2",
            "chore(main): release gen_agent_ensemble 0.5.0",
            "fix: handle `quotes`, $(shell syntax), and café safely",
        ]
        for title in titles:
            with self.subTest(title=title):
                result = self.run_validator({"pull_request": {"title": title}})
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_titles_have_actionable_feedback(self):
        titles = [
            "Handle errors", "", ": description", "(core): description",
            "fix(): description", "fix(  ): description",
            "fix(core: description", "fix(core)): description",
            "fix((core)): description", "fix:description", "fix:\tdescription",
            "fix : description", "fix(core) : description",
            "fix!(core): description", "fix!!: description",
            "fix(core)!!: description", "fix: ", "fix:   \t",
            "fix: description\nmore", "fix: description\n",
            "fix: description\rmore", "fix: description\u2028more",
            "fix(co\nre): description", " fix: description",
            "123: description", None, 42,
        ]
        for title in titles:
            with self.subTest(title=title):
                result = self.run_validator({"pull_request": {"title": title}})
                self.assertEqual(result.returncode, 1)
                self.assertIn("Rename the PR using `type(scope)!: description`", result.stderr)
                self.assertIn("fix(codex): handle empty responses", result.stderr)
                self.assertIn("then rerun the check", result.stderr)

    def test_missing_title_fails_closed(self):
        for event in [{}, {"pull_request": {}}, {"pull_request": None}]:
            with self.subTest(event=event):
                result = self.run_validator(event)
                self.assertEqual(result.returncode, 1)
                self.assertIn("Could not read pull_request.title", result.stderr)


if __name__ == "__main__":
    unittest.main()
