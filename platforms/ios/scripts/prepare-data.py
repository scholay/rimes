#!/usr/bin/env python3
"""Generate minimal iOS schemas and compile dictionaries on the build host."""
from pathlib import Path
import os,subprocess,json,shutil,hashlib
root=Path(__file__).resolve().parents[3]
base=root/'platforms/ios/Resources/EngineData'
base.mkdir(parents=True,exist_ok=True)
os.environ.setdefault('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
encoding=root/'Vendor/ios-build/encoding.swift'
encoding.write_text((root/'Shared/Sources/RimesCore/ChordEncoding.swift').read_text()+'\nprint(String(data:try! JSONSerialization.data(withJSONObject:["algebra":ZiranmaShuangpin.syllableAlgebra,"preedit":ZiranmaShuangpin.preeditFormat]),encoding:.utf8)!)\n')
rules=json.loads(subprocess.check_output(['xcrun','swift',str(encoding)],text=True))
shutil.copy2(root/'rime-data/wubi86.dict.yaml',base/'wubi86.dict.yaml')
(base/'default.yaml').write_text('config_version: "1.0"\nschema_list:\n  - schema: rimes_pinyin\n  - schema: rimes_ziranma\n  - schema: rimes_wubi\nmenu:\n  page_size: 9\n')
for mode in ['pinyin','ziranma','wubi']:
    wubi=mode=='wubi'; double=mode=='ziranma'
    alg=rules['algebra'] if double else ['abbrev/^([a-z]).+$/$1/'] if not wubi else []
    preedit=rules['preedit'] if double else []
    schema=f'''# RIMES iOS original minimal schema (MIT). No desktop includes or Lua.
schema:
  schema_id: rimes_{mode}
  name: RIMES {mode}
  version: "0.1.0"
switches:
  - name: ascii_mode
    reset: 0
engine:
  processors: [ascii_composer, speller, punctuator, selector, navigator, express_editor]
  segmentors: [ascii_segmentor, abc_segmentor, punct_segmentor, fallback_segmentor]
  translators: [punct_translator, {'table_translator' if wubi else 'script_translator'}]
speller:
  alphabet: abcdefghijklmnopqrstuvwxyz
  delimiter: " '"
  algebra: {json.dumps(alg,ensure_ascii=False)}
translator:
  dictionary: {'wubi86' if wubi else 'pinyin_simp'}
  prism: rimes_{mode}
  enable_user_dict: true
  enable_sentence: true
  enable_completion: true
  preedit_format: {json.dumps(preedit,ensure_ascii=False)}
punctuator:
  half_shape:
    ',': '，'
    '.': '。'
    '?': '？'
    '!': '！'
    ':': '：'
    ';': '；'
'''
    (base/f'rimes_{mode}.schema.yaml').write_text(schema)
user=root/'Vendor/ios-build/data-user';user.mkdir(exist_ok=True)
subprocess.run([str(root/'Vendor/ios-build/host/rime/bin/rime_deployer'),'--build',str(base),str(base),str(base/'build')],check=True)
required=['rimes_pinyin.schema.yaml','rimes_ziranma.schema.yaml','rimes_wubi.schema.yaml','pinyin_simp.table.bin','wubi86.table.bin']
for name in required:
    if not (base/'build'/name).is_file():raise RuntimeError('Missing compiled asset: '+name)
files={str(p.relative_to(base)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(base.rglob('*')) if p.is_file() and p.name!='checksums.json' and '.userdb' not in str(p)}
(base/'checksums.json').write_text(json.dumps(files,indent=2)+'\n')
print('Compiled',len(files),'resources')
