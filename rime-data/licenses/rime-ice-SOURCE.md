# Rime Ice and related data source notice

- Primary upstream: https://github.com/iDvel/rime-ice
- Upstream license: GNU General Public License version 3 only
- RIMES import revision: `d6d9f9cea97da478540b8a5e9a5c102216e2cf1d`
- Corresponding source: the plain-text files under `rime-data/` in the RIMES
  repository and in each platform preview archive
- License text: `GPL-3.0.txt` in this directory

The original upstream commit identifier was not recorded when the data was
first imported into RIMES. The exact imported snapshot is therefore identified
by the RIMES import revision above; all later RIMES changes remain available in
the public repository history. No generated Rime `build/` output or user
database is distributed as source.

The preview closure derived from Rime Ice includes its full/double-pinyin
schemas, supporting dictionaries, Lua modules, OpenCC data, symbol tables,
custom phrases, and the radical-pinyin and melt-English dependencies. RIMES's
own schema selection and `my_combo` changes are tracked separately in the same
repository.

`lua/search.lua` retains its embedded attribution to Mirtle and its separate
CC BY-SA 4.0 notice:

- Source: https://github.com/mirtlecn/rime-radical-pinyin/blob/master/search.lua.md
- License: https://creativecommons.org/licenses/by-sa/4.0/

Source URLs and copyright/license headers embedded in individual files remain
part of the corresponding source and must not be removed.
