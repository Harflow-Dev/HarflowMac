# PbTerminal

Everything the Monitor app needs to run an embedded terminal, moved out of the app target — see
`../../CLAUDE.md` (the root architecture rulebook) and
`../../.claude/plans/2026-09-25-monitor-architecture-plan-settled.md` (Phase 3, decision 5) for the
full context this package implements.

## What is here

| Type | Owns |
|---|---|
| `TerminalSession` | One embedded terminal — a SwiftTerm `LocalProcessTerminalView` the app started, either a take-over of a task's session or a brand-new interactive one. Lives as long as the session, so switching tabs never restarts it (`AppModel.swift:6-8` in the pre-refactor code, now here). |
| `TerminalHost` | `NSViewRepresentable` reparenting a session's `NSView` and making it first responder. |
| `TerminalSessionRegistry` | Every session the app has started, published; `session(forTask:)`, `interactiveSessions`, `add`/`remove`, and an ended-session event stream so a coordinator can apply "remove an ended interactive session unless selected" — the registry itself never reads the selection. |
| `TakeoverService` | The whole take-over flow, app-scoped so it outlives the view that started it: `ctl takeover` grant → wrapper argv → embedded session or Terminal.app hand-off → `takeover-attach` → on refusal, terminate and write the outcome. Reads/writes busy and the outcome line only through `PbRepository.TaskActionRepository` (decision 4); `takeover`/`takeoverAttach` themselves are raw passthroughs (F3's dependency-direction fix — this package depends on `PbRepository`, never the reverse). |
| `DummyTerminalHost` (`#if DEBUG`) | A placeholder view for previews/tests that never constructs or starts a real `LocalProcessTerminalView`. |

This is the **only** package that imports SwiftTerm — see `AGENTS.md` for why, and for the Swift 5
language-mode exception it shares with `MonitorCore`.

## Build and test

```bash
cd macos/PbCore/PbTerminal
swift build
swift test
```

`Module: PbModule` registers `TerminalSessionRegistry` and `TakeoverService` into `GlobalValues`.
It must run **after** `PbRepository.Module` (decision 13: lowest layer first) — it reads the
repositories it needs back out of `GlobalValues` rather than taking them as constructor parameters,
since it has no reference to the concrete instances `PbRepository.Module` built.
