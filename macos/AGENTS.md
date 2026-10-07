# Polybridge Monitor — architecture rules

This is the shared rulebook for every package under `macos/` (`PbCore/*`, `PbFoundation/*`,
`PbFeatures/*`, and the root `PolybridgeMonitor` app). Per-module `AGENTS.md` files point back here
rather than repeating it.

## The chain

`Coordinator → NavigationView → View → VM → UseCase → ViewRepository`

1. VM protocols are `@MainActor` and extend `ViewModel` (PbCommon). Views are generic over their VM
   protocol and hold `@State var viewModel: VM`, set with `State(initialValue:)` in `init`. They
   read `@Environment(\.viewEvent)` and forward with `.publishViewEvent(from:to:)`. Navigation views
   are generic over a coordinator *protocol*, never a concrete coordinator.
2. VMs are internal `@Observable @MainActor final class` types. Stored protocol dependencies are
   `@ObservationIgnored`.
3. `UseCase` and `Routing` protocols are declared in the VM's own file and marked `@Mockable`. The
   coordinator conforms to every `Routing` it needs.
4. Dependencies are protocols, with no concrete default parameters.
5. Coordinators own navigation and build views. `handle(path:)` handles its own destinations,
   delegates to a child coordinator, or bubbles to the parent. `start(with:)` is only for mounting a
   subtree.
6. `@GlobalEnvironment(\.x)` values are registered in each module's `Module: PbModule`.
   `@GlobalEntry` defaults must **not** call a `@MainActor` initialiser — the default has to resolve
   before any module has registered a real value.
7. Subscriptions are set up in `didAppear()` behind a `didSubscribe` guard, and pipelines end in
   `weakAssign(to:on:)`. **Teardown rule** (an extension of these rules, since leases and polls
   must stop when a view goes away): any VM holding a lease, poll or timer exposes an idempotent `didDisappear()` that releases
   or cancels them and resets `didSubscribe = false`, so a view that reappears (e.g. the menu-bar
   popover) subscribes again. Nothing is acquired in `init`.
8. Every screen and component gets a `#Preview` inside `#if DEBUG`, driven by a `PreviewMock` VM or
   a dummy Model.
9. Tests use Swift Testing, mirror the source paths, and are named `givenX_whenY_thenZ` with
   `// given / when / then` sections. They use generated `Mock*` types and wait with polling
   (`waitUntil` from `PbTestUtilities`) — never a fixed `sleep`.
10. Public declarations get `///` docs, and files use `// MARK: - TypeName`.

## Component Models (decision 9)

Component Models sit at meaningful presentation boundaries; trivial components may take plain
values, and components may hold local `@State`. Mapping from domain types to component Models
happens in the VM — UseCases never return component models. UI helpers that used to live in views (`EnforcementText`, `Format`,
`StatusColor`/`BackendStyle`, the limited `MarkdownText` parser) are tested helpers in PbUI, not
view-local functions.

## ViewEvent (decision 10)

Presentation events include `alert`, `dialog`, `incident(source:message:)`, `incidentResolved(source:)`, and `none`.
Actionable workflow read failures use source-scoped incidents rendered as a dismissible top overlay
by the window presentation context. Preparation is neutral state, never an incident. Dismissal leaves
failure details accessible; a successful read resolves only its own source. Outcome lines (refusal
text, "queued", cascade summaries) remain durable VM/repository state.

## Repository concurrency (decision 12)

Repositories are `nonisolated` and `Sendable`. They keep async state in private actors and publish
synchronous snapshots with `@Subjected`. VMs are `@MainActor`. Ordering guarantees are part of the
contract (busy check-and-insert is atomic, events apply in arrival order, routing to a new task
waits until the refreshed listing has reached the main queue).

## Scope exceptions (decision 14)

No logging protocol and no localization: the Monitor has neither today, and adding either would be
a behaviour change. These are intentional deviations, not oversights.

## Language modes

Every package targets tools 6.2 / macOS 14. Every package **except** `MonitorCore` builds in Swift 6
mode, including the root `PolybridgeMonitor` package since Phase 5. **`MonitorCore` uses
`swiftLanguageModes: [.v5]`** — its tailing/process-table internals do not compile under Swift 6's
strict concurrency checking, and moving it is separate work, not part of this refactor. The root
package held `.v5` transitionally through Phase 4 for a different reason (it held the embedded
terminal's `TerminalSession`/`TerminalHost` directly, before Phase 3B moved them into the now-deleted
`PbTerminal` package, itself removed once the Monitor's take-over flow moved to Terminal.app only);
once Phase 5's app shell (`App.swift`/`AppDelegate`/`AppCoordinator`/`AppModulesRegistry`) was the
only code left in it, it built cleanly in Swift 6 mode with no source changes beyond the two isolation
fixes any new Swift 6 code needs anywhere in this app: an `@MainActor`-isolated conformance clause
(`@MainActor UNUserNotificationCenterDelegate`) for a delegate protocol whose requirements can be
invoked off the main thread, and a `Task { @MainActor in }` hop instead of capturing `self` across an
escaping closure boundary — see `App.swift`'s own header comments for exactly where and why.

## Package graph

`MonitorCore` is the bottom layer (dependency-free values and I/O) — any package may import it.
Above it, dependencies point only downward: Foundation (`PbUtilities`/`PbCommon`/`PbUI`) ← Core
(`MonitorCore`/`PbRepository`) ← Features (`PbFeatures/*`) ← app (`PolybridgeMonitor`). Every target
declares every product it imports — no `@_exported` re-exports, ever.

## Before finishing a change

1. `swiftformat macos && swiftlint lint` from the repo root must report nothing to format and 0
   violations. `.swiftlint-baseline.json` holds MonitorCore's pre-existing source violations only;
   `macos/PbCore/MonitorCore/Sources` stays byte-identical, so never edit it for a lint rule. To
   regenerate the baseline, run `swiftlint lint --write-baseline` with a config that includes only
   that folder, then make each `file` entry repo-relative so it matches on any checkout.
2. `scripts/check-private-refs.sh` must pass.
3. The per-package `swift test` loop and `macos/build-app.sh` must pass.
4. The headless smoke (launch the built binary with a temporary `HOME` and a fake `polybridge-ctl`,
   check the first `list`, an FSEvents-driven second `list`, and that the app stays alive) is a
   local gate only: it depends on FSEvents timing and a window server, which shared CI runners do not
   provide reliably.
