#!/usr/bin/env python3
"""Tests for tools/source_state.py and the release source check in
tools/verify-release.py: a release is never labeled with a commit that does
not hold its sources.

Run: python3 -I tools/test_source_state.py
"""
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


source_state = load("source_state", "tools/source_state.py")
verify_release = load("verify_release", "tools/verify-release.py")


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True,
                          capture_output=True, text=True).stdout.strip()


class SourceStateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "test@example.invalid")
        git(self.repo, "config", "user.name", "test")
        Path(self.repo, ".gitignore").write_text("target/\n")
        Path(self.repo, "a.rs").write_text("fn a() {}\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "-m", "init")
        self.sha = git(self.repo, "rev-parse", "HEAD")

    def tearDown(self):
        self.tmp.cleanup()

    def label(self, allow_dirty):
        return source_state.source_label(self.repo, allow_dirty)[0]

    def test_clean_checkout_is_labeled_with_its_commit(self):
        # Ignored build output is never staged, so it does not matter.
        Path(self.repo, "target").mkdir()
        Path(self.repo, "target", "out").write_text("x")
        self.assertEqual(self.label(False), self.sha)
        self.assertEqual(self.label(True), self.sha)

    def test_modified_tracked_file_blocks_a_release(self):
        Path(self.repo, "a.rs").write_text("fn a() { evil() }\n")
        self.assertIsNone(self.label(False))
        self.assertEqual(self.label(True), self.sha + "-dirty")

    def test_untracked_file_blocks_a_release(self):
        # The build scripts stage unignored untracked files too.
        Path(self.repo, "new").mkdir()
        Path(self.repo, "new", "b.rs").write_text("fn b() {}\n")
        self.assertIsNone(self.label(False))
        self.assertEqual(self.label(True), self.sha + "-dirty")

    def test_staged_change_blocks_a_release(self):
        Path(self.repo, "a.rs").write_text("fn a2() {}\n")
        git(self.repo, "add", "a.rs")
        self.assertIsNone(self.label(False))

    def test_cli_exit_codes(self):
        self.assertEqual(source_state.main([self.repo]), 0)
        Path(self.repo, "c.rs").write_text("")
        self.assertEqual(source_state.main([self.repo]), 1)
        self.assertEqual(source_state.main([self.repo, "--allow-dirty"]), 0)
        with tempfile.TemporaryDirectory() as not_git:
            self.assertEqual(source_state.main([not_git]), 2)


class ReleaseSourceCheckTest(unittest.TestCase):
    SHA = "a3b42dfb9" + "0" * 31

    def failures(self, commit, release):
        c = verify_release.Checker()
        verify_release.check_source_commit(c, commit, release)
        return c.failed

    def test_release_needs_a_clean_full_commit(self):
        self.assertEqual(self.failures(self.SHA, release=True), 0)
        self.assertGreater(self.failures(self.SHA + "-dirty", release=True), 0)
        self.assertGreater(self.failures(None, release=True), 0)
        self.assertGreater(self.failures("a3b42dfb9", release=True), 0)

    def test_test_build_may_be_dirty(self):
        self.assertEqual(self.failures(self.SHA + "-dirty", release=False), 0)
        self.assertEqual(self.failures(None, release=False), 0)


if __name__ == "__main__":
    unittest.main()
