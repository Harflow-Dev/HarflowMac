# H2b2 — Continue attempt ownership

A bounded non-UI follow-up to the Continue client foundation. The shared production-composed
TaskContinuationRepository owns app-session attempts and explicit successor checks. No task-screen
caller, launch/refusal copy or composer behavior changes in this slice. H2b and M05 remain incomplete.

Requests bind selected runtime, conversation and full source identity. Exact loaded identity is
required; Continue eligibility is still decided by the engine. Per-conversation reservation plus
source-alias deduplication prevents duplicate invocations. The existing task busy guard surrounds
only the command. Immutable attempt UUIDs separate completions; runtime selection changes do not
erase earlier uncertainty. Acknowledged and uncertain source invocations remain protected in the
app session. There is no automatic launch, retry, observation loop or private engine I/O.

Invocation outcome and recorded-successor evidence remain separate. A healthy public one-hop
bridge can permit an explicitly chosen next source while preserving earlier unknown outcomes;
it never attributes a found record to this invocation or automatically selects a successor.
Accepted task ID alone does not establish a recorded bridge. Empty/failed/incomplete/readiness-
unknown observations cannot prove absence of pending launches or reopen an uncertain source.

Checks admit at most four pages/400 rows, count related headers toward that bound but use only
verified direct items for bridges, reject duplicate rows/cursor nonprogress, and check a 120-second
monotonic budget around page awaits. A dependency is not forcibly preempted by that budget.
Healthy proof is retained through failed/cancelled rechecks, capped at 400 IDs per attempt. At 256
attempt records, admission refuses instead of evicting unsafe evidence. State is not persisted;
relaunch recovery remains separate. Existing legacy action gates otherwise remain unchanged;
future UI must use owner state and fresh current-target authority together.

The earlier status-unavailable slice is independently committed as `82d2678` after all 373 focused
Swift definitions across 17 suites passed. The owner confirmed desktop availability for its final three
native suites. This new repository slice requires no native interaction; only fake public ctl
responses and deterministic parked non-UI readers are used.

Primary focused verification passed 64 discovered Swift definitions across seven affected suites:
TaskContinuationAdmissionTests (9), TaskContinuationCheckTests (9) (including parameterized readiness
cases), TaskContinuationRetentionTests (5), ModuleTests (2), TaskActionRepositoryImplTests (26),
TaskStoppingRepositoryTests (10) and QualificationBoundCommandTests (3). Implementer independently
passed the 23 new definitions. Final independent review found no actionable issue. Formatting,
strict lint, both guards and whitespace checks passed. The final app build passed.

No push/release, runtime qualification, full milestone acceptance or
visible Continue feature is claimed. This is the final implementation slice before returning to
UI testing, per owner instruction.
