# RIMES

**[中文](README.md)** · **[English](README.en.md)**

A modern macOS input method built from scratch: **librime** engine + custom candidate UI + a persistent **buffer workbench**. Its core schemes are Rime Ice full Pinyin, Natural Code double Pinyin, Xiaohe double Pinyin, Wubi 86, and English; Feiyao chord/mutual typing is supplied by the disabled-by-default Chording extension. **Self-contained** — librime and Rime data are bundled; no separate Squirrel install required.

> Internal codename remains **RimeBuffer** (SPM target, `Sources/RimeBuffer/`). `ETInput.app` is kept as a compatibility path for existing installs and in-app updates. The public product name is **RIMES** (rime-scholay).

## Demo videos

- [Bilibili — full walkthrough](https://www.bilibili.com/video/BV17XuH6SEDg/)
- [Douyin — product demo](https://www.douyin.com/video/7671078195197742355)

Shorter feature clips for live translation, AI generation, stream input, and more are in the same Bilibili collection.

## What problem it solves

Most IMEs commit straight into the focused field. RIMES inserts a **pre-commit text workbench**:

1. Chinese / English land in the buffer first
2. You can translate in real time or generate and rewrite with the selected AI connector
3. Only after you confirm — paper-plane or Return — does text get **explicitly delivered** into the live input field

Nothing auto-posts, and nothing silently edits the web page. Built for writing, commenting, bilingual work, and AI-assisted flows.

## Highlights

| Capability | Notes |
|---|---|
| Input schemes | Rime Ice full Pinyin, Natural Code and Xiaohe double Pinyin, Wubi 86, English; optional Chording extension |
| Buffer workbench | Toggle with `⌘⇧B`; stage first, deliver in chunks |
| Clipboard history | Show / hide with `⌘⇧P`; read only while the workbench is safely visible |
| Settings | Open Settings anywhere with `⌘⇧S` |
| Live translation | Apple on-device translation by default (macOS 15+); AI connector optional |
| AI generate | Codex CLI / Claude Code CLI / OpenAI-compatible API |
| Stream input | Pinyin/chords → up to 5 configured mutually exclusive guesses → deliver the chosen one |
| Remote typing | Encrypted Mac ↔ Mac delivery; no shared Wi‑Fi or Apple ID required |

<!-- BEGIN PRESET BUFFER PLUGINS -->
## Preset buffer plug-ins

This table is generated from [`Catalog/buffer-plugins.json`](Catalog/buffer-plugins.json). Every plug-in update must also update its catalog version and pass `python3 scripts/sync-buffer-plugin-catalog.py --check`.

| Plug-in | ID | Version | Default installation | Default state |
|---|---|---:|---|---|
| AI Generation | `builtin.ai-text` | 2.1 | Bundled with RIMES | Enabled |
| Real-time Translation | `builtin.apple-translation` | 2.1 | Bundled with RIMES | Enabled |
| Stream of Consciousness Input | `builtin.stream-input` | 1.3 | Bundled with RIMES | Enabled |

Every plug-in in the table is bundled with RIMES and enabled on a clean first run.
<!-- END PRESET BUFFER PLUGINS -->

## Built-in extensions

| Extension | Stable ID | Version | Default state |
|---|---|---:|---|
| Statistics | `builtin.statistics` | 1.0 | Enabled |
| Typing Speed | `builtin.typing-speed` | 1.0 | Enabled |
| Chording | `builtin.fly-chord-learning` | 2.0 | Disabled |

Chording 2.0 preserves the legacy ID and learning progress while taking ownership of Feiyao chord/mutual input, the chord window, lessons, practice, and progress. When disabled, ordinary input cannot enter the Feiyao schema and Stream Input returns to sequential full Pinyin.

## Install

### Temporary free preview (v0.4.3)

Until the project can join the Apple Developer Program, community testers may download
`RIMES-0.4.3.pkg` from the official
[GitHub Pre-release v0.4.3](https://github.com/scholay/rimes/releases/tag/v0.4.3).
This package is **unsigned, not notarized, and not verified by Apple**; it is not a formal
release. Download only from `scholay/rimes`, then compare the package's locally calculated
SHA-256 with the value published on that Release page.

Double-click the package once to trigger the macOS warning, then choose **Open Anyway** under
**System Settings → Privacy & Security** and continue in Installer. If RIMES does not appear as
an input source, log out and back in. Never disable Gatekeeper globally or remove quarantine
attributes with `xattr`. Stop if macOS says the package is “damaged” or “will damage your
computer”. An organization-managed Mac may block this exception through MDM. See
[the detailed preview guide](UNSIGNED-PREVIEW.md) and
[Apple's official guidance](https://support.apple.com/zh-cn/102445).

The v0.4.3 preview cannot use in-app updates. When a higher Developer ID-signed and
Apple-notarized release becomes available, preview users must download and install it manually
once from the official Release page.

### Formal releases

After Developer ID becomes available, formal releases will continue to provide only
Developer ID-signed and Apple-notarized `RIMES-<version>.pkg` files through
[GitHub Releases](https://github.com/scholay/rimes/releases). The installer fixes the
compatibility bundle `ETInput.app` at `/Library/Input Methods`, then registers and enables the
parent/child input sources in order and makes one best-effort switch to “RIMES”. If a recent
macOS release does not refresh the input menu immediately, installation still succeeds; log
out and back in, then confirm RIMES in System Settings. Do not terminate
`TextInputMenuAgent` or `imklaunchagent`.

Developers:

```bash
./build_install.sh                # build + install for current user + register
.build/release/RimeBuffer smoke   # engine self-check without install
tail -f ~/rimebuffer.log          # behavior log
```

More smoke targets and the release pipeline are documented in [RELEASE.md](RELEASE.md).

### Windows / Linux input-schemes preview

Windows and Linux currently receive a separate **Data / Input-Schemes Preview**. It reuses
RIMES's five core Rime schemas, dictionaries, Lua modules, plus the packaged optional Chording
schema data, but
requires an existing installation of [Weasel](https://github.com/rime/weasel) on Windows or
[Fcitx5 Rime](https://github.com/fcitx/fcitx5-rime) / [IBus Rime](https://github.com/rime/ibus-rime)
on Linux.

The repository also contains an in-development
[native Windows foundation](platforms/windows/native/README.md). Its x64/Win32 TSF registration,
bounded Broker protocol, real `librime` session, and committed-text path have been validated on
Windows 11. It remains a commit-only engineering milestone: preedit and candidate UI, Broker logon
startup, a signed installer, and the macOS buffer/workbench are not yet implemented, so it is not
included in a public release.

The public data preview does not include the macOS buffer workbench, AI/translation/OCR, native
settings, the experimental Windows TSF described above, or a Linux Fcitx5/IBus frontend.
Cross-batch mutual typing is a current macOS frontend feature and cannot be supplied by a data
package alone. Use the
**Pre-release** assets named `RIMES-Windows-Data-Preview-*` or
`RIMES-Linux-Data-Preview-*`; see [CROSS-PLATFORM-PREVIEW.md](CROSS-PLATFORM-PREVIEW.md)
for the exact boundary, safety model, and validation commands.

## Docs

| Doc | Contents |
|---|---|
| [SYSTEM-ARCHITECTURE.md](SYSTEM-ARCHITECTURE.md) | Authoritative system architecture (start here if hacking) |
| [ARCHITECTURE.md](ARCHITECTURE.md) | P1/P2 historical contracts and footguns |
| [PLUGIN-CONFIGURATION.md](PLUGIN-CONFIGURATION.md) | Declarative plugin configuration |
| [UNSIGNED-PREVIEW.md](UNSIGNED-PREVIEW.md) | Download, verification, and safe-install steps for the unsigned v0.4.3 preview |
| [CROSS-PLATFORM-PREVIEW.md](CROSS-PLATFORM-PREVIEW.md) | Windows / Linux input-schemes preview boundary and validation |
| [RELEASE.md](RELEASE.md) | CI, universal binaries, in-app updates |

## Auto-update

Formally signed builds check GitHub Releases on
[`scholay/rimes`](https://github.com/scholay/rimes); the unsigned v0.4.3 preview is excluded
from that channel. To ship:

```bash
./scripts/release.sh patch         # stable macOS release
./scripts/release.sh preview 0.2.0 # Windows/Linux data preview
```

Both release channels are published in the new repository: macOS `vX.Y.Z` is normally stable;
`v0.4.3` is a one-time unsigned pre-release exception and is excluded from auto-update.
Windows/Linux `platform-preview-vX.Y.Z` is always a pre-release.

## Contributors

See [CONTRIBUTORS.md](CONTRIBUTORS.md) for the full list.

**AI coding assistants**: Claude, Cursor, Codex, and Grok helped with design, implementation, and review; humans remain responsible for merges and releases.

## Known issues

- **On macOS 26, switching input methods while WeChat is focused may crash WeChat** (inside Apple’s `TextInputUIMacHelper`). Upstream issue; also affects stock Rime/Squirrel ([rime/squirrel#951](https://github.com/rime/squirrel/issues/951)). **Workaround**: switch IME elsewhere first, then focus WeChat.

## License & third parties

RIMES-authored code is released under the [MIT License](LICENSE). Bundled Rime
schemas, dictionaries, and Lua/OpenCC data retain their GPL/LGPL/CC licenses
and attribution; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
`rime-data/licenses/` for the exact boundary.
