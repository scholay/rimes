# RIMES Native Windows Foundation

Current stable release: **[1.1.0](https://github.com/scholay/rimes/releases/tag/windows-v1.1.0)**. Download the EXE installer for a data-preserving upgrade. Version resources are unified; [acceptance evidence](validation/2026-10-04-1.1.0.md) distinguishes package checks, the actual upgrade and remaining daily-use coverage.

Post-release damaged-install recovery, candidate settings and caret placement
changes have [separate source/native test evidence](validation/2026-10-07-community-repair.md).
They still require a new packaged candidate and real desktop acceptance.

This directory contains the native Windows implementation of RIMES. It is
separate from the Weasel data preview in the parent directory.

The in-process TSF DLL stays small:

- `RimesTsf.dll` is the Windows Text Services Framework boundary. It now
  starts an inline composition (preedit + dotted display attribute), shows a
  DPI-aware candidate window near `ITfContextView::GetTextExt`, and commits
  through a write edit session.
- `RimesBroker.exe` is a per-user process that owns the single `librime`
  instance. Missing path flags resolve to files next to the executable or to
  `%LOCALAPPDATA%\RIMES` / `%APPDATA%\RIMES`. `--install-autostart` writes a
  current-user Run key. The TSF client launches a sibling Broker on first use
  and reconnects after a crash.
- `RimesRegistrar.exe` registers or removes the TSF text service.
- `src/core` is the bounded named-pipe protocol shared by TSF and Broker.
- `librime/` pins official `rime.dll` (x64 and x86) for CI and local smokes.

TSF still must not load `librime` or do network I/O. Broker failure fail-opens.

Installation and host acceptance are recorded in the
[1.1.0 delivery report](../../../validation/release-1.1.0/delivery.md).
The [1.0.0 preparation checklist](RELEASE-1.0.0.md) remains historical context.

## Interaction (macOS-aligned)

Where the TSF host cooperates, typing matches the macOS RIMES controller:

- Latin keys while composing stay inside the engine.
- Space commits the highlighted candidate.
- `1`–`9` select by label.
- PageDown / PageUp page the menu.
- Escape cancels and commits nothing.
- A short independent Shift tap uses the scheme's Chinese/English switch.
  Its raw-code commit is collected immediately while Shift remains a host
  modifier. Other key combinations, long holds and focus changes cancel the
  tap; unavailable or older Brokers do not receive deferred input.

The candidate panel is a `WS_EX_NOACTIVATE` topmost tool window so it cannot
steal focus from the host.

Settings → Appearance → Size controls the candidate font, page size (1–9),
and vertical arrangement. Page size changes the real librime menu pagination.
Vertical candidates use additional columns when the current monitor is too
short to fit the page. If the host temporarily cannot resolve its caret, the
panel keeps the last position within the current focus context; with no valid
position it stays hidden until a caret is available.

New Buffer shortcut settings default to **Ctrl+Shift+B**, corresponding to
macOS Cmd+Shift+B. Saved Ctrl+Alt shortcuts are retained; Settings can select
either combination and another letter. A conflicting shortcut is reported,
and a failed change keeps the previous shortcut active. Buffer remains
accessible from the tray when registration fails.

Ctrl/Alt/Win/AltGr combinations with Return, Backspace or Escape are host
commands, even while Buffer captures ordinary input. Switching the workbench
back to Input stops automatic translation and queued processing; source and
completed results remain available for explicit sending. These changes describe
the current source, not a replacement of the published 1.1.0 installer.

## Build

Use a Visual Studio 2022 developer environment with the x86/x64 C++ workload
and a current Windows SDK:

```powershell
cmake --preset windows-x64
cmake --build --preset windows-x64-release
ctest --preset windows-x64-release

cmake --preset windows-x86
cmake --build --preset windows-x86-release
ctest --preset windows-x86-release
```

Both architectures are required. A 64-bit TSF DLL cannot be loaded by a
32-bit application, and vice versa.

CTest covers protocol, engine unit, key translation, broker options, candidate
layout, registrar metadata, the pipe endpoint, and inferred default paths. It
does not load `rime.dll`.

## Pinned librime and typing tests

```powershell
..\scripts\Fetch-RimesLibrime.ps1 -Architecture x64
..\tests\Invoke-RimesImeE2E.ps1 -Architecture x64 -ProbeDesktop
```

`Invoke-RimesImeE2E.ps1` starts a real Broker against the isolated
`testdata/e2e` table schema and drives the real `TextService` through a Fake
TSF stack (`ITfThreadMgr` / `ITfContext` / `ITfComposition`). It asserts
preedit, candidate contents, `nihao`+Space → `你好`, number selection, paging,
Escape, Shift switching, ordinary editing and host-command pass-through.

Hosted GitHub `windows-2022` runners usually have a logon session and can
launch Notepad, but they are **not** a reliable interactive IME desktop: no
Chinese language pack, no user IME switch, and TSF often never attaches to a
SendInput host. The required CI assertions are therefore in-process. The
script records a desktop probe for honesty. Real-host coverage is
[MANUAL-TEST.md](MANUAL-TEST.md).

PR-time evidence is the non-required **Windows IME** workflow
(`.github/workflows/windows-ime.yml`). The older **Windows Native Foundation**
workflow stays schedule/manual only so it cannot join the macOS release gate.

See [librime/README.md](librime/README.md) for URLs and SHA-256.

## Daily-use layout

With no path flags, Broker uses:

| Role | Default |
| --- | --- |
| `rime.dll` | `<exe>\rime.dll`, else `%LOCALAPPDATA%\RIMES\runtime\rime.dll` |
| Shared data | `<exe>\shared`, else `%LOCALAPPDATA%\RIMES\shared` |
| User data | `%APPDATA%\RIMES` |
| Logs | `%LOCALAPPDATA%\RIMES\logs` |

```powershell
.\RimesBroker.exe --print-paths
.\RimesBroker.exe --install-autostart
.\RimesBroker.exe --remove-autostart
```

First TSF activation also launches `RimesBroker.exe` from the same directory
as `RimesTsf.dll` when the pipe is missing.

## Product shared data

The native Broker needs the product Lua files as well as OpenCC's standard
`s2t.json` and its referenced dictionaries. The pinned DLL does not supply them.
Stage a complete data directory using Python 3.10+ and an explicit OpenCC build:

```powershell
python ..\scripts\prepare-native-data.py stage `
  --opencc-data C:\OpenCC\share\opencc `
  --opencc-license C:\OpenCC\source\LICENSE `
  --opencc-revision 'REPLACE_WITH_FULL_OPENCC_SOURCE_COMMIT' `
  --output C:\RimesTest\shared
python ..\scripts\prepare-native-data.py verify C:\RimesTest\shared
python -m unittest discover -s ..\tests -p test_native_data.py
```

Use a new output directory. The tool copies only the reviewed 55-file RIMES
closure, the dictionaries referenced by `s2t.json`, and OpenCC's license. The
standard configuration adds four files (59 total, plus the manifest). It refuses
missing dependencies, unsafe paths, symlinks and existing output; verification
detects extra files and changed bytes after transfer. The source revision records
the supplied OpenCC build's provenance; the manifest is not a signature or an
independent attestation of that external build.

Place the resulting `shared` beside `RimesBroker.exe` or pass `--shared-data-dir`.
Run `RimesEngineSmoke` with the matching-architecture DLL and a **fresh test user
directory**, then complete [real-host checks](MANUAL-TEST.md). Successful staging
alone does not prove Windows librime, TSF or the final installer works.

## Safety boundaries

- The TSF DLL must not perform network requests or load `librime`.
- Pipe frames and every variable-length field are bounded before allocation.
- Broker failure or protocol incompatibility must fail open for typing.
- Secure-mode TSF hosts never connect to the Broker.
- Registration identifiers in `src/tsf/Guids.h` are release identity.
- Registration changes input profiles and must only run on an authorized
  test machine.

## Later-step blockers

- Product data can now be staged with the tool above. The complete product
  schemas still need to be exercised on Windows with the pinned MSVC DLL.
- Display-attribute underline depends on the host querying
  `ITfDisplayAttributeProvider`. The registrar does not add a new TSF
  category, so some hosts may skip the dotted underline.
- Capsule and Mailbox have no Windows frontend yet; Buffer and AI are available in this branch.
- The 1.1.0 release uses an unsigned EXE installer. Windows security prompts may appear; signing is optional.
- The EXE installer handles elevated dual-architecture registration. The actual upgrade was verified; fresh-install coverage and broader host acceptance remain separate follow-up checks.
