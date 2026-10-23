"""Offline Windows WACLI-state contracts exercised through extracted PowerShell AST functions.

The scripts are never dot-sourced or invoked as programs: each test parses one
FunctionDefinitionAst and evaluates only that function declaration. Fixtures
are synthetic temporary files/zips and do not touch a real profile or archive.
"""
from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from zipfile import ZipFile


ROOT = Path(__file__).resolve().parents[1]
PWsh = "pwsh"


class WindowsWacliContractTests(unittest.TestCase):
    def run_function(self, script: Path, function: str, body: str) -> str:
        """Extract and invoke exactly one function definition from *script*."""
        if shutil.which(PWsh) is None:
            self.skipTest('PowerShell unavailable; AST guard contract not executed')
        harness = r'''
param([string]$Source, [string]$FunctionName, [string]$Body)
$tokens = $null
$errors = $null
$parsed = [System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "parse errors: $($errors -join '; ')" }
$definition = $parsed.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq $FunctionName
}, $true)
if (-not $definition) { throw "function not found: $FunctionName" }
# This executes only a function declaration reconstructed from its AST extent;
# script parameters, elevation checks, and all top-level/live code are skipped.
. ([scriptblock]::Create($definition.Extent.Text))
& ([scriptblock]::Create($Body))
'''
        with tempfile.TemporaryDirectory(prefix="wacli-pwsh-harness-") as td:
            harness_path = Path(td) / "extract-and-invoke.ps1"
            harness_path.write_text(harness, encoding="utf-8")
            completed = subprocess.run(
                [PWsh, "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
                 str(harness_path), "-Source", str(script), "-FunctionName",
                 function, "-Body", body],
                text=True, capture_output=True, check=False,
            )
        if completed.returncode:
            raise AssertionError(
                f"pwsh failed ({completed.returncode})\nstdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
            )
        return completed.stdout + completed.stderr

    def invoke_guard(self, script: Path, source: Path) -> tuple[bool, str]:
        body = f"try {{ Assert-WindowsWhatsappCaptureSafe -Source {self.ps_quote(str(source))}; 'PASS' }} catch {{ 'BLOCK: ' + $_.Exception.Message }}"
        output = self.run_function(script, "Assert-WindowsWhatsappCaptureSafe", body)
        return "PASS" in output, output

    def invoke_reserved_check(self, script: Path, source: Path) -> bool:
        body = f"if (Test-WacliReservedArchiveSource -Source {self.ps_quote(str(source))}) {{ 'BLOCK' }} else {{ 'PASS' }}"
        output = self.run_function(script, "Test-WacliReservedArchiveSource", body)
        return "BLOCK" in output

    @staticmethod
    def ps_quote(value: str) -> str:
        return "'" + value.replace("'", "''") + "'"

    def test_backup_guards_reject_sqlite_variants_only_inside_whatsapp(self):
        for script in (ROOT / "backup.ps1", ROOT / "backup-secrets.ps1"):
            with self.subTest(script=script.name), tempfile.TemporaryDirectory(prefix="wacli-win-guard-") as td:
                root = Path(td)
                whatsapp = root / "WhatsApp"
                whatsapp.mkdir()
                for name in ("msgstore.db", "contacts.sqlite", "state.sqlite3-wal", "cache.db-shm", "journal-journal"):
                    (whatsapp / name).write_bytes(b"synthetic sqlite marker")
                (root / "other-account.db").write_bytes(b"unrelated account fixture")
                passed, output = self.invoke_guard(script, root)
                self.assertFalse(passed, output)
                self.assertIn("live SQLite state", output)

    def test_backup_guards_allow_absent_non_whatsapp_and_metadata_only_trees(self):
        for script in (ROOT / "backup.ps1", ROOT / "backup-secrets.ps1"):
            with self.subTest(script=script.name), tempfile.TemporaryDirectory(prefix="wacli-win-safe-") as td:
                root = Path(td)
                self.assertEqual(self.invoke_guard(script, root)[0], True)
                (root / "OtherAccount").mkdir()
                (root / "OtherAccount" / "account.db").write_bytes(b"unrelated account fixture")
                self.assertEqual(self.invoke_guard(script, root)[0], True)
                whatsapp = root / "whatsapp"
                (whatsapp / "metadata").mkdir(parents=True)
                (whatsapp / "metadata" / "version.json").write_text("{}", encoding="utf-8")
                self.assertEqual(self.invoke_guard(script, root)[0], True)

    def test_backup_guards_reject_when_source_itself_is_whatsapp(self):
        for script in (ROOT / "backup.ps1", ROOT / "backup-secrets.ps1"):
            with self.subTest(script=script.name), tempfile.TemporaryDirectory(prefix="wacli-win-direct-") as td:
                whatsapp = Path(td) / "whatsapp"
                whatsapp.mkdir()
                (whatsapp / "messages.sqlite").write_bytes(b"synthetic")
                passed, output = self.invoke_guard(script, whatsapp)
                self.assertFalse(passed, output)

    def test_backup_vss_guard_checks_remapped_source(self):
        script = ROOT / "backup.ps1"
        text = script.read_text(encoding="utf-8")
        self.assertLess(text.index("$actualSource = $source"), text.index("Assert-WindowsWhatsappCaptureSafe -Source $actualSource"))
        with tempfile.TemporaryDirectory(prefix="wacli-win-vss-") as td:
            root = Path(td)
            live = root / "live" / "WhatsApp"
            snapshot = root / "vss" / "WhatsApp"
            live.mkdir(parents=True)
            snapshot.mkdir(parents=True)
            (snapshot / "msgstore.db-wal").write_bytes(b"synthetic snapshot sidecar")
            self.assertTrue(self.invoke_guard(script, live)[0])
            passed, output = self.invoke_guard(script, snapshot)
            self.assertFalse(passed, output)
            self.assertIn("live SQLite state", output)

    def test_restore_reserved_native_tree_is_blocked_for_custom_manifest_sources(self):
        for script in (ROOT / "restore.ps1", ROOT / "restore-secrets.ps1"):
            with self.subTest(script=script.name), tempfile.TemporaryDirectory(prefix="wacli-win-reserved-") as td:
                root = Path(td)
                native = root / "NativeState" / "wacli"
                native.mkdir(parents=True)
                (native / "state.sqlite").write_bytes(b"synthetic native payload")
                self.assertTrue(self.invoke_reserved_check(script, native))
                self.assertTrue(self.invoke_reserved_check(script, native / "state.sqlite"))
                self.assertTrue(self.invoke_reserved_check(script, root))
                safe = root / "ordinary" / "config.json"
                safe.parent.mkdir(parents=True)
                safe.write_text("{}", encoding="utf-8")
                self.assertFalse(self.invoke_reserved_check(script, safe))

    def test_restore_embedded_native_payload_is_report_only(self):
        script = ROOT / "restore.ps1"
        with tempfile.TemporaryDirectory(prefix="wacli-win-embedded-") as td:
            root = Path(td)
            (root / "NativeState" / "wacli").mkdir(parents=True)
            marker = root / "NativeState" / "wacli" / "state.sqlite"
            marker.write_bytes(b"synthetic native payload")
            before = marker.read_bytes()
            body = f"$script:WacliPayloadReported = $false; Report-WacliPayloadPreserved -Path {self.ps_quote(str(root))}"
            output = self.run_function(script, "Report-WacliPayloadPreserved", body)
            self.assertIn("Linux-native state", output)
            self.assertIn("not activated or remapped", output)
            self.assertEqual(marker.read_bytes(), before)
            self.assertFalse((root / "activated").exists())

    def test_restore_standalone_native_payload_is_report_only(self):
        script = ROOT / "restore-secrets.ps1"
        with tempfile.TemporaryDirectory(prefix="wacli-win-standalone-") as td:
            archive = Path(td) / "tool-secrets.zip"
            with ZipFile(archive, "w") as zf:
                zf.writestr("NativeState/wacli/state.sqlite", b"synthetic native payload")
            before = archive.read_bytes()
            body = f"Report-WacliPayloadPreserved -ArchivePath {self.ps_quote(str(archive))}"
            output = self.run_function(script, "Report-WacliPayloadPreserved", body)
            self.assertIn("Linux-native state", output)
            self.assertIn("not activated or remapped", output)
            self.assertEqual(archive.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
