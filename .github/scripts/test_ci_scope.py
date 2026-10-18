import json
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from ci_gate import EXPENSIVE, validate
from ci_scope import classify, git, main


class ScopeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.name", "CI Test")
        git(self.repo, "config", "user.email", "ci@example.invalid")
        self.write("doc/guide.md", "original\n")
        self.write("lib/code.dart", "original\n")
        self.base = self.commit()

    def write(self, path, content="changed\n"):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)

    def commit(self):
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "fixture", "--allow-empty")
        return git(self.repo, "rev-parse", "HEAD").decode().strip()

    def scope(self, base=None, head=None, event="pull_request"):
        return classify(self.repo, event, base or self.base, head or self.commit())

    def test_ordinary_doc_modify_add_delete_and_rename(self):
        self.write("doc/guide.md")
        self.assertEqual(self.scope(), "docs")
        self.write("doc/nested/new.md")
        self.assertEqual(self.scope(), "docs")
        git(self.repo, "mv", "doc/guide.md", "doc/renamed.md")
        self.assertEqual(self.scope(), "docs")
        (self.repo / "doc/renamed.md").unlink()
        self.assertEqual(self.scope(), "docs")

    def test_doc_deletion(self):
        (self.repo / "doc/guide.md").unlink()
        self.assertEqual(self.scope(), "docs")

    def test_all_other_paths_are_full(self):
        for path in ("README.md", "CHANGELOG.md", "AGENTS.md", "native/readme.md",
                     "docs/readme.md", "doc/guide.MD", "doc/code.py", "doc.md",
                     "test/new.dart", "tool/check.dart", "pubspec.yaml",
                     ".github/workflows/ci.yml", ".github/scripts/ci_scope.py"):
            with self.subTest(path=path):
                git(self.repo, "reset", "--hard", self.base)
                self.write(path)
                self.assertEqual(self.scope(), "full")

    def test_mixed_paths(self):
        self.write("doc/guide.md")
        self.write("lib/code.dart")
        self.assertEqual(self.scope(), "full")

    def test_complete_range_includes_earlier_source_commit(self):
        self.write("lib/code.dart")
        self.commit()
        self.write("doc/guide.md")
        self.assertEqual(self.scope(), "full")

    def test_target_only_changes_are_not_pr_changes(self):
        git(self.repo, "checkout", "-qb", "target")
        self.write("lib/code.dart")
        target = self.commit()
        git(self.repo, "checkout", "-qb", "pr", self.base)
        self.write("doc/guide.md")
        self.assertEqual(self.scope(base=target), "docs")

    def test_uses_pr_head_not_checkout_merge(self):
        self.write("doc/guide.md")
        head = self.commit()
        git(self.repo, "checkout", "-qb", "target", self.base)
        self.write("lib/code.dart")
        base = self.commit()
        git(self.repo, "merge", "--no-ff", "-m", "synthetic merge", head)
        self.assertEqual(self.scope(base=base, head=head), "docs")

    def test_rename_into_doc_from_non_doc(self):
        git(self.repo, "mv", "lib/code.dart", "doc/code.md")
        self.assertEqual(self.scope(), "full")

    def test_rename_out_of_doc(self):
        git(self.repo, "mv", "doc/guide.md", "README.md")
        self.assertEqual(self.scope(), "full")

    def test_executable_change(self):
        (self.repo / "doc/guide.md").chmod(0o755)
        self.assertEqual(self.scope(), "full")

    def test_new_executable_doc(self):
        self.write("doc/run.md")
        (self.repo / "doc/run.md").chmod(0o755)
        self.assertEqual(self.scope(), "full")

    def test_executable_content_change_and_deletion(self):
        (self.repo / "doc/guide.md").chmod(0o755)
        base = self.commit()
        self.write("doc/guide.md")
        self.assertEqual(self.scope(base=base), "full")
        (self.repo / "doc/guide.md").unlink()
        self.assertEqual(self.scope(base=base), "full")

    def test_symlink_add_and_type_change(self):
        (self.repo / "doc/link.md").symlink_to("guide.md")
        self.assertEqual(self.scope(), "full")
        git(self.repo, "reset", "--hard", self.base)
        (self.repo / "doc/guide.md").unlink()
        (self.repo / "doc/guide.md").symlink_to("../lib/code.dart")
        self.assertEqual(self.scope(), "full")

    def test_push_and_unknown_events_always_full(self):
        self.write("doc/guide.md")
        head = self.commit()
        for event in ("push", "workflow_dispatch", "pull_request_target", ""):
            self.assertEqual(self.scope(head=head, event=event), "full")

    def test_missing_or_malformed_commits_and_empty_changes(self):
        for base in (None, "", "bad", "0" * 40, "--help", self.base):
            self.assertEqual(classify(self.repo, "pull_request", base, self.base), "full")
        self.assertEqual(classify(self.repo, "pull_request", self.base, None), "full")
        blob = git(self.repo, "rev-parse", "HEAD:doc/guide.md").decode().strip()
        self.assertEqual(classify(self.repo, "pull_request", blob, self.base), "full")

    def test_git_failure(self):
        self.assertEqual(classify(self.repo / "missing", "pull_request",
                                  self.base, self.base), "full")

    def test_shallow_history(self):
        self.write("doc/guide.md")
        head = self.commit()
        shallow = Path(self.temp.name) / "shallow"
        git(self.repo, "clone", "--depth=1", self.repo.as_uri(), str(shallow))
        self.assertEqual(classify(shallow, "pull_request", self.base, head), "full")

    def test_unrelated_histories(self):
        git(self.repo, "checkout", "--orphan", "unrelated")
        self.write("doc/guide.md")
        self.assertEqual(self.scope(), "full")

    def test_ambiguous_merge_bases(self):
        tree = git(self.repo, "rev-parse", "HEAD^{tree}").decode().strip()
        def commit_tree(message, parents):
            args = ["commit-tree", tree, "-m", message]
            for parent in parents:
                args.extend(["-p", parent])
            return git(self.repo, *args).decode().strip()
        left = commit_tree("left", [self.base])
        right = commit_tree("right", [self.base])
        base = commit_tree("base merge", [left, right])
        head = commit_tree("head merge", [right, left])
        self.assertEqual(len(git(self.repo, "merge-base", "--all", base, head).splitlines()), 2)
        self.assertEqual(classify(self.repo, "pull_request", base, head), "full")

    def test_unusual_path_names_are_not_line_parsed(self):
        self.write("doc/space and\nnewline.md")
        self.assertEqual(self.scope(), "docs")
        self.write("source\n/doc/fake.md")
        self.assertEqual(self.scope(), "full")

    def test_cli_outputs_docs_for_pr_and_full_for_push(self):
        self.write("doc/guide.md")
        head = self.commit()
        event = Path(self.temp.name) / "event.json"
        event.write_text(json.dumps({"pull_request": {
            "base": {"sha": self.base}, "head": {"sha": head},
        }}))
        output = Path(self.temp.name) / "output"
        for name, expected in (("pull_request", "docs"), ("push", "full")):
            output.write_text("")
            subprocess.run(
                [sys.executable, str(Path(__file__).with_name("ci_scope.py").resolve())],
                cwd=self.repo, check=True, capture_output=True,
                env={**os.environ, "GITHUB_EVENT_NAME": name,
                     "GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output)},
            )
            self.assertEqual(output.read_text(), f"scope={expected}\n")

    def test_bad_event_payload_falls_back(self):
        event = Path(self.temp.name) / "event.json"
        output = Path(self.temp.name) / "output"
        for payload in ("not json", "{}", '{"pull_request": null}'):
            event.write_text(payload)
            output.write_text("")
            with patch.dict(os.environ, {"GITHUB_EVENT_NAME": "pull_request",
                            "GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output)}):
                main()
            self.assertEqual(output.read_text(), "scope=full\n")


class GateTests(unittest.TestCase):
    def results(self, scope):
        return {"scope": {"result": "success", "outputs": {"scope": scope}},
                "static": {"result": "success"},
                **{name: {"result": "skipped" if scope == "docs" else "success"}
                   for name in EXPENSIVE}}

    def test_positive_full_and_docs(self):
        validate(self.results("full"), "push")
        validate(self.results("full"), "pull_request")
        validate(self.results("docs"), "pull_request")

    def test_push_can_never_skip(self):
        with self.assertRaises(ValueError):
            validate(self.results("docs"), "push")

    def test_every_job_failure_cancellation_and_unexpected_skip(self):
        for scope in ("docs", "full"):
            for job in self.results(scope):
                for outcome in ("failure", "cancelled", "", "skipped", "success", None):
                    results = self.results(scope)
                    if results[job]["result"] == outcome:
                        continue
                    results[job]["result"] = outcome
                    with self.subTest(scope=scope, job=job, outcome=outcome):
                        with self.assertRaises(ValueError):
                            validate(results, "pull_request")

    def test_missing_jobs_and_output(self):
        for name in self.results("full"):
            results = self.results("full")
            del results[name]
            with self.assertRaises(ValueError):
                validate(results, "pull_request")
        for scope in (None, "", "unknown", "DOCS"):
            with self.assertRaises(ValueError):
                validate(self.results(scope), "pull_request")
        results = self.results("full")
        del results["scope"]["outputs"]
        with self.assertRaises(ValueError):
            validate(results, "pull_request")
        results = self.results("full")
        results["unexpected"] = {"result": "success"}
        with self.assertRaises(ValueError):
            validate(results, "pull_request")


if __name__ == "__main__":
    unittest.main()
