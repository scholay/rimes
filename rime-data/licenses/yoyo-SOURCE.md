# 呦呦音形 (yoyo) source notice

The 呦呦音形 chord schemes of 麓鸣输入法 are by Rayalizing, from
[`Rayalizing/yoyo`](https://github.com/Rayalizing/yoyo) at revision
`2f9dcc86f04558282c185b7c712630a311b8513b` (2026-08-13), directory `rime/`.

RIMES bundles the 音形 branch only: 折梅 fingering (`yoyo-yx`) and 寒梅
fingering (`yoyo-yx-hm`). The pure-shape schemes (北冥, 无相), the practice
schema, yoyo's `default.yaml`, scripts, fonts and web assets are not included.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `yoyo.yaml` | 21,046 | `c1df2b6e519503c3f5e9e12cd2615de10b9790308b71a10c4ad11aa0a3809361` |
| `yoyo-yx.schema.yaml` | 5,776 | `4e77d96fdf6bc87a7b4610b2c59e244b1ba5e385aae4e7d2f1eae1c4245c6751` |
| `yoyo-yx-hm.schema.yaml` | 6,231 | `c3c036501bad66e54729d93449ea4d6bfb881d2cb87bedb3c17300f26f178d58` |
| `yoyo-yx.dict.yaml` | 538 | `d16e2395655132b8fc00ab3a05023ad46e6bbdaa517f20a7017a2f22067339e5` |
| `yoyo-yx-hm.dict.yaml` | 541 | `986733db582206f37046aeeff0376a9b43a74137f9bb257586af7f537cfdaf49` |
| `yoyo-yx-char.dict.yaml` | 226,874 | `14ae9b2c1e9e0a4b0257a777d9d7df95ad826576efbbcefc6d24ecbefc8eb71e` |
| `yoyo-yx-word.dict.yaml` | 16,645,418 | `703b60c094f9acebfaa31fc252d8809ed0af8a05a0b94edfc94866bcd9548284` |
| `yoyo_kf.dict.yaml` | 1,445 | `304d5f170e35c4a4f3b385bd9e48690356085f38a06e7ec45d4ac6fc7183bb36` |
| `lua/yoyo/commit_raw.lua` | 1,120 | `7cde8b1052eab5b7b4cad89f3da8a6bf752593df4ef02c12c4d15b0fa06a5ad3` |
| `lua/yoyo/popping.lua` | 3,067 | `f895cb3baa686f32a6fabdaf0b703f43102a0f452eaa8f932cbe88a495d56a01` |
| `lua/yoyo/yoyo.lua` | 1,214 | `b34c156d39f43277e7cc2a61bbc3139984d2104b4f786401717acd63e013cd72` |

All files are verbatim except `yoyo_kf.dict.yaml`, whose CRLF line endings
are normalized to LF by this repository's `.gitattributes` (`rime-data/**
text eol=lf`); its content is otherwise unchanged. RIMES does not patch the
schemas: the chord extension selects them and delivers physical key presses
and releases to librime's `chord_composer`.

## License

The upstream repository does not declare a license. Its encoding scripts
(`rime/scripts/编码生成和重码可视化/data/`) include Rime Ice data under the GNU
General Public License version 3, and the site ranks words by the 白霜 (rime-frost)
dictionary; whether the generated dictionaries carry those terms is for the
author to state.

RIMES bundles these files with attribution and unmodified content. No explicit
license or redistribution grant from the author has been recorded; RIMES will
remove them, or adopt the terms the author chooses, at the author's request.
