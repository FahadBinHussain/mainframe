"""Synthetic source/archive fixtures only: no downloads or executable invocation."""
import base64
import copy
import gzip
import hashlib
import io
import os
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import google_workspace_cli_linux as g

VERSION = "1.2.3"
INTEGRITY = "sha512-" + base64.b64encode(hashlib.sha512(b"package").digest()).decode()


def elf(e_type=2):
    data = bytearray(64)
    data[:7] = b"\x7fELF" + bytes((2, 1, 1))
    for start, end, value in ((16, 18, e_type), (18, 20, 62), (20, 24, 1), (52, 54, 64)):
        data[start:end] = value.to_bytes(end - start, "little")
    return bytes(data) + b"inert-fixture-never-executed"


def archive(names=None, *, root=True, special=None, binary=None, pax=None):
    names = ["./gws", "./LICENSE", "./README.md", "./CHANGELOG.md"] if names is None else names
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz", format=tarfile.PAX_FORMAT) as tar:
        if root:
            item = tarfile.TarInfo(".")
            item.type = tarfile.DIRTYPE
            tar.addfile(item)
        for name in names:
            data = (elf() if binary is None else binary) if name.endswith("gws") else b"fixture"
            item = tarfile.TarInfo(name)
            item.size = len(data)
            if pax: item.pax_headers = pax
            if special and name == special[0]:
                item.type = special[1]
                item.linkname = "/outside/target"
                item.size = 0
                tar.addfile(item)
            else:
                tar.addfile(item, io.BytesIO(data))
    return output.getvalue()


class Response:
    def __init__(self, data):
        self.stream = io.BytesIO(data)
        self.closed = False
    def read(self, size=-1): return self.stream.read(size)
    def close(self): self.closed = True


def package():
    return {"name": g.PACKAGE, "version": VERSION,
            "repository": {"type": "git", "url": "git+" + g.REPOSITORY + ".git"},
            "bin": {"gws": "run.js"}, "engines": {"node": ">=18"},
            "scripts": {"postinstall": "node install.js"},
            "dist": {"integrity": INTEGRITY}}


def release(blob):
    tag = "v" + VERSION
    base = f"{g.REPOSITORY}/releases/download/{tag}/"
    sha = hashlib.sha256(blob).hexdigest()
    checksum = (sha + "  " + g.ASSET + "\n").encode()
    return {"package": g._package(package()), "version": VERSION, "tag": tag,
            "url": base + g.ASSET, "sha256": sha, "size": str(len(blob)),
            "asset_name": g.ASSET, "checksum_url": base + g.CHECKSUM_ASSET,
            "checksum_sha256": hashlib.sha256(checksum).hexdigest(), "checksum_size": str(len(checksum)),
            "manifest_source": f"https://registry.npmjs.org/{g.PACKAGE}/{VERSION}",
            "release_source": g.GITHUB_API + tag, "repository": g.REPOSITORY}


class GoogleWorkspaceCliTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="gws-fixture-")
        self.addCleanup(temporary.cleanup)
        self.parent = Path(temporary.name)
        # Unexpected network or process usage fails every test immediately.
        for obj, name in ((g._gh, "_open"), (g._registry, "_open"),
                          (subprocess, "run"), (subprocess, "Popen"), (os, "system")):
            guard = patch.object(obj, name, side_effect=AssertionError("network/process forbidden in fixtures"))
            guard.start()
            self.addCleanup(guard.stop)
        self.old_environment = dict(os.environ)
        self.addCleanup(lambda: self.assertEqual(dict(os.environ), self.old_environment))

    def install_fixture(self, blob, root=None, metadata=None):
        root = root or self.parent / "new"
        response = Response(blob)
        with patch.object(g._gh, "_open", return_value=response):
            result = g.install_release(metadata or release(blob), root)
        self.assertTrue(response.closed)
        return result

    def resolve_fixture(self, mutate_release=None, mutate_raw=None, mutate_planned=None, checksum=None):
        blob = archive()
        pinned = release(blob)
        checksum = checksum if checksum is not None else (pinned["sha256"] + "  " + g.ASSET + "\n").encode()
        assets = []
        for name, data, url in ((g.ASSET, blob, pinned["url"]), (g.CHECKSUM_ASSET, checksum, pinned["checksum_url"])):
            assets.append({"name": name, "browser_download_url": url,
                           "size": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest()})
        metadata = {"tag_name": "v" + VERSION, "draft": False, "prerelease": False,
                    "published_at": "2026-01-01T00:00:00Z", "assets": assets}
        raw = package()
        planned = {"name": g.PACKAGE, "version": VERSION, "source": pinned["manifest_source"], "integrity": INTEGRITY}
        if mutate_release: mutate_release(metadata)
        if mutate_raw: mutate_raw(raw)
        if mutate_planned: mutate_planned(planned)
        with patch.object(g._pnpm, "manifest", return_value=planned), patch.object(g._registry, "_json", return_value=raw), patch.object(g._gh, "_json", return_value=metadata), patch.object(g._gh, "_open", return_value=Response(checksum)) as opened:
            result = g.resolve_release("x86_64")
            opened.assert_called_once_with(pinned["checksum_url"], limit=g.METADATA_LIMIT)
        return result

    def test_exact_metadata_resolution_fetches_checksum_only_not_archive(self):
        result = self.resolve_fixture()
        self.assertEqual((result["version"], result["package"]["integrity"]), (VERSION, INTEGRITY))
        with self.assertRaises(RuntimeError): g.resolve_release("aarch64")

    def test_resolver_rejects_release_and_package_drift(self):
        changes = [lambda r: r.update(tag_name="v9.9.9"), lambda r: r.update(draft=True),
                   lambda r: r.update(prerelease=True), lambda r: r["assets"].append(r["assets"][0]),
                   lambda r: r["assets"][0].pop("digest"),
                   lambda r: r["assets"][1].update(browser_download_url="https://github.com/other/repo/file")]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(RuntimeError): self.resolve_fixture(mutate_release=change)
        for change in (lambda r: r.update(bin={"gws": "other.js"}),
                       lambda r: r.update(dependencies={"unknown": "1.0.0"}),
                       lambda r: r.update(dependencies=None),
                       lambda r: r.update(scripts={}),
                       lambda r: r.update(repository="https://evil.invalid/cli")):
            with self.subTest(change=change), self.assertRaises(RuntimeError): self.resolve_fixture(mutate_raw=change)
        with self.assertRaises(RuntimeError): self.resolve_fixture(mutate_planned=lambda r: r.update(integrity="different"))

    def test_checksum_size_hash_and_anchored_text_are_verified(self):
        sha = "a" * 64
        good = (sha + "  " + g.ASSET + "\n").encode()
        g._checksum(good, str(len(good)), hashlib.sha256(good).hexdigest(), sha)
        for raw, size, digest in ((good, str(len(good) + 1), hashlib.sha256(good).hexdigest()),
                                  (good, str(len(good)), "b" * 64)):
            with self.assertRaises(RuntimeError): g._checksum(raw, size, digest, sha)
        for bad in (good + b"junk", good + b"\n", good.replace(b"  ", b" "), good.replace(b"google-workspace", b"other"), good[:-1], b"junk " + good):
            with self.subTest(bad=bad), self.assertRaises(RuntimeError):
                g._checksum(bad, str(len(bad)), hashlib.sha256(bad).hexdigest(), sha)
        with self.assertRaises(RuntimeError): self.resolve_fixture(checksum=good + b"junk")

    def test_embedded_provenance_is_revalidated_at_install_boundary(self):
        original = release(archive())
        bad_values = [("version", "9.9.9"), ("repository", "https://evil.invalid"),
                      ("sha256", "bad"), ("size", "0001"),
                      ("url", original["url"].replace("github.com", "raw.githubusercontent.com"))]
        for key, value in bad_values:
            bad = copy.deepcopy(original); bad[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): g.validate_install(bad, self.parent / "new")
        for key, value in (("bin", {"gws": "other.js"}), ("integrity", "sha512-invalid"),
                           ("source", "https://registry.npmjs.org/other/1.2.3"),
                           ("dependencies", {"unknown": "1.0.0"})):
            bad = copy.deepcopy(original); bad["package"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): g._validate_release(bad)

    def test_official_dot_slash_layout_is_published_with_private_state_paths(self):
        root = self.parent / "new"
        r = release(archive())
        layout = g.layout_plan(r, root)
        self.assertFalse(root.exists())
        self.assertEqual(layout["runtime"], {"node": {"required": False, "path": None}, "pnpm": {"required": False, "path": None}})
        self.install_fixture(archive(), root)
        self.assertEqual((root / "bin/gws").read_bytes(), elf())
        self.assertEqual(stat.S_IMODE((root / "bin/gws").stat().st_mode), 0o755)
        for key, path in layout["paths"].items():
            if key == "binary": continue
            self.assertTrue(Path(path).is_dir(), key)
            self.assertEqual(stat.S_IMODE(Path(path).stat().st_mode), 0o700)
        self.assertEqual(layout["proposed_environment"]["HOME"], str(root / "home"))
        self.assertEqual(layout["proposed_environment"]["PATH"], str(root / "bin"))
        with self.assertRaises(ValueError): g.validate_install(r, root)

    def test_size_and_hash_mismatch_fail_before_extraction_and_clean_stage(self):
        blob = archive()
        for key, value in (("size", str(len(blob) + 1)), ("sha256", "0" * 64)):
            metadata = release(blob); metadata[key] = value
            with self.subTest(key=key), patch.object(g, "_extract") as extract:
                with self.assertRaises(RuntimeError): self.install_fixture(blob, metadata=metadata)
                extract.assert_not_called()
            self.assertEqual(list(self.parent.iterdir()), [])

    def test_unsafe_layouts_links_and_elf_fail_without_publication(self):
        valid = ["gws", "LICENSE", "README.md", "CHANGELOG.md"]
        blobs = [archive(valid + ["./gws"]), archive(valid + ["extra"]),
                 archive(["../gws", *valid[1:]]), archive(["/gws", *valid[1:]]),
                 archive(["gws/", *valid[1:]]), archive(root=False),
                 archive(binary=elf(e_type=1)), archive(binary=b"not ELF"),
                 archive(special=("./gws", tarfile.SYMTYPE)),
                 archive(special=("./gws", tarfile.LNKTYPE)),
                 archive(special=("./gws", tarfile.FIFOTYPE))]
        for blob in blobs:
            with self.subTest(sha=hashlib.sha256(blob).hexdigest()), self.assertRaises((ValueError, RuntimeError)):
                self.install_fixture(blob)
            self.assertEqual(list(self.parent.iterdir()), [])

    def test_decompression_and_hidden_tar_payload_are_bounded(self):
        blob = archive(pax={"comment": "x" * 20000})
        with patch.object(g, "ARCHIVE_TOTAL_LIMIT", 10240), self.assertRaises(ValueError): self.install_fixture(blob)
        hidden = gzip.compress(gzip.decompress(archive()) + b"hidden payload")
        with self.assertRaisesRegex(ValueError, "Non-padding"): self.install_fixture(hidden)
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_live_roots_symlinks_and_unsafe_parents_are_refused(self):
        metadata = release(archive())
        existing = self.parent / "existing"; existing.mkdir()
        link = self.parent / "link"; link.symlink_to(existing, target_is_directory=True)
        for target in (Path.home() / "bad", Path("/etc/bad"), Path("/"),
                       Path(g.__file__).parent / "bad", Path("relative"),
                       self.parent / "a/../bad", self.parent / "bad\nname", existing, link, link / "new"):
            with self.subTest(target=target), self.assertRaises((ValueError, RuntimeError, OSError)):
                g.layout_plan(metadata, target)
        unsafe = self.parent / "unsafe"; unsafe.mkdir(); unsafe.chmod(0o777)
        with self.assertRaises(ValueError): g.validate_install(metadata, unsafe / "new")
        unsafe.chmod(0o700)
        with patch.object(g.platform, "system", return_value="Darwin"), self.assertRaises(RuntimeError):
            g.validate_install(metadata, self.parent / "new")

    def test_raced_destination_is_never_overwritten(self):
        root = self.parent / "new"
        original_publish = g._bw._publish_noreplace
        def race(stage, destination, parent_fd=None):
            root.mkdir()
            (root / "sentinel").write_bytes(b"preserve")
            return original_publish(stage, destination, parent_fd=parent_fd)
        with patch.object(g._bw, "_publish_noreplace", side_effect=race), self.assertRaises(RuntimeError):
            self.install_fixture(archive(), root)
        self.assertEqual((root / "sentinel").read_bytes(), b"preserve")
        self.assertEqual(list(self.parent.iterdir()), [root])


if __name__ == "__main__":
    unittest.main()
