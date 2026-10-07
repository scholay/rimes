# macOS community repair — 2026-10-07

This records source and isolated-process validation for issues #81 and #61.
It does not claim a new published installer or acceptance on the reporters' machines.
The live input method, input-source selection and user dictionaries were not replaced.

## #81 — installer watchdog process-group race

The fork parent and child now check the actual PGID after a failed `setpgid`.
An EPERM is accepted only when the other side already established the child-owned group.
A disappeared leader follows the normal wait/descendant cleanup path.
A genuine failure reports the phase and retires the direct child with bounded TERM/KILL,
including a child stopped before its group was created; it never signals the supervisor's group.

On a local Apple Silicon host running macOS 27.0 (26A428), the unmodified helper failed
4 / 1600 executions at 8-way concurrency and 2 / 1000 serial executions. Failures
included both parent EPERM and silent child status 125. The repaired helper completed
the same 1600 + 1000 invocations with zero failures.

`python3 -m unittest discover -s scripts/pkg/tests -p 'test*.py' -v`: 8 tests passed.
These compile the real helper and variants that report EPERM after actually setting
the group, deny group creation, or stop an ungrouped child. They exercise serial,
parallel and nested fast commands; timeout/signal cleanup; leader-less descendants;
lock release; and nested `--lock-exec` ownership. The tests run in macOS CI.

## #61 — external ordinary Rime schemes

Settings now append ordinary schemes from Rime's deployed list, using their real
schema ID and name. The selection, preferred schema, last ordinary fallback and
F4 adoption retain the external ID across restart and chord enable/disable.
Cold startup and narrow `schema_list` rewrites preserve explicitly configured local
external schemes, so deploying the extension no longer removes them.

Dependency schemes and retired chord schemes remain hidden. Path-like/unsafe IDs,
missing schemes and symlink entries are excluded from startup preservation.
Scheme importer restrictions and third-party scheme contents were not changed.

Validation passed:

- `swift build -c debug`.
- `schema-smoke`, including external names/identity, restart, F4 adoption,
  chord fallback, removed-scheme fallback, and preservation of unrelated YAML settings.
- `external-schema-engine-smoke`: an isolated ordinary schema copied from the built-in
  fixture deployed through the real bundled librime; its real name and ID appeared,
  a private session produced and committed “你好”, and the external selection survived
  cold startup and the ordinary schema-list rewrite.
- Existing `smoke` (engine, built-in schemas, candidate/commit, F4 and exhaustive chord
  mappings), `chord-unification-smoke`, `settings-routing-smoke`, `activation-cache-smoke`.
- Log privacy lint and `git diff --check`.

The integration fixture proves the external-schema path. It is not the reporter's
third-party `flypy` package and does not certify that package's lexicon or Lua behavior.
No external-scheme GUI acceptance or new installed/published package is claimed here.
