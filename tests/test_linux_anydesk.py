import hashlib
import io
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import anydesk_linux as ad


class Response:
    def __init__(self, data, headers=None):
        self.stream = io.BytesIO(data)
        self.headers = headers or {}
        self.closed = False

    def read(self, amount=-1):
        return self.stream.read(amount)

    def close(self):
        self.closed = True


class AnyDeskLinuxTests(unittest.TestCase):
    def stanza(self, **overrides):
        data = {
            "Package": "anydesk", "Architecture": "amd64", "Version": "8.1.0",
            "Filename": "pool/main/a/anydesk/anydesk_8.1.0_amd64.deb",
            "Size": "4", "SHA256": "a" * 64,
        }
        data.update(overrides)
        return "\n".join(f"{k}: {v}" for k, v in data.items())

    def release(self, payload=b"test"):
        return {
            "version": "8.1.0", "url": ad.OFFICIAL_BASE + "pool/main/a/anydesk/anydesk_8.1.0_amd64.deb",
            "sha256": hashlib.sha256(payload).hexdigest(), "size": str(len(payload)),
            "checksum_source": ad.METADATA_URL, "terms_url": ad.TERMS_URL,
        }

    def test_valid_metadata_resolves_dynamic_release(self):
        response = Response((self.stanza(Size="4", Version="9.2.3", Filename="pool/main/a/anydesk/anydesk_9.2.3_amd64.deb") + "\n").encode())
        with patch.object(ad, "_open_url", return_value=response) as opened:
            release = ad.resolve_release("x86_64")
        self.assertEqual(release["version"], "9.2.3")
        self.assertEqual(release["size"], "4")
        opened.assert_called_once_with(ad.METADATA_URL, limit=ad.METADATA_LIMIT)

    def test_bad_missing_and_ambiguous_metadata_fail_closed(self):
        for raw in ("Package: anydesk\nArchitecture: amd64\n", self.stanza(SHA256="bad"),
                    self.stanza() + "\n\n" + self.stanza(Version="8.1.1", Filename="pool/main/a/anydesk/anydesk_8.1.1_amd64.deb")):
            with self.subTest(raw=raw), patch.object(ad, "_open_url", return_value=Response(raw.encode())):
                with self.assertRaises(RuntimeError):
                    ad.resolve_release("x86_64")

    def test_unsupported_architecture_does_not_network(self):
        with patch.object(ad, "_open_url") as opened:
            with self.assertRaisesRegex(RuntimeError, "Unsupported architecture"):
                ad.resolve_release("aarch64")
        opened.assert_not_called()

    def test_release_url_validation_rejects_foreign_credentials_port_path_and_query(self):
        for url in (
            "https://evil.example/pool/main/a/anydesk/anydesk_8.1.0_amd64.deb",
            "https://user:pass@deb.anydesk.com/pool/main/a/anydesk/anydesk_8.1.0_amd64.deb",
            "https://deb.anydesk.com:443/pool/main/a/anydesk/anydesk_8.1.0_amd64.deb",
            "https://deb.anydesk.com/tmp/anydesk_8.1.0_amd64.deb",
            "https://deb.anydesk.com/pool/main/a/anydesk/anydesk_8.1.0_amd64.deb?x=1",
        ):
            bad = self.release(); bad["url"] = url
            with self.subTest(url=url), self.assertRaises(ValueError):
                ad.validate_install(bad, accepted_terms=True, allow_service=True)

    def test_both_install_gates_are_required_without_io(self):
        release = self.release()
        with patch.object(ad, "_open_url") as opened:
            with self.assertRaisesRegex(PermissionError, "terms"):
                ad.validate_install(release, allow_service=True)
            with self.assertRaisesRegex(PermissionError, "service"):
                ad.validate_install(release, accepted_terms=True)
        opened.assert_not_called()

    def test_checksum_and_size_mismatch_never_run_runner(self):
        payload = b"test"
        for release in (dict(self.release(payload), sha256="b" * 64), dict(self.release(payload), size="5")):
            runner = Mock()
            with patch.object(ad, "_open_url", return_value=Response(payload)):
                with self.subTest(release=release), self.assertRaisesRegex(RuntimeError, "mismatch"):
                    ad.install_release(release, accepted_terms=True, allow_service=True, runner=runner)
            runner.assert_not_called()

    def test_success_uses_absolute_deb_and_cleans_private_directory(self):
        payload = b"test"
        release = self.release(payload)
        runner = Mock(return_value=subprocess.CompletedProcess([], 0))
        observed = {}

        def capture(command, **kwargs):
            observed["command"] = command
            observed["kwargs"] = kwargs
            observed["path"] = command[-1]
            observed["exists"] = os.path.exists(command[-1])
            observed["mode"] = os.stat(Path(command[-1]).parent).st_mode & 0o777
            return subprocess.CompletedProcess(command, 0)

        with patch.object(ad, "_open_url", return_value=Response(payload)), patch.object(ad.os, "geteuid", return_value=0):
            ad.install_release(release, accepted_terms=True, allow_service=True, runner=capture)
        self.assertEqual(observed["command"][:3], ["apt-get", "install", "-y"])
        self.assertTrue(observed["path"].startswith("/tmp/anydesk-"))
        self.assertTrue(observed["exists"])
        self.assertEqual(observed["mode"], 0o700)
        self.assertEqual(observed["kwargs"], {"check": False, "shell": False, "timeout": 300})
        self.assertFalse(os.path.exists(observed["path"]))

    def test_foreign_redirect_is_rejected_and_limits_are_enforced(self):
        with self.assertRaisesRegex(RuntimeError, "non-official"):
            ad._OfficialRedirectHandler().redirect_request(Mock(), Mock(), 302, "Found", {}, "https://evil.example/x")
        with self.assertRaisesRegex(RuntimeError, "limit"):
            ad._read_bounded(Response(b"12345"), 4)
        with self.assertRaisesRegex(RuntimeError, "limit"):
            with patch.object(ad.urllib.request, "build_opener", return_value=Mock(open=Mock(return_value=Response(b"", {"Content-Length": str(ad.METADATA_LIMIT + 1)})))):
                ad._open_url(ad.METADATA_URL, limit=ad.METADATA_LIMIT)


if __name__ == "__main__":
    unittest.main()
