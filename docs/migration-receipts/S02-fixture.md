# S02 isolated installer fixture procedure

This describes qualification tooling, not an alternate production acquisition path.
The production app has no endpoint override. Temporary scripts and original logs
remain outside product repositories; [S02-installer.json](S02-installer.json)
records their exact hashes and observed results. Reproducing this tooling requires
reviewing equivalent fixture sources against the owning installer APIs; the hashes
alone do not make an arbitrary replacement script trustworthy.

## Pinned acquisition inputs

Use the exact `macos/HfCore/MonitorCore/Sources/MonitorCore/Resources/ManagedRuntime.json`
from the app input. Independently acquire its CPython archive and all 29 dependency
wheels into a scratch cache, checking size and SHA-256 before execution. Retain the
original response bytes for the exact engine 0.0.7 PyPI release JSON and its canonical
wheel URL. Verify the wheel digest independently against that response and compare
its 172 Python payloads with the selected engine source. Do not manufacture metadata,
repack an installed tree as an original archive, or substitute a completion receipt.

S02 acquired 30 pinned interpreter/dependency inputs plus the original engine wheel.
All passed size/hash checks. The engine wheel SHA-256 is
`badd323d07b184674bc269b37c8fbd8c2274db31bb01e1b644bb59c940a8407e`.
A further installed-payload check compared 1,123 files from all 30 original wheels
with the fresh generation: zero mismatches. Installation-transformed RECORD and
`.data` paths are excluded explicitly; this is not an assertion about those paths.

## Production installer composition

A scratch Swift package depends on the existing MonitorCore package and decodes the
unchanged specification. It constructs the public `ManagedRuntimeInstaller` with:

- `ManagedRuntimeLayout` bound to a new canonical scratch HOME;
- the real `ManagedRuntimeProcessRunner`;
- a local-only `ManagedRuntimeDownloading` implementation mapping exact original
  HTTPS URLs to retained original bytes;
- a scrubbed base environment, controlled system PATH and private temporary directory.

The injected downloader enforces HTTPS/no userinfo, exact URL, required host, byte
limit and original hash. Production `acquire()` still verifies artifacts; corruption
variants target the interpreter or engine wheel after original metadata succeeds.
The local transport does not exercise the production TLS/redirect implementation.
Those policies have unit-suite evidence; no new transport qualification is inferred.

The harness refuses unsafe HOME before calling the installer: secure mode-0700
root, current ownership, canonical containment, no symlink ancestors/traversal,
known root marker, and empty initial HOME. Unsafe-HOME refusal is a harness guard,
not a new production guarantee. Negative runs use independent roots.

Only this scratch HOME receives installation. Production performs extraction,
hash-required offline pip installation, pip check, native imports, exact version
qualification, relocation, completion receipt and activation. Both `checkExisting`
and `prepare` then run in fresh processes with a downloader that refuses every call;
assert the same generation and zero downloader calls. Preserve before/after receipt,
active target, generation count and absence of staging directories.

Process cleanup tracks the owned launch group and same-user processes whose cwd
remains inside the dedicated private root, rechecking process identity before
signals. It protects cleanup against repeated interruption. A synthetic `setsid`
descendant test first reproduced the old group-only escape, then passed after the
root-cwd sweep. Never share such a root with a running app while invoking the
cleanup helper. It would regard that app as belonging to the fixture run.

S02's 17 checks passed, including real installation, fresh-process reuse and
pre-activation artifact failures with no active, staging or generation artifacts.
The attempted external-network-deny sandbox was rejected by macOS. The successful
run used host permissions and the local-only injected downloader; OS-enforced
network denial is not established.

## Synthetic state and public validation

Invoke the seeder through the freshly qualified generation's Python with `-I` and
an explicit environment allowlist. Reject inherited provider credentials, client
configuration paths, runtime overrides and dynamic-loader/Python overrides. macOS
injects `__CF_USER_TEXT_ENCODING`; the harness permits only its bounded numeric
encoding form with the actual UID, not arbitrary environment inputs.

The seeder uses installed production state ownership, task/workflow codecs,
approval admission and EventLog writing. It creates labeled synthetic task output,
workflow states and absent-owner approval uncertainty. There is no provider dispatch.
Normalized event envelopes, sequence, kind and task identity are validated before
any native capture. Raw backend JSONL alone does not qualify populated Activity.

Run the installed generation's real `state-inspect`, `list`, task `status`, approval
task `status`, `approval-list` and `approval-get`. Validate each command's actual
success shape, common envelope and exact root; public commands do not all have a
`result` field. Persist stdout/stderr/exit status and before/after record hashes
before asserting success, so failed validation retains evidence.

The initial seed's generic success-shape assertion was wrong. A validation-only
continuation verified the already generated state and wrote recovered provenance;
it did not overwrite existing task records. Production reads subsequently reconciled
the absent approval owner into a failed task and invalidated request. Hash changes
are recorded rather than hidden. This specimen supports uncertainty/error pixels,
not deliverable approvals or observed execution.

Append accepts only original or recovered validated provenance bound to the exact
scratch root, generation, module and current state hashes. The verified append added
`s02-refresh-ed67373f26ae` with six normalized event envelopes, then passed the same
six public reads. This establishes a fixture mutation route, not that the app's
FSEvents path has consumed it.

The recovered root is historical evidence, not a claim that the final seeder
produced its base state. A separate fresh root was installed, seeded and appended
successfully on the first attempt using unchanged final seeder SHA-256
`185fdfd2f05bb05add15c41a0c0f94cad5b4c50f3e5a8cc31c4db31f4891993e`.
Both seed and append provenance report `recoveredAfterInterruptedValidation: false`;
each passed all six installed CLI checks. Final append task:
`s02-refresh-ee31aebbce6b`. Its fresh generation also passed the independent
1,123-file wheel-payload comparison. Exact generation identity is in the JSON receipt.

## Application isolation prerequisite

A prepared scratch app copy uses the unique qualification bundle identifier and
removes URL schemes to avoid owner single-instance/URL forwarding. Re-signing
changes embedded signature bytes and related load-command sizes. Excluding only
those fields and the signature blob, its executable content matches the built app;
its managed-runtime resource remains byte-identical. This is not original-bundle
registration or single-instance qualification. Implicit LaunchServices metadata for
an isolated identity may occur on a later launch; no explicit registration command
was run.

The app has not been launched. Read-only Foundation probes showed that temporary
HOME and CFFIXED_USER_HOME select the scratch home but do not make standard/suite
preferences read its preseeded plist on this host. String command-line `NO` values
also do not satisfy the repository's Boolean preference reads. Notification flags
therefore remain unproven before launch. The owner-state boundary requires a verified
isolation strategy or an explicit exception for only the new qualification preference
domain; an unanswered permission question does not authorize the launch.
