import base64, hashlib, io, json, os, tarfile, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
import sys
sys.path.insert(0, str(Path(__file__).parents[1]))
import opencode2_linux as o

class R:
    def __init__(self, data): self.io=io.BytesIO(data); self.headers={"Content-Length":str(len(data))}
    def read(self,n=-1): return self.io.read(n)
    def close(self): pass

def elf():
    b=bytearray(64); b[:7]=b"\x7fELF"+bytes((2,1,1)); b[16:18]=(2).to_bytes(2,'little'); b[18:20]=(62).to_bytes(2,'little'); b[20:24]=(1).to_bytes(4,'little'); return bytes(b)+b'x'

def tgz(binary=None, package=None, extra=False):
    out=io.BytesIO(); package=package or {"name":o.LINUX_PACKAGE,"version":"2.1.3"}
    with tarfile.open(fileobj=out, mode='w:gz') as t:
        for n,data in (("package/package.json",json.dumps(package).encode()), ("package/bin/opencode",binary or elf())):
            x=tarfile.TarInfo(n); x.size=len(data); x.mode=0o755; t.addfile(x,io.BytesIO(data))
        if extra:
            x=tarfile.TarInfo("package/extra"); x.size=1; t.addfile(x,io.BytesIO(b"x"))
    return out.getvalue()

def integ(data): return 'sha512-'+base64.b64encode(hashlib.sha512(data).digest()).decode()

class OpenCode2Tests(unittest.TestCase):
    def setUp(self):
        self.v='2.1.3'; self.payload=tgz(); self.integrity=integ(self.payload); self.sha=hashlib.sha512(self.payload).hexdigest(); self.unpacked=len(json.dumps({"name":o.LINUX_PACKAGE,"version":self.v}).encode())+len(elf())
        win_bytes=b'x'*64; self.win_sha=hashlib.sha512(win_bytes).hexdigest()
        self.manifest={'version':self.v,'architecture':{'64bit':{'url':o._tarball(o.WINDOWS_PACKAGE,self.v),'hash':'sha512:'+self.win_sha}}}
        def meta(name, integ_value=None, size=None):
            return {'name':name,'version':self.v,'dist':{'tarball':o._tarball(name,self.v),'integrity':integ_value or integ(b'x'*64),'fileCount':2,'unpackedSize':size or 10},'repository':{'type':'git','url':'git+https://github.com/anomalyco/opencode.git'}}
        self.wrapper=meta(o.PACKAGE); self.wrapper['optionalDependencies']={o.WINDOWS_PACKAGE:self.v,o.LINUX_PACKAGE:self.v}; self.win=meta(o.WINDOWS_PACKAGE,integ(win_bytes)); self.linux=meta(o.LINUX_PACKAGE,self.integrity,self.unpacked)
    def test_resolution_uses_exact_sources_and_cross_checks_sha512(self):
        with patch.object(o,'_json',side_effect=[self.manifest,self.wrapper,self.win,self.linux]): r=o.resolve_release('x86_64')
        self.assertEqual(r['version'],self.v); self.assertEqual(r['sha512'],self.sha); self.assertEqual(r['url'],o._tarball(o.LINUX_PACKAGE,self.v)); self.assertEqual(r['unpacked_size'],str(self.unpacked))
        bad=dict(self.win,dist=dict(self.win['dist'],integrity=integ(b'c'*64)))
        with patch.object(o,'_json',side_effect=[self.manifest,self.wrapper,bad,self.linux]), self.assertRaisesRegex(RuntimeError,'disagrees'): o.resolve_release('x86_64')
    def release(self):
        return {'version':self.v,'url':o._tarball(o.LINUX_PACKAGE,self.v),'integrity':self.integrity,'sha512':self.sha,'unpacked_size':str(self.unpacked),'file_count':'2','asset_name':'cli-linux-x64-baseline-2.1.3.tgz','manifest_source':o.SCOOP_MANIFEST_URL,'wrapper_source':o._pkg_url(o.PACKAGE,self.v),'windows_source':o._pkg_url(o.WINDOWS_PACKAGE,self.v),'linux_source':o._pkg_url(o.LINUX_PACKAGE,self.v),'windows_url':o._tarball(o.WINDOWS_PACKAGE,self.v),'windows_integrity':self.win['dist']['integrity'],'windows_sha512':self.win_sha,'wrapper_tarball':o._tarball(o.PACKAGE,self.v),'wrapper_integrity':self.wrapper['dist']['integrity'],'wrapper_file_count':'2','wrapper_unpacked_size':'10','windows_file_count':'2','windows_unpacked_size':'10','linux_file_count':'2','linux_unpacked_size':str(self.unpacked),'repository':'git+https://github.com/anomalyco/opencode.git','compatibility':'Linux x86_64 ELF64 baseline binary'}
    def test_install_publishes_binary_and_hardlink_without_execution(self):
        root=Path(tempfile.mkdtemp())/'new'
        with patch.object(o,'_cpu_compatible'), patch.object(o,'_open',return_value=R(self.payload)): o.install_release(self.release(),root)
        self.assertTrue((root/'opencode').exists()); self.assertTrue((root/'opencode2').exists()); self.assertEqual(os.stat(root/'opencode').st_ino,os.stat(root/'opencode2').st_ino)
    def test_bad_archive_and_existing_root_fail_closed(self):
        root=Path(tempfile.mkdtemp())/'new'; bad=tgz(extra=True); r=self.release(); r['sha512']=hashlib.sha512(bad).hexdigest(); r['integrity']=integ(bad); r['unpacked_size']=r['linux_unpacked_size']=str(self.unpacked+1)
        with patch.object(o,'_cpu_compatible'), patch.object(o,'_open',return_value=R(bad)), self.assertRaises(ValueError): o.install_release(r,root)
        self.assertFalse(root.exists()); old=Path(tempfile.mkdtemp())/'old'; old.mkdir()
        with patch.object(o,'_cpu_compatible'), self.assertRaises(ValueError): o.validate_install(self.release(),old)
    def test_strict_metadata_and_archive_guards(self):
        with self.assertRaises(RuntimeError): o._integrity('sha512-'+base64.b64encode(b'x'*64).decode()+'=')
        r=self.release(); r['repository']='git+https://github.com/other/repo.git'
        with self.assertRaises(ValueError): o._validate_release(r)
        r=self.release(); r['asset_name']='wrong.tgz'
        with self.assertRaises(ValueError): o._validate_release(r)
    def test_architecture_and_url_guards(self):
        with self.assertRaises(RuntimeError): o.resolve_release('aarch64')
        r=self.release(); r['url']='https://evil.example/x'
        with patch.object(o,'_cpu_compatible'), self.assertRaises(ValueError): o.validate_install(r,Path(tempfile.mkdtemp())/'new')

if __name__=='__main__': unittest.main()
