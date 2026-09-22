# iOS resource and dependency inventory

Checked 2026-09-22. Exact commits and download SHA-256 values are in
`dependencies.lock.json`. Full license texts are in `Licenses/` and are displayed
by the containing app through `Resources/THIRD_PARTY.txt`.

| Shipped component | Source/version | Changes for iOS | License and distribution record |
|---|---|---|---|
| librime | [rime/librime](https://github.com/rime/librime/tree/33e78140250125871856cdc5b42ddc6a5fcd3cd4), 1.17.0 | Static build, logging/external plugins/timestamps disabled; source unmodified | BSD-3-Clause; retain copyright, conditions and disclaimer in source and binary notices |
| LevelDB | [google/leveldb](https://github.com/google/leveldb/tree/99b3c03b3284f5886f9ef9a4ef703d57373e61be) | Static build; optional compression/allocator integrations disabled | BSD-3-Clause; included notice |
| marisa-trie | [s-yata/marisa-trie](https://github.com/s-yata/marisa-trie/tree/3e87d53b78e15f2f43783d5e376561a8c9722051) | Static build, source unmodified | Upstream BSD-2-Clause option selected; included copyright, conditions and disclaimer |
| yaml-cpp | [jbeder/yaml-cpp](https://github.com/jbeder/yaml-cpp/tree/2f86d13775d119edbb69af52e5f566fd65c6953b), 0.8.0 | Static build without tests/tools/contrib | MIT; retain copyright and permission notice |
| OpenCC | [BYVoid/OpenCC](https://github.com/BYVoid/OpenCC/tree/556ed22496d650bd0b13b6c163be9814637970ae), 1.1.9 | Library only on iOS; Darts disabled; no conversion dictionaries or CLI shipped | Apache-2.0; preserve license and applicable notices; no source patches |
| OpenCC bundled marisa | `deps/marisa-0.2.6` at the pinned OpenCC revision | Source unmodified | Upstream BSD-2-Clause option selected; separate included notice |
| OpenCC RapidJSON headers | `deps/rapidjson-1.1.0` at the pinned OpenCC revision | Source unmodified | Upstream MIT/Tencent license and third-party statements retained in the included license file |
| Boost headers | [Boost 1.86.0](https://archives.boost.io/release/1.86.0/source/) | Headers used by librime, no Boost runtime downloaded at launch | Boost Software License 1.0; included license |
| Simplified Pinyin dictionary | [rime-pinyin-simp](https://github.com/rime/rime-pinyin-simp/tree/0c6861ef7420ee780270ca6d993d18d4101049d0) | Dictionary source unchanged; compiled into table/prism assets | Apache-2.0; original source metadata and license retained |
| Wubi 86 dictionary | [rime-wubi](https://github.com/rime/rime-wubi/tree/152a0d3f3efe40cae216d1e3b338242446848d07) | Dictionary bytes match pinned source; compiled into table/prism assets | LGPL-3.0; full license texts, unchanged corresponding source, attribution and source URL bundled. See AppStore/RESOURCE_CLEARANCE.md for distribution basis. |
| FlyYao map | Repository `chord-keymaps/Isaac2025.json` at `20651da` | 426 mappings unchanged; iOS ID/name and default full-Pinyin metadata applied | Publisher-declared functional mapping example; public name Default chord. Source provenance retained. This is not an upstream license grant or an independently verified patent clearance; see AppStore/RESOURCE_CLEARANCE.md. |
| iOS schemas and Ziranma algebra | RIMES original schemas; portable encoding algorithm copied from this repository | Minimal schemas use only built-in Rime processors; no desktop schema chain, Lua, prediction or language model | Repository MIT; generated schema headers identify RIMES authorship; parity check protects desktop encoding behavior |
| App icon | Generated from the owner's existing Scholay Rhino 2D reference assets, at their request | Flat black monoline rhino and backwards cap on white; 1024-square opaque PNG | Owner-provided character reference; generated with built-in image_gen. Prompt and provenance in `AppStore/icon/monoline/`; model version not exposed by tool |

XcodeGen 2.46.0 is a checksum-pinned build tool and is not shipped in the app.
CMake, Git, Python and the Apple toolchain are host tools. OpenCC's test frameworks,
benchmarks, bindings and command-line parsers are not included in the iOS library.

`scripts/prepare-data.py` records checksums for the generated engine assets.
`scripts/verify.py` checks dictionary sources, mapping parity, generated hashes,
schema allowlist and the release audit. Permission changes require evidence in
`distribution-audit.json`; neither this inventory nor a successful build is a
TestFlight redistribution clearance.
