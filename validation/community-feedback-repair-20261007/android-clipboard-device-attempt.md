# Isolated Android filesystem-contract attempt, 2026-10-07

The follow-up found one connected, available Xiaomi handset, model 25098PN5AC, Android 16 / API 36. No emulator was available. The phone's selected daily input method is `org.scholay.rimes.android.debug`, so installing the regular Debug or app-test APK would affect that daily product and was not attempted.

An isolated minimal host was built under the ignored `.build/mobile-clipboard-device-host` directory, with application ID `org.scholay.rimes.clipboardvalidation` and instrumentation package `org.scholay.rimes.clipboardvalidation.test`. It has no Activity, IME, service or requested permission, does not launch an editor, and excludes backup. Its minimal runner calls only the synthetic filesystem contract. `TextClipboardStore.java`, `TextClipboardHistory.java` and `TextClipboardStoreContract.java` were copied byte-for-byte from commit `427aa71`; their SHA-256 hashes and the resulting APK hashes are recorded in [the machine-readable evidence](android-clipboard-device-attempt.json). Both APK builds succeeded.

Only installation of the new isolated host was attempted. The device rejected it:

```text
Performing Streamed Install
Failure [INSTALL_FAILED_USER_RESTRICTED: Install canceled by user]
```

The validation host was absent after the attempt. The test APK was not installed, and instrumentation was not invoked: **the 12 synthetic filesystem assertions remain unexecuted on a device**. No restriction was disabled, no emulator was created, no phone restart or default-IME switch occurred, and no daily product was installed, uninstalled or cleared.

Readback confirmed that the selected daily IME remained the same, with version 1.1.0 / code14 and its prior last-update timestamp unchanged. No real clipboard contents or user history were read or written. Device-level filesystem acceptance still requires successful installation of the isolated validation host, followed by its instrumentation; the earlier JVM, iOS simulator and build results remain separate evidence.
