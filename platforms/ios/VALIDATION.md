# Validation — 2026-09-21

Source branch: `codex/ios-v0.1`, based on `20651da`. This is local development
validation, not TestFlight distribution or physical-device acceptance.

## Passed

| Layer | Evidence |
|---|---|
| Dependency build | librime 1.17.0 and pinned dependencies compiled from source for arm64 iPhone and arm64 Simulator; static XCFramework generated |
| Reproducible build entry | `scripts/build.sh` completed bootstrap checksum/revision checks, host dictionary compilation, core tests and both platform builds |
| Core behavior | 15 XCTest cases passed; all 426 built-in mappings tested for reachability, both hand release orders, preview/commit equality and Ziranma encoding; whole-map precedence and valid/invalid fragment composition covered |
| Gesture cancellation | Cross-region recovery, invalid release, third finger, repeated touch, cancellation and late duplicate release covered in core tests |
| Buffer | Source editing invalidates old generations, Unicode cursor editing, lossless block joining and partial delivery remainder covered |
| AI | Real URLSession streaming path exercised with URLProtocol fixtures; endpoint/consent validation, 429 handling, byte-split UTF-8 SSE, bounded multiline events, truncated streams, length termination and redirect refusal covered; no paid provider invoked |
| Host data/engine | Real pinyin `nihao` → `你好`, Ziranma `nihk` → `你好`, Wubi `wq` → `你`; candidate selection commits the expected text |
| iOS native execution | App installed and launched on iPhone 17 Pro / iOS 26.5 simulator. Three real Chinese engine checks and ad-hoc-signed shared-group Keychain read/write/delete passed; see `validation/simulator-smoke.json` |
| App presentation | Home screen rendered and inspected, English and simplified Chinese launches; `validation/home-simulator.png` records the latter |
| iOS build products | Simulator app + keyboard extension and hosted XCTest bundle compile; arm64 iPhone app + keyboard extension compile without device signing |
| Desktop regression | Full macOS `swift build -c debug` passed; `chord-keymap-smoke` (516 permutations), `chord-ziranma-smoke` (98 syllable / 35 fragment samples, 415 inventory codes, 426 mappings), and `ai-text-smoke` passed |
| Resource policy | Asset hashes, shared/desktop encoding source parity, exact mapping fixture parity, schema allowlist, permissions and privacy manifest checks passed |
| Distribution gate | `verify.py --distribution` correctly exits 2 and lists unmet prerequisites |

Simulator timings in the JSON are narrow engine measurements from one synthetic
run. They do not measure full keyboard presentation, physical touch latency,
extension memory pressure, or P95 acceptance on an iPhone.

## Environment blockers and incomplete checks

- Xcode 27.0 build 27A266a is present, but its device/simulator plug-ins do not match
  installed shared components. Xcode expects CoreSimulator 1171.7; installed is
  1051.55. Xcode's CoreDevice plugin also reports a missing CoreDevice symbol.
- Direct simulator service commands can install/launch the app, but Xcode cannot
  enumerate a matching simulator destination. Hosted XCTest builds successfully;
  `test-without-building` could not execute. This is not counted as a passed test run.
- Xcode's bundled Device Hub was found under `Contents/Applications/DeviceHub.app`,
  but did not provide an accessible UI during testing. No successful keyboard UI
  automation or system keyboard activation is claimed.
- No connected, available iPhone was listed. No physical installation, two-thumb
  gesture trial, app-to-extension Keychain readback, real full-access toggle test,
  lock/unlock, host-app compatibility, extension-memory or latency acceptance has
  been performed. User developer membership is not yet ready.
- Live AI-provider compatibility still needs testing with a user-configured endpoint
  and key. Automated networking tests used synthetic responses and no real key.
- CI workflow is added but has not run on GitHub. No app archive uploaded, no
  TestFlight record created, no external testers invited, no App Store submission.

## Remaining acceptance on the signed iPhone

1. Complete Xcode device-component setup and select the actual developer team;
   register the containing app, extension, App Group and shared Keychain group.
2. Add the keyboard and test Pinyin, Ziranma, Wubi, English and chords offline with
   Full Access off. Verify built-in resources do not depend on app-group writes.
3. In Notes, Safari forms, Messages and WeChat verify composition, candidates,
   deletion, numeric/punctuation switching, explicit Buffer next/all insertion and
   switching between two fields. Secure fields must stay with the system keyboard.
4. Test both hand orders, stationary + sliding hand, returning to start, invalid
   release, third touch, rotation and interruption. Inspect portrait/landscape,
   light/dark, expanded candidates, Buffer and custom profile layouts. Tune thumb
   ergonomics on the physical device before treating the layout as final.
5. Enable Full Access and separately consent to a configured provider. Verify
   Keychain sharing, streaming preview, cancellation, source edits, offline/error
   handling and permission revocation; inspect that requests contain only explicit
   Buffer text. Then disable Full Access and recheck offline typing.
6. Measure full cold keyboard presentation (<1 second target), warm key-to-candidate
   P95 (<100 ms target), and peak extension memory during sustained typing and AI.
   Record device/OS/build and repeat across hide/show and lock/unlock cycles.
7. Resolve Wubi/FlyYao distribution evidence and public privacy/support details in
   `distribution-audit.json`. Only then archive for TestFlight, install the processed
   build, and record that separate acceptance result.

The original checkout's ten modified macOS source files were preserved. This work
was performed in a separate worktree, and the running desktop input method was not
replaced or restarted.

## Physical installation update — 2026-09-21

The earlier device/environment blockers above describe the initial validation run.
This later local installation achieved the following additional evidence:

- Xcode 27 can now enumerate physical and simulator destinations. The connected
  device was an iPhone 15 Pro on iOS 26.7; Developer Mode was confirmed enabled.
- After the user renewed Xcode account authentication, both development profiles
  included this iPhone and `group.org.scholay.rimes.ios`. Shared Keychain entitlements
  were present. The project records the verified development team and explicit
  App Group capability to support repeatable local signing.
- Corrected generated bundle metadata that had retained XcodeGen's default `1.0`.
  Both final signed bundles now report **0.1.0 (1)**; source verification checks
  the version/build substitutions.
- The signed app and embedded keyboard extension passed signature verification.
  CoreDevice installed the app successfully, and the device's installed-app query
  read back `org.scholay.rimes.ios`, version 0.1.0, build 1.
- App launch succeeded. Its explicit synthetic engine smoke was copied back from
  the physical app container: Pinyin, Ziranma, Wubi and Keychain read/write/delete
  all passed. See `validation/iphone15pro-local-install.json`.

This is a **local development installation**, not TestFlight. Main-app engine and
Keychain checks do not prove keyboard activation, cross-process sharing, thumb
ergonomics, all host apps, permission revocation, or keyboard latency/memory targets.
Those acceptance items and the distribution-rights gate remain open.
