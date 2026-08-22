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

## Xiaohe double-pinyin addition

The release-quality Xiaohe scheme added on 2026-08-22 uses these pinned
primary-upstream inputs from `iDvel/rime-ice` revision
`c398c0d4526b012cb3b306f792089abed13e0413`:

- `double_pinyin_flypy.schema.yaml`: the Xiaohe preedit and speller mappings
  were transplanted into RIMES's already-bundled Rime Ice schema snapshot, as
  documented in the modified file header. The pinned upstream schema SHA-256
  is `73c4f66483b7ff19c3bd64308df37de2d22693511711f75da657d1b179b88e32`;
  its RIMES SHA-256 is
  `3bc68712c8b9590169dd5f03c37f7d9a7bb5a071d9f8f792703ecb7970f973fb`.
- `en_dicts/cn_en_flypy.txt`: redistributed verbatim; SHA-256
  `edeee1d7a84b378a248a3ea1384f22dcfde64694caee87fe05901a09a90cfc6f`.

Both remain covered by the upstream GNU General Public License version 3 only
and by the `GPL-3.0.txt` copy in this directory.

`lua/search.lua` retains its embedded attribution to Mirtle and its separate
CC BY-SA 4.0 notice:

- Source: https://github.com/mirtlecn/rime-radical-pinyin/blob/master/search.lua.md
- License: https://creativecommons.org/licenses/by-sa/4.0/

Source URLs and copyright/license headers embedded in individual files remain
part of the corresponding source and must not be removed.
