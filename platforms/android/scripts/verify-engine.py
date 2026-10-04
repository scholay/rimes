#!/usr/bin/env python3
"""Fail closed on absent/corrupted data, forbidden runtime inputs or native alignment."""
import hashlib,json,pathlib,struct,re,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
subprocess.run([sys.executable,str(ROOT/'resources/icons/convert-lucide.py'),'--check'],check=True)
assets=ROOT/'app/build/generated/rime/assets'
receipt=json.loads((ROOT/'app/build/generated/rime/build-receipt.json').read_text())
assert receipt['ndk']=='29.0.14206865' and receipt['cmake']=='3.22.1'
for name,digest in receipt['inputs'].items():
    assert hashlib.sha256((ROOT.parents[1]/name).read_bytes()).hexdigest()==digest, 'Rebuild native inputs: '+name
data=assets/'rime'
manifest=json.loads((data/'manifest.json').read_text())
assert manifest['format']==1
lock=json.loads((ROOT.parent/'ios/dependencies.lock.json').read_text())
assert manifest['librime']==lock['librime']['commit']
for name,digest in manifest['files'].items():
    assert '..' not in name and not name.startswith('/')
    assert hashlib.sha256((data/name).read_bytes()).hexdigest()==digest,name
assert not list(data.rglob('*.dict.yaml')), 'Raw dictionaries must not trigger on-device compilation'
for schema in ('rimes_pinyin','rimes_pinyin9','rimes_ziranma','rimes_wubi'):
    for suffix in ('','_private'):
        text=(data/'build'/(schema+suffix+'.schema.yaml')).read_text()
        assert 'page_size: 9' in text
        assert ('enable_user_dict: false' if suffix else 'enable_user_dict: true') in text
syllables=json.loads((data/'nine-key-syllables.json').read_text())
assert len(syllables)>400 and 'ni' in syllables and 'hao' in syllables
nine_source=(ROOT/'resources/rimes_pinyin9.schema.yaml').read_text()
groups=('abc','def','ghi','jkl','mno','pqrs','tuv','wxyz')
for syllable in syllables:
    digits=''.join(str(next(i+2 for i,group in enumerate(groups) if letter in group)) for letter in syllable)
    assert 'derive/^'+syllable+'$/'+digits+'/' in nine_source,syllable
profile_source=(ROOT/'resources/chord-profile.json').read_bytes()
assert (data/'chord-profile.json').read_bytes()==profile_source
profile=json.loads(profile_source)
chord_java=(ROOT/'core/src/main/java/org/scholay/rimes/core/ChordData.java').read_text()
assert hashlib.sha256(profile_source).hexdigest()==re.search(r'SOURCE_SHA256="([a-f0-9]+)"',chord_java)[1]
generated=re.findall(r'\{"([a-z,.]+)","([a-z]+)","([A-Za-z]+)"\}',chord_java)
assert generated==[(m['keys'],m['output'],m['kind']) for m in profile['mappings']]
assert len(generated)==427 and profile['leftKeys']=='qwertasdfgzxcvb' and profile['rightKeys']=='yuiophjklnm,.'
for license in ('librime-BSD.txt','Boost-1.0.txt','leveldb-LICENSE.txt','marisa-trie-COPYING.md.txt',
                'yaml-cpp-LICENSE.txt','opencc-LICENSE.txt','wubi86-LGPL-3.0.txt','pinyin_simp-APACHE-2.0.txt'):
    assert (assets/'licenses'/license).read_bytes()==(ROOT.parent/'ios/Licenses'/license).read_bytes(),license
assert (assets/'licenses/RIMES-Apache-2.0.txt').read_bytes()==(ROOT.parents[1]/'LICENSE').read_bytes(), 'RIMES Apache license'
for source,name in [('NOTICE','RIMES-NOTICE.txt'),('OfficialPlugins/NOTICE','RIMES-Plugins-NOTICE.txt')]:
    assert (assets/'licenses'/name).read_bytes()==(ROOT.parents[1]/source).read_bytes(),name
for abi in ('arm64-v8a','x86_64'):
    lib=ROOT/'app/build/generated/rime/jniLibs'/abi/'librimes_jni.so'
    assert hashlib.sha256(lib.read_bytes()).hexdigest()==receipt['libraries'][abi],abi
    data=lib.read_bytes(); assert data[:6]==b'\x7fELF\x02\x01'
    offset=struct.unpack_from('<Q',data,32)[0]
    size,count=struct.unpack_from('<HH',data,54)
    segments=[]
    for i in range(count):
        p=struct.unpack_from('<IIQQQQQQ',data,offset+i*size)
        if p[0]==1:
            assert p[7]>=16384 and p[2]%16384==p[3]%16384,(abi,p)
            segments.append(p[7])
    assert segments
    print(abi,'ELF LOAD alignment:',segments)
print('PASS: precompiled resources, schemas, licenses, ABI libraries and 16 KB ELF alignment')
