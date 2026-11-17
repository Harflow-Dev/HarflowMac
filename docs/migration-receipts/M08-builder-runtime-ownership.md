# M08 builder runtime ownership

## Scope

Builder submissions and persisted sessions retain runtime ownership. The durable version 1
binding contains executable, expected lexical state root and product version only. Environment
and credentials remain in the in-memory runtime token. Reopening with a matching durable binding
uses a fresh qualified token; an in-flight environment change supersedes adoption.

Attempt IDs, process owner and draft identity prevent delayed acknowledgements from overwriting
replacement records. Missing acknowledgements and generic transport failures preserve an uncertain
reservation. Legacy and mismatched records remain intact and cannot automatically reconnect or
dispatch again. Ordinary persistence and save/re-key cleanup preserve retained associations.

Selected builders revoke activity, reads and commands when their runtime changes or disappears.
Cached builders must match the requesting runtime before adoption. Explicit canvas/proposal
transitions release only the exact verified association. No recovery flow for unresolvable legacy
associations is introduced.

The existing approved builder states at Design
`b710856a31702e46e3b8f3a54be19f3cb7c422dc`,
`v2/scripts/states-workflow-gaps.js`, remain the presentation reference. The right-pane layout
remains `34c3b0576e221d17b1096136db6c5d0fbb4c5000`. No node geometry changes.

## Verification

The final guarded model run passed 178 discovered test definitions across 13 suites, with no
failures and an empty hosted setup. It covers matching-runtime reopening, runtime and environment
changes, legacy records, uncertain replies, stale attempts, late persistence failures, retained
save/re-key reservations and runtime-qualified cache reuse. Existing proposal, draft, conflict,
discard, delete, undo, activity and usage regressions passed in that run.

Release `macos/build-app.sh` passed using two build jobs and existing DerivedData, including
bundle checks and ad-hoc signature verification. The app was not launched. Formatting, strict
lint with zero violations, legacy/private guards and diff whitespace checks passed. Independent
review closed at round 3. Earlier failed compilation and model runs led to corrected mock syntax,
runtime-aware fixtures and operation-completion assertions; the final post-fix run is the result
reported above. Native/hosted UI acceptance remains deferred until an explicit desktop-test cue.

This is source/model qualification only; it does not claim desktop acceptance, publication,
installation, a new engine contract, or Rust product adoption.
