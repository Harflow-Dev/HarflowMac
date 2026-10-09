# Monitor performance baselines

Issue #23 starts with measurement, before selecting a transport, cache, or catalog optimization.
These tools use synthetic history and never dispatch agents. Monitor remains a consumer of the
existing versioned CLI contracts.

## Reproduce the CLI baseline

From the checkout, after `uv sync`:

```bash
.venv/bin/python scripts/benchmark-monitor.py --size small --repeats 5 --output /tmp/monitor-small.json
.venv/bin/python scripts/benchmark-monitor.py --size large --repeats 5 --output /tmp/monitor-large.json
```

Each repeat uses a new temporary home. The small fixture contains 12 definitions, 24 runs,
12 nested runs, and 32 task records. The large fixture contains 240 definitions, 400 runs,
200 nested runs, and 1,200 task records. A separate malformed-history fixture exercises blocked
catalog preparation without changing permissions. IDs and timestamps are deterministic.

The runner launches the checkout interpreter and real CLI readers, measures whole scenarios and
each process, and records raw samples alongside nearest-rank p50/p95. Five samples provide a
descriptive baseline; their p95 is the maximum, not a stable tail estimate. Catalog-cold means a
new derivative catalog, with filesystem caches left intact. Later reads have warm catalog/OS
caches but still launch fresh CLI interpreters. These are CLI scenarios, not app launch or
rendering latency. The worker supplies synthetic human ancestry to avoid host process-table
permission variability; it rejects commands outside its read-only allowlist.

## Profile the actual app

```bash
macos/build-app.sh
.venv/bin/python scripts/benchmark-monitor.py --size large --fixture-home /tmp/monitor-fixture
.venv/bin/python scripts/profile-monitor.py --app 'macos/build/Polybridge Monitor.app' \
  --home /tmp/monitor-fixture --output /tmp/monitor-profile --seconds 30 --sample
```

Use a new fixture home and empty output directory. The fixture creates restricted CLI wrappers
and a versioned marker required by the profiler. The profiler copies and signs a temporary app
with a unique bundle identifier and removes its URL registration. It pins the tool directory,
isolates history and drafts with `HOME`, disables finish notifications, and terminates only its
own app process. It does not install the app or stop an existing Monitor.

Interact with the isolated window during the observation interval to open and reopen workflows,
switch workflows, and request older history. Record interactions separately. The harness itself
does not automate selection or determine pixel readiness. Leave unchanged polling visible for at
least 12 seconds to include the two-second workflow and ten-second task safety polls. `--sample`
captures stacks in a second launch; use that run for diagnosis rather than latency comparisons.
For Instruments, attach Time Profiler or SwiftUI to the isolated PID, without changing personal
profiling permissions. Record any unavailable capture explicitly.

## Opt-in instrumentation

`POLYBRIDGE_MONITOR_METRICS=1` enables version 1 JSONL records on the app's stderr. The default
is disabled. Labels are fixed: `transport`, `decode`, `workflowLoad`, `workflowReconciliation`,
`workflowViewUpdate`, `sidebarViewUpdate`, `sidebarContentReady`, and `workflowContentReady`.
Records contain monotonic timestamps, elapsed milliseconds, stdout/stderr byte counts, and the app's resident-memory high-water mark. They
exclude commands, identifiers, paths, prompts, and answers. Readiness markers mean populated
state has been applied, not that pixels have rendered. The profile harness derives first useful
sidebar state from the first readiness timestamp relative to its monotonic launch origin.
One transport record represents one CLI invocation attempt, including failures.

Workflow load includes waiting for reads; reconciliation and view-update durations measure
specific internal work. View updates do not establish that pixels have appeared. RSS sampled
by the profiling harness is a lower bound on the peak; app instrumentation uses `getrusage`.
Synchronous stderr recording has overhead outside the measured interval, so compare equivalent
instrumented runs and use separate profiler captures to investigate main-thread stalls.

The CLI runner measures catalog bootstrap separately and parent-side JSON decoding; those
measurements are not Swift decoding or SQL-only timings. Process startup/import overhead is
included in wall time. A blocked response is a terminal diagnostic, not a completed load.

## Baseline and next-stage targets

Measured on 8 October 2026 (Asia/Jakarta), macOS 26.6.2 (25G83), arm64,
Python 3.13.5, release Monitor built from `11118f6` plus this measurement change.
Other desktop apps remained running. Exploratory profiling overlapped builds/tests; the
repeated CLI baseline ran after the full suites/builds finished, with a brief new-test run
and isolated app observation overlapping early samples. This is a developer-workstation
baseline, not a controlled hardware comparison. A production Monitor was observed using
approximately one CPU; it was left untouched.

Raw results: [small CLI](benchmarks/monitor-2026-10-08-small.json),
[large CLI](benchmarks/monitor-2026-10-08-large.json), and
[app readiness and timing records](benchmarks/monitor-2026-10-08-app.json).

CLI scenarios have five repeats. Times are milliseconds; bytes include stdout and stderr.
The cold-launch label in raw data means the initial workflow inventory CLI sequence,
not the entire app launch. Cold task inventory follows that sequence. Warm reopening
models an already cached snapshot by requesting status only; actual cache reuse was also
observed in Monitor. The runner does not implement Swift cache eviction or rendering.

| CLI scenario | Small p50 / p95 | Large p50 / p95 | Processes small / large | Median KiB small / large |
|---|---:|---:|---:|---:|
| Catalog-cold workflow inventory | 1298 / 2216 | 11931 / 16084 | 2 / 16 | 47.7 / 179.5 |
| Task inventory | 125 / 140 | 200 / 228 | 1 / 1 | 21.4 / 66.2 |
| Task summary | 128 / 135 | 553 / 664 | 1 / 1 | 2.0 / 2.0 |
| Saved workflow editor read | 675 / 758 | 1225 / 1405 | 1 / 1 | 1.2 / 1.2 |
| Cold run snapshot + index | 2553 / 4308 | 4053 / 4630 | 4 / 5 | 380.7 / 469.5 |
| Warm run status | 614 / 1021 | 667 / 711 | 1 / 1 | 5.0 / 5.0 |
| Switch run snapshot + index | 1329 / 1752 | 1406 / 1766 | 2 / 2 | 4.8 / 4.8 |
| Unchanged run poll | 683 / 945 | 718 / 793 | 1 / 1 | 5.0 / 5.0 |
| All workflow history pages | 599 / 1304 | 2839 / 6104 | 1 / 4 | 47.1 / 686.4 |
| Terminal blocked history | 112 / 169 | 131 / 140 | 1 / 1 | 1.8 / 1.8 |

The final app startup observations (one launch per size) reached populated sidebar state
in **5,198 ms small / 12,049 ms large**. Observed peak RSS was **117.2 / 150.7 MiB**.
Small observation lasted 15 seconds (12 ctl attempts, 159.8 KiB); large lasted 45 seconds
(41 ctl attempts, 2,937.3 KiB). Counts exclude tool discovery, login-shell, and setup processes.
App p50/p95 launch latency is not established by these single observations.

The final small-fixture run graph and nested child link were verified through the actual app.
Its first run load measured 3,867 ms at the internal load boundary; cached reopening showed
the complete graph in an 880 ms accessibility observation, including automation overhead.
Search by fixture ID disambiguated otherwise identical run titles for that reopening.
Earlier editor and run-selection checks also reached the expected canvas. Large-fixture
detail switching was not timed reliably through accessibility; its CLI sequences are in the
table, and the app startup/polling capture is separate.

### Ranked observations

1. **Repeated workflow reads are material.** Large initial inventory required 16 CLI
   processes and about 12 seconds median. Cold run opening required five processes and
   about four seconds. Small warm status spent about 614 ms despite transferring only
   5 KiB; current digest reuse already avoids the cold snapshot transfer.
2. **Large sidebar main-thread work deserves a separate investigation.** The final large
   startup capture recorded a 2,013 ms sidebar recomputation, versus 9.5 ms small; maximum
   decoding duration was 49 ms large. A separate 10-second stack sample recorded 649 of
   911 main-thread samples under SwiftUI view-graph transaction flushing, including sidebar
   row evaluation. A 15-second Instruments Time Profiler capture completed successfully.
   Exploratory captures also recorded much longer intervals under concurrent activity;
   those are not used as stable latency targets. These observations do not establish the
   cause of the original intermittent stall or a rendered-frame hitch count.
3. **Do not infer SQL dominance from these timers.** Catalog bootstrap is only one catalog
   boundary, not all SQL/file reads. In small initial inventory its median aggregate was
   24 ms out of 1,298 ms elapsed. Small cold-run parent JSON decoding totaled about 0.6 ms.
   Attribution among interpreter imports, server initialization, other metadata reads, and
   round trips needs a focused follow-up before choosing IPC or indexes.

### Targets for the optimization stage

- Same fixtures and comparable host load: initial workflow inventory p95 at most **1,550 ms
  small / 11,250 ms large** (roughly 30% below this baseline).
- Cold run snapshot plus index p95 at most **2,600 ms small / 2,800 ms large** (roughly 40%
  below baseline); warm status and unchanged poll p95 at most **500 ms**.
- Actual first populated sidebar state: **2,500 ms small / 6,000 ms large**, established
  with at least ten app launches before claiming tail latency improvements.
- Main-actor sidebar recomputation p95 at most **100 ms** on the large fixture. Preserve
  immediate valid cached run display, bounded history/memory, immutable page revisions,
  preparation/blocked semantics, selection, scroll, ownership, and cancellation guards.

These are proposed acceptance targets for the next stage, not achieved results. Reprofile
the highest-ranked paths and review the optimization choice before implementation.

## Validation record

- New Python benchmark/profile tests: **9 passed**; include complete runner execution,
  deterministic fixtures, real task summary replay, nested-link consistency, preparation,
  blocked completion semantics, pagination, and mutation rejection.
- All nine Swift package suites passed. After readiness-marker edits, MonitorCore
  **208 tests** and MainWindowFeature **800 tests** passed again.
- Release app build and signing verification, SwiftFormat (no changes), SwiftLint
  (zero violations), private-reference guard, and whitespace checks passed.
- Full Python suite: **5 failed, 5,972 passed, 327 skipped**. All five failures were timeout
  assertions in unchanged workflow tests. A separate rerun passed three and timed out two:
  `test_serial_worker_cap_never_blocks_barriers[True]` and
  `test_implicit_convergence_loop_uses_separate_activation_generations`. Python server
  source is unchanged; no timeout assertion was relaxed. The full suite is not green.
- Independent methodology and code reviews found missing index reads, malformed task
  associations, missing summary streams, unsupported getter flags, and parser robustness
  gaps; the harness corrections were applied and the new tests rerun.

Instruments traces and complete stack reports remain local under `/tmp/polybridge-issue23`:
they contain environment/device metadata and are not included in the repository. Numeric
records above contain no prompt or answer content. Issue #23 remains open for optimization.

## Sidebar background presentation stage

This stage changes sidebar computation and rendering publication; CLI reads and transport remain
unchanged. Sidebar source snapshots are separate from observed presentation. A detached utility
worker builds immutable presentation values and shared indexes; the main actor compares complete
presentation fields before applying changes. Clock inputs remain explicit, and command/reveal
notifications retain their event semantics.

Additional opt-in numeric stages distinguish `sidebarPreparation`, `sidebarBuild`, `sidebarApply`,
`sidebarScheduling`, and `sidebarUpdateLatency`. Scheduling measures latest-input enqueue to
detached worker entry, including a pending worker wait. Build records include numeric `background_thread`; apply records
include `rendering_writes` (changed presentation-field assignments, not SwiftUI frame counts).
These records still contain no task IDs, paths, prompts or answers. Background elapsed work,
main-actor work, scheduling delay and pixel rendering are different boundaries.

For repeated actual-app observations, preserve a pre-change build and run ten fresh synthetic
homes per fixture size for each build. For example, substitute `before` or `after` for the label
and use the corresponding built app path:

```bash
label=after
app="macos/build/Polybridge Monitor.app"
for size in small large; do
  seconds=18
  if [ "$size" = large ]; then seconds=45; fi
  for repeat in $(seq 1 10); do
    home="/tmp/monitor-sidebar-$label-$size-$repeat-home"
    output="/tmp/monitor-sidebar-$label-$size-$repeat-profile"
    .venv/bin/python scripts/benchmark-monitor.py --size "$size" --fixture-home "$home"
    .venv/bin/python scripts/profile-monitor.py --app "$app" \
      --home "$home" --output "$output" --seconds "$seconds"
  done
done
```

Use distinct fresh paths for the second build. Keep builds/tests and UI automation out of the
latency observation interval where possible, and disclose any overlap. Profile interactive
search, selection, disclosure, pagination and unchanged polling separately from the launch series.

Sidebar history now loads automatically when its trailing row enters the actual List viewport.
Each source allows one request at a time. A new applied content revision requires fresh layout
before another page; unchanged cursors, preparation, blocked catalogs and errors stop automatic
paging. Retry stays explicit. Search and backend filters still apply to loaded history, and
automatic loading can continue while they are active. Closing the window cancels requests and
clears cursor claims so reopening can retry the same page. Activity-log pagination is unchanged.

### Before/after observations

Raw numeric records and executable hashes are in
[the sidebar comparison](benchmarks/monitor-2026-10-08-sidebar.json). Each build has ten launches
per size. Small homes contain 12 saved definitions, 24 runs (12 nested), and 32 tasks;
large homes contain 240 definitions, 400 runs (200 nested), and 1,200 tasks. These launch
observations exercise first-page inventory and unchanged polling, not exhaustive history.
Small launches run for 18 seconds; large launches run for 45 seconds. An earlier 18-second
large baseline omitted prepared workflow inventory and is excluded. The fresh synthetic
catalogs used warm filesystem caches on macOS 26.6.2 arm64, Python 3.13.5, release builds.
Before observations overlapped builds/tests; after observations did not. Other desktop apps,
including a production Monitor using about one CPU, remained running.

All quantiles below use nearest rank over the recorded stage events pooled within ten launches.
They describe this sample, not stable tail estimates. The old `sidebarViewUpdate` combines
synchronous building and application; it is not the same boundary as any single new stage.

| Boundary (milliseconds, p50 / p95) | Small before | Small after | Large before | Large after |
|---|---:|---:|---:|---:|
| Old synchronous sidebar update | 0.072 / 10.475 | — | 0.031 / 2061.010 | — |
| Main-actor snapshot/preparation | — | 0.023 / 0.088 | — | 0.032 / 0.236 |
| Background build | — | 0.359 / 0.670 | — | 1.159 / 12.198 |
| Main-actor comparison/application | — | 0.026 / 0.100 | — | 0.048 / 2.569 |
| Queue to worker entry | — | 0.016 / 0.244 | — | 0.020 / 0.360 |
| Capture to applied state | — | 0.868 / 55.646 | — | 2.454 / 48.508 |
| Launch to first populated state | 3722 / 4145 | 3517 / 3692 | 12056 / 14412 | 10492 / 10588 |

Large background-build p95 **12.198 ms** meets the **100 ms** target; its observed maximum
was 13.418 ms. A conservative combined main-actor bound is the sum of the largest preparation
and application events: **3.700 ms large / 0.205 ms small**, below the **16 ms** target.
This bounds every measured pair without adding separate p95 values. Queue p95 is 0.360 ms
large (maximum 3.949 ms). End-to-end state publication includes additional main-actor waiting;
its large maximum was 70.114 ms. None of these boundaries measures displayed frames.

All 170 large and 101 small build records reported background execution. Of completed
applications, **136/166 large and 70/100 small wrote zero presentation fields**. Clock or
source changes can legitimately write; zero writes is a presentation assertion, not a count
of SwiftUI frames. Cancellation explains the difference between build and application counts.

Sampled peak RSS p50/p95 was 150.6/169.5 MiB before and 154.5/168.8 MiB after for large;
125.6/130.4 MiB before and 126.0/126.3 MiB after for small. Sampling every 100 ms yields a
lower bound, not a proven peak. Large transport-attempt median increased from 35 to 58
within the fixed observation window (small 22 to 26); This is consistent with more existing polls completing in the window;
reduced UI blocking is an inference, and the counts alone do not establish its cause. The repeated workload is therefore not a fixed number of CLI requests,
and these counts do not show a transport optimization. Large median transferred KiB was
2258 before / 5411 after; small 305 / 370. No CLI command or response shape changed.

The measured sidebar bottleneck is substantially reduced and moved off the main thread.
Remaining priorities are CLI/catalog loading and unrelated main-actor work; startup still
spends several seconds before useful state. The broader startup target remains unmet.
Issue #23 stays open until subsequent loading work has reproducible regression evidence.

### Interactive profiling and validation

A separate isolated large-fixture app session exercised search, switching between older tasks,
workflow expansion/collapse, and bottom-triggered loading. Scrolling appended older history;
a short unmatched filter continued loading until both sources displayed their end labels.
Searching then selected task 1 from the older pages, and switching selected task 10. Expanding
a workflow revealed its child shortcut; collapsing removed it. Synthetic tasks intentionally
have no activity events, so their detail pane reports empty/missing activity.

Two 20-second `sample` captures used 10 ms and 1 ms intervals, separately from the launch
series. The action capture placed `SidebarPresentationBuilder.compute/build/prepareIndexes`
on `com.apple.root.utility-qos.cooperative`; main-thread conversation indexing in that capture
belonged to `MenuBarVM.recompute`, outside this stage. During the longer, sampled interactive
session after loading more history, background build p95 was 33.989 ms (maximum 94.883),
main-actor preparation maximum 1.021 ms, and application maximum 3.877 ms. End-to-end
publication maximum was 290.169 ms. This perturbed session is exploratory, not another
latency series or a frame-stall measurement. Accessibility observations include automation
overhead and are not used as UI latency measurements.

Final verification: MainWindowFeature **820 tests**, MonitorCore **210**, PbUI **113**,
MenuBarFeature **55**, and app target **95** passed with serialized Swift tests. The Python
benchmark/profile tooling tests passed **9 tests**. SwiftFormat completed, SwiftLint reported
zero violations across 507 files, private-reference guard and whitespace check passed, and
an isolated release app built and verified its signature. The earlier full Python suite's
baseline failures remain documented above; no Python production behavior changed here.
Independent read-only Codex review found a canceled-pagination/reopen cursor claim defect;
it was fixed and covered for both history sources, then the final suites were rerun. The
second code-review pass found no further actionable defects. The final numeric review independently recomputed all reported quantiles, counters,
and bounds from the raw records and found no blocking findings. Its wording feedback
was applied to distinguish observed transport counts from a causal explanation.

The actual app's initial scrollbar reading changed during disclosure/layout settling. A
subsequent attempt to measure prolonged settled scroll stability was inconclusive: accessibility
observation stalled until the timed isolated app had exited (one tool call took about 746 seconds).
This is automation observation overhead, not a measured app interaction latency. Bottom paging,
older-task selection, and nested disclosure were verified before that failure; prolonged scroll
stability is supported by the passing serialized AppKit regression, not a reliable later UI
measurement. No stable frame-stall distribution or exact pixel latency is claimed.

## Stage 3: lightweight workflow CLI reads

The comparison starts from committed sidebar stage `db89158`. Existing workflow list, saved
definition, run page, status and detail reads now use a shared read layer before the CLI imports
the MCP server. MCP decorators and error adaptation stay in the server. Ordinary and bounded
readers retain their existing caller verification, ownership checks and aggregate metadata
budgets. Monitor flags do not grant human authority. Mutation, dispatch, inspection and assigned
input commands keep their previous paths. The sidebar still makes its three sequential reads
and uses the same polling cadence; background presentation and automatic history loading remain.

`PB_WORKFLOW_READ_METRICS=1` enables content-free stderr records with fixed `import`, `authority`,
`catalog`, `projection` and `serialization` stages. It is disabled by default. Projection includes
disk reads and thread scheduling, not just formatting. Catalog bootstrap can occur inside
authority or projection; these timings overlap and must not be added together. Serialization
measures JSON encoding, excluding stdout writing. The benchmark additionally measures `ctl`
import, catalog bootstrap, parent-side decoding and CLI high-water RSS in both revisions.
Parent launch to worker entry includes interpreter startup, script imports and argument parsing;
it does not isolate the interpreter alone. The worker's catalog/lineage imports and synthetic
human-ancestry setup are observation overhead held constant across revisions. Historical internal
authority/projection spans were unavailable, so no exact before-stage attribution is inferred.

Reproduce the comparison against an archived base and the working checkout with the same
interpreter. Run small and large concurrently in separate terminals for each revision, then wait
for both before changing revision or timing mode:

```bash
mkdir -p /tmp/polybridge-read-before
git archive db89158 | tar -x -C /tmp/polybridge-read-before
.venv/bin/python scripts/benchmark-workflow-reads.py --source /tmp/polybridge-read-before \
  --size small --repeats 10 --series-concurrency paired-sizes --output /tmp/read-before-small.json
.venv/bin/python scripts/benchmark-workflow-reads.py --source /tmp/polybridge-read-before \
  --size large --repeats 10 --series-concurrency paired-sizes --output /tmp/read-before-large.json
.venv/bin/python scripts/benchmark-workflow-reads.py --source . \
  --size small --repeats 10 --series-concurrency paired-sizes --output /tmp/read-after-small.json
.venv/bin/python scripts/benchmark-workflow-reads.py --source . \
  --size large --repeats 10 --series-concurrency paired-sizes --output /tmp/read-after-large.json
```

Repeat the final pair with `--read-timings off` to observe the default instrumentation path.
The CLI runner reuses the same deterministic fixtures and complete scenario sequences documented
above. Each repeat has a fresh synthetic home; filesystem caches remain warm. It never invokes
an installed CLI, changes personal profiling permissions or dispatches a model. Ten samples give
descriptive nearest-rank tails, not stable p95 estimates. These CLI completion boundaries are
separate from app state publication and displayed pixels.

### CLI observations and attribution

[Raw CLI results](benchmarks/monitor-2026-10-08-cli-startup.json) include ten repeats per size,
source-file hashes, individual process measurements and separate response/diagnostic bytes.
The base archive is `db89158`; the after source is the uncommitted shared-read implementation.
Measurements used macOS 26.6.2 arm64 and Python 3.13.5 on the same developer workstation.
Small and large series ran concurrently in both revisions. Other desktop apps remained running.
A short 46-test run overlaps approximately the first three seconds of the instrumented after
series (verified from log timestamps); no full suite or release build
overlaps those accepted samples. Intermediate timing series are excluded. A timing-disabled
attempt that overlapped the full suite is also excluded and repeated after validation.

Times below are milliseconds, nearest-rank p50 / p95. After values have read timings enabled.
The initial inventory row is the existing repeated `workflow-list-page` preparation-to-ready
proxy, not the complete three-read sidebar sequence or app launch.

| CLI scenario | Small before | Small after | Large before | Large after |
|---|---:|---:|---:|---:|
| Initial ready workflow page | 1032 / 1401 | 271 / 517 | 9074 / 10251 | 3406 / 4319 |
| Task inventory | 102 / 124 | 117 / 297 | 106 / 116 | 143 / 201 |
| Task summary | 102 / 122 | 126 / 254 | 302 / 330 | 385 / 531 |
| Saved workflow editor | 498 / 616 | 124 / 192 | 696 / 797 | 365 / 546 |
| Cold run snapshot + index | 2012 / 2648 | 518 / 944 | 2547 / 3222 | 717 / 1202 |
| Warm run status | 509 / 631 | 128 / 214 | 480 / 603 | 130 / 269 |
| Switch run snapshot + index | 1005 / 1140 | 264 / 416 | 1012 / 1160 | 277 / 515 |
| Unchanged run poll | 525 / 638 | 149 / 206 | 540 / 559 | 130 / 181 |
| All workflow history pages | 516 / 664 | 147 / 205 | 2069 / 2294 | 599 / 1083 |
| Terminal blocked history | 104 / 168 | 126 / 201 | 99 / 133 | 123 / 169 |

Unchanged-read p95 meets **500 ms** for both sizes. Initial ready-page p95 meets **1,550 ms
small / 11,250 ms large**. The base already met the latter proxy targets in this ten-sample
comparison; the new path provides additional margin. Unchanged task commands were not optimized;
their noisier after results must not be presented as an improvement.

Process counts are unchanged: initial workflow preparation takes 2 small / 16 large CLI
processes; cold snapshot plus index takes 4 / 5; switching takes 2 / 2; unchanged polling takes
1 / 1; complete workflow history takes 1 / 4. Median response payloads also remain unchanged
at 47.3 / 177.1 KiB for initial preparation, 380.2 / 468.8 KiB for cold snapshots, 4.8 / 4.8 KiB
for unchanged polls and 47.0 / 685.8 KiB for complete history. Timing diagnostics increase stderr
bytes, recorded separately; they do not change response JSON. Counts exclude interpreter setup,
shell/tool discovery and setup-client processes.

Median unchanged-process measurements distinguish the remaining costs:

| Boundary | Small before → after | Large before → after |
|---|---:|---:|
| `ctl` import (ms) | 49.6 → 68.1 | 50.1 → 62.6 |
| Command body (ms) | 363.2 → 19.5 | 366.5 → 21.0 |
| CLI high-water RSS (MiB) | 77.9 → 36.5 | 78.2 → 36.9 |
| Parent JSON decoding (ms) | 0.054 → 0.058 | 0.056 → 0.066 |

After-only unchanged-read authority p95 is 7.4 / 9.5 ms, disk/projection p95 7.0 / 11.2 ms,
and JSON encoding p95 0.074 / 0.090 ms. Parent launch to worker entry has medians 40.8 / 41.4 ms;
the baseline runner did not collect this boundary and records `null`, not a zero-duration sample.
These costs include scheduling and instrumentation overhead. Command-body reduction is consistent
with avoiding server initialization, but the entire old command body cannot be attributed to MCP
imports alone. Module-exclusion tests establish that the new CLI reads import neither MCP nor
the server and do not construct a task registry or start its maintenance.

Large initial preparation still spends a median 1,167 ms in catalog bootstrap across its
16 processes (before 931 ms). After authority p95 is 1,327 ms and disk/projection p95 413 ms,
with overlapping catalog work. Catalog itself was not optimized. Repeated interpreter/import
work and bounded preparation remain the next measured bottlenecks; serialization and decoding
are small here. A later batching proposal can use these residual process counts. This stage
adds neither batching nor a service, cache or index.

The large saved-definition read also retains ordinary caller verification: its authority p95
is 378 ms, versus 1.5 ms for definition disk/projection. That security-sensitive scan is a
separate residual cost from bounded Monitor page preparation; no authority check was skipped
to meet a latency target.

### Validation boundaries

Response characterization before extraction passed 108 tests. New subprocess tests reject
MCP/server imports and task-registry construction for every routed read command. Expected
human and managed-role outcomes use synthetic saved definitions and durable ownership receipts,
alongside invalid/undecidable authority, snapshot guards, preparation/blocked history, active
pages, nested headers, stale cursors and concurrent snapshot-change regressions. The independent
read-only review found a parity-test gap: two adapters sharing a mocked reader could agree on
the same mistake. Real ownership/receipt tests now assert expected scope independently.

An initial stale test mock read ordinary workflow collections before the test home was isolated.
The audited read path calls no raw task/run/definition writers, but refreshes of existing
derivative catalogs cannot be ruled out. Subsequent tests and all performance measurements used
synthetic history. A sandboxed full-suite attempt was stopped because process inspection was
blocked; its identity failures are not counted as final verification. The full suite was rerun
with process inspection available. No model integration tests, installation, commits, pushes
or GitHub mutations were performed.

All nine serialized Swift suites passed: PbCommon 17, PbUI 113, PbUtilities 19,
MonitorCore 210, PbRepository 255, MainWindowFeature 820, MenuBarFeature 55,
SettingsFeature 63 and the app target 95 tests. SwiftFormat lint found no files requiring
formatting; SwiftLint reported zero violations across 507 files. The private-reference and
whitespace guards passed. The isolated release build verified its signature; its executable
SHA-256 is unchanged from the committed sidebar stage
(`a5d6c911eda8bbb49c6d24869c49189c77b6a0605f0376ec500f8bbfc2770e9d`).

Final full Python verification passed **6,039 tests, 327 skipped** in 610 seconds, with model
integrations disabled. Affected read/authority/tooling suites passed **280 tests**. An earlier
full run had five failures: one stale server-reader test hook and four client subprocess tests
whose isolated HOME did not yet exist. The hook was moved to the shared reader without relaxing
its behavior assertions, the HOME directory was created, and the client/catalog rerun passed
357 tests with one skipped. The final full run above follows those fixes. The earlier stage's
workflow timeout failures did not recur. Independent code and numeric reviews found no remaining
blocking findings in the shared-read implementation and accepted CLI results.

The final clean timing-disabled series also has ten repeats per size, with no full tests,
builds or app observations overlapping it. Disabled-path p95 is **273.5 / 194.6 ms** for unchanged
polls, **582.2 / 5,407.6 ms** for initial ready workflow pages, **1,092.5 / 1,099.3 ms** for cold
workflow opening, **263.3 / 297.4 ms** for warm reopening and **314.7 / 1,259.1 ms** for complete
history pagination (small / large). It meets the unchanged-read and inventory targets too.
All raw read-stage maps are empty, confirming timing output is disabled. On/off series were
collected in different workstation intervals; slower values in the disabled series do not
establish negative instrumentation overhead. Source hashes match the final timing-enabled code.

### Actual app observations and remaining startup work

[Raw app results](benchmarks/monitor-2026-10-08-cli-startup-app.json) contain ten after launches
per size. The before comparison reuses the ten final sidebar-stage launches from
`monitor-2026-10-08-sidebar.json`, corresponding to committed `db89158`. The release executable
hash is identical, as are the profiler and fixture definitions. New after launches were serialized
with fresh synthetic homes, 18-second small / 45-second large windows and warm filesystem caches.
No tests, builds, benchmarks or UI automation overlapped them. Before and after occurred in
different workstation intervals with other desktop apps running. RSS sampling and opt-in app
timings have observation overhead in both series.

| App boundary (milliseconds, p50 / p95) | Small before | Small after | Large before | Large after |
|---|---:|---:|---:|---:|
| Launch to populated sidebar state | 3517 / 3692 | 1659 / 3813 | 10492 / 10588 | 11036 / 12680 |
| Main-actor preparation | 0.023 / 0.088 | 0.029 / 0.096 | 0.032 / 0.236 | 0.057 / 0.189 |
| Background build | 0.359 / 0.670 | 0.630 / 0.949 | 1.159 / 12.198 | 1.962 / 8.426 |
| Main-actor comparison/application | 0.026 / 0.100 | 0.080 / 0.106 | 0.048 / 2.569 | 0.451 / 1.454 |
| Presentation enqueue to worker entry | 0.016 / 0.244 | 0.025 / 0.352 | 0.020 / 0.360 | 0.028 / 0.482 |
| Capture to applied state | 0.868 / 55.646 | 0.961 / 59.816 | 2.454 / 48.508 | 2.790 / 54.166 |

All 20 after launches reached populated state and remained alive through the observation window.
The small median improves, but its descriptive p95 remains above **2,500 ms**. Large median and
p95 are higher than before and remain above **6,000 ms**. These app observations do not demonstrate
a broad startup improvement despite the CLI gains. Different workstation intervals and ten
samples limit causal and tail conclusions; the higher values are reported rather than discarded.
Readiness still means populated state publication, not displayed pixels or complete retained history.

The background sidebar behavior remains intact: all 119 small / 214 large build records report
background execution; 86/116 small and 178/208 large applications write zero presentation fields.
Large build p95 8.426 ms meets the existing 100 ms target. The sum of the largest measured main-actor
preparation and application events bounds their combined work at **0.237 ms small / 5.188 ms large**,
below 16 ms. Scheduling p95 is reported separately above (maximum 4.474 / 10.909 ms), and capture-to-
application includes further main-actor waiting. These metrics do not measure SwiftUI frame stalls.

Median sampled peak app RSS is 126.0 → 126.4 MiB small and 154.6 → 154.9 MiB large. Descriptive
RSS p95 is 126.3 → 145.2 MiB small and 168.8 → 156.1 MiB large. This is a sampled lower bound,
separate from CLI child high-water memory; no total process-tree memory reduction is claimed.
Median transport attempts in fixed windows increase from 26 → 32 small and 58 → 72.5
large, with transferred KiB 370 → 502 and 5,411 → 7,650. More polls can finish when reads are faster;
these counts do not show batching or a changed polling cadence. Discovery, shell and setup-client
processes remain outside these counts.

One large after launch completed small preparatory responses around 1.6, 3.9, 6.2 and 8.5 seconds,
then larger ready responses around 10.5–10.7 seconds; populated state followed at 10.8 seconds.
The repeated intervals are consistent with the existing preparation/retry schedule dominating
startup even when individual reads are faster. This is an inference from transport timestamps and
the unchanged scheduling code, not an isolated causal experiment. The next plan should investigate
bounded preparation rounds and retry scheduling alongside residual process/import work. Ordinary
large-definition authority scans remain another measured cost. Serialization and sidebar building
are smaller here. No target miss authorizes batching, a persistent service, cache or index in this
stage; Issue #23 requires further startup work and remains outside this stage's closure scope.

A separate fresh-large-fixture launch captured 20 seconds of stacks at 10 ms intervals, starting
two seconds after launch. It used the profiler's private-bundle and owned-PID cleanup, with its
`observe` helper forced to sample the first launch so preparation was still cold. The capture
succeeded (exit 0) and is excluded from latency quantiles. `SidebarPresentationBuilder.compute`,
`build` and `prepareIndexes` appeared on `com.apple.root.utility-qos.cooperative`; the main thread
most often waited in the event loop/Mach receive path (1,597 of 1,688 sampled main-thread stacks).
This supports investigating preparation/waiting rather than claiming a new sidebar CPU bottleneck.
It does not establish a frame-stall distribution or displayed-content latency. No accessibility
automation ran during these observations; the prior stage's automation-overhead limitation is
unchanged. Local stacks contain device metadata and are not published; their numeric observations
are retained in the app result artifact.

Final independent read-only Codex review recomputed the app and timing-disabled CLI findings,
checked baseline provenance, source/executable hashes and stack evidence, and found no remaining
findings. The final private-reference and whitespace guards passed after report updates.

## Stage 4: viewport-bound Parallel activity

This stage targets interaction after launch, in both standalone Parallel groups and the activity
columns beneath the workflow canvas. The existing startup findings and unmet startup targets remain
unchanged. Detailed feeds are resident for viewport-intersecting columns plus one neighbor on each
side; complete lightweight group metadata remains available for ordering, summaries and actions.
Viewport measurements, rather than speculative lazy-view appearance, determine activity leases.

### Reproduction and boundaries

Create fixtures only in a new, empty synthetic HOME:

```sh
.venv/bin/python scripts/benchmark-parallel.py --fixture-home /tmp/pb-parallel-64 --conversations 64 --chain 16 --activity long --workflow
.venv/bin/python scripts/profile-monitor.py --app 'macos/build/Polybridge Monitor.app' --home /tmp/pb-parallel-64 --output /tmp/pb-parallel-profile --seconds 300
.venv/bin/python scripts/benchmark-parallel.py --fixture-home /tmp/pb-parallel-64 --append-burst 32
```

The fixture matrix is 8/64/256 conversations, one/16 resume checkpoints per conversation, and
sparse/long activity. Sparse checkpoints contain eight normalized events (two paired tool calls);
long checkpoints contain 516 (256 paired calls). Every checkpoint has a deterministic summary and
resume ancestry. `--workflow` adds one saved definition and one completed execution associated
with every checkpoint, allowing the same data to exercise the embedded workflow pane. Wrapper
commands permit reads only. Burst notices deliberately stress tailing after synthetic completion;
they do not simulate a real live-agent lifecycle.

The opt-in Swift benchmark uses the same conversation, checkpoint and tool-call counts:

```sh
cd macos/PbFeatures/MainWindowFeature
POLYBRIDGE_MONITOR_METRICS=1 PB_PARALLEL_BENCHMARK_OUTPUT=/tmp/pb-parallel-model-results.json swift test --no-parallel --filter benchmarkParallelResidency
```

Model-settlement timestamps measure computed presentation application, not displayed frames.
This benchmark uses a debug test build with generated Mockable dependencies. Its settlement
observer polls every 50 ms; elapsed settlement includes that observation floor. Precise internal
preparation, scheduling, build and application boundaries come from opt-in MonitorMetrics records.
The package's existing test target cannot compile in release mode: release omits source mocks and
DEBUG preview fixtures referenced by tests. Two attempted optimized test builds failed before
collecting observations. The release app is built and assessed separately.
The eager comparator measures timeline computation over every column, excluding CLI reads, view
layout and SwiftUI rendering; it is not a baseline of the entire old application. CUA action and
accessibility observation round trips include automation overhead and must not be substituted for
input-to-visible-update latency. Stack sampling is a separate perturbed diagnostic run. Ten
observations provide descriptive tails, not stable tail estimates.

### Final model measurements and remaining validation

The final post-retention debug run completed 840 observations across all 12 fixture shapes and
seven scenarios (ten observations per shape/scenario). All 720 completed presentation builds ran
off the main thread. VM-owned residency remained at most four columns and 64 checkpoint leases
for the measured viewport. Unchanged polls produced no builds or presentation publications.
Raw numeric observations are in [monitor-2026-10-08-parallel.json](benchmarks/monitor-2026-10-08-parallel.json).

For 256 conversations with 16 checkpoints and long feeds, descriptive p95 measurements were:

| Boundary | Milliseconds |
| --- | ---: |
| Former eager all-column timeline CPU comparator | 5109.31 |
| Resident background build during viewport crossing | 74.20 |
| Resident background build during rapid reversal | 80.40 |
| Changed resident activity: preparation / application | 1.89 / 0.96 |
| Prompt toggle: preparation / application | 1.00 / 1.38 |
| Viewport main-actor work, including lease reacquisition | 41.93 |
| Lease reacquisition within viewport work | 33.95 |
| Initial mock membership preparation | 281.37 |

The background build target is met in these observations; the 16 ms main-actor target is unmet
for viewport transitions and initial membership preparation. These boundaries measure different
amounts of work: the eager comparator processes the whole group, while resident builds process
nearby columns. They establish reduced computation, not an equivalent whole-app speedup ratio.

An earlier debug run exposed repeated full ancestry construction during conversation grouping.
Grouping now indexes ancestry and grouping keys once per input, with parity tests; the final run
passed without relaxing assertions. The interrupted exploratory run is not included in final
statistics.

Actual-app baseline scrolling was observed for 8, 64 and 256 columns. Automation round trips
were slow and one app-binding operation stalled; overlapping exploratory runs cannot establish
a matched before/after latency or memory comparison. Final optimized displayed-frame latency,
embedded-pane interaction verification, native stall profiling and traversal memory validation
remain incomplete. The visible-interaction p95 target of 100 ms is therefore unverified. SwiftUI
may retain lazy view snapshots after eviction; the proven bounds apply to VM-owned heavy models
and leases, not a guarantee of constant total process memory. Lease reacquisition is the clearest
remaining measured interaction cost.

Final verification: 845 MainWindowFeature tests and 17 Python benchmark/profile tooling tests
passed after the retention fixes. MonitorCore (211) and PbRepository (255) suites passed during
this stage. SwiftFormat reported no changes needed; SwiftLint reported zero violations. The
private-reference guard and diff whitespace check passed. The final release product compiled
and the local app bundle assembled successfully without installation. Independent read-only
Codex review found no remaining code or report blockers after the raw metric evidence was added.

## Stage 5: automatic activity pagination (verification in progress)

Task detail, standalone Parallel and the workflow's bottom Parallel pane share a lazy vertical
activity feed. It positions at latest activity, reveals older loaded rows in batches of 100, and
requests bounded history near the oldest visible edge after positioning or restoration settles.
Only visible Parallel columns initiate pagination; neighboring columns retain activity leases.
Short viewports permit one automatic older-history operation per positioning or interaction episode;
intentional upward scrolling or a tool disclosure replenishes that budget. This prevents a collapsed
group with unchanged visible height from draining its conversation on mount. Valid empty decoded
pages still commit their cursor; the UI fill budget does not turn them into reader failures.
A mounted feed retains lightweight geometry for rows it has measured; column eviction discards
that view-owned geometry. Loaded history and its measurements can grow through requested paging.
Show all and manual Load more controls are removed; failed history reads retain explicit Retry.
Initial resume-chain history forms a recent suffix: the newest member is paged before the previous
member is revealed. If a resumed turn is newly discovered while someone is reading, existing rows
and the reading anchor remain visible; its seeded tail may leave a gap until requested pagination
fills that turn. The app does not drain unrequested history to close that gap automatically.

Event deduplication, incremental folding and prepend reconstruction run on each stream's serialized
utility queue. History completion follows its committed item snapshot. Task-detail and Parallel
presentations use immutable snapshots and background workers, with complete equality at application.
Parallel acquires resident resume-member leases in cancellable batches of at most four attempted
members or four milliseconds, yielding between batches. A single synchronous acquisition can exceed
four milliseconds; the budget bounds additional attempts, not an uninterruptible call's duration.
The repository separately limits initial activity reads through their first committed history
snapshot and complete initial summary scans to four shared FIFO jobs. Activity and summary work
for one stream may use two slots. Queued work is canceled when its owning interest is released;
running work retains its slot until completion. A long summary scan can therefore delay queued
feeds. This bound does not change post-initial polling, snapshot refreshes, or group membership.

The repository experiment ran 150 observations (ten per scenario and logical 8/64/256 group size)
with synthetic logs and no model calls. Each logical size uses the same sixteen resident streams;
these labels establish resident repository behavior, not whole-group UI scaling. All 3,360 recorded
read/fold boundaries ran off the main thread. Thirty unchanged-poll observations produced zero folds
and zero publications. Initial/page/prepend publication counts were not measured.

| Repository boundary | Descriptive p50 ms | Descriptive p95 ms |
| --- | ---: | ---: |
| Initial settlement | 113.82 | 167.32 |
| Older-page settlement | 59.86 | 61.56 |
| Prepend settlement | 58.50 | 62.17 |
| Controlled burst settlement | 62.33 | 64.93 |
| Older-page folding | 0.61 | 3.50 |
| Older-page reading | 15.93 | 21.18 |

Settlement includes the test observer's approximately 50 ms sampling floor. These are internal
boundaries, not displayed-content latency. Ten observations provide descriptive tails, not stable
tail estimates. Process RSS high-water was 52,363,264 bytes, including the test runner and previous
cases; it is not a per-scenario or per-conversation memory estimate. Raw numeric results are in
[monitor-2026-10-08-activity.json](benchmarks/monitor-2026-10-08-activity.json).

Reproduce the repository experiment with `POLYBRIDGE_MONITOR_METRICS=1` and
`PB_ACTIVITY_REPOSITORY_BENCHMARK_OUTPUT=/tmp/activity.json` plus
`PB_ACTIVITY_REPOSITORY_METRICS_PATH=/tmp/activity.log` while running
`swift test --no-parallel --filter benchmarkActivityRepository > /tmp/activity.log 2>&1`
from `macos/PbCore/PbRepository`. Parse the final log after the process exits to include buffered
metric lines; keep the original raw numeric observations. Fixture generation uses
`scripts/benchmark-parallel.py --conversations 8 --chain 16 --activity long --workflow` with a new
synthetic `--fixture-home`; repeat for 64 and 256. No production history is read or modified.

Baseline actual-app observations covered standalone horizontal reversals, manual detail history
paging and workflow-pane horizontal reversals (ten each). Their CUA action and accessibility
observation times are retained separately in the raw artifact. They are automation round trips,
not displayed-frame measurements or an equivalent comparison to automatic history paging.
Complete final actual-app interaction validation remains pending; automation is intermittent after resuming.
Neither the visible-interaction p95 target of 100 ms nor the final main-actor target of 16 ms is
claimed from the repository experiment.

The final model experiment contains 840 observations: ten per scenario across 8/64/256 conversations,
1/16 resume members, and sparse/long feeds (2/256 tool calls per member). All 1,623 completed
presentation builds ran off the main thread. Resident columns were at most four and leased members
at most 64. Unchanged complete inputs produced zero builds and zero rendering writes. Batched lease
acquisition creates more intermediate changed loading presentations than the previous single batch;
the increased build count is not a duplicate-poll publication regression.

| Largest model fixture, descriptive p95 | Stage 4 ms | Stage 5 ms |
| --- | ---: | ---: |
| Background build: viewport crossing | 74.20 | 5.41 |
| Background build: rapid reversal | 80.40 | 3.99 |
| Main-actor viewport work: crossing | 41.93 | 12.88 |
| Main-actor viewport work: reversal | 43.39 | 16.91 |
| Initial membership preparation | 281.37 | 248.96 |

The background build target is met in this model experiment. Crossing meets the 16 ms viewport
boundary; reversal and initial membership preparation remain above it. For resident activity changes,
preparation/application p95 were 0.49/0.65 ms. Scheduling p95 was 0.05 ms during crossings and reversals.
These boundaries can nest and must not be added as independent timings. Recent-suffix preparation
builds one turn initially instead of folding all sixteen seeded tails; the comparison intentionally
includes that reduced work and is not an equivalent full-history throughput ratio. Internal model
settlement includes the test observer's roughly 60 ms sampling floor and is not displayed latency.

Reproduce the model experiment from the repository root with `POLYBRIDGE_MONITOR_METRICS=1` and
`PB_PARALLEL_BENCHMARK_OUTPUT=/tmp/parallel.json` while running
`swift test --package-path macos/PbFeatures/MainWindowFeature --disable-build-manifest-caching --no-parallel --filter benchmarkParallelResidency > /tmp/parallel.log 2>&1`.
The final repository experiment was rerun after the duplicate-record correction without concurrent
heavy verification. Its earlier optimized run is retained as exploratory evidence; differences between
those runs do not establish a speedup attributable to deduplication.

Final source checks so far: 875 MainWindowFeature tests, 259 PbRepository tests, 212 MonitorCore tests,
6,047 Python unit tests (327 skipped), and 16 benchmark tooling tests passed. Exact CI versions
SwiftFormat 0.62.1 and SwiftLint 0.65.0 pass; the private-reference guard and whitespace check pass.
Native hosted tests cover automatic pagination, prepend plus concurrent arrivals, live-follow
suppression, eviction/restoration, and completed anchor restoration after widening and narrowing.
The final isolated release build (36.50 seconds after the history fix) and 95 app-consumer tests pass. Independent read-only Codex review
round three found no actionable findings. The isolated release-app check
found a paging admission race: the feed could retain its loading indicator when the controller
declined a stale request. The final acceptance handoff and regression tests correct this; rejected
task-detail requests also produce zero observable presentation writes. The rebuilt eight-conversation
Parallel feed automatically advanced from 51 to 101 steps, then settled without a loading indicator.
Neighboring columns retained their 51-step seed until entering the viewport. No Show all or manual
Load more controls appeared in the settled Parallel accessibility tree.
A computer-automation observation also waited about 18,773 seconds while the Mac
was unavailable; that interval is excluded from interaction latency measurements.

The final release-app observation includes initial loading, normal polls, attempted accessibility
scrolling and a locked display; it is not a matched scenario sample. All 95 recorded background
presentation builds, 153 page reads and 153 folds ran off the main thread. Aggregate descriptive
preparation p50/p95 were 7.57/16.77 ms, comparison/application 0.075/0.195 ms, build 15.04/36.48 ms
and scheduling 0.23/195.73 ms. These correlated, mixed-boundary records cannot establish the
interaction target. Preparation exceeds 16 ms in this observation; scheduling remains material.
Recorded process RSS high-water was 240,238,592 bytes; a single `ps` lifetime CPU snapshot was 66.4%,
not a scenario average or peak. Maximum recorded residency was seven columns and 112 members;
the actual viewport differs from the fixed model benchmark and no four-column app limit is claimed.
A separate perturbed three-second stack sample included main-thread display-cycle/layout work
and waiting on the event loop. It does not establish frame-stall durations.

Repeated automation errors included invalid/ambiguous elements and missing windows. The bundle-ID
automation call subsequently confirmed the Mac was locked. Only one final horizontal AX round trip
completed (5,765 ms including automation); it is not displayed latency or a usable ten-sample tail.
After resuming, the standalone Parallel tool disclosure responded and moving its vertical scrollbar
to the oldest edge loaded 101 to 151 steps; subsequent observations showed 251 steps. The workflow
bottom pane also displayed automatic history with 101 steps and no manual controls. These are
functional observations on the pre-review-fix release, not matched timing samples. Automation still
reported missing windows, ambiguous links and timeouts, including 51-second and 69-second round trips.
After the GitHub review fix, the rebuilt release app opened Task detail, expanded its tool group,
and automatically paged into a previous resume member (569 steps). The workflow bottom pane
expanded its group and automatically advanced from 151 to 201 steps at the oldest edge. The shared
feed now preserves Task detail's prompt bubble and hides it in both Parallel surfaces, whose explicit
header toggle owns prompt visibility. Hosted regression tests reproduced the duplicate prompt before
the fix and passed afterward, followed by all 874 affected suite tests.
The next GitHub pass found a workflow-history admission leak during Refresh workflows. Restarting
polling now cancels and clears the older request and reserved cursor. A cancellation-ignoring
reader regression covers late success and failure while a fresh same-cursor request remains active.
The final 875-test suite and release build pass; the rebuilt workflow activity pane settles with
automatic history, no loading indicator and no manual history controls.
Matched ten-observation sets for all three sizes, native lazy horizontal scrolling and exact
app-level anchor restoration remain unverified.
The displayed 100 ms target is unverified. These limitations remain explicit;
unit/native-hosted coverage does not substitute for the missing actual-app checks.

The post-review eight-conversation release observation is preserved separately as
`actual_app_post_review` with raw content-free timing records. Its mixed load/interaction/poll
sample includes all three surfaces, not matched per-scenario tails. Parallel preparation p95 was
6.18 ms and application 0.072 ms, but background build p95 was 200.65 ms and scheduling 151.42 ms.
Task-detail build/application p95 were 85.59/0.342 ms; page read/fold p95 were 614.91/31.18 ms.
All recorded presentation builds, reads and folds were off-main. Recorded RSS high-water was
396,722,176 bytes after requested history and multiple surfaces. These observations reinforce the
remaining scheduling/read/build costs; they do not establish the displayed interaction target.

Repository and model timings precede the final short-fill, reset and paging-admission fixes.
The folding and background presentation algorithms are unchanged, but the admission and UI paths
have changed; these experiments do not mount SwiftUI feeds or measure the final UI fixes.
Raw evidence records both measured and final source hashes.

Installed-app verification at `99c517b` found a separate blocker after review and green CI:
opening completed activity caused sustained SwiftUI layout work (about 98% CPU after seven
minutes). A three-second, content-free stack sample placed all 223 main-thread samples in
SwiftUI graph/layout work. The owned verification process was stopped. This observation is
an application hang, not automation observation overhead; installed activity verification is
incomplete until it is resolved. The installed-app hang was not reproduced in the synthetic
variable-height markdown feed experiments. Those experiments reproduced incorrect bottom
positioning and follow-state changes during resizing; synthetic responsiveness was not
quantitatively measured. These regressions do not establish the hang's cause.
The CPU number is one Monitor-process observation from macOS `ps %cpu`, whose local manual
describes a decaying average over up to a minute. It is not a scenario peak; its normalization
to a core or total machine capacity was not independently established. `sample` reports native
physical-footprint strings `116.1M` and peak `116.2M`; the preserved evidence and local manual
do not establish the `M` scale. Byte values are unavailable, and these rounded footprint values
are excluded from comparisons with the separate RSS measurements.
The attempted positioning fixes did not converge across all synthetic shapes and were removed;
production sources remain at `99c517b`. Their evidence is retained outside the repository.
The saved Monitor bundle was restored and its signature and executable hash verified; the failed
candidate remains available for diagnosis. The verified server installation and refreshed client
registrations remain in place. PR #31 returned to draft, and installation delivery remains incomplete.


### October 9 follow-up: actual activity layout and sidebar clipping

Verification is still in progress. The same completed activity selection reproduced the
layout hang in private release applications. Moving row measurements out of observed state
was insufficient. Suppressing unchanged native scroll publications and removing the disclosure
animation from ordinary sidebar selection was also insufficient for this case.

A controlled build changed only the vertical `LazyVStack` to `VStack`. That activity opened;
273 of 274 main-thread samples then waited on the event loop, compared with all main samples
in graph/layout work for the lazy variants. This isolates participation of the lazy container;
it does not identify the specific SwiftUI mechanism. The eager stack was diagnostic only,
and the production source was immediately restored to lazy rendering. Replacing observed SwiftUI row geometry with generation-bound native row measurements
allowed the previously hanging activity to open and paginate in a private release app. This
retains lazy rendering; the final candidate still needs actual-app verification. CUA call duration includes observation overhead and is not
used as displayed interaction latency.

The natural-height sidebar candidate displayed the selected middle child-workflow shortcut
with its title, detail and metadata fully visible in the actual application, matching the
reported three-line row pattern. Two hosted sidebar fixtures pass both old and candidate
code, so they provide coverage rather than reproduce the original clipping trigger.
The four-job initial-read limit has delayed-reader and shared-lease cancellation coverage;
its effect on the reported 71-task group has not yet been measured.

[Raw follow-up observations](benchmarks/monitor-2026-10-09-layout.json) retain the individual
layout comparisons and their limits. None of these private candidates has replaced the
saved installed Monitor; delivery and the required matched interaction measurements remain
incomplete.

### Revised Parallel retention policy

The user-approved follow-up replaces the earlier neighbor-prefetch/eviction policy. Activity leases
and updates now cover only viewport-intersecting columns. Never-visited conversations retain only
lightweight descriptors. A visited conversation keeps its complete immutable presentation and
completed input while off screen, without subscriptions or presentation rebuilding. Returning
conversations display that snapshot during stream reacquisition and retained-history restoration;
new committed activity replaces it once ready. Current metadata still supplies headers and action
targets. Conversation removal and full teardown clear snapshots. Memory therefore grows with visited
conversations and explicitly loaded history; the previous bound on heavy off-screen models no longer
applies. Lease counts remain bounded by visible conversations and their resume members.

The affected Parallel VM suite passed 68 tests, including retained content during delayed reentry,
late off-screen updates, current shared leases, historical pagination and lifecycle cleanup. The full
MainWindow suite then passed 893 tests in 91 suites with WindowServer access (154.703 seconds),
including native row-anchor and loading-to-content window-frame fixtures. Earlier sandboxed AppKit
runs had no screens and collapsed test windows; their geometry failures are excluded from product
regression evidence. The loading skeleton was also bounded to the available viewport after its
intrinsic minimum height measured 752 points against a 620-point window. Actual-app confirmation of
the outer-frame jump and final memory measurements remain in progress. These results do not establish the displayed-interaction latency target.

### Sidebar interaction acknowledgement

A sidebar click previously changed routing immediately but left the List binding's observed highlight
at its previous value until background presentation completed. The selection setter now acknowledges
the click synchronously using settled conversation/ownership indexes; full visibility and retention
reconciliation remains in the background worker. This addresses a concrete source of transient old-row
highlight restoration, separately from the loading-placeholder window minimum-height correction.
The affected sidebar run passed 171 tests in 16 suites (59.367 seconds); the isolated release
build succeeded and read-only review found no actionable issue. The full Python suite passed
6,047 tests with 327 skipped (436.83 seconds). After explicit action-time approval, the new private release candidate launched. Six alternating
completed-task selections matched the requested native selected row after each observation and
finished without a loading placeholder or hang. Accessibility observations do not resolve a
split-second transient, so the synchronous-binding regression test supplies that boundary.
Installed-app verification remains pending.

### Blank activity on initial Parallel layout

A private release app reproduced a loaded two-step column with a blank feed beside populated
columns before user scrolling. The shared feed's initial positioning task could return before
its native vertical viewport became positive; later native reports updated nonobserved geometry
without explicitly retrying ScrollViewReader positioning. An observed readiness transition now
retries that positioning. A nested horizontal lazy-stack fixture with a partially visible third
feed and delayed native attachment passes without scrolling, as does the existing resize/prepend
anchor fixture (two tests, 4.742 seconds). This is targeted race coverage, not proof that the
fixture reproduces the screenshot's exact timing. The readiness-only release candidate still reproduced the blank middle column; its loaded body
was also absent from the accessibility tree. Readiness alone is therefore insufficient. The final implementation
targets the last concrete row before enabling numeric bottom restoration, rather than trusting the
transparent bottom sentinel and estimated lazy document height. The release candidate displayed
the previously blank middle body and Finished marker
before scrolling on its first opening and five subsequent fresh group openings. A screenshot also
confirmed visible activity in all three displayed columns. All 15 shared-feed tests passed in
53.393 seconds. These six actual-app observations cover this reported group and are functional
checks, not a displayed-latency series or proof for every activity shape. Installation remains pending.

### Final follow-up verification before publication

The final full MainWindow run passed 895 tests in 91 suites (148.384 seconds) with native
WindowServer access. Repository tests passed 261 cases and app-shell tests passed 95 cases;
the full Python suite passed 6,047 tests with 327 skipped. SwiftFormat checked all 524 files
without changes, SwiftLint completed with file/line-length warnings, and the private-reference
guard and diff whitespace checks passed. The installable release bundle built and signed
successfully. Independent read-only review found no actionable issue. GitHub review, CI and
installation are subsequent delivery gates; none is claimed complete by these local results.

### GitHub review follow-up: restoration generation

Codex identified a repeated-restoration race at d79ed9a: measurement generation advanced on a
nonobserved reference while the view could otherwise remain unchanged, leaving callbacks bound
to an obsolete generation. The generation now lives in SwiftUI State, while measured frames
remain unobserved. The native anchor fixture overlaps resizing and prepending and waits for
stable final clip/document geometry before simulating a reading nudge; all anchor and relative
offset assertions remain intact. The final affected feed run passed 15 tests (57.928 seconds),
the release bundle rebuilt successfully, and read-only follow-up review found no actionable
issue. Actual-app verification after this fix awaits an unlocked Mac; previous six successful
openings describe the pre-review-fix candidate.

The next GitHub review found that the package AGENTS.md still described the superseded neighbor
prefetch/heavy-eviction policy. Its scoped contract now matches the later user-approved visible-only
leases and retained visited snapshots. This follow-up changes documentation only; runtime source
and the post-restoration-fix release binary remain unchanged.

The final review also identified retention pruning changing a conversation identity while its
visited snapshot remained keyed by the old identity. Presentations and completed inputs now
follow the same deterministic membership migration as interaction state, before absent identities
are removed. A regression covers off-screen pruning and immediate retained content on return
while the replacement stream is loading. All 69 Parallel VM tests passed after this fix; the
release app rebuilt successfully, with formatting and private-reference checks passing.

Hosted CI initially missed the heartbeat count in one scenario (136/160), then in all four
scenarios on an unchanged rerun (145, 131, 139, 144). All functional assertions passed, and the
four unchanged tests passed locally. Timer/process throttling is a plausible explanation, not
proven by these counts. The heartbeat fixtures now hold a scoped user-initiated latency-critical
process activity and use explicit user-initiated scheduling while their native windows are
occluded. Every timeout, heartbeat threshold, and functional assertion remains unchanged.
All four tests passed locally after this scheduling correction; CI remains the delivery gate.

The foreground activity alone did not resolve hosted misses (152, 140, 149, 143 pulses),
weakening the App Nap hypothesis. Heartbeat timers now request strict 50 ms delivery and
failure messages report independent timer-handler firing counts alongside main-actor pulses.
This is a controlled measurement correction; timer coalescing is not established as the cause.
All four affected tests passed locally again; no assertions or deadlines were relaxed.
