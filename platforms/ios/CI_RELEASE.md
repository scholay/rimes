# iOS GitHub Actions release

Current iOS target: **1.1.5 (60)**. This rebuild changes the AI settings explanation to provider-neutral wording without changing the user-configured connection or consent behavior. Follow [the rebuild record](AppStore/release-preparation/1.1.5-build60.md) for validation and submission evidence. Build 59 was uploaded and submitted on October 15, then rejected by App Review under Guideline 5.0; its separate external TestFlight review still showed **Waiting for Review** when checked at 22:31 Asia/Tokyo. The existing six accepted screenshots remain applicable. Earlier device installation and outstanding physical acceptance limitations are documented in [the build 59 record](AppStore/release-preparation/1.1.5.md). Build, upload, TestFlight, App Review and public availability remain separate states. [TestFlight invitation](https://testflight.apple.com/join/Kdj9RB4q).

Build 60 was uploaded through Xcode at 22:44 and resubmitted for App Review at
22:50 Asia/Tokyo on 2026-10-15. The submission page confirmed **1.1.5 (60),
Waiting for Review**. This is not App Store approval or external TestFlight
distribution; build 59's separate beta review was left unchanged.

`ios.yml` runs unsigned builds, shared tests and hosted iOS tests on matching
pull requests targeting main and matching pushes to main. `ios-release.yml` runs
only for stable tags `ios-vMAJOR.MINOR.PATCH`, using macos-26 / Xcode 26.6 and
Fastlane 2.240.1. It does not use the maintainer's interactive Apple login.

## One-time configuration

The `ios-app-store` GitHub environment has been created and restricted to
`ios-v*` tags. Add these environment Secrets through GitHub Settings; do not put them
in chat, git, workflow inputs or logs:

| Secret | Value |
|---|---|
| ASC_KEY_ID | App Store Connect API key ID |
| ASC_ISSUER_ID | Team API key issuer ID |
| ASC_PRIVATE_KEY_BASE64 | Base64-encoded downloaded .p8 key, App Manager role sufficient for release operations |
| IOS_DISTRIBUTION_P12_BASE64 | Base64-encoded Apple Distribution certificate with its private key |
| IOS_DISTRIBUTION_P12_PASSWORD | Nonempty password protecting that P12 |
| IOS_APP_PROFILE_BASE64 | App Store profile for org.scholay.rimes.ios |
| IOS_KEYBOARD_PROFILE_BASE64 | App Store profile for org.scholay.rimes.ios.keyboard |

Both profiles must use team 585J2TL9U6, the supplied certificate, the existing App
Group and shared Keychain entitlement. No new Apple permissions are granted by
the workflow. Profiles and certificates expire: replace the Secrets when renewed.
Do not export every private key from the developer's login keychain.

As inspected during setup, this repository has no iOS signing/API Secrets.
The implementation is not evidence that credentialed CI publication has run.

## Publish a new version

1. Integrate the intended iOS source changes into `origin/main` and add real
   three-locale update notes in `AppStore/release-notes/<version>.json`. Run checks
   on that commit. Local main-only maintenance is not permission to push or tag.
2. Create and push its exact version tag, e.g. `ios-v1.0.0`. Never tag an older
   commit while the intended app changes remain uncommitted in a worktree.
3. Actions requires the tagged commit to be in `origin/main` history, validates
   the tag, notes and Secrets, builds/tests, imports signing
   material into an ephemeral keychain and signs both targets. Marketing version
   comes from the tag. Build number is `(run_number + 100).run_attempt.0`.
4. It uploads the IPA, waits up to 40 minutes for Apple processing, selects that
   exact build, sends the update notes and submits for review with automatic
   release after approval. No beta testers are added.
5. Read the job summary's version/build/commit and Apple review state. Upload,
   review submission, approval and live release are distinct outcomes.

The pipeline does not withdraw a pending review, replace a different draft, change
storefront selection, accept new agreements, or resolve EU DSA classification.
A duplicate already-submitted version fails rather than submitting twice. If an
upload succeeds but processing times out, inspect Apple state before retrying;
rerunning creates a different build number. Signing material is removed on failure
as well as success; only GitHub-hosted disposable runners are supported.

The existing 0.1.0 (10) review record is historical evidence, not live Apple status.
Read App Store Connect before describing a version as approved or available.
The strict manual distribution checklist remains an evidence record; CI does not
mark outstanding real-device checks passed.
The owner-authorized tag is the release action. Review licensing/privacy and actual
device results when the relevant functionality or bundled content changes.

References: [GitHub signing](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications),
[Fastlane deliver](https://docs.fastlane.tools/actions/deliver/),
[Apple API](https://developer.apple.com/app-store-connect/api/).
