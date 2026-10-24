import json
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, call, patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import ngrok_linux as ngrok


VERSION = "3.4.5"
WINDOWS_SHA = "a" * 64
LINUX_SHA = "b" * 64
WINDOWS_URL = f"https://bin.ngrok.com/a/SyntheticWin/ngrok-v3-{VERSION}-windows-amd64.zip"
LINUX_URL = f"https://bin.ngrok.com/a/SyntheticLinux/ngrok-v3-{VERSION}-linux-amd64.tar.gz"


def manifest(version=VERSION, url=WINDOWS_URL, digest=WINDOWS_SHA):
    return json.dumps({
        "version": version,
        "architecture": {"64bit": {"url": url, "hash": digest}},
    }).encode()


def entry(url, archive, digest, arch="64-bit", label="SHA256"):
    return (
        '<div class="link"><div><a class="btn download" href="' + url + '"></a></div>'
        '<div class="archive">' + archive + '</div><div class="arch">' + arch + '</div>'
        '<div class="sha"><input type="text" readonly value="' + digest + '"></div>'
        '<div class="checksum-label">' + label + '</div></div>'
    )


def platform(name, records):
    return (
        '<div class="platform archive"><div class="logo"><span>' + name + '</span></div>'
        '<div class="links">' + "".join(records) + '</div></div>'
    )


def archive_page(version=VERSION, linux_url=LINUX_URL, linux_sha=LINUX_SHA,
                 windows_url=WINDOWS_URL, windows_sha=WINDOWS_SHA,
                 extra_linux=(), linux_format=".tar.gz", linux_arch="64-bit", linux_label="SHA256"):
    return (
        '<html><body><div class="release"><h2>Version ' + version + '</h2>'
        + platform("Windows", [entry(windows_url, ".zip", windows_sha)])
        + platform("Linux", [entry(linux_url, linux_format, linux_sha, linux_arch, linux_label), *extra_linux])
        + '</div></body></html>'
    ).encode()


class NgrokMetadataTests(unittest.TestCase):
    def resolve(self, manifest_bytes=None, html_bytes=None, architecture="x86_64"):
        manifest_bytes = manifest_bytes if manifest_bytes is not None else manifest()
        html_bytes = html_bytes if html_bytes is not None else archive_page()
        responses = {ngrok.SCOOP_MANIFEST: manifest_bytes, ngrok.ARCHIVE_INDEX: html_bytes}
        with patch.object(ngrok, "_fetch_metadata", side_effect=lambda url: responses[url]) as fetch:
            result = ngrok.build_dry_plan(architecture)
        return result, fetch

    def test_exact_windows_linux_version_and_checksums_are_metadata_only(self):
        result, fetch = self.resolve()
        self.assertEqual(fetch.call_args_list, [call(ngrok.SCOOP_MANIFEST), call(ngrok.ARCHIVE_INDEX)])
        self.assertEqual(result["status"], "dry-only")
        self.assertFalse(result["executable"])
        self.assertEqual(result["proposed_command"], [])
        self.assertEqual(result["package"]["version"], VERSION)
        self.assertFalse(result["package"]["version_is_user_pinned"])
        self.assertEqual(result["windows_manifest_observation"]["sha256"], WINDOWS_SHA)
        self.assertEqual(result["linux_archive_candidate"]["url"], LINUX_URL)
        self.assertEqual(result["linux_archive_candidate"]["sha256"], LINUX_SHA)
        self.assertFalse(result["installation"]["enabled"])
        self.assertFalse(result["installation"]["account_or_agent_config_read"])
        self.assertTrue(result["execution_blockers"])
        self.assertIn("no Linux archive bytes", result["artifact_review"])
        self.assertNotIn(LINUX_URL, [item.args[0] for item in fetch.call_args_list])

    def test_default_scope_never_accepts_nonmetadata_urls(self):
        with self.assertRaisesRegex(ValueError, "non-metadata"):
            ngrok._fetch_metadata(LINUX_URL)
        with self.assertRaisesRegex(ValueError, "non-metadata"):
            ngrok._fetch_metadata([])

    def test_metadata_fetch_rejects_oversize_before_reading_body(self):
        response = MagicMock()
        response.geturl.return_value = ngrok.SCOOP_MANIFEST
        response.headers = {"Content-Length": str(ngrok.SCOOP_LIMIT + 1)}
        response.__enter__.return_value = response
        opener = MagicMock()
        opener.open.return_value = response
        with patch.object(ngrok.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "size limit"):
                ngrok._fetch_metadata(ngrok.SCOOP_MANIFEST)
        response.read.assert_not_called()

    def test_metadata_fetch_bounds_stream_without_content_length(self):
        response = MagicMock()
        response.geturl.return_value = ngrok.SCOOP_MANIFEST
        response.headers = {}
        response.__enter__.return_value = response
        response.read.side_effect = [b"x" * 65536] * 16 + [b"x"]
        opener = MagicMock()
        opener.open.return_value = response
        with patch.object(ngrok.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "size limit"):
                ngrok._fetch_metadata(ngrok.SCOOP_MANIFEST)
        self.assertEqual(sum(item.args[0] for item in response.read.call_args_list), ngrok.SCOOP_LIMIT + 1)

    def test_metadata_fetch_sanitizes_transport_failure(self):
        marker = "synthetic-secret-marker-not-for-output"
        opener = MagicMock()
        opener.open.side_effect = OSError(marker)
        with patch.object(ngrok.urllib.request, "build_opener", return_value=opener):
            with self.assertRaises(RuntimeError) as caught:
                ngrok._fetch_metadata(ngrok.SCOOP_MANIFEST)
        self.assertNotIn(marker, str(caught.exception))

    def test_metadata_fetch_sanitizes_body_read_failure(self):
        marker = "synthetic-read-error-not-for-output"
        response = MagicMock()
        response.geturl.return_value = ngrok.SCOOP_MANIFEST
        response.headers = {}
        response.__enter__.return_value = response
        response.read.side_effect = OSError(marker)
        opener = MagicMock()
        opener.open.return_value = response
        with patch.object(ngrok.urllib.request, "build_opener", return_value=opener):
            with self.assertRaises(RuntimeError) as caught:
                ngrok._fetch_metadata(ngrok.SCOOP_MANIFEST)
        self.assertNotIn(marker, str(caught.exception))

    def test_metadata_fetch_redirect_handler_refuses_redirects(self):
        with self.assertRaisesRegex(RuntimeError, "redirect refused"):
            ngrok._NoRedirect().redirect_request(None, None, 302, "Found", {}, "https://example.invalid/")

    def test_architecture_is_rejected_before_network(self):
        with patch.object(ngrok, "_fetch_metadata") as fetch:
            with self.assertRaisesRegex(ValueError, "x86_64"):
                ngrok.build_dry_plan("aarch64")
        fetch.assert_not_called()

    def test_version_mismatch_fails_closed(self):
        with patch.object(ngrok, "_fetch_metadata", side_effect=[manifest(), archive_page("3.4.6")]):
            with self.assertRaisesRegex(ValueError, "missing or ambiguous"):
                ngrok.build_dry_plan("x86_64")

    def test_truncated_unbalanced_and_nested_archive_documents_fail_closed(self):
        good = archive_page().decode()
        malformed = (
            good.removesuffix("</body></html>"),
            good.replace("</div></body></html>", "</body></html>", 1),
            good.replace("<body>", '<body><div class="wrapper">', 1),
            good.replace('<div class="release">', '<div class="release"><div class="release">', 1),
        )
        for page in malformed:
            with self.subTest(page=page[-80:]), patch.object(ngrok, "_fetch_metadata", side_effect=[manifest(), page.encode()]):
                with self.assertRaises(ValueError):
                    ngrok.build_dry_plan("x86_64")

    def test_duplicate_html_attributes_and_metadata_fields_fail_closed(self):
        good = archive_page().decode()
        duplicate_href = good.replace(
            f'href="{WINDOWS_URL}"',
            f'href="{WINDOWS_URL}" href="https://evil.example/ambiguous.zip"',
            1,
        )
        duplicate_archive = good.replace(
            '<div class="archive">.zip</div><div class="arch">64-bit</div>',
            '<div class="archive">.zip</div><div class="archive">.zip</div><div class="arch">64-bit</div>',
            1,
        )
        for page in (duplicate_href, duplicate_archive):
            with self.subTest(page=page[-100:]), patch.object(ngrok, "_fetch_metadata", side_effect=[manifest(), page.encode()]):
                with self.assertRaises(ValueError):
                    ngrok.build_dry_plan("x86_64")

    def test_scoop_windows_checksum_must_match_official_index(self):
        mismatched = "c" * 64
        with patch.object(ngrok, "_fetch_metadata", side_effect=[manifest(digest=mismatched), archive_page()]):
            with self.assertRaisesRegex(ValueError, "disagrees"):
                ngrok.build_dry_plan("x86_64")

    def test_scoop_manifest_requires_exact_version_and_windows_asset(self):
        for bad in (
            manifest(version="latest"),
            manifest(url="https://evil.example/a/Synthetic/ngrok-v3-3.4.5-windows-amd64.zip"),
            manifest(digest="not-a-sha256"),
        ):
            with patch.object(ngrok, "_fetch_metadata", return_value=bad):
                with self.assertRaises(ValueError):
                    ngrok.build_dry_plan("x86_64")

    def test_linux_candidate_url_and_digest_must_be_vendor_bound(self):
        cases = (
            ("https://evil.example/a/Synthetic/ngrok-v3-3.4.5-linux-amd64.tar.gz", LINUX_SHA),
            ("https://bin.ngrok.com/a/Synthetic/ngrok-v3-3.4.6-linux-amd64.tar.gz", LINUX_SHA),
            (LINUX_URL, "bad-digest"),
        )
        for url, digest in cases:
            with self.subTest(url=url, digest=digest):
                with patch.object(ngrok, "_fetch_metadata", side_effect=[manifest(), archive_page(linux_url=url, linux_sha=digest)]):
                    with self.assertRaises(ValueError):
                        ngrok.build_dry_plan("x86_64")

    def test_target_must_be_linux_amd64_tar_gz_and_sha256(self):
        for kwargs in (
            {"linux_format": ".zip"},
            {"linux_arch": "ARM64"},
            {"linux_label": "SHA512"},
        ):
            with self.subTest(kwargs=kwargs):
                with patch.object(ngrok, "_fetch_metadata", side_effect=[manifest(), archive_page(**kwargs)]):
                    with self.assertRaises(ValueError):
                        ngrok.build_dry_plan("x86_64")

    def test_duplicate_linux_candidate_is_ambiguous(self):
        duplicate = entry("https://bin.ngrok.com/a/Other/ngrok-v3-3.4.5-linux-amd64.tar.gz", ".tar.gz", "c" * 64)
        with patch.object(ngrok, "_fetch_metadata", side_effect=[manifest(), archive_page(extra_linux=[duplicate])]):
            with self.assertRaisesRegex(ValueError, "ambiguous"):
                ngrok.build_dry_plan("x86_64")

    def test_error_does_not_echo_malformed_manifest_or_page_payload(self):
        private_marker = "synthetic-never-echo-7f48"
        with patch.object(ngrok, "_fetch_metadata", return_value=(private_marker + "\n").encode()):
            with self.assertRaises(ValueError) as caught:
                ngrok.build_dry_plan("x86_64")
        self.assertNotIn(private_marker, str(caught.exception))


if __name__ == "__main__":
    unittest.main()
