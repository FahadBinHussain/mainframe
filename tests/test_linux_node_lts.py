import hashlib, io, json, os, sys, tarfile, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).parents[1]))
import node_lts_linux as node

class Response:
    def __init__(self, data): self.data=io.BytesIO(data); self.headers={}
    def read(self, n=-1): return self.data.read(n)
    def close(self): pass

def elf():
    p=bytearray(b"\x7fELF"+bytes((2,1,1))+b"\0"*60); p[18:20]=(62).to_bytes(2,"little"); p[20:24]=(1).to_bytes(4,"little"); return bytes(p)

def archive(version="24.22.1", *, symlink=False, escape=False, symlink_dir=False, writable=False, bad_elf=False):
    raw=io.BytesIO(); root=f"node-v{version}-linux-x64"; payload=elf()
    if bad_elf: payload=b"BAD!"+payload[4:]
    with tarfile.open(fileobj=raw, mode="w:xz") as t:
        def add_dir(name, mode=0o755):
            d=tarfile.TarInfo(name); d.type=tarfile.DIRTYPE; d.mode=mode; t.addfile(d)
        add_dir(root); add_dir(root+"/bin")
        f=tarfile.TarInfo(root+"/node"); f.size=len(payload); f.mode=0o755; t.addfile(f,io.BytesIO(payload))
        if symlink_dir:
            s=tarfile.TarInfo(root+"/bin/link"); s.type=tarfile.SYMTYPE; s.linkname=".."; t.addfile(s)
            f=tarfile.TarInfo(root+"/bin/link/node"); f.size=len(payload); f.mode=0o755; t.addfile(f,io.BytesIO(payload))
        elif symlink:
            s=tarfile.TarInfo(root+"/bin/node"); s.type=tarfile.SYMTYPE; s.linkname="../node" if not escape else "../../outside"; t.addfile(s)
        else:
            f=tarfile.TarInfo(root+"/bin/node"); f.size=len(payload); f.mode=0o666 if writable else 0o755; t.addfile(f,io.BytesIO(payload))
    return raw.getvalue()

def release(version="24.22.1", data=None, ext="zip"):
    data=data or archive(version); return {"version":version,"url":f"https://nodejs.org/dist/v{version}/node-v{version}-linux-x64.tar.xz","sha256":hashlib.sha256(data).hexdigest(),"size":"unknown","asset_name":f"node-v{version}-linux-x64.tar.xz","manifest_source":node.SCOOP_MANIFEST_URL,"index_source":node.NODE_INDEX_URL,"checksums_source":f"https://nodejs.org/dist/v{version}/SHASUMS256.txt","windows_url":f"https://nodejs.org/dist/v{version}/node-v{version}-win-x64.{ext}","windows_sha256":"a"*64,"compatibility_source":node.COMPATIBILITY_SOURCE,"compatibility":"Node Linux x64 glibc >= 2.28 libstdc++"}

@unittest.skipUnless(sys.platform.startswith("linux"), "Linux adapter tests")
class NodeLtsTests(unittest.TestCase):
    def test_manifest_zip_or_7z_and_checksum_crosscheck(self):
        v="24.22.1"
        for ext in ("zip","7z"):
            u=f"https://nodejs.org/dist/v{v}/node-v{v}-win-x64.{ext}"; manifest={"version":v,"architecture":{"64bit":{"url":u,"hash":"a"*64}}}; index=[{"version":"v"+v,"lts":"Jod"}]
            sums=("b"*64+"  node-v"+v+"-linux-x64.tar.xz\n"+"a"*64+"  node-v"+v+f"-win-x64.{ext}\n").encode()
            with self.subTest(ext=ext), patch.object(node,"_json",side_effect=[manifest,index]), patch.object(node,"_open",return_value=Response(sums)):
                self.assertEqual(node.resolve_release("x86_64")["windows_url"],u)
    def test_unknown_lts_type_fails_closed(self):
        v="24.22.1"; m={"version":v,"architecture":{"64bit":{"url":f"https://nodejs.org/dist/v{v}/node-v{v}-win-x64.zip","hash":"a"*64}}}
        for lts in (False, 1, [], ""):
            with patch.object(node,"_json",side_effect=[m,[{"version":"v"+v,"lts":lts}]]), self.assertRaises(RuntimeError): node.resolve_release("x86_64")
    def test_symlink_escape_prefix_and_writable_guards(self):
        for kwargs in ({"symlink":True},{"symlink":True,"escape":True},{"symlink_dir":True},{"writable":True}):
            with tempfile.TemporaryDirectory() as td, patch.object(node,"_open",return_value=Response(archive(**kwargs))):
                with self.assertRaises((RuntimeError,ValueError)): node.install_release(release(data=archive(**kwargs)),Path(td)/"new")
    def test_checksum_and_elf_fail_before_publication(self):
        data=archive(bad_elf=True); r=release(data=data); r["sha256"]="0"*64
        with tempfile.TemporaryDirectory() as td, patch.object(node,"_open",return_value=Response(data)), self.assertRaises(RuntimeError): node.install_release(r,Path(td)/"new")
    def test_redirect_requires_exact_path_and_passes_newurl(self):
        h=node._Redirects("/dist/v1/SHASUMS256.txt"); req=__import__("urllib.request").request.Request("https://nodejs.org/dist/v1/SHASUMS256.txt")
        with self.assertRaises(RuntimeError): h.redirect_request(req,None,302,"",{},"https://nodejs.org/dist/v1/node-v1.tar.xz")

    def test_scoop_redirect_allows_only_exact_https_source(self):
        import urllib.request
        source=node.SCOOP_MANIFEST_URL; req=urllib.request.Request(source)
        h=node._ScoopRedirects()
        safe=h.redirect_request(req,None,302,"",{},source)
        self.assertEqual(safe.full_url, source)
        for target in (
            "https://github.com/ScoopInstaller/Main/raw/master/bucket/nodejs-lts.json",
            "https://raw.githubusercontent.com/ScoopInstaller/Main/raw/master/bucket/other.json",
            "http://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/nodejs-lts.json",
            "https://user:pass@raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/nodejs-lts.json",
            "https://raw.githubusercontent.com:443/ScoopInstaller/Main/master/bucket/nodejs-lts.json",
            source + "?download=1",
            source + "#manifest",
        ):
            with self.subTest(target=target), self.assertRaises(RuntimeError):
                h.redirect_request(req,None,302,"",{},target)

    def test_scoop_opener_uses_dedicated_redirect_handler(self):
        import urllib.request
        class Opener:
            def open(self, request, timeout):
                self.request=request; self.timeout=timeout
                return Response(b"{}")
        opener=Opener()
        with patch.object(urllib.request, "build_opener", return_value=opener) as build:
            node._open_scoop(node.SCOOP_MANIFEST_URL, limit=1024)
        handler=build.call_args.args[0]
        self.assertIsInstance(handler, node._ScoopRedirects)
        self.assertEqual(handler.max_redirections, node.SCOOP_MAX_REDIRECTIONS)
        self.assertEqual(opener.request.full_url, node.SCOOP_MANIFEST_URL)
    def test_existing_root_and_non_linux_architecture_fail_closed(self):
        with tempfile.TemporaryDirectory() as td:
            dest=Path(td)/"existing"; dest.mkdir()
            with self.assertRaises(ValueError): node.validate_install(release(),dest)
        with patch.object(node,"_json") as network, self.assertRaises(RuntimeError): node.resolve_release("aarch64")
        network.assert_not_called()
    @unittest.skipUnless(os.environ.get("RUN_LIVE_NODE_METADATA") == "1", "opt-in live metadata")
    def test_live_resolver_metadata_only(self):
        got=node.resolve_release("x86_64"); self.assertRegex(got["version"], r"^\d+\.\d+\.\d+"); self.assertEqual(got["size"],"unknown")

if __name__ == "__main__": unittest.main()
