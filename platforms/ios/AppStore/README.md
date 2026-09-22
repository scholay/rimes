# RIMES App Store submission — 22 September 2026

**Historical snapshot: build 10 was submitted on 22 September 2026 and recorded as WAITING FOR REVIEW. This is not a live store-status check.**

Current development build is 0.1.0 (22), installed and read back on iPhone 15 Pro.
This code push does not upload or replace the store submission. Operational JSON
readbacks and signing artifacts listed below are kept locally, outside this commit.

- [App Store Connect](https://appstoreconnect.apple.com/apps/6814620242/distribution/reviewsubmissions)
- Submitted 2026-09-22 10:34 China Standard Time.
- Submission ID: `f5c2e139-3347-416d-9a35-fe4052dd9418`.
- Build ID: `8e152a49-fbf7-43e2-9a3a-5ae3961b50c2`.
- Free; automatic release after approval; 174 selected territories excluding mainland China.
- EU DSA classification/verification remains incomplete. Selected territories are not a count of live storefronts.
- English, Simplified Chinese and Traditional Chinese metadata, five real screenshots, privacy disclosures, support/privacy URLs and confirmed review contact are saved.
- Content Rights declaration saved on the basis documented in `RESOURCE_CLEARANCE.md`; not declared to contain no third-party content.
- No testers added and no TestFlight installation claimed.

## Build 10 changes and verification

Black monoline flat rhino AppIcon replaces the colorful icon. Prompt, source and
provenance are in `icon/monoline/`. Built-in image_gen does not expose a model
version; no image2/image2.5 claim is made. Default chord public naming, compatible
persisted IDs and JSON import remain intact. Updated notices preserve licenses
and distinguish functional mappings from bundled licensed components.

Resource/source parity checks, simulator build/install/launch, device signed
build, archive and store IPA signature/profile/privacy checks passed. App and
extension are iPhone-only 0.1.0 (10). No functional changes from build 9, where
26 shared and 22 hosted iOS tests passed.

Physical update was attempted but CoreDevice returned error 4016 and device
inventory lists the iPhone 15 Pro unavailable. At that time the last verified installed version was
build 9. Subsequent local installations are recorded in ../VALIDATION.md. Actual keyboard, shared
Keychain, Full Access, translation, haptics and sustained performance acceptance
remain as recorded in `../VALIDATION.md`; submission does not mark them passed.

## Artifacts

- `build-proof.json`: store IPA hash, signing, upload, build and review identifiers.
- `asc-readback.json`: authoritative visible review status and remaining limitations.
- `submission-plan.json`: region selection and unresolved EU eligibility.
- `../validation/build10-status.json`: build and physical-install results.
- `metadata/`, `screenshots/manifest.json`, `review-notes.txt`: submitted material.
- `../build/RIMES-0.1.0-10.xcarchive` and `../build/AppStoreExport10/RIMES.ipa`: ignored local release outputs.

No new paid agreement, private public-facing contact address, or trader status was
accepted or invented. Review timing and approval remain Apple's decision.
