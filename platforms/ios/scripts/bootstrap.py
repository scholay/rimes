#!/usr/bin/env python3
"""Fetch verified source/tool inputs; never fetch executable input schemes."""
from pathlib import Path
import hashlib,subprocess,urllib.request,tarfile,zipfile,json
ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'Vendor/ios-build';WORK.mkdir(parents=True,exist_ok=True)
LOCK=json.loads((ROOT/'platforms/ios/dependencies.lock.json').read_text())
def run(*args):subprocess.run([str(a) for a in args],check=True)
def download(item,path):
    if not path.exists():
        tmp=path.with_suffix(path.suffix+'.part')
        with urllib.request.urlopen(item['url'],timeout=90) as r,tmp.open('wb') as f:
            while chunk:=r.read(1024*1024):f.write(chunk)
        tmp.replace(path)
    if hashlib.sha256(path.read_bytes()).hexdigest()!=item['sha256']:raise RuntimeError('Checksum mismatch: '+str(path))
src=WORK/'librime'
if not src.exists():
    run('git','clone','--depth','1','--branch',LOCK['librime']['tag'],LOCK['librime']['url'],src)
if subprocess.check_output(['git','-C',str(src),'rev-parse','HEAD'],text=True).strip()!=LOCK['librime']['commit']:raise RuntimeError('Unexpected librime revision')
run('git','-C',src,'submodule','update','--init','--depth','1','deps/leveldb','deps/marisa-trie','deps/yaml-cpp','deps/opencc')
for dep,sha in LOCK['submodules'].items():
    if subprocess.check_output(['git','-C',str(src/'deps'/dep),'rev-parse','HEAD'],text=True).strip()!=sha:raise RuntimeError('Unexpected dependency: '+dep)
boost=WORK/'boost.tar.bz2';download(LOCK['boost'],boost)
if not (WORK/'boost_1_86_0').exists():
    with tarfile.open(boost) as t:
        # Python 3.12+ data filter rejects path traversal / dangerous links.
        t.extractall(WORK,filter='data')
archive=WORK/'xcodegen.zip';download(LOCK['xcodegen'],archive)
if not (WORK/'xcodegen/bin/xcodegen').exists():
    with zipfile.ZipFile(archive) as z:z.extractall(WORK)
    (WORK/'xcodegen/bin/xcodegen').chmod(0o755)
for item in LOCK['data']:
    path=ROOT/item['path'];path.parent.mkdir(parents=True,exist_ok=True);download(item,path)
print('Source and tool inputs verified')
