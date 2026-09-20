#!/usr/bin/env python3
"""Build upstream librime and locked submodules, without runtime code downloads."""
import hashlib, json, os, pathlib, subprocess, sys, platform
ROOT=pathlib.Path(__file__).resolve().parents[3]
WORK=ROOT/'Vendor/ios-build'
SRC=WORK/'librime'
os.environ.setdefault('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
def run(*args): subprocess.run([str(x) for x in args],check=True)
def build(slice):
    prefix=WORK/slice/'install'; prefix.mkdir(parents=True,exist_ok=True)
    sdk='macosx' if slice=='host' else ('iphoneos' if slice=='device' else 'iphonesimulator')
    arch=platform.machine() if slice=='host' else 'arm64'
    base=['-DCMAKE_BUILD_TYPE=Release','-DCMAKE_POLICY_VERSION_MINIMUM=3.5',f'-DCMAKE_OSX_ARCHITECTURES={arch}',f'-DCMAKE_OSX_SYSROOT={sdk}',f'-DCMAKE_INSTALL_PREFIX={prefix}','-DBUILD_SHARED_LIBS=OFF','-DBUILD_TESTING=OFF']
    if slice!='host': base+=['-DCMAKE_SYSTEM_NAME=iOS','-DCMAKE_MACOSX_BUNDLE=OFF','-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0','-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY','-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO']
    for dep,flags in [('leveldb',['-DLEVELDB_BUILD_TESTS=OFF','-DLEVELDB_BUILD_BENCHMARKS=OFF','-DHAVE_SNAPPY=OFF','-DHAVE_CRC32C=OFF','-DHAVE_TCMALLOC=OFF']),('marisa-trie',['-DENABLE_TOOLS=OFF']),('yaml-cpp',['-DYAML_CPP_BUILD_TESTS=OFF','-DYAML_CPP_BUILD_TOOLS=OFF','-DYAML_CPP_BUILD_CONTRIB=OFF']),('opencc',['-DENABLE_GTEST=OFF','-DENABLE_DARTS=OFF','-DBUILD_DOCUMENTATION=OFF'])]:
        folder=WORK/slice/dep
        fingerprint=hashlib.sha256(json.dumps(base+flags,sort_keys=True).encode()).hexdigest()
        if (folder/'.done').exists() and (folder/'.done').read_text()==fingerprint: continue
        run('cmake','-S',SRC/'deps'/dep,'-B',folder,*base,*flags)
        if dep == 'opencc' and slice != 'host':
            run('cmake','--build',folder,'--target','libopencc','--parallel','6')
            import shutil
            (prefix/'lib').mkdir(exist_ok=True)
            for lib in folder.rglob('*.a'): shutil.copy2(lib,prefix/'lib'/lib.name)
            shutil.copytree(SRC/'deps/opencc/src',prefix/'include/opencc',dirs_exist_ok=True)
            shutil.copy2(folder/'src/opencc_config.h',prefix/'include/opencc/opencc_config.h')
        else:
            run('cmake','--build',folder,'--target','install','--parallel','6')
        (folder/'.done').write_text(fingerprint)
    folder=WORK/slice/'rime'
    base += [f'-DBoost_INCLUDE_DIR={WORK/"boost_1_86_0"}', f'-DYamlCpp_NEW_API={prefix/"include"}']
    for package, library in [('YamlCpp','yaml-cpp'),('LevelDb','leveldb'),('Marisa','marisa'),('Opencc','opencc')]:
        base += [f'-D{package}_INCLUDE_PATH={prefix/"include"}', f'-D{package}_LIBRARY={prefix/"lib"/f"lib{library}.a"}']
    run('cmake','-S',SRC,'-B',folder,*base,f'-DCMAKE_PREFIX_PATH={prefix}',f'-DBOOST_ROOT={WORK/"boost_1_86_0"}','-DBoost_NO_BOOST_CMAKE=ON','-DCMAKE_POLICY_DEFAULT_CMP0167=OLD','-DBUILD_STATIC=ON','-DBUILD_TEST=OFF','-DENABLE_LOGGING=OFF','-DENABLE_EXTERNAL_PLUGINS=OFF','-DENABLE_TIMESTAMP=OFF', '-DBUILD_SHARED_LIBS=' + ('ON' if slice=='host' else 'OFF'))
    run('cmake','--build',folder,'--target', 'rime_deployer' if slice=='host' else 'rime-static','--parallel','6')
    if slice!='host':
        headers=WORK/'headers'; headers.mkdir(exist_ok=True)
        for name in ['rime_api.h','rime_levers_api.h']:
            (headers/name).write_bytes((SRC/'src'/name).read_bytes())
        libs=list((folder/'lib').glob('*.a'))+list((prefix/'lib').glob('*.a'))
        run('xcrun','libtool','-static','-o',WORK/slice/'librime.a',*libs)
if __name__=='__main__':
    slices=sys.argv[1:] or ['host','device','simulator']
    for s in slices: build(s)
    if all((WORK/s/'librime.a').exists() for s in ['device','simulator']):
        out=ROOT/'Vendor/Rime.xcframework'
        signature=hashlib.sha256(b''.join((WORK/s/'librime.a').read_bytes() for s in ['device','simulator'])).hexdigest()
        stamp=WORK/'xcframework.sha256'
        if out.exists() and (not stamp.exists() or stamp.read_text()!=signature):
            import shutil
            shutil.rmtree(out)
        if not out.exists(): run('xcodebuild','-create-xcframework','-library',WORK/'device/librime.a','-headers',WORK/'headers','-library',WORK/'simulator/librime.a','-headers',WORK/'headers','-output',out)

        stamp.write_text(signature)
