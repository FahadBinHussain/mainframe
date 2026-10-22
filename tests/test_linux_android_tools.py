import hashlib
import io
import json
import os
import stat
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import android_commandline_tools as act

VERSION = "12345678"
WIN = f"https://dl.google.com/android/repository/commandlinetools-win-{VERSION}_latest.zip"
LINUX = f"https://dl.google.com/android/repository/commandlinetools-linux-{VERSION}_latest.zip"
WIN_HASH = "a" * 64
LINUX_HASH = "b" * 64


def response(data):
    return io.BytesIO(data)


def manifest():
    return json.dumps({"version": VERSION, "url": WIN, "hash": WIN_HASH}).encode()


def page(name=LINUX.rsplit("/", 1)[1], checksum=LINUX_HASH, modal_url=LINUX):
    return ("<html><table><tr><th>Platform</th><th>SDK tools package</th><th>SHA-256 checksum</th></tr>"
            f"<tr><td>Linux</td><td><button data-modal-dialog-id=\"sdk_linux_download\">{name}</button></td><td>{checksum}</td></tr>"
            f"</table><div id=\"sdk_linux_download\"><div><a href=\"{modal_url}\">download</a></div></div></html>").encode()


def make_zip(*, unsafe=False, symlink=False):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as z:
        if unsafe:
            z.writestr("cmdline-tools/bin/../escape", b"x")
        else:
            for name, data in {
                "cmdline-tools/bin/sdkmanager": b"#!/bin/sh\n",
                "cmdline-tools/lib/tool.jar": b"jar",
                "cmdline-tools/source.properties": b"Pkg.Revision=1\n",
                "cmdline-tools/NOTICE": b"notice",
            }.items():
                info = zipfile.ZipInfo(name)
                info.external_attr = (0o100755 if name.endswith("sdkmanager") else 0o100644) << 16
                z.writestr(info, data)
        if symlink:
            info = zipfile.ZipInfo("cmdline-tools/link")
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(info, b"sdkmanager")
    return stream.getvalue()


class AndroidToolsTests(unittest.TestCase):
    def test_resolve_parses_official_manifest_and_linux_table(self):
        with patch.object(act, "_open_url", side_effect=[response(manifest()), response(page())]):
            result = act.resolve_release("x86_64")
        self.assertEqual(result["version"], VERSION)
        self.assertEqual(result["url"], LINUX)
        self.assertEqual(result["sha256"], LINUX_HASH)
        self.assertEqual(result["manifest_source"], act.MANIFEST_SOURCE)

    def test_architecture_rejected_before_network(self):
        with patch.object(act, "_open_url") as opened:
            with self.assertRaisesRegex(ValueError, "only x86_64"):
                act.resolve_release("aarch64")
        opened.assert_not_called()

    def test_metadata_version_and_checksum_fail_loudly(self):
        cases = [page(name=f"commandlinetools-linux-99999999_latest.zip"),
                 page(checksum="b" * 63),
                 page(checksum=LINUX_HASH + " " + "c" * 64)]
        for body in cases:
            with self.subTest(body=body), patch.object(act, "_open_url", side_effect=[response(manifest()), response(body)]):
                with self.assertRaises(ValueError):
                    act.resolve_release("x86_64")

    def test_metadata_requires_one_matching_modal_url(self):
        cases = [
            page(modal_url="https://evil.example/android/repository/" + LINUX.rsplit("/", 1)[1]),
            page(modal_url=LINUX + "?download=1"),
            page(modal_url=LINUX.replace("12345678", "99999999")),
        ]
        for body in cases:
            with self.subTest(body=body), patch.object(act, "_open_url", side_effect=[response(manifest()), response(body)]):
                with self.assertRaises(ValueError):
                    act.resolve_release("x86_64")
        duplicate = page().replace(b'</div></html>', f'<a href="{LINUX}">again</a></div></html>'.encode())
        with patch.object(act, "_open_url", side_effect=[response(manifest()), response(duplicate)]):
            with self.assertRaises(ValueError):
                act.resolve_release("x86_64")

    def test_official_url_rejects_credentials_ports_and_noncanonical_paths(self):
        for url in (LINUX.replace("https://", "https://u:p@"), LINUX.replace("dl.google.com", "dl.google.com:443"), LINUX.replace("/android/repository/", "/other/")):
            self.assertFalse(act._official_archive(url, "linux", VERSION))

    def test_manifest_source_and_url_validation(self):
        bad = {"version": VERSION, "url": WIN.replace("dl.google.com", "evil.example"), "hash": WIN_HASH}
        with patch.object(act, "_open_url", return_value=response(json.dumps(bad).encode())):
            with self.assertRaises(ValueError): act.resolve_release("x86_64")

    def test_terms_gate_happens_before_release_or_filesystem(self):
        with tempfile.TemporaryDirectory() as d, patch.object(act, "_validate_release") as validate, patch.object(act, "_open_url") as opened:
            root = Path(d) / "sdk"
            with self.assertRaises(PermissionError): act.install_release({}, root, False)
            with self.assertRaises(PermissionError): act.validate_install({}, root, False)
        validate.assert_not_called(); opened.assert_not_called(); self.assertFalse(root.exists())

    def test_validate_install_is_side_effect_free_and_requires_new_root(self):
        release = {"version": VERSION, "url": LINUX, "sha256": LINUX_HASH,
                   "manifest_source": act.MANIFEST_SOURCE, "checksum_source": act.METADATA_SOURCE,
                   "terms_url": act.TERMS_URL}
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "sdk"
            act.validate_install(release, root, True)
            self.assertFalse(root.exists())
            root.mkdir()
            with self.assertRaises(FileExistsError): act.validate_install(release, root, True)

    def test_checksum_mismatch_leaves_no_root(self):
        archive = make_zip()
        release = {"version": VERSION, "url": LINUX, "sha256": "0" * 64,
                   "manifest_source": act.MANIFEST_SOURCE, "checksum_source": act.METADATA_SOURCE,
                   "terms_url": act.TERMS_URL}
        with tempfile.TemporaryDirectory() as d, patch.object(act, "_open_url", return_value=response(archive)):
            with self.assertRaisesRegex(ValueError, "checksum"):
                act.install_release(release, Path(d) / "sdk", True)
            self.assertEqual(list(Path(d).iterdir()), [])

    def test_archive_download_size_limit_cleans_up_without_installing(self):
        archive = make_zip()
        release = {"version": VERSION, "url": LINUX, "sha256": hashlib.sha256(archive).hexdigest(),
                   "manifest_source": act.MANIFEST_SOURCE, "checksum_source": act.METADATA_SOURCE,
                   "terms_url": act.TERMS_URL}
        with tempfile.TemporaryDirectory() as d, patch.object(act, "_open_url", return_value=response(archive)), patch.object(act, "_ARCHIVE_MAX", 8):
            with self.assertRaisesRegex(ValueError, "size limit"):
                act.install_release(release, Path(d) / "sdk", True)
            self.assertEqual(list(Path(d).iterdir()), [])

    def test_source_properties_is_required_before_extraction(self):
        original = io.BytesIO(make_zip())
        reduced = io.BytesIO()
        with zipfile.ZipFile(original) as src, zipfile.ZipFile(reduced, "w") as dst:
            for member in src.infolist():
                if not member.filename.endswith("source.properties"):
                    dst.writestr(member, src.read(member))
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaisesRegex(ValueError, "required"):
                act._extract_verified(reduced.getvalue(), Path(d))
            self.assertEqual(list(Path(d).iterdir()), [])

    def test_secure_install_layout_and_executable_bits(self):
        archive = make_zip()
        release = {"version": VERSION, "url": LINUX, "sha256": hashlib.sha256(archive).hexdigest(),
                   "manifest_source": act.MANIFEST_SOURCE, "checksum_source": act.METADATA_SOURCE,
                   "terms_url": act.TERMS_URL}
        with tempfile.TemporaryDirectory() as d, patch.object(act, "_open_url", return_value=response(archive)):
            root = Path(d) / "sdk"
            act.install_release(release, root, True)
            self.assertTrue((root / "cmdline-tools/latest/bin/sdkmanager").is_file())
            self.assertTrue(os.access(root / "cmdline-tools/latest/bin/sdkmanager", os.X_OK))
            self.assertTrue((root / "cmdline-tools/latest/lib/tool.jar").is_file())
            self.assertTrue((root / "platform-tools").is_dir())

    def test_unsafe_zip_and_symlink_are_rejected_without_root(self):
        release_base = {"version": VERSION, "url": LINUX,
                        "manifest_source": act.MANIFEST_SOURCE, "checksum_source": act.METADATA_SOURCE,
                        "terms_url": act.TERMS_URL}
        for archive in (make_zip(unsafe=True), make_zip(symlink=True)):
            release = {**release_base, "sha256": hashlib.sha256(archive).hexdigest()}
            with tempfile.TemporaryDirectory() as d, patch.object(act, "_open_url", return_value=response(archive)):
                with self.assertRaises(ValueError): act.install_release(release, Path(d) / "sdk", True)
                self.assertFalse((Path(d) / "sdk").exists())

    def test_install_never_executes_or_writes_license(self):
        archive = make_zip()
        release = {"version": VERSION, "url": LINUX, "sha256": hashlib.sha256(archive).hexdigest(),
                   "manifest_source": act.MANIFEST_SOURCE, "checksum_source": act.METADATA_SOURCE,
                   "terms_url": act.TERMS_URL}
        with tempfile.TemporaryDirectory() as d, patch.object(act, "_open_url", return_value=response(archive)):
            root = Path(d) / "sdk"
            act.install_release(release, root, True)
            self.assertFalse((root / "licenses").exists())
            self.assertFalse((root / "cmdline-tools/latest/bin/sdkmanager").read_bytes().startswith(b"executed"))

    def test_notice_txt_is_accepted_and_lib_must_be_nonempty(self):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as z:
            for name, data, mode in (
                ("cmdline-tools/bin/sdkmanager", b"#!/bin/sh\n", 0o100755),
                ("cmdline-tools/lib/tool.jar", b"jar", 0o100644),
                ("cmdline-tools/source.properties", b"Pkg.Revision=1\n", 0o100644),
                ("cmdline-tools/NOTICE.txt", b"notice", 0o100644),
            ):
                info = zipfile.ZipInfo(name)
                info.external_attr = mode << 16
                z.writestr(info, data)
        with tempfile.TemporaryDirectory() as d:
            act._extract_verified(stream.getvalue(), Path(d))
            self.assertTrue((Path(d) / "cmdline-tools/NOTICE.txt").is_file())

        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as z:
            for name, data, mode in (
                ("cmdline-tools/bin/sdkmanager", b"x", 0o100755),
                ("cmdline-tools/lib/empty.jar", b"", 0o100644),
                ("cmdline-tools/NOTICE", b"notice", 0o100644),
            ):
                info = zipfile.ZipInfo(name)
                info.external_attr = mode << 16
                z.writestr(info, data)
        with tempfile.TemporaryDirectory() as d, self.assertRaises(ValueError):
            act._extract_verified(stream.getvalue(), Path(d))

    def test_zip_normalizes_duplicates_ancestors_special_files_and_expansion(self):
        cases = []
        for names in (
            [("cmdline-tools/bin/sdkmanager", b"x", 0o100755), ("cmdline-tools//bin/sdkmanager", b"x", 0o100755)],
            [("cmdline-tools", b"file", 0o100644), ("cmdline-tools/bin/sdkmanager", b"x", 0o100755)],
            [("cmdline-tools/bin/sdkmanager", b"x", 0o100755), ("cmdline-tools/lib/tool.jar", b"x", 0o100644), ("cmdline-tools/NOTICE", b"x", 0o100644)],
        ):
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, "w") as z:
                for name, data, mode in names:
                    info = zipfile.ZipInfo(name)
                    info.external_attr = ((stat.S_IFIFO | 0o644) if name.endswith("tool.jar") and len(names) == 3 else mode) << 16
                    z.writestr(info, data)
            cases.append(stream.getvalue())
        for archive in cases:
            with tempfile.TemporaryDirectory() as d, self.assertRaises(ValueError):
                act._extract_verified(archive, Path(d))

        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as z:
            for name, data, mode in (("cmdline-tools/bin/sdkmanager", b"x", 0o100755), ("cmdline-tools/lib/tool.jar", b"long", 0o100644), ("cmdline-tools/NOTICE", b"x", 0o100644)):
                info = zipfile.ZipInfo(name)
                info.external_attr = mode << 16
                z.writestr(info, data)
        with tempfile.TemporaryDirectory() as d, patch.object(act, "_EXTRACTED_MAX", 2):
            with self.assertRaises(ValueError):
                act._extract_verified(stream.getvalue(), Path(d))

    def test_streaming_extraction_enforces_declared_expanded_cap(self):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as z:
            for name, data, mode in (("cmdline-tools/bin/sdkmanager", b"x", 0o100755), ("cmdline-tools/lib/tool.jar", b"123", 0o100644), ("cmdline-tools/NOTICE", b"x", 0o100644)):
                info = zipfile.ZipInfo(name); info.external_attr = mode << 16; info.file_size = 10
                z.writestr(info, data)
        with tempfile.TemporaryDirectory() as d, patch.object(act, "_EXTRACTED_MAX", 2):
            with self.assertRaises(ValueError):
                act._extract_verified(io.BytesIO(stream.getvalue()), Path(d))

    def test_root_rejects_lexical_parent_and_symlink_ancestor(self):
        release = {"version": VERSION, "url": LINUX, "sha256": LINUX_HASH,
                   "manifest_source": act.MANIFEST_SOURCE, "checksum_source": act.METADATA_SOURCE,
                   "terms_url": act.TERMS_URL}
        with tempfile.TemporaryDirectory() as d:
            base = Path(d) / "base"
            base.mkdir()
            with self.assertRaises(ValueError):
                act.validate_install(release, base / ".." / "sdk", True)
            link = Path(d) / "link"
            link.symlink_to(base, target_is_directory=True)
            with self.assertRaises(ValueError):
                act.validate_install(release, link / "sdk", True)


if __name__ == "__main__":
    unittest.main()
