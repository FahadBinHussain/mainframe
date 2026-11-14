import inspect
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import linux_real as lr


class RestoredSkillsSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.staging = self.root / "staging"
        self.skills = self.staging / "home-staging" / ".agents" / "skills"
        self.skills.mkdir(parents=True)
        # the target is a parameter: any agent's skill dir, not one fixed path.
        self.target = self.root / "agent-skills"

    def tearDown(self):
        self.temp.cleanup()

    def stage_skill(self, name, body="# test skill"):
        skill = self.skills / name
        skill.mkdir()
        (skill / "SKILL.md").write_text(body)
        return skill

    def test_sync_copies_staged_skills_and_creates_the_target(self):
        self.stage_skill("browser-use")
        self.stage_skill("research", "# research skill")
        result = lr.sync_restored_skills(self.staging, self.target)
        self.assertEqual(result["status"], "synced")
        self.assertEqual(result["synced"], ["browser-use", "research"])
        self.assertEqual((self.target / "browser-use" / "SKILL.md").read_text(),
                         "# test skill")
        self.assertEqual((self.target / "research" / "SKILL.md").read_text(),
                         "# research skill")

    def test_existing_skill_is_skipped_never_overwritten(self):
        self.target.mkdir(parents=True)
        existing = self.target / "browser-use"
        existing.mkdir()
        (existing / "SKILL.md").write_text("# mine, do not touch")
        self.stage_skill("browser-use", "# backup version")
        self.stage_skill("research")
        result = lr.sync_restored_skills(self.staging, self.target)
        self.assertEqual(result["synced"], ["research"])
        self.assertEqual(result["skipped_existing"], ["browser-use"])
        self.assertEqual((existing / "SKILL.md").read_text(),
                         "# mine, do not touch")

    def test_pre_existing_target_entries_are_untouched(self):
        self.target.mkdir(parents=True)
        keeper = self.target / "learned-here"
        keeper.mkdir()
        (keeper / "SKILL.md").write_text("# learned here")
        self.stage_skill("browser-use")
        lr.sync_restored_skills(self.staging, self.target)
        self.assertEqual((keeper / "SKILL.md").read_text(), "# learned here")

    def test_skill_containing_a_symlink_is_skipped(self):
        self.target.mkdir(parents=True)
        bad = self.stage_skill("sneaky")
        (bad / "escape").symlink_to("/etc/passwd")
        self.stage_skill("clean")
        result = lr.sync_restored_skills(self.staging, self.target)
        self.assertEqual(result["synced"], ["clean"])
        self.assertEqual(result["skipped_symlink"], ["sneaky"])
        self.assertFalse((self.target / "sneaky").exists())

    def test_symlinked_skill_directory_itself_is_skipped(self):
        self.target.mkdir(parents=True)
        target = self.root / "elsewhere"
        target.mkdir()
        (self.skills / "linked").symlink_to(target, target_is_directory=True)
        result = lr.sync_restored_skills(self.staging, self.target)
        self.assertEqual(result["skipped_symlink"], ["linked"])
        self.assertFalse((self.target / "linked").exists())

    def test_target_that_is_a_file_fails_loudly(self):
        self.target.write_text("not a directory")
        self.stage_skill("browser-use")
        with self.assertRaises(RuntimeError):
            lr.sync_restored_skills(self.staging, self.target)

    def test_no_staged_skills_reports_cleanly(self):
        result = lr.sync_restored_skills(self.staging, self.target)
        self.assertEqual(result["status"], "no-skills-staged")
        self.assertEqual(result["synced"], [])

    def test_stray_file_in_the_skills_tree_is_skipped(self):
        (self.skills / "README.txt").write_text("not a skill")
        self.stage_skill("browser-use")
        result = lr.sync_restored_skills(self.staging, self.target)
        self.assertEqual(result["synced"], ["browser-use"])
        self.assertEqual(result["skipped_other"], ["README.txt"])
        self.assertFalse((self.target / "README.txt").exists())

    def test_no_flag_means_no_sync_target(self):
        self.assertIsNone(lr.resolve_muse_skills_dir(False, None))

    def test_bare_flag_uses_the_muse_default_dir(self):
        self.assertEqual(
            lr.resolve_muse_skills_dir(True, None),
            Path.home() / "workspace" / "custom-skills")

    def test_explicit_dir_wins_over_the_bare_flag(self):
        explicit = self.root / "other-agent" / "skills"
        self.assertEqual(
            lr.resolve_muse_skills_dir(True, explicit), explicit.resolve())
        self.assertEqual(
            lr.resolve_muse_skills_dir(False, explicit), explicit.resolve())

    def test_run_restore_and_leg_accept_the_target_param(self):
        self.assertIn("muse_skills_dir",
                      inspect.signature(lr.run_restore).parameters)
        self.assertIn("muse_skills_dir",
                      inspect.signature(lr.run_restore_leg).parameters)
        self.assertNotIn("skip_muse_skills",
                         inspect.signature(lr.run_restore).parameters)


if __name__ == "__main__":
    unittest.main()
