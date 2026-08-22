# Third-party notices

## Rime Ice configuration and dictionaries

The Rime schemas, dictionaries, Lua modules, OpenCC data, symbol tables, and
supporting files under `rime-data/` include material derived from
[`iDvel/rime-ice`](https://github.com/iDvel/rime-ice), distributed under the
GNU General Public License version 3 only. The original import is identified by
RIMES commit `d6d9f9cea97da478540b8a5e9a5c102216e2cf1d`; subsequent modifications
are available in this repository's history. The corresponding source is the
plain-text data shipped in this repository and in the preview packages.

The GPL text and a detailed source notice are included as
`rime-data/licenses/GPL-3.0.txt` and
`rime-data/licenses/rime-ice-SOURCE.md`.

The Xiaohe double-pinyin mapping and its mixed Chinese/English static table
are additionally pinned to upstream Rime Ice revision
`c398c0d4526b012cb3b306f792089abed13e0413`. The schema header and Rime Ice
source notice record the RIMES adaptation and exact checksums.

`rime-data/lua/search.lua` retains its embedded attribution to Mirtle and is
licensed separately under
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/); its source URL
is recorded both in the file header and the Rime Ice source notice.

## rime-easy-en dictionary

`rime-data/easy_en.dict.yaml` is imported from
[`BlindingDark/rime-easy-en`](https://github.com/BlindingDark/rime-easy-en) at
revision `54a4a07289412efc54134092c0d945f895a71ed3` and is distributed under
the GNU Lesser General Public License version 3. The license and source notice
are included under `rime-data/licenses/`.

## Rime Wubi 86

`rime-data/wubi86.schema.yaml` and `rime-data/wubi86.dict.yaml` are imported
from [`rime/rime-wubi`](https://github.com/rime/rime-wubi) at revision
`152a0d3f3efe40cae216d1e3b338242446848d07` and are distributed under the GNU
Lesser General Public License version 3. The dictionary is verbatim; RIMES
modifies the schema to use the already bundled Rime Ice dictionary for pinyin
reverse lookup and the bundled default punctuation preset. The exact source,
modification boundary, checksum, and license text are included as
`rime-data/licenses/rime-wubi-SOURCE.md` and
`rime-data/licenses/rime-wubi-LICENSE`.

RIMES-authored application and packaging code remains MIT-licensed. Those MIT
terms do not replace the licenses above for third-party data.

## GRDB.swift

The My Prompt local search index uses
[`groue/GRDB.swift`](https://github.com/groue/GRDB.swift), version 7.11.1.

Copyright (C) 2015-2025 Gwendal Roué

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## rmscene

The narrow reMarkable v6 typed-text reader in RIMES is informed by
[`ricklupton/rmscene`](https://github.com/ricklupton/rmscene), version 0.8.0.

Copyright (c) 2022 Rick Lupton

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
