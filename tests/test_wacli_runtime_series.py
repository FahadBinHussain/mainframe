"""Source artifact checks only: no accounts, live capture or dependency execution."""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('runtime_verifier', ROOT / 'patches/wacli/verify_runtime.py')
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)


class RuntimeSeriesTests(unittest.TestCase):
    def test_series_is_exact_pinned_and_all_members_are_verified(self):
        manifest = json.loads((verifier.PATCHES / 'runtime-series.json').read_text())
        self.assertEqual(manifest['base'], verifier.BASE)
        self.assertEqual(manifest['dependency'], verifier.DEPENDENCY)
        for group in ('wacli', 'whatsmeow'):
            self.assertTrue(manifest[group])
            for entry in manifest[group]:
                path = verifier.checked_artifact(entry)
                content = path.read_text()
                self.assertIn('diff --git ', content)
        self.assertTrue(manifest['wacli_test_pattern'].startswith('^(Test'))
        self.assertTrue(manifest['dependency_test_pattern'].startswith('^Test'))

    def test_changed_patch_and_unsafe_members_refuse(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(verifier, 'PATCHES', Path(temporary)):
            root = Path(temporary)
            artifact = root / 'fixture.patch'
            artifact.write_bytes(b'synthetic patch')
            digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
            self.assertEqual(verifier.checked_artifact({'path': artifact.name, 'sha256': digest}), artifact)
            artifact.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'digest'):
                verifier.checked_artifact({'path': artifact.name, 'sha256': digest})
            for name in ('../escape.patch', '/absolute.patch'):
                with self.assertRaisesRegex(ValueError, 'member'):
                    verifier.checked_artifact({'path': name, 'sha256': digest})
            link = root / 'link.patch'; link.symlink_to(artifact)
            with self.assertRaisesRegex(ValueError, 'regular'):
                verifier.checked_artifact({'path': link.name, 'sha256': digest})


if __name__ == '__main__':
    unittest.main()
