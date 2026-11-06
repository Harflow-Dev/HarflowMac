# M01 — Native app host and acceptance proposals

Planning only, 2026-11-04. [M01 receipt and owner decisions](M01.md). Evidence at Mac `9175d46baf8c8507eb7cec81d21b90225103f557`. No build, product test, app launch, install or signing performed.

## M02 host and test ownership decision

**Recommend:** thin Xcode application target owns the single process entry point, packaging, identity and signing; an importable SwiftPM shell library retains the existing coordination/lifecycle implementation and guarded tests. Foundation/Core/Feature modules remain. This is a proposed ownership change, not implemented architecture.

| Choice | Assessment |
| --- | --- |
| Xcode owns all current shell sources and tests | Possible; moves119 historical shell tests outside guarded SwiftPM route; needs evidence-equivalent Xcode event/result validation, not bare xcodebuild exit |
| Xcode entry + SwiftPM shell implementation/tests | Recommended; one entry point, minimal public host surface; preserve injected lifecycle tests and module graph |
| Xcode compiles same sources as SwiftPM executable | Reject duplicate ownership/entry points and diverging product definitions |
| Xcode merely invokes existing bundle script | Does not establish requested native app-target ownership |

Current `macos/Harflow/Package.swift:7,30` defines executable + same-package HarflowTests. `macos/Harflow/AGENTS.md` documents testable executable import and shell-only ownership. `App.swift:481` initializes modules synchronously before coordinator/settings resolution; `:505` supplies Window/MenuBarExtra/Settings through feature coordinators. M02 must migrate this without dual compilation, duplicate @main or order changes.

## Invariants and M02 acceptance checklist proposal

| Area | Exact source evidence and required invariant |
| --- | --- |
| Identity | `macos/Harflow/Resources/Info.plist:13` dev.harflow.mac,0.0.9/build1; `:25` harflow URL scheme/macOS26. App and engine versions independent |
| Early packaged diagnostic | `macos/Harflow/Sources/Harflow/PackagedStartup.swift:13` sole --check-packaged-startup before app initialization; no repository/runtime/network side effect first |
| Module graph/language | macos/AGENTS.md downward dependencies, Swift6.2/macOS26; MonitorCore remains Swift5-mode; shell owns no feature rendering |
| Resources | `macos/HfCore/MonitorCore/Package.swift:13` production ManagedRuntime.json vs test ContractsV1 copied separately; `ManagedRuntimeSpecification.swift:76` Bundle.module. Preserve bundle identity/location and offline fixture self-containment |
| Build authority | `macos/build-app.sh:11` currently builds SwiftPM product/copies dependency bundles/plist/icons. Adapt one documented entry point to one Xcode build authority; avoid two packaging recipes |
| Guarded tests | `docs/development.md:29` discovered IDs, Swift Testing event streams/logical counts/no skips/XCTest silence/bounded group cleanup; serialized packages; hosted AppKit focus/toolchain rules `:37` survive |
| Shell seams | Preserve injected AppDelegate clock/scheduler/window/bundle/notifications, module startup, best-effort single-instance election, early URLs and visible-window rules; no strengthened guarantee from new host |
| CI | `.github/workflows/macos.yml:12,34` guards/tooling, pinned format/lint, bundle + packaged diagnostic, serialized guarded suites. `:15` pins SwiftFormat0.60.1/SwiftLint0.63.2; development guide's Homebrew prose is stale and should be reconciled in assigned M02 docs |
| Packaged startup | `docs/releasing.md:3` exact tag/source/app identity, source-identical MonitorCore_MonitorCore.bundle/ManagedRuntime.json and rejection of misplaced copies; absolute executable/fresh cwd/private HOME+TMPDIR/minimal env/10s timeout; no acquisition/registration |
| Release/signing | `docs/releasing.md:19` exact validated artifact, inside-out hardened signing/timestamp, reject unexpected executable code, notarize/staple/revalidate. No deep signing, JIT/library-validation exemption, quarantine removal or embedded interpreter |
| GUI isolation | `docs/development.md:23`, S02: generated fixture + production-installer-preseeded temporary HOME, verified effective preference domain/notification settings; temporary HOME alone insufficient. Separate test bundle ID without URL schemes for GUI checks |

M02 acceptance must include resource lookup in actual bundle, early diagnostic behavior, single shell entry/test ownership, preserved serialized guarded coverage, updated CI/build entry point and release inputs. It must not install or publish absent separate authorization. S06 failures are not waived for the redesigned host merely because its build succeeds.

## Intended Python0.0.8 — cheap evidence, not qualification

- Actual source ManagedRuntime.json:236 engine0.0.7; :246 CPython3.13.16. `docs/managed-runtime.md:7`: python-build-standalone20261020,29 dependencies.
- MCP `pyproject.toml:7` still0.0.7. Local `git tag --list '*0.0.8*'` returned no matches. **Publication remains unknown**; no network/release/live-runtime probe occurred.
- `docs/managed-runtime.md:3` requires immutable selected exact release, no ambient Python/uv/source adoption and no startup downloads. Local fixture qualification differs from publisher authenticity/release trust (:49).
- M03 must pin artifact URL/digest/source, interpreter/dependencies/platform, selected root, actual version-info/capability/fixture identity, package-loader behavior and exact stock harness versions. Obtain explicit alternative-runtime decision if intended0.0.8 unavailable; never silently change pin.
- S09 source0.0.7 under CPython3.11.15 synthetic injection does not qualify Mac's managed3.13.16 route,0.0.8, stock backends or any installed app.
- S06: eight packages passed; MainWindow238/241 suites, three failures (long Markdown geometry/sidebar row height/toolbar reevaluation). Bounded freeze waiver, baseline origin unknown. Build-only ad-hoc success is not UI/install/runtime/CI/distribution evidence.

## Native budgets — candidate thresholds requiring owner ratification

Electron thresholds are historical and not native-approved. The following values are proposals; none was measured in M01. Do not relax them later merely to pass.

| Metric | Candidate budget |
| --- | --- |
| Cold launch, preinstalled qualified runtime | p95≤1.5s interactive shell; populated first public page p95≤2.5s; unavailable state within declared bounded command deadline |
| Keyboard/composer/local selection response | p95≤100ms, ctl/provider latency separately reported |
| Fixed60Hz scroll/stream | p95 frame≤16.7ms,p99≤33.3ms; no app-reconciliation main-thread stall>100ms |
| Unchanged observations | Zero rendering publications/row reconstruction/measurement after initial settle; clocks scoped separately |
| Bounded history | Document and enforce page/byte/event/resident-row limits; no whole-history eager view graph; active lane leases only visible viewport; retained visited snapshots measured separately |
| Physical footprint | Candidate idle≤250MiB, representative≤500MiB; stress ceiling needs explicit ratification after bounded prototype measurement |
| Disposal/soak | Active observations/child counts return to baseline on teardown; no monotonic retained-host growth;≤10% footprint growth after warmup on repeated identical navigation cycles |
| Keyboard/VoiceOver | Every retained action reachable; correct label/value/state/decision scope; no traps; focus preserved/restored; no color-only safety information; spoken checks required, not inferred from AX tree |
| Adaptive/appearance | Light/dark/system, increased contrast, Reduce Motion, large text; proposed800/1024/1440px widths, owner-approved minimum; no inaccessible required controls |

### Measurement protocol proposal

Release build on recorded owner Apple Silicon hardware/macOS/toolchain, fixed display/refresh/power settings. Warmup then≥30 cold/100 interaction samples, p50/p95/p99 with raw traces and failure counts; provider time excluded and public handshake+ctl process latency reported separately. Record actual selected artifact/runtime/profile, no synthetic-to-real promotion.

Reuse accepted dataset shapes: CI300tasks/30k events/5workflows; representative5k/500k/50workflows/500runs; stress50k/5m/20fake owners. Add deterministic native10k-event transcripts, long Markdown/tool calls, bounded diff/artifact sets, parallel visible lanes and workflow graphs. Measure frame intervals/main-thread signposts/CPU/physical footprint and RSS/view+host counts/active observations. Separate initial paint, older paging, live append, manual scroll anchoring, lane switches, stale response and navigation disposal. Run a two-minute synthetic soak plus an explicitly assigned longer repeated workload before memory acceptance; neither alone proves unbounded lifetime safety.

Verify light/dark/system and adaptive states in actual native pixels; keyboard/focus/VoiceOver/Reduce Motion/increased contrast/large text/narrow windows require rendered-flow evidence. Exact-action approval summaries and unknown/refusal/capture states are assertions, not cosmetic snapshots. Native builds, fixture tests, packaged startup, backend qualification and signed distribution remain separate result classes.

Current `docs/monitor-performance.md:3` says profiler refuses before launch/output pending runtime integration; do not present it as a working production measurement path. `:39` denies a full memory ceiling; `:44` documents an opt-in two-minute synthetic3000-row soak only. Assign instrumentation changes separately if needed; M01 does not implement them.
