#!/usr/bin/env python3
"""Cases for session-store.py: a fake home with a profile config dir whose
`projects` links into ~/.claude, the default layout, and every refusal."""
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "session-store.py")


@unittest.skipIf(os.name == "nt", "the fix needs symlinks; Windows refuses it by design")
class SessionStoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = os.path.realpath(self.tmp.name)
        self.claude_store = os.path.join(self.home, ".claude", "projects")
        self.profile = os.path.join(self.home, "launcher", "profile")
        self.target = os.path.join(self.home, "claude-projects")

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *args, profile=True):
        env = dict(os.environ, HOME=self.home)
        env.pop("CLAUDE_CONFIG_DIR", None)
        if profile:
            env["CLAUDE_CONFIG_DIR"] = self.profile
        p = subprocess.run([sys.executable, SCRIPT] + list(args), env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        return p.returncode, p.stdout

    def make_linked_layout(self):
        os.makedirs(os.path.join(self.claude_store, "proj", "memory"))
        with open(os.path.join(self.claude_store, "proj", "memory", "MEMORY.md"), "w") as f:
            f.write("- note\n")
        os.makedirs(self.profile)
        os.symlink(self.claude_store, os.path.join(self.profile, "projects"))

    def test_no_store_is_fine(self):
        rc, out = self.run_script("check")
        self.assertEqual(rc, 0, out)
        self.assertIn("status=ok", out)

    def test_default_config_dir_is_fine(self):
        os.makedirs(self.claude_store)
        rc, out = self.run_script("check", profile=False)
        self.assertEqual(rc, 0, out)
        self.assertIn("status=ok", out)

    def test_linked_store_is_affected(self):
        self.make_linked_layout()
        rc, out = self.run_script("check")
        self.assertEqual(rc, 3, out)
        self.assertIn("status=affected", out)
        self.assertIn(self.target, out)

    def test_fix_needs_yes(self):
        self.make_linked_layout()
        rc, out = self.run_script("fix")
        self.assertEqual(rc, 2, out)
        self.assertFalse(os.path.islink(self.claude_store))
        self.assertFalse(os.path.lexists(self.target))

    def test_fix_moves_links_and_is_idempotent(self):
        self.make_linked_layout()
        rc, out = self.run_script("fix", "--yes")
        self.assertEqual(rc, 0, out)
        self.assertIn("status=fixed", out)
        self.assertTrue(os.path.isdir(self.target) and not os.path.islink(self.target))
        self.assertTrue(os.path.islink(self.claude_store))
        self.assertEqual(os.path.realpath(self.claude_store), self.target)
        via_profile = os.path.join(self.profile, "projects", "proj", "memory", "MEMORY.md")
        with open(via_profile) as f:
            self.assertEqual(f.read(), "- note\n")
        self.assertEqual(os.path.realpath(via_profile),
                         os.path.join(self.target, "proj", "memory", "MEMORY.md"))
        rc, out = self.run_script("check")
        self.assertEqual(rc, 0, out)
        rc, out = self.run_script("fix", "--yes")
        self.assertEqual(rc, 0, out)
        self.assertIn("nothing to fix", out)

    def test_fix_refuses_existing_target(self):
        self.make_linked_layout()
        os.makedirs(self.target)
        rc, out = self.run_script("fix", "--yes")
        self.assertEqual(rc, 4, out)
        self.assertIn("already exists", out)
        self.assertFalse(os.path.islink(self.claude_store))

    def test_fix_refuses_target_under_claude(self):
        self.make_linked_layout()
        rc, out = self.run_script("fix", "--yes", "--to", os.path.join(self.home, ".claude", "moved"))
        self.assertEqual(rc, 4, out)
        self.assertIn("under .claude", out)
        self.assertFalse(os.path.islink(self.claude_store))

    def test_fix_prints_exact_undo(self):
        self.make_linked_layout()
        rc, out = self.run_script("fix", "--yes")
        self.assertEqual(rc, 0, out)
        self.assertIn("undo, while no session is writing: rm '%s' && mv '%s' '%s'"
                      % (self.claude_store, self.target, self.claude_store), out)

    def test_fix_refuses_link_to_whole_claude_dir(self):
        claude_dir = os.path.join(self.home, ".claude")
        os.makedirs(os.path.join(claude_dir, "projects"))
        os.makedirs(self.profile)
        os.symlink(claude_dir, os.path.join(self.profile, "projects"))
        rc, out = self.run_script("check")
        self.assertEqual(rc, 3, out)
        rc, out = self.run_script("fix", "--yes")
        self.assertEqual(rc, 4, out)
        self.assertIn("not a `projects` folder", out)
        self.assertFalse(os.path.islink(claude_dir))
        self.assertFalse(os.path.lexists(self.target))

    def test_fix_refuses_target_reached_through_link_into_claude(self):
        self.make_linked_layout()
        os.symlink(os.path.join(self.home, ".claude"), os.path.join(self.home, "sneaky"))
        rc, out = self.run_script("fix", "--yes", "--to", os.path.join(self.home, "sneaky", "moved"))
        self.assertEqual(rc, 4, out)
        self.assertIn("under .claude", out)
        self.assertFalse(os.path.islink(self.claude_store))

    def test_fix_honours_to(self):
        self.make_linked_layout()
        other = os.path.join(self.home, "data", "sessions")
        os.makedirs(os.path.dirname(other))
        rc, out = self.run_script("fix", "--yes", "--to", other)
        self.assertEqual(rc, 0, out)
        self.assertEqual(os.path.realpath(self.claude_store), other)


if __name__ == "__main__":
    unittest.main(verbosity=2)
