# Rime Wubi 86 source notice

- Primary upstream: https://github.com/rime/rime-wubi
- Source revision: `152a0d3f3efe40cae216d1e3b338242446848d07`
- Imported assets:
  - `wubi86.dict.yaml`
  - `wubi86.schema.yaml`
- Upstream license: GNU Lesser General Public License version 3 only
- License text: `rime-wubi-LICENSE` in this directory

The dictionary is redistributed verbatim. Its SHA-256 at import is
`f833d86b72341fe82e069a425b6625f29ef85f1bc0f34f6fb7975fe514888b5a`.

RIMES modifies the schema, as marked in its header, to reuse the already
bundled `rime_ice` dictionary for the `z`-prefixed pinyin reverse lookup and
to use RIMES's bundled `default` punctuation preset. This removes the
upstream `pinyin_simp` runtime dependency without changing the Wubi 86 code
table. The upstream schema SHA-256 is
`cdb5aac1a9aa071552d5fdffdfe5a6618b429b19358b8b1e003130e835d5a166`;
the modified RIMES schema SHA-256 is
`cfc987d641ff625b89de9903202e464841019d12e533168c300d4cb51b17431c`.
The corresponding source is the plain-text `wubi86.schema.yaml` shipped beside
the dictionary.

The upstream attribution records that the dictionary is derived from
ibus-table work by Yu Yuwei and from the original Wubi work by Wang Yongmin;
the file headers and the upstream `AUTHORS` history remain authoritative.
