import hashlib, io, os, sys, tarfile, tempfile, unittest, zipfile
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).parents[1]))
import github_native_linux as g

def elf(*, etype=2, version=1):
    b=bytearray(64); b[:7]=b"\x7fELF"+bytes((2,1,1)); b[16:18]=etype.to_bytes(2,'little'); b[18:20]=(62).to_bytes(2,'little'); b[20:24]=version.to_bytes(4,'little'); b[52:54]=(64).to_bytes(2,'little'); return bytes(b)+b'x'
class R:
    def __init__(self,d): self.d=io.BytesIO(d); self.headers={'Content-Length':str(len(d))}
    def read(self,n=-1): return self.d.read(n)
    def close(self): pass
class GithubNativeTests(unittest.TestCase):
    def metadata(self,name='deno',version='1.2.3',payload=None):
        s=g._PRODUCTS[name]; tag=s['tag'](version); base=f"https://github.com/{s['repo']}/releases/download/{tag}/"; windows=elf()
        manifest={'version':version,'architecture':{'64bit':{'url':base+s['win'](version)+s.get('win_suffix',''),'hash':hashlib.sha256(windows).hexdigest()}}}
        payload=elf() if payload is None else payload
        assets=[{'name':s['win'](version),'browser_download_url':base+s['win'](version),'size':len(windows),'digest':'sha256:'+hashlib.sha256(windows).hexdigest()},{'name':s['asset'],'browser_download_url':base+s['asset'],'size':len(payload),'digest':'sha256:'+hashlib.sha256(payload).hexdigest()}]
        return manifest,{'tag_name':tag,'draft':False,'prerelease':False,'published_at':'2026-01-01T00:00:00Z','assets':assets}
    def resolved(self,name='deno',payload=None):
        m,r=self.metadata(name,payload=payload)
        with patch.object(g,'_json',side_effect=[m,r]): return g.resolve_release(name,'x86_64')
    def test_resolves_each_product_and_exact_provenance(self):
        for n in g._PRODUCTS:
            with self.subTest(n=n):
                out=self.resolved(n); self.assertEqual(out['name'],n); self.assertEqual(out['asset_name'],g._PRODUCTS[n]['asset']); self.assertTrue(out['release_source'].startswith('https://api.github.com/repos/'))
    def test_resolution_rejects_variants_hash_and_release_state(self):
        m,r=self.metadata()
        with self.assertRaises(RuntimeError): g.resolve_release('deno','aarch64')
        m['architecture']['64bit']['url']=m['architecture']['64bit']['url'].replace('deno-x86_64-pc-windows-msvc.zip','deno.exe')
        with patch.object(g,'_json',side_effect=[m,r]), self.assertRaises(RuntimeError): g.resolve_release('deno','x86_64')
        m,r=self.metadata(); m['architecture']['64bit']['hash']='0'*64
        with patch.object(g,'_json',side_effect=[m,r]), self.assertRaises(RuntimeError): g.resolve_release('deno','x86_64')
        m,r=self.metadata(); r['assets'][0]['digest']='sha256:'+'b'*64
        with patch.object(g,'_json',side_effect=[m,r]), self.assertRaises(RuntimeError): g.resolve_release('deno','x86_64')
        m,r=self.metadata(); r['prerelease']=True
        with patch.object(g,'_json',side_effect=[m,r]), self.assertRaises(RuntimeError): g.resolve_release('deno','x86_64')
    def test_validate_rejects_spoofed_metadata_unhashable_name_and_port(self):
        good=self.resolved()
        for key,val in [('url','https://evil.example/x'),('url','https://github.com:443/denoland/deno/releases/download/v1.2.3/deno-x86_64-unknown-linux-gnu.zip'),('size','01'),('asset_name','deno.exe')]:
            with self.subTest(key=key), self.assertRaises(ValueError): g.validate_install({**good,key:val},Path(tempfile.mkdtemp())/'new')
        with self.assertRaises(ValueError): g.validate_install({**good,'name':[]},Path(tempfile.mkdtemp())/'new')
    def test_raw_products_publish_normal_command_names(self):
        for n in ('cloudflared','yq'):
            payload=elf(); rel=self.resolved(n,payload); root=Path(tempfile.mkdtemp())/n
            with patch.object(g,'_open',return_value=R(payload)): g.install_release(rel,root)
            self.assertEqual((root/n).read_bytes(),payload); self.assertTrue(os.access(root/n,os.X_OK)); self.assertFalse((root/g._PRODUCTS[n]['asset']).exists())
    def test_zip_success_and_traversal_attack(self):
        payload=elf(); rel=self.resolved('deno',payload); raw=io.BytesIO()
        with zipfile.ZipFile(raw,'w') as z: z.writestr('deno',payload)
        blob=raw.getvalue(); rel['size']=str(len(blob)); rel['sha256']=hashlib.sha256(blob).hexdigest()
        root=Path(tempfile.mkdtemp())/'deno'
        with patch.object(g,'_open',return_value=R(blob)): g.install_release(rel,root)
        self.assertEqual((root/'deno').read_bytes(),payload)
        bad=io.BytesIO()
        with zipfile.ZipFile(bad,'w') as z: z.writestr('../deno',payload)
        badblob=bad.getvalue(); badrel=dict(rel); badrel['size']=str(len(badblob)); badrel['sha256']=hashlib.sha256(badblob).hexdigest()
        with patch.object(g,'_open',return_value=R(badblob)), self.assertRaises(ValueError): g.install_release(badrel,Path(tempfile.mkdtemp())/'bad')
    def test_tar_success_root_dir_and_attack_members(self):
        payload=elf(); rel=self.resolved('pnpm',payload); raw=io.BytesIO()
        with tarfile.open(fileobj=raw,mode='w:gz') as t:
            d=tarfile.TarInfo('pnpm-linux-x64/'); d.type=tarfile.DIRTYPE; t.addfile(d)
            f=tarfile.TarInfo('pnpm-linux-x64/pnpm'); f.size=len(payload); t.addfile(f,io.BytesIO(payload))
        blob=raw.getvalue(); rel['size']=str(len(blob)); rel['sha256']=hashlib.sha256(blob).hexdigest()
        root=Path(tempfile.mkdtemp())/'pnpm'
        with patch.object(g,'_open',return_value=R(blob)): g.install_release(rel,root)
        self.assertEqual((root/'pnpm').read_bytes(),payload)
        for name in ('../pnpm-linux-x64/pnpm','pnpm-linux-x64/pnpm'):
            bad=io.BytesIO()
            with tarfile.open(fileobj=bad,mode='w:gz') as t:
                f=tarfile.TarInfo(name); f.size=len(payload); t.addfile(f,io.BytesIO(payload))
                if name=='pnpm-linux-x64/pnpm': t.addfile(f,io.BytesIO(payload))
            badblob=bad.getvalue(); badrel=dict(rel); badrel['size']=str(len(badblob)); badrel['sha256']=hashlib.sha256(badblob).hexdigest()
            with patch.object(g,'_open',return_value=R(badblob)), self.assertRaises(ValueError): g.install_release(badrel,Path(tempfile.mkdtemp())/'bad')
        special=io.BytesIO()
        with tarfile.open(fileobj=special,mode='w:gz') as t:
            f=tarfile.TarInfo('pnpm-linux-x64/pnpm'); f.type=tarfile.SYMTYPE; f.linkname='/etc/passwd'; t.addfile(f)
        specialblob=special.getvalue(); specialrel=dict(rel); specialrel['size']=str(len(specialblob)); specialrel['sha256']=hashlib.sha256(specialblob).hexdigest()
        with patch.object(g,'_open',return_value=R(specialblob)), self.assertRaises(ValueError): g.install_release(specialrel,Path(tempfile.mkdtemp())/'special')
    def test_elf_type_and_version_required(self):
        for bad in (elf(etype=1),elf(version=2)):
            rel=self.resolved('yq',bad)
            with patch.object(g,'_open',return_value=R(bad)), self.assertRaises(RuntimeError): g.install_release(rel,Path(tempfile.mkdtemp())/'bad')
    def test_hash_failure_and_destination_safety(self):
        payload=elf(); rel=self.resolved('deno',payload); bad=dict(rel); bad['sha256']='0'*64
        with patch.object(g,'_open',return_value=R(payload)), self.assertRaises(RuntimeError): g.install_release(bad,Path(tempfile.mkdtemp())/'x')
        parent=Path(tempfile.mkdtemp()); existing=parent/'old'; existing.mkdir(); link=parent/'link'; link.symlink_to(existing,target_is_directory=True)
        with self.assertRaises(ValueError): g.validate_install(rel,existing)
        with self.assertRaises(ValueError): g.validate_install(rel,link)
        with patch.object(g.platform,'system',return_value='Darwin'),patch.object(g,'_open') as net,self.assertRaises(RuntimeError): g.install_release(rel,parent/'new')
        net.assert_not_called()
    def test_no_binary_execution_and_unsupported_name(self):
        with self.assertRaises(RuntimeError): g.resolve_release('not-supported','x86_64')
if __name__=='__main__': unittest.main()
