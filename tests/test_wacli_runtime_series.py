"""Source artifact checks only: no accounts, live capture or dependency execution."""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import re
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

    def test_lifecycle_and_media_tests_cannot_silently_drop_out_of_verifier(self):
        manifest = json.loads((verifier.PATCHES / 'runtime-series.json').read_text())
        cases = {
            'wacli_test_pattern': ('TestDrainDelegateOwnerRejectsAfterSeal',
                'TestStageRejectsPresealDescriptorCorruption',
                'TestEnumerateMediaMembershipLimitFailsWithoutPartialSet',
                'TestStoreVerifyMediaSyntheticReferencesAndRefusal',
                'TestDrainCausalGrandchildSurvivesAncestorFinish',
                'TestDrainSendAttemptOutlivesTimeoutAndRetainsFailure',
                'TestOperationAdmissionSealRaceHasNoLateAcceptance',
                'TestAddEventHandlerPreservesSDKCallbackContext',
                'TestDrainOwnedSendMissingOwnerRefusesBeforeEffects',
                'TestDrainOwnedSendUnscopedOwnerRefusesBeforeEffects',
                'TestDrainCanceledSendAttemptDoesNotLaunchEffects',
                'TestDrainSourceProducerInventory'),
            'dependency_test_pattern': ('TestLifecycleDrainCancellationSealsAdmission',
                'TestSyntheticHandlerChildOutlivesQueueLoop', 'TestSyntheticQueuedCancellationIsSticky',
                'TestSyntheticSocketWriteOutlivesCallerCancellation',
                'TestLifecycleAtomicAllRootSealBeforeWait',
                'TestLifecycleIgnoredLaunchRejectionRetainedByDrain',
                'TestProtocolLifecycleLaunchRegistersAndRetainsWorkerError'),
        }
        for pattern, names in cases.items():
            for name in names:
                self.assertIsNotNone(re.search(manifest[pattern], name), name)
        verifier_source = Path(verifier.__file__).read_text()
        for package in ('./internal/store', './internal/mediamembership', './socket'):
            self.assertIn(package, verifier_source)
        wacli = verifier.PATCHES / '0006-lifecycle-api-and-sealed-media-membership.patch'
        sdk = verifier.PATCHES / 'whatsmeow/0002-lifecycle-scopes-and-handler-drain.patch'
        self.assertNotIn('diff --git a/go.mod', wacli.read_text())
        self.assertIn('return nil, ErrLifecycleCoverageIncomplete', sdk.read_text())

    def test_producer_extension_is_source_only_and_cannot_approve_coverage(self):
        manifest = json.loads((verifier.PATCHES / 'runtime-series.json').read_text())
        self.assertEqual(manifest['extension_status'], 'local-unsubmitted-unaccepted')
        self.assertFalse(manifest['capture_enabled'])
        wacli = verifier.PATCHES / '0007-causal-application-producers.patch'
        sdk = verifier.PATCHES / 'whatsmeow/0003-causal-producer-admission.patch'
        for artifact in (wacli, sdk):
            source = artifact.read_text()
            self.assertIn('unsubmitted and unaccepted upstream', source)
            self.assertNotIn('diff --git a/go.mod', source)
            self.assertIn('_test.go', source)
        self.assertIn('func RegisterOperationChild', wacli.read_text())
        self.assertIn('func LifecycleCoverageGaps()', sdk.read_text())
        self.assertIn('func (cli *Client) sealLifecycleRoots()', sdk.read_text())
        self.assertIn('socket/socket_lifecycle_test.go', sdk.read_text())

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
