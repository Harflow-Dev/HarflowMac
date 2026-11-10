# H2b1 — Continue client foundation

This bounded follow-up adds the base Continue client, with no task-screen callers or visible
controls. H2b and M05 remain incomplete. The selected runtime and vendored bundle remain 0.0.12;
no engine code, fixture bundle, installation, release or exact-runtime qualification changes.

The client uses existing phase-aware exchange and ConversationLaunchOutcome types. Both
`task-continue.v1` and `task-successors.v1` must occur in the same fresh selected-runtime handshake.
Only the base command is offered; source prefix resolution and eligibility stay with the engine.
Acceptance may be pending resources. Structured errors retain code/message/data, and display text
is not parsed. Unknown outcomes and ambiguous post-dispatch failures never trigger automatic replay.
A later refusal or empty recorded-successor read cannot clear an earlier uncertain invocation.

Shared launch/mutation envelope validation rejects result/error/unknown collisions; exit-3
remapping must not turn a contradictory payload into a canonical unknown response. Existing
conversation launch/mutation behavior is covered by affected regression suites.

Future UI design decisions remain open at HarflowDesign `17739e4`,
`v2/scripts/m05-proposal.js`: “New session started” overstates accepted pending launches, and
generic “Nothing started” overstates a refusal after a prior unknown launch. This stage does not
change that design or implement its copy. Successor reconciliation, per-conversation launch state,
composer locking, pending selection and launch controls require separate work.

Primary focused verification passed 169 discovered Swift test definitions across seven affected
suites: ContinueClientTests15, ConversationLaunchTests43, ConversationDeliveryOutcomeTests39,
ConversationDeliveryTransportTests25, ConversationDeliveryRetryTests15,
ConversationDeliveryReceiptIdentityTests13 and ConversationDeliveryFixtureTests19. Parameterized
cases run inside those definitions. The implementer independently passed the new15 definitions.
Final independent review found no actionable issue. Formatting, strict lint, both guards and
whitespace checks passed. The final app build passed.

Only fixtures/fake runners were used; no live task was continued. No full package/milestone gate,
engine qualification, publication or visible Continue feature is claimed. The unrelated H2s
working-tree stage remains separate, awaiting three native regressions on an unlocked desktop.
