"""Synthetic-only tests for Windows WACLI VSS backup wiring.

These tests create temporary directories, JSON metadata, and a synthetic SQLite
media-reference fixture only. They never run backup.ps1, the native VSS helper,
WACLI, or inspect a real account store.
"""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
MODULE = REPO / "wacli-vss-backup.psm1"


@unittest.skipUnless(shutil.which("pwsh"), "PowerShell Core is required")
class WacliVssBackupInputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wacli-vss-input-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def run_powershell(self, body):
        env = os.environ.copy()
        env["SYNTHETIC_ROOT"] = str(self.root)
        script = f"Import-Module '{MODULE}' -Force\n$ErrorActionPreference = 'Stop'\n" + body
        return subprocess.run(
            ["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

    def test_enumerates_profile_store_config_media_and_legacy_roots(self):
        script = r'''
$root = $env:SYNTHETIC_ROOT
$app = Join-Path $root 'AppData'
$user = Join-Path $root 'UserProfile'
$profiles = Join-Path (Join-Path (Join-Path $app 'mainframe') 'accounts') 'whatsapp'
$profile = Join-Path $profiles 'synthetic-profile'
$profileStore = Join-Path $profile 'store'
$externalStore = Join-Path $root 'external-store'
$externalConfig = Join-Path $root 'external-config'
$externalMedia = Join-Path $root 'external-media'
$legacy = Join-Path $user '.wacli'
foreach ($path in @($profileStore, $externalStore, $externalConfig, $externalMedia, $legacy)) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}
$metadata = @{ kind = 'wacli'; storePath = $externalStore; configPath = $externalConfig; mediaRoots = @($externalMedia) }
$metadata | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $profile 'mainframe-whatsapp.json')
$inputs = Get-WacliVssInputs -AppDataRoot $app -UserProfileRoot $user
$inputs | ConvertTo-Json -Depth 8 -Compress
'''
        result = self.run_powershell(script)
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        payload = json.loads(result.stdout.strip())
        self.assertTrue(payload["HasState"])
        roots = {Path(root["Path"]): set(root["Roles"]) for root in payload["Roots"]}
        profiles = self.root / "AppData/mainframe/accounts/whatsapp"
        self.assertIn(profiles, roots)
        self.assertIn("profiles-and-profile-config", roots[profiles])
        self.assertIn("profile-store", roots[profiles])
        self.assertIn(self.root / "external-store", roots)
        self.assertIn(self.root / "external-config", roots)
        self.assertIn(self.root / "external-media", roots)
        self.assertIn(self.root / "UserProfile/.wacli", roots)
        self.assertEqual(len(payload["MetadataFiles"]), 1)
        self.assertEqual(payload["MediaReferenceCoverage"], "unproven")

    def test_missing_metadata_store_fails_loudly(self):
        script = r'''
$root = $env:SYNTHETIC_ROOT
$app = Join-Path $root 'AppData'
$user = Join-Path $root 'UserProfile'
$profiles = Join-Path (Join-Path (Join-Path $app 'mainframe') 'accounts') 'whatsapp'
$profile = Join-Path $profiles 'synthetic-profile'
New-Item -ItemType Directory -Force -Path (Join-Path $profile 'store') | Out-Null
@{ kind = 'wacli'; storePath = (Join-Path $root 'missing-required-store') } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $profile 'mainframe-whatsapp.json')
try { Get-WacliVssInputs -AppDataRoot $app -UserProfileRoot $user | Out-Null; exit 9 }
catch { [Console]::Error.WriteLine($_.Exception.Message); exit 2 }
'''
        result = self.run_powershell(script)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Required WACLI metadata-store root is missing or unavailable", result.stderr)

    def test_unproven_media_reference_coverage_blocks_before_native_build_and_output(self):
        profile = self.root / "AppData/mainframe/accounts/whatsapp/synthetic-profile"
        profile_store = profile / "store"
        external_store = self.root / "external-store"
        metadata_media = self.root / "metadata-media"
        sqlite_only_media = self.root / "sqlite-only-media"
        for path in (profile_store, external_store, metadata_media, sqlite_only_media):
            path.mkdir(parents=True, exist_ok=True)
        media_file = sqlite_only_media / "synthetic-blob.bin"
        media_file.write_bytes(b"synthetic only")
        connection = sqlite3.connect(profile_store / "wacli.db")
        try:
            connection.execute("CREATE TABLE synthetic_media_refs(path TEXT NOT NULL)")
            connection.execute("INSERT INTO synthetic_media_refs(path) VALUES (?)", (str(media_file),))
            connection.commit()
        finally:
            connection.close()

        script = r'''
$root = $env:SYNTHETIC_ROOT
$app = Join-Path $root 'AppData'
$user = Join-Path $root 'UserProfile'
$profile = Join-Path (Join-Path (Join-Path (Join-Path $app 'mainframe') 'accounts') 'whatsapp') 'synthetic-profile'
$metadata = @{ kind = 'wacli'; storePath = (Join-Path $root 'external-store'); mediaRoots = @((Join-Path $root 'metadata-media')) }
$metadata | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $profile 'mainframe-whatsapp.json')
$inputs = Get-WacliVssInputs -AppDataRoot $app -UserProfileRoot $user
if ($inputs.MediaReferenceCoverage -ne 'unproven') { [Console]::Error.WriteLine('coverage unexpectedly proven'); exit 6 }
$destination = Join-Path $root 'WacliWindowsVss'
try {
    Invoke-WacliVssCopy -Inputs $inputs -DestinationRoot $destination -RepositoryRoot (Join-Path $root 'missing-repository') | Out-Null
    exit 9
} catch {
    if (Test-Path -LiteralPath $destination) { [Console]::Error.WriteLine('stale output remains'); exit 8 }
    if ($_.Exception.Message -notmatch 'external-media completeness is unproven') {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 7
    }
    'BLOCKED'
}
'''
        result = self.run_powershell(script)
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        self.assertIn("BLOCKED", result.stdout)

    def test_no_state_is_distinct_from_missing_required_root(self):
        script = r'''
$inputs = Get-WacliVssInputs -AppDataRoot (Join-Path $env:SYNTHETIC_ROOT 'absent-appdata') -UserProfileRoot (Join-Path $env:SYNTHETIC_ROOT 'absent-user')
$inputs | ConvertTo-Json -Compress
'''
        result = self.run_powershell(script)
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        self.assertFalse(json.loads(result.stdout.strip())["HasState"])

    def test_single_call_wires_all_roots_to_one_multivolume_set_and_fails_closed(self):
        cli = (REPO / "wacli-vss-client/src/backup_copy_main.cpp").read_text()
        module = MODULE.read_text()
        cpp_tests = (REPO / "wacli-vss-client/tests/copy_tests.cpp").read_text()
        self.assertEqual(cli.count("stage_snapshot_roots("), 1)
        self.assertIn("roots, *resolver, *backend, *copy", cli)
        self.assertIn("if (!copy->discard(error))", cli)
        self.assertIn("Private staging cleanup failed", cli)
        self.assertEqual(module.count("& $exe @($arguments.ToArray())"), 1)
        self.assertIn("foreach ($root in $Inputs.Roots)", module)
        self.assertIn("no live-copy fallback was attempted", module)
        self.assertIn('"C:\\\\store", "D:\\\\media"', cpp_tests)
        self.assertIn("check(b.starts == 1 && b.dos == 1", cpp_tests)
        self.assertIn("must never be read", cpp_tests)

    def test_export_fixture_covers_sidecars_config_and_media_without_filters(self):
        native_tests = (REPO / "wacli-vss-client/tests/native_copy_tests.cpp").read_text()
        for member in (
            'session.db-wal', 'session.db-shm', 'session.db-journal',
            'wacli.db-wal', 'wacli.db-shm', 'wacli.db-journal',
            'profile\\\\config.json', 'media\\\\blob',
        ):
            self.assertIn(member, native_tests)
        self.assertIn("verified_export_includes_every_wacli_member", native_tests)
        self.assertIn("verified_export_failure_is_loud_and_removed", native_tests)


if __name__ == "__main__":
    unittest.main()
