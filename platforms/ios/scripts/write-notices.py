#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[3];base=root/'platforms/ios'
text='RIMES iOS 0.1 — Third-party notices\n\n'
text+='RIMES application code and original minimal schemas: MIT, Copyright 2026 scholay.\n'
text+='librime 1.17.0, commit 33e78140250125871856cdc5b42ddc6a5fcd3cd4: BSD-3-Clause.\n'
text+='Build dependencies: LevelDB (BSD), Marisa (BSD/LGPL dual, BSD option), OpenCC (Apache-2.0), yaml-cpp (MIT), Boost (BSL-1.0). Revisions: dependencies.lock.json. OpenCC bundles Marisa and RapidJSON headers with the notices below.\n'
text+='pinyin_simp dictionary: rime/rime-pinyin-simp, commit 0c6861ef7420ee780270ca6d993d18d4101049d0, Apache-2.0. Derived upstream from Android PinyinIME.\n'
text+='Wubi 86: rime/rime-wubi commit 152a0d3f3efe40cae216d1e3b338242446848d07, LGPL-3.0. Original YAML dictionary included in EngineData, unchanged. Development-only pending distribution review.\n'
text+='FlyYao mappings: RIMES chord-keymaps/Isaac2025.json at 20651da. Provenance/distribution review pending.\n'
text+='The iOS schemas omit all desktop Lua, reverse-lookup schemas, predictive plugins and external includes. These modifications are separate from the unchanged dictionary source.\n'
for file in sorted((base/'Licenses').glob('*')):text+='\n--- '+file.name+' ---\n'+'\n'.join(line.rstrip() for line in file.read_text().splitlines()).rstrip()+'\n'
text+='\n--- RIMES MIT ---\n'+(root/'LICENSE').read_text()
(base/'Resources/THIRD_PARTY.txt').write_text(text)
