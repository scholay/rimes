# RIMES Native Windows Foundation

This directory contains the native Windows implementation of RIMES. It is
separate from the Weasel data preview in the parent directory.

The current foundation deliberately keeps the in-process TSF DLL small:

- `RimesTsf.dll` implements the Windows Text Services Framework boundary.
- `RimesBroker.exe` is a per-user process that owns the single `librime`
  instance and all input sessions. It accepts authenticated, bounded named-pipe
  requests from the TSF clients.
- `RimesRegistrar.exe` registers or removes the TSF text service by using the
  documented TSF APIs.
- `src/core` contains the bounded, versioned named-pipe protocol shared by the
  TSF and broker processes.

The end-to-end commit path is implemented: a TSF client can send physical key
down/up events to the Broker, let `librime` select a candidate, and insert the
committed UTF-16 text into the host through a write edit session. The returned
range is collapsed to its end and becomes the new caret selection; caret
positioning is best-effort after a successful insertion so a host quirk cannot
cause a duplicate commit.

This foundation is not yet a user-facing Windows release. It does not render
preedit or candidates, start the Broker at logon, install through a signed MSI,
or reproduce the macOS settings, buffer, and workbench. A successful commit
smoke therefore does not prove the full host compatibility, DPI/multi-monitor,
upgrade, repair, uninstall, or feature-parity matrix.

## Verified milestone

The current source has been verified on Windows 11 x64 with Visual Studio 2022
and Windows SDK 10.0.26100:

- Release builds complete under `/W4 /WX` for x64 and Win32.
- All six native CTests pass for both architectures.
- An isolated real-`librime` smoke completes a composition and requires a
  non-empty Space-key commit.
- The interactive x64 TSF test host accepts `nihao` followed by Space and
  displays `你好`.
- The live Session-1 Broker wire smoke requires a handled selection key,
  non-empty committed text, and a finished composition.
- x64 and x86 COM/TSF registrations verify simultaneously without changing
  the user's default input method.

These checks validate the commit-only milestone, not a signed release.

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

## Safety boundaries

- The TSF DLL must not perform network requests or load `librime`.
- Pipe frames and every variable-length field are bounded before allocation.
- Broker failure or protocol incompatibility must fail open for typing: the
  host application's key event is left untouched.
- Registration identifiers in `src/tsf/Guids.h` are release identity. Do not
  regenerate them between builds.
- Registration and installation are reversible, but they change the current
  Windows input profiles and therefore must only be run on an explicitly
  authorized test machine.
