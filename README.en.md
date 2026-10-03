# RIMES

[![中文](.github/readme/labels/zh.svg)](README.md) [![English](.github/readme/labels/en.svg)](README.en.md) [![日本語](.github/readme/labels/ja.svg)](README.ja.md) [![한국어](.github/readme/labels/ko.svg)](README.ko.md) [![Español](.github/readme/labels/es.svg)](README.es.md)

With respect for open source, the Chinese input logic of this project is based on the [RIME input method engine](https://rime.im/).
RIMES is an input method for more than one operating system. Three original slot-like surfaces carry what you want to do: 1. an explicit buffer before text is committed 2. Capsule, for clipboard history, screenshots, and a personal knowledge base 3. Mailbox, a conversation window for information that arrives from outside.

Schemes include full Pinyin, double Pinyin, Shengbi, Wubi, and English, plus the chorded input used in stenography and custom imports. For new users, the package **bundles** librime and the dictionaries and is ready to use.

> The public product name is **RIMES** (rime-scholay).

## Demo videos

- [Bilibili — full walkthrough](https://www.bilibili.com/video/BV17XuH6SEDg/)
- [Douyin — product demo](https://www.douyin.com/video/7671078195197742355)

## What problem it solves

One input method covers everyday translation, generation, and polishing, without leaving the app you are in. The input method and its plug-ins do the work:

- **Buffer** (`⌘⇧B`): a text workbench before commit. Chinese or English enters the buffer first, where you can translate it live or generate and rewrite it with the selected AI connector. After you confirm, it is **explicitly delivered** into the current field.
- **Capsule** (`⌘⇧V`): a bar at the bottom of the screen. Text, links, images, files, and colors you just copied appear in Recent. What you want to keep goes into notes, images, PDFs, skills, or passwords.
- **Mailbox** (`⌘⇧M`): AI conversations, notes, and external items waiting for review stay in this window. You can start a conversation and choose a connector you have already configured.

## Notes on the main capabilities

> After installation and a graphical login, a one-shot background job uses `open -g` to start the same RIMES process, so the global shortcuts for Buffer, Clipboard History, Mailbox, and Capsule work across input methods.
>
> Before a release package replaces the system payload, it audits every ordinary local account. It fails immediately if it finds a same-ID development app or job other than the current GUI user's development install, which postinstall can retire, or if a home cannot be checked safely. Postinstall retires that development install, audits again, and only then updates the system job as a transaction that can be rolled back. The login guard only stops later if development traces appear. Neither job sets `KeepAlive`, and neither starts a second UI/IME service.
>
> Mailbox and Capsule are ordinary windows that take keyboard focus. Opening either from another input method, by shortcut or by a Mailbox notification, switches to RIMES first so the feature is complete. Closing it does not switch back, and a later switch you make yourself is left as you set it. The feature then falls back as described below.
>
> These features do not touch another input method's IMK client, and they do not read, commit, or cancel its composition. The only injected key is the optional single `⌘V` when Capsule activates (see the Capsule bar below). The Settings shortcut also works across input methods. Its Mailbox and Capsule pages show configuration and status only. Conversations and records stay in their own windows.

| Capability | Shortcut | Contents | Action | Storage | Limit |
|---|---|---|---|---|---|
| Input schemes | — | Rime Ice full Pinyin, Natural Code, Xiaohe, Wubi 86, English | — | — | — |
| Buffer | `⌘⇧B` | Text before it is committed | Switch to RIMES, then capture and deliver in chunks | — | After you switch away, only the system clipboard is used, not IMK |
| Capsule bar | `⌘⇧V` | Recent copies; notes, images, PDFs, skills, passwords | Click to select, double-click or Return to paste. `⌘S` saves | This Mac only | Paste needs Accessibility; otherwise it only reaches the clipboard |
| Mailbox | `⌘⇧M` | AI conversations, notes, items waiting for review | New conversation; the first Return starts generation | The model is bound to that conversation | CLIs use their default model |
| Capsule manager | Gear or brush | Five kinds of items, with preview and copy | Four chords reveal a password, for at most 15 seconds | Optional iCloud; passwords and keys stay on this Mac | The passphrase is stored only as a local digest |
| Settings | `⌘⇧S` | Shortcuts, status, sync, and security | Opens only while RIMES is the current input method | — | Does not embed the Mailbox or Capsule windows |

Live translation, AI generation, and stream input are buffer plug-ins. Chording is a built-in extension. Versions and IDs are in the lists below.

| Name | Kind | Notes | Default |
|---|---|---|---|
| Live translation | Buffer plug-in | Apple on-device translation, or AI | Enabled, macOS 15+ |
| AI generation | Buffer plug-in | Codex, Claude Code, or an OpenAI-compatible API. Plain / Markdown / JSON stays in Buffer until you commit it | Enabled |
| Stream input | Buffer plug-in | Pinyin or chords go to the selected AI, which returns at most 5 mutually exclusive guesses | Enabled; delivered only after you choose one |
| Chording | Built-in extension | Combined chords and left-then-right split strokes, plus custom keymaps | Disabled |

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

## Install

Work on macOS, iOS, Windows, Android, and Linux is underway, at different stages. Download links for each platform are coming. Until then, clone the source and build it locally:

```bash
git clone https://github.com/scholay/rimes.git
cd rimes
```

| Platform | Status | Build |
|---|---|---|
| macOS | Input method, plus Buffer, Capsule, and Mailbox | `./build_install.sh` |
| iOS | Keyboard and main app (iOS 17+): offline Pinyin, Natural Code, Wubi, English, and Buffer | Open [`platforms/ios/RIMES.xcodeproj`](platforms/ios/README.md) in Xcode |
| Windows | Native TSF input method: preedit, candidates, and commit. No Buffer, Capsule, or Mailbox yet, and no signed installer | See [`platforms/windows/native/README.md`](platforms/windows/native/README.md) |
| Android | In development | Source is not in this repository yet |
| Linux | Fcitx5 input method, Buffer, and Capsule. No Mailbox yet | See [`platforms/linux/ime/README.md`](platforms/linux/ime/README.md) |

## Documentation

| Document | Contents |
|---|---|
| [SYSTEM-ARCHITECTURE.md](SYSTEM-ARCHITECTURE.md) | Current authoritative architecture. Read this first when taking over development |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Historical P1/P2 contracts and pitfalls |
| [PLUGIN-CONFIGURATION.md](PLUGIN-CONFIGURATION.md) | Declarative plug-in configuration |
| [UNSIGNED-PREVIEW.md](UNSIGNED-PREVIEW.md) | Download, checksum, and safe install steps for the unsigned preview |
| [CROSS-PLATFORM-PREVIEW.md](CROSS-PLATFORM-PREVIEW.md) | Scope and checks for the Windows / Linux scheme preview |
| [platforms/ios/README.md](platforms/ios/README.md) | iOS keyboard and main app |
| [platforms/windows/native/README.md](platforms/windows/native/README.md) | Native Windows TSF input method |
| [platforms/linux/ime/README.md](platforms/linux/ime/README.md) | Linux Fcitx5 input method, Buffer, and Capsule |
| [RELEASE.md](RELEASE.md) | Release process: channels, one-command release, cadence, and version rules |
| [RELEASE-REFERENCE.md](RELEASE-REFERENCE.md) | Release reference: signing, installer, in-app updates, CI |
| [RELEASE-HISTORY.md](RELEASE-HISTORY.md) | Closed release channels, the old repository move, and the rename |
| [CHANGELOG.md](CHANGELOG.md) | Per-version changes generated from public GitHub Releases and commit messages |

## Automatic updates

An installed, formally signed copy of RIMES checks GitHub Releases for [`scholay/rimes`](https://github.com/scholay/rimes). Unsigned `vX.Y.Z-preview.N` builds are not on that channel.

There is one release entry point, and the version comes only from the tag. The process is in [RELEASE.md](RELEASE.md), and the changes are in [CHANGELOG.md](CHANGELOG.md):

```bash
./scripts/release.sh --dry-run preview  # preview the plan, CI gates, and release notes
./scripts/release.sh preview            # unsigned macOS preview vX.Y.Z-preview.N
./scripts/release.sh stable             # promote the preview line to vX.Y.Z (requires Developer ID)
./scripts/release.sh platform minor     # explicit Windows/Linux data preview for maintenance (does not block macOS)
```

Every release is published on `scholay/rimes`. macOS `vX.Y.Z` is a stable release. `vX.Y.Z-preview.N` is an unsigned pre-release and is not updated automatically. Windows/Linux `platform-preview-vX.Y.Z` is always a pre-release.

## Links

- [RIME input method engine](https://rime.im/) — Chinese input in this project is based on RIME.
- [Linux.do](https://linux.do/u/leowangling/preferences/account) — Thanks to Linux.do, a sincere, friendly, united, and professional community, and to its members.
- [iRime](https://github.com/jimmy54/iRime) — Thanks to the iRime author for guidance and for helping introduce RIMES.

## Contributors

The full list is in [CONTRIBUTORS.md](CONTRIBUTORS.md).

The core maintainer is a consumer-product manager, not a programmer by training, and is grateful for the era of vibe coding.

**AI programming assistants**: Claude, Cursor, Codex, and Grok took part in design, implementation, and review.

## Known issues

- **Linux: quitting Fcitx5 before a deploy finishes can leave the process running for minutes.** A first-run or background librime deploy cannot be cancelled, and a larger dictionary makes the wait longer. See [#43](https://github.com/scholay/rimes/issues/43).
- **Linux: clicking another field immediately after dragging the Buffer toolbar can leave capture on.** Reproduced only in Firefox on X11, when the click lands in the same window within about 10 ms of release. Click again or press Esc to recover. See [#44](https://github.com/scholay/rimes/issues/44).

## License and third parties

RIMES's own code is under the [MIT License](LICENSE). Bundled Rime schemes, dictionaries, and Lua/OpenCC data keep their own GPL/LGPL/CC licenses and credits. The full boundary is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and `rime-data/licenses/`.
