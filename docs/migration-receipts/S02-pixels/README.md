# S02 hosted fixture pixels

These are unmodified production-view renders from synthetic, isolated test models.
They are not screenshots of the ordinary application against the qualified engine.
[manifest.json](manifest.json) records exact PNG hashes and scope. Primary and
visual-specialist inspection found no visible credentials or personal paths; that
was a visual check, not a forensic metadata audit.

| Image | Observed state and limits |
| --- | --- |
| [Task header](task-header-light.png) | Synthetic continuity/notices and activity controls; no live task or binding proof |
| [Activity composer](activity-composer-light.png) | Native activity/composer at a narrow viewport; no keyboard-operation claim |
| [Checking workflow](workflow-checking-light.png) | Earlier pending-state render, actual 1000×620 pt; canvas/tray separated by 4 pt |
| [Validated workflow light](workflow-validated-light.png) | Rendered success hint, actual 1000×652 pt; history-scan fixture incident visible |
| [Validated workflow dark](workflow-validated-dark.png) | Same height and incident; dark palette contrast is a capture concern |
| [Blocked approval](approval-blocked.png) | Synthetic unsupported caller-owned request; complete command access, response delivery and execution are not established by this still |
| [New session](new-session-light.png) | Synthetic ready qualification; fixed-footer/scroll reachability remains unverified |
| [Settings ready](settings-ready.png) | Synthetic Harnesses state; transparent composition and blank top element remain unverified |
| [Settings failed](settings-failed.png) | Synthetic failed qualification, not an observed real harness failure |
| [Settings unsupported](settings-unsupported.png) | Synthetic unsupported-engine state, not the selected runtime's capability claim |

Validated workflow heights grew 32 pt from their requested dimensions. Their
visible canvas/tray separation is not proof about a constrained 620-point view.
Every validated image includes the `StartScreenHistoryScanner.ScanError` incident;
these are not healthy-screen reference approvals. The earlier AX maximum 95.5
failure was not reproduced and its cause remains unproven.

Static pixels do not establish scrolling, keyboard focus order, VoiceOver semantics,
Settings General, notifications or normal window material composition. Existing
native test results are separate evidence. Ordinary-app smoke and live selected
runtime binding remain blocked on verified preference isolation or owner approval
for the unique test preference domain.
