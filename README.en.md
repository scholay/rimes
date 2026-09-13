# RIMES

**[中文](README.md)** · **[English](README.en.md)**

A modern macOS input method built from scratch: **librime** engine + custom candidate UI + a persistent **buffer workbench**. Its core schemes are Rime Ice full Pinyin, Natural Code double Pinyin, Xiaohe double Pinyin, Wubi 86, and English; the disabled-by-default Chording extension supplies the Feiyao preset and custom keymaps, with one behavior supporting both combined and left-then-right split strokes. **Self-contained** — librime and Rime data are bundled; no separate Squirrel install required.

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

After installation and an Aqua login, a one-shot background job uses `open -g` to start the same RIMES process. Buffer, Clipboard History, Mailbox, and Capsule shortcuts therefore work regardless of the active input source. A development install atomically publishes a per-user job. Before replacing the system payload, the package audits every ordinary local account and fails closed on any same-ID development app/job except a verified current-GUI-user install that postinstall can retire, or when a home cannot be checked safely. Postinstall retires that development install, audits again, and only then updates the system job as a rollback-capable transaction; the login guard's check for development artifacts is only a later defensive stop. Neither job has a `KeepAlive` policy or starts a second UI/IME service. Mailbox and Capsule are ordinary key windows. Under another IME, these companion features never access an IMK client, switch the input source, inject paste or other keystrokes, use Accessibility/Post Event, or read, commit, or cancel that IME's composition. Settings remains available only while a RIMES input source is active; its Mailbox and Capsule pages show configuration and status only, while actual conversations and records stay in their standalone windows.

| Capability | Notes |
|---|---|
| Input schemes | Rime Ice full Pinyin, Natural Code and Xiaohe double Pinyin, Wubi 86, English; optional Chording extension |
| Buffer workbench | Toggle with `⌘⇧B`; with a RIMES input source it can capture text and deliver it in chunks, while under another input source it only allows explicit system-pasteboard import and result copying and never accesses IMK delivery |
| Capsule rail | Formerly Clipboard History, a peer of Buffer; `⌘⇧P` opens its standalone bottom window across input sources. Header tabs switch between Recent (the clipboard history) and read-only Notes, Images, PDFs, Skills and Passwords; `⌘S` saves the selected Recent cards into Capsule, and the gear and a card's hover brush open the Capsule manager. While capture is enabled and unprotected, it records text, links, images, files, colors, and their lossless representations in a private local database. A single click only selects; double-click, Return, or `⌘1`–`⌘9` activates. With another input source active, every record type only restores the original system-pasteboard payload, moves to the front of history, and closes silently; the user then presses `⌘V`. RIMES never invokes Paste, a context menu, synthetic `⌘V`, Accessibility, or Post Event. `⌘C` still only copies the selection |
| Mailbox | A peer of Buffer; `⌘⇧M` toggles its ordinary key window across input sources and retains conversations and reviews independently. “New Conversation” selects from configured connectors/models: each CLI exposes only its default model, while OpenAI uses the locally configured model. The selection is frozen per conversation without changing the global setting; the process-local draft creates no empty thread, and the first Return creates the conversation and starts generation |
| Capsule manager | Opened from the rail's gear or a card's brush and drawn as the rail grown upward; the gear or Esc returns to the rail. It manages five local record kinds, and previews or copies images/PDFs/files. Revealing a Password requires four ordered native physical-key chords; the default is `RH / WO / CVN / QU`, four slots show progress, and plaintext is concealed after at most 15 seconds. Changing or resetting the code first requires the current credential; raw custom chords are never stored or synced, only one local salted-digest credential. An optional chosen iCloud Drive folder syncs six portable kinds and media assets while Passwords, Skill paths, the reveal credential, and the master key stay local |
| Settings | Open Settings with `⌘⇧S` only while the active input source belongs to RIMES; the Mailbox and Capsule pages contain shortcut, local-status, sync, and security configuration rather than their operational panes |
| Live translation | Apple on-device translation by default (macOS 15+); AI connector optional |
| AI generate | Codex CLI / Claude Code CLI / OpenAI-compatible API; results stay in Buffer with Plain / Markdown / JSON output and are delivered only by the user |
| Stream input | Pinyin/chords → low-latency local Rime + Octagram, with AI fallback for complex input → up to 5 mutually exclusive guesses → deliver the chosen one |
| Remote typing | Encrypted Mac ↔ Mac delivery; no shared Wi‑Fi or Apple ID required |

<!-- BEGIN PRESET BUFFER PLUGINS -->
## Preset buffer plug-ins

This table is generated from [`Catalog/buffer-plugins.json`](Catalog/buffer-plugins.json). Every plug-in update must also update its catalog version and pass `python3 scripts/sync-buffer-plugin-catalog.py --check`.

| Plug-in | ID | Version | Default installation | Default state |
|---|---|---:|---|---|
| AI Generation | `builtin.ai-text` | 2.1 | Bundled with RIMES | Enabled |
| Real-time Translation | `builtin.apple-translation` | 2.1 | Bundled with RIMES | Enabled |
| Stream of Consciousness Input | `builtin.stream-input` | 1.4 | Bundled with RIMES | Enabled |
| Electronic Music | `builtin.music` | 0.2.3 | Bundled with RIMES | Enabled |

Every plug-in in the table is bundled with RIMES and enabled on a clean first run.
<!-- END PRESET BUFFER PLUGINS -->

## Built-in extensions

| Extension | Stable ID | Version | Default state |
|---|---|---:|---|
| Statistics | `builtin.statistics` | 2.0 | Enabled |
| Typing Speed | `builtin.typing-speed` | 2.0 | Enabled |
| Chording | `builtin.fly-chord-learning` | 2.0 | Disabled |

Chording preserves the legacy ID and learning progress, with a single behavior supporting combined and left-then-right split strokes instead of separate modes. It manages editable keymaps, the chord window, lessons, practice, and progress; Feiyao is a built-in preset that can be copied and customized. When disabled, ordinary input returns to an ordinary scheme and Stream Input returns to sequential full Pinyin. See the [keymap and migration guide](CHORD-KEYMAPS.md).

## Install

### Unsigned public preview (v0.5.0-preview.1)

Until the project can join the Apple Developer Program, community testers may download
`RIMES-0.5.0-preview.1.pkg` from the official
[GitHub Pre-release v0.5.0-preview.1](https://github.com/scholay/rimes/releases/tag/v0.5.0-preview.1).
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

The `v0.5.0-preview.1` preview cannot use in-app updates. When a Developer ID-signed and
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
Cross-batch split-stroke pairing is a current macOS frontend feature and cannot be supplied by a data
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
| [UNSIGNED-PREVIEW.md](UNSIGNED-PREVIEW.md) | Download, verification, and safe-install steps for the current unsigned preview |
| [CROSS-PLATFORM-PREVIEW.md](CROSS-PLATFORM-PREVIEW.md) | Windows / Linux input-schemes preview boundary and validation |
| [RELEASE.md](RELEASE.md) | CI, universal binaries, in-app updates |

## Auto-update

Formally signed builds check GitHub Releases on
[`scholay/rimes`](https://github.com/scholay/rimes); unsigned `vX.Y.Z-preview.N` builds are excluded
from that channel. To ship:

```bash
./scripts/release.sh patch         # stable macOS release
./scripts/release.sh preview 0.2.0 # Windows/Linux data preview
```

All release channels are published in the new repository: macOS `vX.Y.Z` is formal;
`vX.Y.Z-preview.N` is an unsigned pre-release excluded from auto-update. Windows/Linux
`platform-preview-vX.Y.Z` is always a pre-release.

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
