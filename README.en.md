# RIMES

**[中文](README.md)** · **[English](README.en.md)**

A modern macOS input method built from scratch: **librime** engine + custom candidate UI + a persistent **buffer workbench**. Ships with Feiyao chord/mutual typing, Natural Code double Pinyin, full Pinyin, and English. **Self-contained** — librime and Rime data are bundled; no separate Squirrel install required.

> Internal codename remains **RimeBuffer** (SPM target, `Sources/RimeBuffer/`). `ETInput.app` is kept as a compatibility path for existing installs and in-app updates. The public product name is **RIMES** (rime-scholay).

## Demo videos

- [Bilibili — full walkthrough](https://www.bilibili.com/video/BV17XuH6SEDg/)
- [Douyin — product demo](https://www.douyin.com/video/7671078195197742355)

Shorter feature clips (live translation, AI generate, stream input, My Prompt, Remarkable, Marine, and more) are in the same Bilibili collection.

## What problem it solves

Most IMEs commit straight into the focused field. RIMES inserts a **pre-commit text workbench**:

1. Chinese / English land in the buffer first
2. You can translate, rewrite with AI, look up prompts, or attach browser page context
3. Only after you confirm — paper-plane or Return — does text get **explicitly delivered** into the live input field

Nothing auto-posts, and nothing silently edits the web page. Built for writing, commenting, bilingual work, and AI-assisted flows.

## Highlights

| Capability | Notes |
|---|---|
| Input schemes | Full Pinyin, Natural Code double Pinyin, English; Feiyao chord / mutual |
| Buffer workbench | Toggle with `⌘⇧B`; stage first, deliver in chunks |
| Live translation | Apple on-device translation by default (macOS 15+); AI connector optional |
| AI generate | Codex CLI / Claude Code CLI / OpenAI-compatible API |
| Stream input | Pinyin/chords → up to 3 mutually exclusive guesses → deliver the chosen one |
| My Prompt | Local-first retrieval over Fabric / Obsidian-style prompt libraries |
| Marine Chrome | Chrome extension supplies page context (e.g. Bilibili comment/reply); generate only after local confirm |
| Remarkable | USB + on-device OCR of the current page into the buffer |
| Remote typing | Encrypted Mac ↔ Mac delivery; no shared Wi‑Fi or Apple ID required |

## Install

End users: download `RIMES-<version>.pkg` from [GitHub Releases](https://github.com/scholay/rimes/releases) and run the installer. It places the compatibility bundle `ETInput.app` in `/Library/Input Methods`, then registers, enables, and tries to switch to “RIMES”.

Developers:

```bash
./build_install.sh                # build + install for current user + register
.build/release/RimeBuffer smoke   # engine self-check without install
tail -f ~/rimebuffer.log          # behavior log
```

More smoke targets and the release pipeline are documented in [RELEASE.md](RELEASE.md).

### Windows / Linux input-schemes preview

Windows and Linux currently receive a separate **Data / Input-Schemes Preview**. It reuses
RIMES's four Rime schemas, dictionaries, Lua modules, and same-batch chord configuration, but
requires an existing installation of [Weasel](https://github.com/rime/weasel) on Windows or
[Fcitx5 Rime](https://github.com/fcitx/fcitx5-rime) / [IBus Rime](https://github.com/rime/ibus-rime)
on Linux.

The preview does not include the macOS buffer workbench, AI/translation/OCR, native settings,
or a RIMES-owned Windows TSF or Linux Fcitx5/IBus frontend. Cross-batch mutual typing is a
current macOS frontend feature and cannot be supplied by a data package alone. Use the
**Pre-release** assets named `RIMES-Windows-Data-Preview-*` or
`RIMES-Linux-Data-Preview-*`; see [CROSS-PLATFORM-PREVIEW.md](CROSS-PLATFORM-PREVIEW.md)
for the exact boundary, safety model, and validation commands.

### Marine Chrome (optional)

Stable Chrome only today. Extension sources live in [`Extensions/marine-chrome`](Extensions/marine-chrome):

1. Open `chrome://extensions`, enable Developer mode, load unpacked `Extensions/marine-chrome`
2. Complete the two-sided pairing with RIMES in the UI (no secret pasting)
3. Enable Buffer + Marine Chrome in RIMES and select it as the workbench owner

The extension is a page sensor only: it does not run a model, auto-fill fields, or publish content.

## Docs

| Doc | Contents |
|---|---|
| [SYSTEM-ARCHITECTURE.md](SYSTEM-ARCHITECTURE.md) | Authoritative system architecture (start here if hacking) |
| [ARCHITECTURE.md](ARCHITECTURE.md) | P1/P2 historical contracts and footguns |
| [PLUGIN-CONFIGURATION.md](PLUGIN-CONFIGURATION.md) | Declarative plugin configuration |
| [CROSS-PLATFORM-PREVIEW.md](CROSS-PLATFORM-PREVIEW.md) | Windows / Linux input-schemes preview boundary and validation |
| [RELEASE.md](RELEASE.md) | CI, universal binaries, in-app updates |

## Auto-update

Installed builds check GitHub Releases on [`scholay/rimes`](https://github.com/scholay/rimes). To ship:

```bash
./scripts/release.sh patch         # stable macOS release
./scripts/release.sh preview 0.2.0 # Windows/Linux data preview
```

Both release channels are published in the new repository: macOS `vX.Y.Z`
is stable, while Windows/Linux `platform-preview-vX.Y.Z` is always a pre-release.

## Known issues

- **On macOS 26, switching input methods while WeChat is focused may crash WeChat** (inside Apple’s `TextInputUIMacHelper`). Upstream issue; also affects stock Rime/Squirrel ([rime/squirrel#951](https://github.com/rime/squirrel/issues/951)). **Workaround**: switch IME elsewhere first, then focus WeChat.

## License & third parties

RIMES-authored code is released under the [MIT License](LICENSE). Bundled Rime
schemas, dictionaries, and Lua/OpenCC data retain their GPL/LGPL/CC licenses
and attribution; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
`rime-data/licenses/` for the exact boundary.
