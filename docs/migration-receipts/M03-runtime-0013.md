# M03 — exact 0.0.13 runtime qualification

Status: the exact 0.0.13 managed runtime qualified in an isolated scratch HOME
through the production `ManagedRuntimeInstaller`: explicit upgrade from 0.0.12,
prior-generation preservation, offline reuse, refusal of a corrupt engine wheel
before subprocess execution, public-interface reads and a launched-app smoke up to
the connected main window. The Pending launches screen was not opened in the app.
Aggregate M03 and M04 acceptance are not established.

## Authorization and immutable inputs

On 2026-11-11 the owner asked for the 0.0.13 runtime to be qualified. Source:
HarflowMac `13f823dbe57316f61db429893ad9d83b856980d3` (clean), which selects 0.0.13
(`fc41410`). This is qualification only: no user app installation, real-state
migration, provider dispatch, MCP registration, push or release.

Published PyPI release (source commit `0ac7e3cc07a2adc8602e6d378549c99184247f93`; wheel and sdist
`yanked` false):

| Input | Bytes | SHA-256 |
| --- | ---: | --- |
| `harflow_mcp-0.0.13-py3-none-any.whl` | 1,381,123 | `1363c549e8d701efb9a0d6f00197f725a262f5fdecca6ff2964f5331d60c8424` |
| `harflow_mcp-0.0.13.tar.gz` (digest from PyPI JSON; not downloaded) | 3,671,428 | `db2f86831ce09690a5365cf7d3f178a29705498a6affeb9ea366a2fe8808675a` |
| `harflow_mcp-0.0.12-py3-none-any.whl` (baseline) | 1,376,349 | `91f350abae800db5cfeb32602451eaad4a08ff085f107da6bafce3e9e5440cfb` |
| PyPI JSON 0.0.13 | | `92dd0e3e58bd19cc14e2077f93efe12740182d2122af59aebbd6ed408e583e78` |
| PyPI JSON 0.0.12 | | `eb59784ec4d45b529f252bfdb5f918d700b7fd7f42a8c9138f46a8f4f15248ca` |
| Production `ManagedRuntime.json` (0.0.13) | | `f9b0b14d0f9f943c8f6a5a3b77e8081f91c62b3ed4b5cfcde075500bbd6c29e2` |
| Baseline `ManagedRuntime.json` (0.0.12, from `fc41410~1`) | | `4860754b2bbb103d51f1825c8f628767bf4352a44772ed834656cac572c5eae7` |

The wheel digest equals the expected value and the sdist digest equals the one in the
0.0.13 specification provenance. Specification identities: 0.0.12
`a04b3ae1ac587a7ba29e401e4856b1dfd2f4a88ad45454c8b561cdb7e671238d`, 0.0.13
`1c50608c03f9e05f52bd6bf531614a49adcf05620d796c82b6b59835cba5ec49`. The two
specifications have identical interpreter (CPython 3.13.16, release 20261020) and 29
dependency pins. Those 30 inputs were copied from an earlier scratch cache after size and
SHA-256 matched the specification; they were not re-downloaded. Network use in this
stage was limited to the two PyPI JSON documents and the two engine wheels.
[Checks](M03-runtime-0013-checks.json) list all hashes; raw reports and tooling stay
outside the repository.

## Method

A scratch command-line harness links the unmodified MonitorCore sources of the commit and
constructs the production installer with the production 0.0.13 and 0.0.12 specifications, the
real process runner and a local-only downloader that serves the exact PyPI JSON bytes and
hash-verified files (the production TLS transport is not exercised). Each run executes with a
scrubbed environment and a scratch HOME, TMPDIR and CFFIXED_USER_HOME. The harness refuses any
HOME that is not a mode-0700, caller-owned, symlink-free directory under the scratch root.

## Qualification observed

| Operation | Acquisition calls | Subprocesses | Result |
| --- | ---: | ---: | --- |
| Baseline 0.0.12 install | 32 | 9 | Qualified |
| Baseline check, then prepare, offline | 0 each | 6 each | Reusable |
| Explicit 0.0.13 upgrade | 32 | 9 | New generation qualified; active pointer switched |
| Check, then prepare, offline (0.0.13) | 0 each | 6 each | Reusable, same generation |
| Corrupt 0.0.13 wheel (flipped byte), on a 0.0.12 install | 32 | 0 | Refused: size/SHA256 verification |
| Corrupt 0.0.13 wheel (truncated), same | 32 | 0 | Refused: size/SHA256 verification |
| Check, then prepare, offline (0.0.12) after refusals | 0 each | 6 each | Prior generation reusable |
| Check 0.0.13 after refusals | 0 | 0 | Installation required, installed 0.0.12 |

The upgrade left the 0.0.12 generation byte-identical (4,942 entries, per-file SHA-256 and
symlink targets compared before and after). After the two refusals the whole runtime tree of
that scratch home (4,950 entries) was identical to its pre-attempt snapshot, with no staging
directory and the active pointer unchanged. The 0.0.13 completion receipt records the exact wheel
SHA-256, `engineYanked` false and the scratch state root. Version-info through the qualified
generation reports product 0.0.13, ctl/setup/events contracts v1, darwin/arm64 and 34
capabilities including `task-pending-launch.v1` and `task-cancel-cascade.v1`. A full
installed-payload comparison against the original wheels, as done for 0.0.10, was not repeated.

## Public reads through the 0.0.13 launcher (scratch HOME)

| Read | Result |
| --- | --- |
| `version-info` | 0.0.13, capabilities above, scratch state root |
| `state-inspect` | missing root on empty home; compatible after seeding |
| `list`, `task-list-page` on empty state | empty, ready, counts complete |
| `task-pending-page` | empty complete inventory (`coverage: complete`, `namespace_complete: true`, zero items), empty and seeded |
| `task-pending-status`, random full ID | `not_found` |
| `task-pending-status`, a seeded task ID | `recorded` |

Four labelled synthetic task records were written by the preserved 0.0.12 generation's own store
code (no provider ran) and read through 0.0.13: `list`, `task-list-page` (after the first call
reported a bootstrap-pending index, a retry returned all four), `status` and `task-events`
succeeded and the eight record files were byte-identical afterwards. Event pages are empty
because the seed has no normalized events; that is a fixture limit, not an engine finding.

## App smoke

The Release app was built from a scratch copy of the commit with a unique test bundle identifier,
URL schemes removed and an ad-hoc signature, then launched against a scratch home pre-seeded
through the production installer with a qualified 0.0.13 generation and four synthetic tasks. Before
launch a helper with the same identity, environment and arguments confirmed the effective preference
domain and home were the scratch values and both notification flags were false; during the run the
process tree was verified to use only the scratch HOME and state root, with no open owner path and
no harness process. The app reached the connected ready state (main window, green connection
indicator, the four synthetic tasks listed); a screenshot is retained with the evidence. The app
stopped on TERM and no process remained.

Not exercised: the Pending launches screen. Navigating to it needs UI input, which was not granted
in this session, so "loads rather than the unavailable state" is unverified in the app (the same
public reads it uses, above, succeed). The launched app created a preference file for its unique
test domain in the real preferences directory despite the scratch HOME (as recorded in S02); it was
removed with the unique domain's other traces. No owner preference domain was touched.

## Not established

Production TLS/redirect acquisition from PyPI (a local downloader served the verified bytes); a
download-from-scratch install of the interpreter and dependencies; the Pending launches screen in the
app; behavior against real task history or any provider; MCP registration; signed or notarized
distribution; native package test suites (not run in this stage); an installed-payload comparison
against the wheels; the owner's live runtime switch. Aggregate M03 and M04 acceptance are not
established.
