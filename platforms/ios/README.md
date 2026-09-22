# RIMES iOS 0.1

Native iPhone application and keyboard extension (iOS 17+). Development preview,
not an App Store or TestFlight release. macOS input-method source and installation
are unchanged.

## Implemented

- Offline simplified Pinyin, Ziranma, Wubi 86 and English; local Rime learning.
- FlyYao and imported JSON mappings, with per-hand start/end sliding, live chord
  preview and a single commit when both hands release. No traversed-key accumulation.
- Explicit Buffer mode, character cursor editing, ordered next/all insertion,
  in-memory drafts and manual AI result confirmation.
- Multiple HTTPS Chat Completions providers, manual model IDs, optional model lookup,
  endpoint consent, shared device-only Keychain credentials, cancellable streaming.
- Containing app with keyboard setup, typing playground, profile editor/import/export,
  privacy and license notices. English and simplified Chinese interface, light/dark,
  compact landscape keyboard. Layout remains provisional until physical thumb testing.

Excluded: Xiaohe, Yoyo/Zhemei/Hanmei, runtime scripts, Mailbox, Capsule, clipboard
monitoring, dictation, music, cloud accounts/sync, subscriptions and auto-send.

## Build

Requires macOS, full Xcode with iOS SDK (Xcode 27 was used locally), CMake, Python
3.12+, Git and network access for the pinned build dependencies. The script sets
`DEVELOPER_DIR` per process and does not change `xcode-select` or install the macOS IME.

From the repository root:

```sh
platforms/ios/scripts/build.sh
```

The bootstrap verifies source revisions and archive SHA-256 values. librime 1.17.0
and pinned dependencies compile locally for arm64 iPhone and arm64 Simulator;
no macOS binaries are repackaged as iOS libraries. Logging and external plugin
loading are disabled. Dictionary deployment runs on the Mac build host, never on
first keyboard presentation. Simulator builds use ad-hoc signing so Keychain
entitlements can be exercised; device builds are unsigned until a team is configured.

Open `RIMES.xcodeproj` in Xcode after building. `project.yml` is the editable project
source; regenerate with `Vendor/ios-build/xcodegen/bin/xcodegen generate --spec
platforms/ios/project.yml` from the repository root. `Shared/` is a local Swift package.
The project now selects the development team verified during the first physical
iPhone installation. Other maintainers should select their own team in Xcode or
override `DEVELOPMENT_TEAM` when building. No credentials or profiles are committed.

For core tests only:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Shared
```

For iOS hosted tests on a correctly configured Xcode installation:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project platforms/ios/RIMES.xcodeproj -scheme RIMES \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The debug app accepts `--engine-smoke` to run real on-device engine and Keychain
checks against synthetic inputs and write `Documents/development-smoke.json`.
It sends nothing over the network, and the hook is excluded from release builds.
This smoke is not a substitute for keyboard-extension lifecycle or physical testing.

## Architecture and boundaries

- `RimesCore` has no AppKit/InputMethodKit/CLI dependency. It owns portable keymaps,
  gesture reduction, Buffer state, provider requests and bounded SSE decoding.
- The original desktop encoding algorithm is preserved in a standalone mobile
  port. `scripts/verify.py` enforces source parity and the 426 mapping fixture.
  Desktop imports/build products are deliberately not restructured in this version.
- UIKit owns key hit testing, candidate UI and `UITextDocumentProxy` insertion.
  Each controller has one Rime session; initialization happens once per process.
- The containing app alone writes App Group configuration. A missing/inaccessible
  group falls back to offline defaults. Keyboard-local user dictionaries are never
  shared with the app, never synchronized, and excluded from backup.
- Keys use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and an explicit shared
  Keychain group. They are not in JSON, exports, logs, source, screenshots or tests.
- API redirects are refused. Only explicit Buffer source text enters the request.
  Errors, partial streams, editing and lifecycle changes never auto-insert results.
- Switching fields while the keyboard stays visible cancels outstanding AI work
  and preserves pending blocks for a fresh Insert action. Hiding/resigning the
  keyboard ends the session and clears its in-memory draft.
- iOS's proxy gives no host acknowledgement of successful application-level send.
  RIMES makes one explicit `insertText` call and consumes that local block; it does
  not retry, synthesize Return or claim a message was sent.
- Basic typing and Buffer work without Full Access. AI requires both Full Access
  and separate recipient consent. Password fields and opting-out host apps use the
  system keyboard. No unsupported mechanisms are used to bypass those limits.

## Distribution gate

`distribution-audit.json` is the release checklist and evidence record.
`python3 platforms/ios/scripts/verify.py --distribution` currently exits 2 because
Wubi's store-distribution/provenance review, FlyYao provenance, developer membership,
physical acceptance and public privacy/support details remain unresolved.

All planned schemes are present in local development builds. They are not silently
removed to pass distribution checks. This repository's MIT license does not replace
third-party terms. Do not distribute the local app or upload it to TestFlight until
those recorded items are resolved with evidence.

Once ready, set the real team through `RIMES_DEVELOPMENT_TEAM` and run
`scripts/archive.sh` from this directory. The script checks the gate before creating
a release archive; it does not upload. In Xcode Organizer review signing, archive
contents, privacy declarations and the intended App Store Connect record before
uploading for internal TestFlight testing. External testing additionally requires
Beta App Review. Never commit provisioning profiles, certificates or credentials.

See `VALIDATION.md` for actual results and remaining acceptance, and
`PRIVACY.md` for the draft public policy and App Store privacy declaration inputs.
`RESOURCE_INVENTORY.md` records the source, changes and license obligations of each
shipped dependency. `TESTFLIGHT.md` contains prepared signing, beta description,
review notes and device-acceptance handoff materials.
