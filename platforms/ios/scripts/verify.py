#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,sys,plistlib
root=Path(__file__).resolve().parents[3]; ios=root/'platforms/ios'; data=ios/'Resources/EngineData'
lock=json.loads((ios/'dependencies.lock.json').read_text())
for item in lock['data'] + lock['localInputs']:
    assert hashlib.sha256((root/item['path']).read_bytes()).hexdigest()==item['sha256'],item['path']
assert (data/'wubi86.dict.yaml').read_bytes()==(root/'rime-data/wubi86.dict.yaml').read_bytes()
checks=json.loads((data/'checksums.json').read_text())
for path,sha in checks.items():
    assert hashlib.sha256((data/path).read_bytes()).hexdigest()==sha,path
for name in ['rimes_pinyin','rimes_ziranma','rimes_wubi']:
    assert (data/'build'/f'{name}.schema.yaml').exists()
    assert (data/'build'/f'{name}.prism.bin').exists()
assert not any(p.suffix in ['.lua','.dylib'] or 'yoyo' in p.name or 'flypy' in p.name for p in data.rglob('*'))
for name in ['App/Info.plist','Keyboard/Info.plist']:
    p=plistlib.loads((ios/name).read_bytes()); assert p['CFBundleLocalizations']==['en','zh-Hans']
p=plistlib.loads((ios/'Keyboard/Info.plist').read_bytes())
assert p['NSExtension']['NSExtensionAttributes']['RequestsOpenAccess'] is True
manifest=plistlib.loads((ios/'Resources/PrivacyInfo.xcprivacy').read_bytes())
assert manifest['NSPrivacyTracking'] is False
# Keep mobile encoding behavior aligned with the desktop source without changing desktop packaging.
a=(root/'Sources/RimeBuffer/ChordOutputEncoding.swift').read_text().split('\nextension ChordKeymapProfile')[0]
b=(root/'Shared/Sources/RimesCore/ChordEncoding.swift').read_text().split('\n',1)[1].replace('public ','')
assert a==b,'Encoding source drift: update the shared port and run mapping/engine tests'
p=json.loads((root/'Shared/Sources/RimesCore/Resources/flyyao.json').read_text())
original=json.loads((root/'chord-keymaps/Isaac2025.json').read_text())
assert p['mappings']==original['mappings'] and len(p['mappings'])==426
print('PASS: resources, source parity, permissions and privacy manifest')
if '--distribution' in sys.argv:
    audit=json.loads((ios/'distribution-audit.json').read_text())
    issues=[x['name'] for x in audit['assets'] if x['status']!='verified']+[x['name'] for x in audit['releasePrerequisites'] if not x['verified']]
    if audit['status']!='ready' or issues:
        print('DISTRIBUTION BLOCKED: '+ '; '.join(issues));sys.exit(2)
