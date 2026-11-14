import inspect
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import linux_real as lr


class MuseSkillsSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.staging = self.root / "staging"
        self.skills = self.staging / "home-staging" / ".agents" / "skills"
        self.skills.mkdir(parents=True)
        self.custom = self.home / "workspace" / "custom-skills"

    def tearDown(self):
        self.temp.cleanup()

    def stage_skill(self, name, body="# test skill"):
        skill = self.skills / name
        skill.mkdir()
        (skill / "SKILL.md").write_text(body)
        return skill

    def test_sync_copies_staged_skills_into_custom_skills(self):
        self.custom.mkdir(parents=True)
        self.stage_skill("browser-use")
        self.stage_skill("research", "# research skill")
        result = lr.sync_muse_skills(self.staging, self.home)
        self.assertEqual(result["status"], "synced")
        self.assertEqual(result["synced"], ["browser-use", "research"])
        self.assertEqual((self.custom / "browser-use" / "SKILL.md").read_text(),
                         "# test skill")
        self.assertEqual((self.custom / "research" / "SKILL.md").read_text(),
                         "# research skill")

    def test_existing_skill_is_skipped_never_overwritten(self):
        self.custom.mkdir(parents=True)
        existing = self.custom / "browser-use"
        existing.mkdir()
        (existing / "SKILL.md").write_text("# mine, do not touch")
        self.stage_skill("browser-use", "# backup version")
        self.stage_skill("research")
        result = lr.sync_muse_skills(self.staging, self.home)
        self.assertEqual(result["synced"], ["research"])
        self.assertEqual(result["skipped_existing"], ["browser-use"])
        self.assertEqual((existing / "SKILL.md").read_text(),
                         "# mine, do not touch")

    def test_pre_existing_custom_skills_are_untouched(self):
        self.custom.mkdir(parents=True)
        keeper = self.custom / "learned-on-vm"
        keeper.mkdir()
        (keeper / "SKILL.md").write_text("# learned here")
        self.stage_skill("browser-use")
        lr.sync_muse_skills(self.staging, self.home)
        self.assertEqual((keeper / "SKILL.md").read_text(), "# learned here")

    def test_skill_containing_a_symlink_is_skipped(self):
        self.custom.mkdir(parents=True)
        bad = self.stage_skill("sneaky")
        (bad / "escape").symlink_to("/etc/passwd")
        self.stage_skill("clean")
        result = lr.sync_muse_skills(self.staging, self.home)
        self.assertEqual(result["synced"], ["clean"])
        self.assertEqual(result["skipped_symlink"], ["sneaky"])
        self.assertFalse((self.custom / "sneaky").exists())

    def test_symlinked_skill_directory_itself_is_skipped(self):
        self.custom.mkdir(parents=True)
        target = self.root / "elsewhere"
        target.mkdir()
        (self.skills / "linked").symlink_to(target, target_is_directory=True)
        result = lr.sync_muse_skills(self.staging, self.home)
        self.assertEqual(result["skipped_symlink"], ["linked"])
        self.assertFalse((self.custom / "linked").exists())

    def test_non_muse_box_is_a_noop_and_creates_nothing(self):
        # no ~/workspace/custom-skills: a plain linux box. the step must
        # not create the directory and must not touch anything.
        self.stage_skill("browser-use")
        result = lr.sync_muse_skills(self.staging, self.home)
        self.assertEqual(result["status"], "skipped-not-muse")
        self.assertFalse((self.home / "workspace").exists())

    def test_no_staged_skills_reports_cleanly(self):
        self.custom.mkdir(parents=True)
        result = lr.sync_muse_skills(self.staging, self.home)
        self.assertEqual(result["status"], "no-skills-staged")
        self.assertEqual(result["synced"], [])

    def test_stray_file_in_the_skills_tree_is_skipped(self):
        self.custom.mkdir(parents=True)
        (self.skills / "README.txt").write_text("not a skill")
        self.stage_skill("browser-use")
        result = lr.sync_muse_skills(self.staging, self.home)
        self.assertEqual(result["synced"], ["browser-use"])
        self.assertEqual(result["skipped_other"], ["README.txt"])
        self.assertFalse((self.custom / "README.txt").exists())

    def test_run_restore_and_leg_accept_the_skip_flag(self):
        self.assertIn("skip_muse_skills",
                      inspect.signature(lr.run_restore).parameters)
        self.assertIn("skip_muse_skills",
                      inspect.signature(lr.run_restore_leg).parameters)


if __name__ == "__main__":
    unittest.main()
