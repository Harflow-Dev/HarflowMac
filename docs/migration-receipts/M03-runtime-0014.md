# M03 — exact 0.0.14 runtime qualification

Status: the exact 0.0.14 managed runtime qualified in an isolated scratch HOME
through the production `ManagedRuntimeInstaller`: explicit upgrade from 0.0.13,
prior-generation preservation, offline reuse, refusal of a corrupt engine wheel
before subprocess execution, public-interface reads including `backend-models`,
and 0.0.13 task records read through 0.0.14. No application was launched. The
model picker in the app, the production TLS acquisition path and a logged-in
Cursor were not exercised. Aggregate M03 and M04 acceptance are not established.

## Authorization and immutable inputs

The owner's plan for the model catalog (Phase 2) required qualifying the 0.0.14
runtime. Source: HarflowMac `4963950` (the commit that selects 0.0.14, clean tree
at the start of the run; the installer steps were re-run against the corrected
specification committed in `6b26805`). This is qualification only: no user app installation,
real-state migration, provider dispatch, MCP registration, push or release. Unlike
the 0.0.13 run, no app was launched: the earlier smoke wrote a preference file
into the real Preferences directory, so this run stops at what can be done
headless. The owner's own check build covers the app.

Published PyPI release (source commit `a891388b1259add2ec8432d7d0fc5ca38163c27d`; wheel and sdist
`yanked` false):

| Input | Bytes | SHA-256 |
| --- | ---: | --- |
| `harflow_mcp-0.0.14-py3-none-any.whl` | 1,393,614 | `76f980845a9b1c72391ec6063b3515df8e2d25cb61f30c97a9ea7742636c3f39` |
| `harflow_mcp-0.0.14.tar.gz` (digest from PyPI JSON; not downloaded) | 3,731,305 | `0e750c46048ee19859279463881f1585bec48b9c14415ed341f617048e81498f` |
| `harflow_mcp-0.0.13-py3-none-any.whl` (baseline) | 1,381,123 | `1363c549e8d701efb9a0d6f00197f725a262f5fdecca6ff2964f5331d60c8424` |
| PyPI JSON 0.0.14 | | `7cc53b1780d778f06a27d611b37fb68d0b1e245e0076156edd6c2be1fcaad9f6` |
| PyPI JSON 0.0.13 (fetched again for this run) | | `69e2a616199fbdeb1d8639eb5dd32fb353f2eaa248d737d2ccee3f2d1705fd1d` |
| Production `ManagedRuntime.json` (0.0.14) | | `568355460d28cb953dc6e1825e198bcc858083acf4dd73107e8a81e25f190075` |
| Baseline `ManagedRuntime.json` (0.0.13, from `54347d6`) | | `f9b0b14d0f9f943c8f6a5a3b77e8081f91c62b3ed4b5cfcde075500bbd6c29e2` |

The wheel digest equals the expected value and the sdist digest equals the one in the
0.0.14 specification provenance. The PyPI JSON for 0.0.13 now has a different digest than
recorded in the 0.0.13 receipt (`92dd0e3e...`); the wheel digest and size are identical, so
this is PyPI metadata drift, not a different artifact. Specification identities: 0.0.13
`1c50608c03f9e05f52bd6bf531614a49adcf05620d796c82b6b59835cba5ec49`, 0.0.14
`cf843ca7588a43733c66726c014774113d2807c210cec2fdce3fdcc38769d4ba`. The two
specifications have identical interpreter (CPython 3.13.16, release 20261020) and 29
dependency pins. Those 30 inputs were copied from the 0.0.13 qualification's scratch cache
after size and SHA-256 matched both specifications; they were not re-downloaded. Network
use in this stage was limited to the PyPI JSON documents and the 0.0.14 engine wheel.
[Checks](M03-runtime-0014-checks.json) list all hashes; raw reports and tooling stay
outside the repository.

## Method

A scratch command-line harness links the unmodified MonitorCore sources of the commit and
constructs the production installer with the production 0.0.14 and 0.0.13 specifications, the
real process runner and a local-only downloader that serves the exact PyPI JSON bytes and
hash-verified files (the production TLS transport is not exercised). Each installer run executes
with a scrubbed environment and a scratch HOME, TMPDIR and CFFIXED_USER_HOME. The harness refuses
any HOME that is not a mode-0700, caller-owned, symlink-free directory under the scratch root.

## Qualification observed

The specification's provenance string was corrected after the first run (it had repeated the lock and export digests the generator appends itself), which changes its identity and the resource hash recorded above but no dependency pin or engine byte. The installer steps in the table below (baseline install, check and offline prepare, upgrade, offline reuse, both corrupt-wheel refusals, check after refusals, fresh install) were repeated with the final specification: the same acquisition and subprocess counts, the same refusals before any subprocess, and an unchanged runtime tree (4,952 entries) after the refusals. The prior-generation byte comparison, the public reads and the `backend-models` reads were made in the first run, whose engine and dependency bytes are identical.

| Operation | Acquisition calls | Subprocesses | Result |
| --- | ---: | ---: | --- |
| Baseline 0.0.13 install | 32 | 9 | Qualified |
| Baseline check, then prepare, offline | 0 each | 6 each | Reusable |
| Explicit 0.0.14 upgrade | 32 | 9 | New generation qualified; active pointer switched |
| Check, then prepare, offline (0.0.14) | 0 each | 6 each | Reusable, same generation |
| Corrupt 0.0.14 wheel (flipped byte), on a 0.0.13 install | 32 | 0 | Refused: size/SHA256 verification |
| Corrupt 0.0.14 wheel (truncated), same | 32 | 0 | Refused: size/SHA256 verification |
| Check, then prepare, offline (0.0.13) after refusals | 0 each | 6 each | Prior generation reusable |
| Check 0.0.14 after refusals | 0 | 0 | Installation required, installed 0.0.13 |
| Fresh 0.0.14 install in a second scratch home | 32 | 9 | Qualified |

The upgrade left the 0.0.13 generation byte-identical (4,944 entries, per-file SHA-256 and
symlink targets compared before and after). After the two refusals the whole runtime tree of
that scratch home (4,952 entries) was identical to its pre-attempt snapshot, with no staging
directory and the active pointer unchanged. The 0.0.14 completion receipt records the exact wheel
SHA-256, `engineYanked` false and the scratch state root. Version-info through the qualified
generation reports product 0.0.14, ctl/setup/events contracts v1, darwin/arm64 and 35
capabilities including `task-pending-launch.v1` and `backend-models.v1`. A full
installed-payload comparison against the original wheels was not repeated.

## Public reads through the 0.0.14 launcher (scratch HOME)

| Read | Result |
| --- | --- |
| `version-info` | 0.0.14, 35 capabilities including `backend-models.v1`, scratch state root |
| `state-inspect` | compatible (seeded home) |
| `list` | four records |
| `task-list-page` | first call: bootstrap pending, zero items; retry: four items, counts complete |
| `status`, `task-events` (seeded task) | succeeded; event pages empty (no normalized events in the seed) |
| `task-pending-page` | empty complete inventory (`coverage: complete`, zero items) |
| `task-pending-status`, random full ID | `not_found` |
| `task-pending-status`, a seeded task ID | `recorded` |

Four labelled synthetic task records were written by the preserved 0.0.13 generation's own store
code (no provider ran) and read through 0.0.14: `list`, `task-list-page`, `status`,
`task-events` and `task-pending-status` succeeded, and the eight record files were
byte-identical afterwards.

## `backend-models` reads (scratch HOME)

These reads were made by the implementing agent as a direct invoker: the engine, not this
record, decides whether a caller is eligible, and no marker was added, removed or overridden.
No `HARFLOW_*` variable existed in the invoking environment, the commands ran under a scrubbed
environment with the scratch HOME and a PATH holding only system directories plus the
directories of the opencode and codex binaries, and the outcome is recorded as returned. Only state, counts, bytes and time are
recorded; model identifiers and labels stay in the scratch evidence.

| Read | Exit | State | Reason | Source | Models | Bytes | Time |
| --- | ---: | --- | --- | --- | ---: | ---: | ---: |
| `--backend=opencode`, fresh home (no state root), harness on PATH | 0 | `available` | none | `cli_output` | 7 (3 with effort levels, none marked default) | 1,192 | 1.06 s |
| `--backend=codex`, fresh home, harness on PATH | 0 | `unavailable` | `source_missing` | `harness_cache` | 0 | 377 | 0.15 s |
| `--backend=opencode`, no harness directory on PATH | 0 | `not_installed` | none | `cli_output` | 0 | 367 | 0.16 s |
| `--backend=codex`, no harness directory on PATH | 0 | `not_installed` | none | `harness_cache` | 0 | 367 | 0.14 s |
| `--backend=opencode`, home with the seeded state root | 0 | `available` | none | `cli_output` | 7 | 1,192 | 0.91 s |
| `--backend=codex`, home with the seeded state root | 0 | `unavailable` | `source_missing` | `harness_cache` | 0 | 377 | 0.17 s |
| `--backend=nosuch` | 2 | usage error naming the six valid backends | | | | 249 | 0.15 s |

Every success reported `scope: user`, `advisory: true`, `truncated: false` and `dropped_count: 0`.
No `agent_caller` or `caller_undecidable` refusal was returned in this run. The codex result is the
expected one for a scratch home without `~/.codex`. The opencode read ran the harness with the
scratch HOME as its home: it created its own configuration, data and state files (about 300 KiB)
under that scratch home only, and the harness offered only the built-in free models, so this does
not show what a signed-in owner would see.

## Not established

Production TLS/redirect acquisition from PyPI (a local downloader served the verified bytes); a
download-from-scratch install of the interpreter and dependencies; any launched app, including
the model picker and its suggestions; backend-models for the owner's real HOME sources
(`~/.codex`, a signed-in opencode, vibe configuration) and for cursor logged in or out,
claude, vibe and antigravity (not read here); behavior against real task history or any
provider; MCP registration; signed or notarized distribution; native package test suites (run
in the commits that change code, not in this stage); an installed-payload comparison against the
wheels; the owner's live runtime switch. Aggregate M03 and M04 acceptance are not established.
