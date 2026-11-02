import io
import json
import os
import stat
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import pwsh_linux as pwsh

VERSION = "9.8.7"
LINUX_NAME = f"powershell-{VERSION}-linux-x64.tar.gz"
WINDOWS_NAME = f"PowerShell-{VERSION}-win-x64.zip"
LINUX_URL = f"https://github.com/PowerShell/PowerShell/releases/download/v{VERSION}/{LINUX_NAME}"
WINDOWS_URL = f"https://github.com/PowerShell/PowerShell/releases/download/v{VERSION}/{WINDOWS_NAME}"
RELEASE_URL = pwsh.RELEASE_API_PREFIX + VERSION
WINDOWS_SHA = "a" * 64
LINUX_SHA = "b" * 64
SIZE = 73399520


def elf64_header() -> bytes:
    """A minimal but complete x86_64 ELF64 executable header."""
    header = bytearray(64)
    header[0:4] = b"\x7fELF"
    header[4] = 2  # ELFCLASS64
    header[5] = 1  # ELFDATA2LSB
    header[6] = 1  # EV_CURRENT
    header[16:18] = (2).to_bytes(2, "little")  # ET_EXEC
    header[18:20] = (62).to_bytes(2, "little")  # EM_X86_64
    header[20:24] = (1).to_bytes(4, "little")  # EV_CURRENT
    header[52:54] = (64).to_bytes(2, "little")  # e_ehsize
    return bytes(header)


def manifest_bytes(version=VERSION, url=WINDOWS_URL, digest=WINDOWS_SHA):
    return json.dumps({
        "version": version,
        "architecture": {"64bit": {"url": url, "hash": digest}},
    }).encode("utf-8")


def release_body(linux_sha=LINUX_SHA, windows_sha=WINDOWS_SHA):
    return ("### SHA256 Hashes of the release artifacts\n\n"
            f"- {WINDOWS_NAME}\n  - {windows_sha.upper()}\n"
            f"- {LINUX_NAME}\n  - {linux_sha.upper()}\n")


def release_bytes(*, linux_sha=LINUX_SHA, windows_sha=WINDOWS_SHA, url=LINUX_URL,
                  asset_digest=None, size=SIZE, body=None):
    assets = [
        {"name": WINDOWS_NAME, "browser_download_url": WINDOWS_URL, "size": size,
         "digest": f"sha256:{windows_sha.lower()}"},
        {"name": LINUX_NAME, "browser_download_url": url, "size": size,
         "digest": f"sha256:{asset_digest.lower()}" if asset_digest is not None
         else f"sha256:{linux_sha.lower()}"},
    ]
    return json.dumps({
        "tag_name": f"v{VERSION}",
        "draft": False,
        "prerelease": False,
        "assets": assets,
        "body": body if body is not None else release_body(linux_sha, windows_sha),
    }).encode("utf-8")


def resolve_with(manifest=None, release=None):
    mapping = {
        pwsh.SCOOP_MANIFEST: manifest if manifest is not None else manifest_bytes(),
        RELEASE_URL: release if release is not None else release_bytes(),
    }
    with patch.object(pwsh, "_fetch_metadata", side_effect=lambda url: mapping[url]):
        return pwsh.resolve_release("x86_64")


class _FakeRequest:
    """Just enough of urllib's Request for the redirect guard."""

    def __init__(self, full_url):
        self.full_url = full_url


def tar_bytes(members):
    """Build an in-memory tar.gz from (name, kind, payload) triples."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w:gz") as tf:
        for name, kind, payload in members:
            info = tarfile.TarInfo(name)
            if kind == "dir":
                info.type = tarfile.DIRTYPE
                info.mode = 0o775
                tf.addfile(info)
            elif kind == "symlink":
                info.type = tarfile.SYMTYPE
                info.linkname = payload
                info.mode = 0o777
                tf.addfile(info)
            else:
                data = payload
                info.size = len(data)
                info.mode = 0o755 if kind == "exec" else 0o644
                tf.addfile(info, io.BytesIO(data))
    return raw.getvalue()


class PowerShellReleasePinTests(unittest.TestCase):
    def test_pins_the_windows_version_and_both_published_digests(self):
        release = resolve_with()
        self.assertEqual(release["version"], VERSION)
        self.assertEqual(release["url"], LINUX_URL)
        self.assertEqual(release["sha256"], LINUX_SHA)
        self.assertEqual(release["size"], str(SIZE))
        self.assertEqual(release["asset_name"], LINUX_NAME)
        self.assertEqual(release["windows_sha256"], WINDOWS_SHA)
        self.assertEqual(release["manifest_source"], pwsh.SCOOP_MANIFEST)
        self.assertEqual(release["release_source"], RELEASE_URL)

    def test_refuses_when_the_asset_digest_and_release_notes_disagree(self):
        with self.assertRaisesRegex(ValueError, "digests disagree"):
            resolve_with(release=release_bytes(asset_digest="c" * 64))

    def test_reads_the_release_notes_when_they_are_crlf(self):
        # GitHub serves the notes with CRLF line endings, and that is what the
        # real 7.6.9 body has. a digest line under them ends with \r\n, so a
        # pattern that demands end-of-line without the \r matches NOTHING and
        # resolve_release can never succeed - which is exactly how the live
        # linux run failed while the LF fixtures stayed green.
        crlf = release_body().replace("\n", "\r\n")
        self.assertNotEqual(crlf, release_body())
        release = resolve_with(release=release_bytes(body=crlf))
        self.assertEqual(release["sha256"], LINUX_SHA)
        self.assertEqual(release["windows_sha256"], WINDOWS_SHA)

    def test_refuses_a_release_without_an_asset_digest(self):
        payload = json.loads(release_bytes())
        payload["assets"][1].pop("digest")
        with self.assertRaisesRegex(ValueError, "required SHA256 digest"):
            resolve_with(release=json.dumps(payload).encode("utf-8"))

    def test_refuses_a_non_official_archive_url(self):
        with self.assertRaisesRegex(ValueError, "not official"):
            resolve_with(release=release_bytes(url="https://attacker.invalid/powershell.tar.gz"))

    def test_refuses_a_windows_checksum_that_does_not_match_the_release(self):
        with self.assertRaisesRegex(ValueError, "Windows checksum"):
            resolve_with(manifest=manifest_bytes(digest="c" * 64))

    def test_refuses_a_draft_or_prerelease_tag(self):
        for flag in ("draft", "prerelease"):
            payload = json.loads(release_bytes())
            payload[flag] = True
            with self.subTest(flag=flag), self.assertRaisesRegex(ValueError, "stable-release status"):
                resolve_with(release=json.dumps(payload).encode("utf-8"))

    def test_refuses_a_architecture_other_than_x86_64(self):
        with self.assertRaisesRegex(RuntimeError, "Unsupported architecture"):
            pwsh.resolve_release("aarch64")


class PowerShellReleaseValidationTests(unittest.TestCase):
    def setUp(self):
        self.release = resolve_with()

    def test_rejects_a_tampered_download_path(self):
        self.release["url"] = f"https://github.com/PowerShell/PowerShell/releases/download/v{VERSION}/other.tar.gz"
        with self.assertRaisesRegex(ValueError, "not exact"):
            pwsh._validate_release(self.release)

    def test_rejects_a_tampered_size(self):
        self.release["size"] = "0"
        with self.assertRaisesRegex(ValueError, "Invalid PowerShell size"):
            pwsh._validate_release(self.release)

    def test_rejects_a_missing_key(self):
        del self.release["sha256"]
        with self.assertRaisesRegex(ValueError, "Invalid PowerShell release metadata"):
            pwsh._validate_release(self.release)

    def test_rejects_a_foreign_manifest_source(self):
        self.release["manifest_source"] = "https://example.invalid/manifest.json"
        with self.assertRaisesRegex(ValueError, "Invalid PowerShell provenance"):
            pwsh._validate_release(self.release)


class PowerShellArchiveSafetyTests(unittest.TestCase):
    def test_member_names_reject_traversal_absolute_and_backslash(self):
        for name in ("../evil", "/etc/passwd", "a/../../b", "a\\b", "", "./x", "a//b"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                pwsh._member_parts(name)

    def test_member_names_accept_the_real_archive_shape(self):
        self.assertEqual(pwsh._member_parts("pwsh"), ["pwsh"])
        self.assertEqual(pwsh._member_parts("Modules/PSReadLine/PSReadLine.psd1"),
                         ["Modules", "PSReadLine", "PSReadLine.psd1"])
        self.assertEqual(pwsh._member_parts("en-US/"), ["en-US"])

    def test_extraction_refuses_a_symlink_member(self):
        archive = tar_bytes([("pwsh", "exec", elf64_header()),
                             ("libfake.so", "symlink", "pwsh")])
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "pwsh.tar.gz"
            path.write_bytes(archive)
            stage = Path(scratch) / "stage"
            stage.mkdir()
            with self.assertRaisesRegex(ValueError, "must not be a link"):
                pwsh._extract_archive(path, stage)

    def test_extraction_refuses_an_absolute_member(self):
        archive = tar_bytes([("/etc/passwd", "file", b"root")])
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "pwsh.tar.gz"
            path.write_bytes(archive)
            stage = Path(scratch) / "stage"
            stage.mkdir()
            with self.assertRaisesRegex(ValueError, "Unsafe PowerShell archive member name"):
                pwsh._extract_archive(path, stage)

    def test_extraction_refuses_a_repeated_member_path(self):
        archive = tar_bytes([("pwsh", "exec", elf64_header()), ("pwsh", "file", b"second")])
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "pwsh.tar.gz"
            path.write_bytes(archive)
            stage = Path(scratch) / "stage"
            stage.mkdir()
            with self.assertRaisesRegex(ValueError, "repeats a member path"):
                pwsh._extract_archive(path, stage)

    def test_extraction_refuses_a_special_file_member(self):
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode="w:gz") as tf:
            info = tarfile.TarInfo("devnull")
            info.type = tarfile.CHRTYPE
            info.devmajor, info.devminor = 1, 3
            tf.addfile(info)
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "pwsh.tar.gz"
            path.write_bytes(raw.getvalue())
            stage = Path(scratch) / "stage"
            stage.mkdir()
            with self.assertRaisesRegex(ValueError, "regular file or directory"):
                pwsh._extract_archive(path, stage)

    def test_extraction_writes_files_directories_and_modes(self):
        archive = tar_bytes([
            ("Modules", "dir", None),
            ("Modules/PSReadLine.psd1", "file", b"module"),
            ("pwsh", "exec", elf64_header()),
        ])
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "pwsh.tar.gz"
            path.write_bytes(archive)
            stage = Path(scratch) / "stage"
            stage.mkdir()
            pwsh._extract_archive(path, stage)
            self.assertTrue((stage / "Modules").is_dir())
            self.assertEqual((stage / "Modules" / "PSReadLine.psd1").read_bytes(), b"module")
            self.assertEqual((stage / "pwsh").read_bytes(), elf64_header())
            if os.name == "posix":
                self.assertEqual(stat.S_IMODE((stage / "Modules" / "PSReadLine.psd1").stat().st_mode), 0o644)
                self.assertEqual(stat.S_IMODE((stage / "pwsh").stat().st_mode), 0o755)


class PowerShellBinaryTests(unittest.TestCase):
    def test_refuses_a_non_elf_file(self):
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "pwsh"
            path.write_bytes(b"#!/bin/sh\necho not elf\n" + b"\x00" * 64)
            with self.assertRaisesRegex(RuntimeError, "not a complete x86_64 ELF64"):
                pwsh._check_elf(path)

    def test_accepts_an_elf64_executable(self):
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "pwsh"
            path.write_bytes(elf64_header())
            pwsh._check_elf(path)


class PowerShellDownloadGuardTests(unittest.TestCase):
    def test_refuses_a_non_official_archive_url(self):
        with self.assertRaisesRegex(RuntimeError, "Refusing non-official"):
            pwsh._download_archive("https://attacker.invalid/powershell.tar.gz", Path("unused"))

    def test_refuses_a_foreign_redirect_target(self):
        handler = pwsh._ArchiveRedirects()
        with self.assertRaisesRegex(RuntimeError, "Refusing non-official"):
            handler.redirect_request(None, None, 302, "Found", {}, "https://attacker.invalid/x")

    def test_refuses_a_redirect_that_does_not_point_at_a_release_asset(self):
        handler = pwsh._ArchiveRedirects()
        request = _FakeRequest(LINUX_URL)
        with self.assertRaisesRegex(RuntimeError, "Refusing non-official"):
            handler.redirect_request(request, None, 302, "Found", {},
                                     "https://release-assets.githubusercontent.com/not-an-asset")

    def test_refuses_a_redirect_that_does_not_come_from_github(self):
        handler = pwsh._ArchiveRedirects()
        request = _FakeRequest("https://attacker.invalid/powershell.tar.gz")
        with self.assertRaisesRegex(RuntimeError, "Refusing non-official"):
            handler.redirect_request(request, None, 302, "Found", {},
                                     "https://release-assets.githubusercontent.com/github-production-release-asset/1/x?sig=1")


@unittest.skipUnless(os.name == "posix", "Linux renameat2 publication is POSIX only")
class PowerShellInstallTests(unittest.TestCase):
    """End-to-end publication on a POSIX host with a stubbed download."""

    def setUp(self):
        self.payload = tar_bytes([
            ("Modules", "dir", None),
            ("Modules/PSReadLine.psd1", "file", b"module"),
            ("pwsh", "exec", elf64_header()),
        ])
        self.release = resolve_with()

    def _install(self, destination, payload=None, digest=None):
        body = payload if payload is not None else self.payload
        calls = {"count": 0}

        def fake_download(url, target):
            calls["count"] += 1
            target.write_bytes(body)
            return len(body), (digest or pwsh.hashlib.sha256(body).hexdigest())

        with patch.object(pwsh, "_download_archive", side_effect=fake_download), \
             patch.object(pwsh, "runtime_check", return_value="9.8.7"):
            return pwsh.install_release(self.release, destination), calls

    def test_publishes_the_tree_and_keeps_the_destination_exclusive(self):
        with tempfile.TemporaryDirectory() as scratch:
            destination = Path(scratch) / "pwsh"
            result, calls = self._install(destination)
            self.assertEqual(calls["count"], 1)
            self.assertTrue((destination / "pwsh").is_file())
            self.assertTrue((destination / "Modules" / "PSReadLine.psd1").is_file())
            self.assertEqual(result["pwsh_version"], "9.8.7")
            self.assertEqual(result["version"], VERSION)
            self.assertTrue(pwsh.is_installed(destination))

    def test_refuses_a_destination_that_already_exists(self):
        with tempfile.TemporaryDirectory() as scratch:
            destination = Path(scratch) / "pwsh"
            destination.mkdir()
            with self.assertRaisesRegex(ValueError, "Refusing existing or symlink"):
                self._install(destination)

    def test_refuses_a_sha256_mismatch(self):
        with tempfile.TemporaryDirectory() as scratch:
            destination = Path(scratch) / "pwsh"
            with self.assertRaisesRegex(RuntimeError, "SHA256 mismatch"):
                self._install(destination, digest="0" * 64)
            self.assertFalse(destination.exists())

    def test_refuses_a_size_mismatch(self):
        self.release["size"] = str(len(self.payload) + 1)
        with tempfile.TemporaryDirectory() as scratch:
            destination = Path(scratch) / "pwsh"
            with self.assertRaisesRegex(RuntimeError, "size mismatch"):
                self._install(destination)
            self.assertFalse(destination.exists())

    def test_a_failed_install_leaves_no_staging_directory_behind(self):
        with tempfile.TemporaryDirectory() as scratch:
            destination = Path(scratch) / "pwsh"
            with self.assertRaises(RuntimeError):
                self._install(destination, digest="0" * 64)
            leftovers = [p.name for p in Path(scratch).iterdir()]
            self.assertEqual(leftovers, [])


if __name__ == "__main__":
    unittest.main()
