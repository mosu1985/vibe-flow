#!/usr/bin/env python3
"""Cases for plan-size.py: the three size limits of the plan approval window, the
invisible-character run, and archive (moving sections into <plan>-history.md)."""
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "plan-size.py")
GATE_TABLE = "## 🚦 Plan gate\n\n| Codex (external critic) | 7.0 | 0 ✅ |\n\nGate: ✅ passed\n"
# A plan the approval hook accepts: the gate line plus the critic's own section.
GATE = "## 🧑‍⚖️ External Codex review\nC1 accepted\n\n" + GATE_TABLE


class PlanSizeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.plan = os.path.join(self.tmp.name, "brave-plan.md")
        self.history = os.path.join(self.tmp.name, "brave-plan-history.md")

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, text):
        with open(self.plan, "wb") as f:
            f.write(text.encode("utf-8"))

    def read(self, path):
        with open(path, "rb") as f:
            return f.read().decode("utf-8")

    def run_script(self, *args):
        env = dict(os.environ, PYTHONIOENCODING="utf-8")
        p = subprocess.run([sys.executable, SCRIPT] + list(args), env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return p.returncode, p.stdout.decode("utf-8", "replace")

    # --- check -------------------------------------------------------------

    def test_small_plan_fits(self):
        self.write("# 🎯 Task\n\n## 💡 Why\nShort.\n\n" + GATE)
        code, out = self.run_script("check", self.plan)
        self.assertEqual(code, 0, out)
        self.assertIn("✅ fits", out)

    def test_wide_lines_exhaust_the_budget_while_the_plan_is_short(self):
        # 20 lines of 2,000 characters: 40,000 characters in all (20% of the size
        # limit), but 20 * 2000^2 = 80M is over the 4 * 4096^2 = 67M line budget.
        rows = "\n".join("| row %02d | %s |" % (i, "x" * 1988) for i in range(20))
        self.write("# 🎯 Task\n\n## 🧩 Code\n" + rows + "\n\n" + GATE)
        code, out = self.run_script("check", self.plan)
        self.assertEqual(code, 1, out)
        self.assertIn("long-line budget", out)
        self.assertIn("## 🧩 Code", out)
        self.assertIn("Longest lines", out)

    def test_the_same_text_on_short_lines_fits(self):
        rows = "\n".join("x" * 100 for _ in range(400))
        self.write("# 🎯 Task\n\n## 🧩 Code\n" + rows + "\n\n" + GATE)
        code, out = self.run_script("check", self.plan)
        self.assertEqual(code, 0, out)

    def test_one_line_over_4096_is_cut(self):
        self.write("# 🎯 Task\n\n" + "y" * 4097 + "\n")
        code, out = self.run_script("check", self.plan)
        self.assertEqual(code, 1, out)
        self.assertIn("longest line", out)

    def test_variation_selectors_do_not_count_toward_a_line(self):
        self.write("# 🎯 Task\n\n" + "z" * 4096 + "️" + "\n")
        code, out = self.run_script("check", self.plan)
        self.assertEqual(code, 0, out)

    def test_over_200000_characters(self):
        self.write("# 🎯 Task\n\n" + ("w" * 99 + "\n") * 2001)
        code, out = self.run_script("check", self.plan)
        self.assertEqual(code, 1, out)
        self.assertIn("characters", out)

    def test_astral_characters_count_twice(self):
        # 100,040 emoji = 200,080 UTF-16 units: over, although only ~102,500 code
        # points; the lines are short, so only the character limit trips.
        self.write(("😀" * 40 + "\n") * 2501)
        code, out = self.run_script("check", self.plan)
        self.assertEqual(code, 1, out)
        self.assertIn("❌ characters", out)
        self.assertIn("✅ long-line budget", out)

    def test_a_run_of_invisible_characters(self):
        self.write("# 🎯 Task\n\nzalgo a" + "́" * 9 + "\n")
        code, out = self.run_script("check", self.plan)
        self.assertEqual(code, 1, out)
        self.assertIn("invisible", out)

    def test_close_to_a_limit_warns_but_passes(self):
        self.write("# 🎯 Task\n\n" + ("v" * 99 + "\n") * 1800)
        code, out = self.run_script("check", self.plan)
        self.assertEqual(code, 0, out)
        self.assertIn("close to the limit", out)

    def test_missing_file(self):
        code, out = self.run_script("check", os.path.join(self.tmp.name, "none.md"))
        self.assertEqual(code, 2, out)

    # --- archive -----------------------------------------------------------

    def plan_with_iterations(self):
        return ("# 🎯 Task\n\n## 🔁 Iteration 2\nNew scope.\n\n"
                "## 👥 Agent crew\n- prompt\n```markdown\n## 👥 Agent crew\n(template inside a fence)\n```\n"
                "tail of crew\n\n"
                "## 🛡️ Security\nold findings\n\n" + GATE)

    def test_archive_moves_sections_and_links_the_history(self):
        self.write(self.plan_with_iterations())
        code, out = self.run_script("archive", self.plan, "--section", "👥 Agent crew",
                                    "--section", "🛡️ Security", "--note", "iteration 1")
        self.assertEqual(code, 0, out)
        plan, hist = self.read(self.plan), self.read(self.history)
        self.assertNotIn("Agent crew", plan)
        self.assertNotIn("old findings", plan)
        self.assertIn("## 🔁 Iteration 2", plan)
        self.assertIn("Gate: ✅ passed", plan)
        self.assertIn("## 📚 Plan history", plan)
        self.assertIn("brave-plan-history.md", plan)
        # The `## ` inside the code fence belongs to the crew section, not a new one.
        self.assertIn("(template inside a fence)", hist)
        self.assertIn("tail of crew", hist)
        self.assertIn("old findings", hist)
        self.assertIn("iteration 1", hist)
        self.assertNotIn("⚠️", out)

    def test_archive_twice_appends_and_keeps_one_link(self):
        self.write(self.plan_with_iterations())
        self.assertEqual(self.run_script("archive", self.plan, "--section", "👥 Agent crew")[0], 0)
        self.assertEqual(self.run_script("archive", self.plan, "--section", "🛡️ Security")[0], 0)
        plan, hist = self.read(self.plan), self.read(self.history)
        self.assertEqual(plan.count("## 📚 Plan history"), 1)
        self.assertEqual(hist.count("# 📦 Moved out of the plan"), 2)
        self.assertEqual(hist.count("# 📚 History of brave-plan.md"), 1)

    def test_ambiguous_heading_moves_nothing(self):
        text = "# 🎯 Task\n\n## 🚦 Plan gate\nround 1\n\n## 🚦 Plan gate\nround 2\nGate: ✅ passed\n"
        self.write(text)
        code, out = self.run_script("archive", self.plan, "--section", "🚦 Plan gate")
        self.assertEqual(code, 2, out)
        self.assertIn("lines 3, 6", out)
        self.assertEqual(self.read(self.plan), text)
        self.assertFalse(os.path.exists(self.history))
        code, out = self.run_script("archive", self.plan, "--line", "3")
        self.assertEqual(code, 0, out)
        plan = self.read(self.plan)
        self.assertNotIn("round 1", plan)
        self.assertIn("round 2", plan)

    def test_unknown_heading_and_non_heading_line_move_nothing(self):
        text = self.plan_with_iterations()
        self.write(text)
        self.assertEqual(self.run_script("archive", self.plan, "--section", "Nope")[0], 2)
        # Line 9 is the `## 👥 Agent crew` inside the code fence.
        self.assertEqual(self.run_script("archive", self.plan, "--line", "9")[0], 2)
        self.assertEqual(self.read(self.plan), text)

    def test_archiving_the_gate_warns(self):
        self.write(self.plan_with_iterations())
        code, out = self.run_script("archive", self.plan, "--section", "🚦 Plan gate")
        self.assertEqual(code, 0, out)
        self.assertIn("no `Gate: ✅ passed` line", out)
        self.assertNotIn("no `## … Codex` section", out)

    def test_archiving_the_critic_section_warns_even_with_a_scored_codex_row(self):
        # The scored row of a critic that ran does not settle the hook; only the section does.
        self.write("# 🎯 Task\n\n## 🧑‍⚖️ External Codex review — round 1\nC1 accepted\n\n" + GATE_TABLE)
        code, out = self.run_script("archive", self.plan, "--section",
                                    "🧑‍⚖️ External Codex review — round 1")
        self.assertEqual(code, 0, out)
        self.assertIn("no `## … Codex` section", out)

    def test_a_codex_not_installed_row_settles_the_critic(self):
        self.write("# 🎯 Task\n\n## 🛡️ Security\nold\n\n## 🚦 Plan gate\n"
                   "| codex (external critic) | — | ⚪️ not installed |\n\nGate: ✅ passed\n")
        code, out = self.run_script("archive", self.plan, "--section", "🛡️ Security")
        self.assertEqual(code, 0, out)
        self.assertNotIn("⚠️", out)

    def test_a_longer_fence_holds_a_nested_fence_and_a_heading(self):
        text = ("# 🎯 Task\n\n## A\n````markdown\n```bash\necho hi\n```\n## inner\n````\n"
                "tail of A\n\n## B\nkeep\n" + GATE)
        self.write(text)
        code, out = self.run_script("archive", self.plan, "--section", "A")
        self.assertEqual(code, 0, out)
        plan, hist = self.read(self.plan), self.read(self.history)
        self.assertNotIn("inner", plan)
        self.assertNotIn("tail of A", plan)
        self.assertIn("## B\nkeep", plan)
        self.assertIn("## inner", hist)
        self.assertIn("tail of A", hist)

    @unittest.skipIf(os.name == "nt", "POSIX permission bits")
    def test_archive_keeps_the_file_mode(self):
        self.write(self.plan_with_iterations())
        os.chmod(self.plan, 0o644)
        self.assertEqual(self.run_script("archive", self.plan, "--section", "🛡️ Security")[0], 0)
        self.assertEqual(os.stat(self.plan).st_mode & 0o777, 0o644)
        self.assertEqual(os.stat(self.history).st_mode & 0o777, 0o644)

    def test_history_section_stays(self):
        self.write(self.plan_with_iterations())
        self.run_script("archive", self.plan, "--section", "🛡️ Security")
        code, out = self.run_script("archive", self.plan, "--section", "📚 Plan history")
        self.assertEqual(code, 2, out)

    def test_crlf_plan_keeps_its_line_endings(self):
        self.write(self.plan_with_iterations().replace("\n", "\r\n"))
        code, out = self.run_script("archive", self.plan, "--section", "🛡️ Security")
        self.assertEqual(code, 0, out)
        plan, hist = self.read(self.plan), self.read(self.history)
        self.assertIn("## 🔁 Iteration 2\r\nNew scope.\r\n", plan)
        self.assertNotIn("old findings", plan)
        # No bare LF anywhere: the plan and its history keep the plan's line endings.
        self.assertEqual(plan.count("\n"), plan.count("\r\n"), repr(plan[-200:]))
        self.assertEqual(hist.count("\n"), hist.count("\r\n"), repr(hist[-200:]))


if __name__ == "__main__":
    unittest.main(verbosity=1)
