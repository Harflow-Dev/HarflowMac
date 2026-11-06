# M03 — exact 0.0.10 runtime adoption

Status: candidate installer qualification passed and exact 0.0.10 selected in
product source delivered in this cohesive local stage. All headless native/tooling and Release/bundle checks passed; final product review
found no actionable issues. Isolated app smoke and all 246 MainWindow suites (1,814 tests) passed on the
owner-approved unlocked quiet desktop.
Aggregate M03 and M04 acceptance are not established.

## Authorization and immutable inputs

On 2026-11-06 the owner accepted the recommendation to qualify exact published
0.0.10 and then select that production pin. Base:
`665f53f36b2f989ba9994a193adb56b8b7749d67`. This is source selection; no user app
installation, real-state migration, provider dispatch, MCP registration, push or
release is implied. Public polling remains unchanged; watcher fixtures are vendored
as part of the full contract bundle without watcher adoption.

Release tag/source: `8a936de61b5f9f2fdff671b65b5384259267350b`.
The release is marked **prerelease**. Wheel
`harflow_mcp-0.0.10-py3-none-any.whl`: 1,145,760 bytes, SHA-256
`c6ada9fd00c1ff85faf9fd94165b84820777bfcda5be5641bf00d300163ac8b9`.
All 180 Python payloads match the immutable source with zero mismatches.

Selected resource SHA-256:
`37dc449a1d0ac25c374ce4fb66b96ec6886bfbb38802a6e829eb8a48aac6edc5`.
Decoded specification identity:
`b4a7512c42ebd06607547a672f63509fb93aa746c1b9e70c802bf8749ccb842d`.
The full byte-identical contract bundle has 209 files and 207 fixture cases;
manifest SHA-256:
`ceb336216b8e5b0938f101b2a8b2ba5f85e3d939e281c446461499a2ae5c4906`.
The existing pinned interpreter and 29 dependency wheels remain unchanged and were
hash-verified when copied into isolated qualification inputs. Exact 0.0.7/0.0.8
specification support remains; arbitrary versions are not admitted.

[Checks and artifact hashes](M03-runtime-0010-checks.json) identify normalized
inputs, current source snapshots and raw reports using paths relative to the scratch
evidence root. Raw reports/tools remain outside the product repository; personal
home paths are not copied into this receipt.

## Qualification observed

All eight runtime reports passed their own expected outcomes:

| Operation | Acquisition calls | Subprocesses | Result |
| --- | ---: | ---: | --- |
| Baseline 0.0.8 install | 32 | 9 | Qualified baseline |
| Baseline check | 0 | 6 | Reusable |
| Explicit 0.0.10 upgrade | 32 | 9 | New generation qualified |
| Check / reuse before failure | 0 each | 6 each | Reusable |
| Corrupt-wheel replacement | 32 | 0 | Expected size/SHA refusal |
| Check / reuse after failure | 0 each | 6 each | Prior qualified generation retained |

The upgrade preserved the old generation's full recorded file hashes, symlink
entries and completion receipt. This is not a claim about modes/timestamps or
mixed-writer continuity. Synthetic old task record bytes were preserved and read
through the new runtime's public interface: all 16 reads passed. A new synthetic
publication through the 0.0.10 production store was subsequently observable through
public polling; all 21 post-publication reads passed. No provider was dispatched.
Installed payload comparison found zero mismatches across 1,131 files from 30
wheels, excluding the 30 RECORD files.

## Native and tooling snapshot

Final selected-pin MonitorCore gate passed 440 tests in 65 suites. Seven dependent
package gates have now completed: HfCommon 17, HfUI 239, HfUtilities 19,
HfRepository 518, MenuBar 88, Settings 87 and Harflow 119 tests, all passed.
The final Python tooling run passed 165 tests and 30 subtests in 25.94 seconds.
Its initial eight failures are retained: bundled-path mocks still expected 0.0.7
after resource selection; the corrected final run is the completion evidence.

SwiftFormat 0.60.1 required no edits in 1,049 admitted files (31 skipped).
SwiftLint 0.63.2 with cache disabled reported zero violations across 1,096 files.
The initial lint-cache failure remains retained rather than relabeled as success.
Repository guards passed in primary verification. The Release build and strict packaged bundle/startup diagnostic passed.
The first build under an empty scratch tool HOME refused missing Xcode macro
approvals; a build using the established development configuration passed without
changing macro trust or security settings. The final guarded MainWindow run passed all 246 suites and 1,814 tests.
Together the nine native packages passed 3,341 tests, with assertions unchanged.

## App-smoke preparation and remaining gates

App-smoke helper source was independently reviewed, including the Darwin waitid
`si_uid == 0` correction. A harmless owned `/usr/bin/true` WNOWAIT probe returned
that value under a nonzero caller UID, sent no signals, reaped successfully and
then returned ECHILD. It is observer evidence, not an app qualification result.
The correction retains owned/unreaped P_PID and initial/live UID checks rather
than treating unavailable exit UID as proof of ownership by itself.

The unique smoke app and preference-helper copies were built and signed; the
read-only AX helper was compiled. The source bundle remained unchanged and its
exact specification was verified. After the owner unlocked the desktop, the
reviewed wrapper completed with exit 0. The same PID 18896, start identity and
qualified generation showed Connected with three synthetic tasks, then four after
public polling. Both AX proofs passed and 26 post-append public checks passed.

The controller completed identity-safe cleanup with exit 0, reaped its owned child
and retained no observed survivors. All five unique-domain preference operations
succeeded: original empty-domain snapshot, notification disable, scratch verification,
restore and fresh empty-domain verification. Independent primary teardown found all
65 retained PID/start identities absent or reused, and zero kernel-executable matches
for the qualification app, helpers or scratch runtime generations. This is a bounded
point-in-time census, not exhaustive historical descendant capture.

The app controller did not retain a raw terminal waitid record. Its successful
reviewed code path establishes unreaped-child completion; the separate harmless
probe supplies raw zero-UID evidence. No app-run raw exit UID is claimed.
The guarded full MainWindow suite completed with exit 0 and a passing validated
manifest after all 246 suites and 1,814 discovered tests. Foreground testing ended
and the owner was notified. No assertions were weakened, skipped or rebaselined.

Remaining successor-completeness and live-intent work belongs to the subsequent
bounded M03 stage. Accepted M05 stored-changes and M10 statistics direction does
not close aggregate migration acceptance. No M04 implementation or owner
performance acceptance follows this exact-runtime stage. Seven pre-existing
tracker/M01 inputs remain outside this stage and were preserved.
