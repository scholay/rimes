# Local translation resource validation — 2026-10-17

Official plugin source: `scholay/rimes-plugins` commit `fb29999`.
Host: Ubuntu 24.04 arm64 Docker container on macOS, Python 3.12, CTranslate2
4.6.0, Argos Chinese/English 1.9 models. No host user profile was used.

- Downloaded all pinned Linux arm64 wheels and both model archives, checked
  SHA-256 and size before extraction, then validated every installed file.
- Real native `rimes-translation --request` translated Chinese to English and
  English to Chinese in an isolated profile. The engine smoke repeated both
  with network proxies directed to a closed loopback port, rejected unsupported
  language and a changed model file, and repaired offline from verified cache.
- 7 resource-manager tests cover installation, restart, corruption, cancellation,
  invalid archives, missing required model files, symlinks/hardlinks and atomic
  activation. 27 Linux CTests pass, including bounded subprocess transport and
  the actual GTK resource dialog communicating with the installed build helper.
- 17 source install/version tests pass with helper/resource ownership fixtures
  and user-model preservation. The deb lifecycle test now checks installed
  helper status and model-cache retention; CI must validate the exact package.

The GUI progress and status surface is implemented. Pixel comparison against
macOS and physical desktop acceptance remain open. Continuous Buffer integration
is recorded below. This validation does not close #155 or establish a release.

## Incremental Buffer adapter

The next source pin adds exact sentence slices, stable unit IDs, separate retry
tickets, 300/900 ms refresh timing and an asynchronous Fcitx adapter. 29 Linux
CTests pass, including real Buffer host callback/revocation tests. Existing
Default Buffer native Fcitx behavior also passes its regression suite.

The production addon was loaded through Fcitx `testfrontend` in the container
with the real pinned engine. Selecting the bundled plugin and pasting Chinese
automatically produced English; appending another sentence retained the ready
prefix, produced a new whole-result identity and translated the suffix without
consuming source. Closing the workbench removed result authority. This test is
included in the amd64 CI real-engine step; it creates and removes isolated data.

The process transport now also tests a producer whose leader exits before its
child: cancellation owns and terminates the remaining process group, retaining
the leader PID until cleanup. No live worker remained after the real Fcitx run.
Derived text delivery, auto-send, physical desktops and macOS pixel comparison
remain separate pending acceptance. Issues #155/#156 remain open.
