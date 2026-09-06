# Session identity and recovery

Investigated against Conduit `2605ee95b907de067e05d0c914a865fab03a05ff` and the reporter's Hermes `9dd6634c5635321cf38840cc30e9b51226689128`.

## Problem and evidence

Issue #134 describes a quick second send after a completed reply leaving a canonical Bot Mode conversation. Local ordering debt causes a persisted-tail read, which can escalate to preserve-current synchronization. That synchronization replaces the catalog before resolving the selected runtime ID. The resolver falls back to an unrelated chat when the runtime alias is absent, and the caller creates a new session when no target exists. Only running turns retain a catalog row; the reported race is after settlement.

Resume also discards `stored_session_id` / `session_key` supplied by Hermes, then admits the returned runtime ID into presentation identity. Scroll identity, catalog matching, composer ownership and persistence each infer equivalence separately. Exact composer-ID checks can reject a submission after a legitimate runtime rebind.

## Design

Introduce a small conversation identity value carrying profile, durable conversation ID and accepted routing IDs. Capture it before a recovery catalog fetch. Preserve-current recovery must use that identity even when the refreshed catalog omits the conversation; catalog absence is not navigation authority. Automatic latest/initial selection retains its existing policy.

Parse the durable resume identity separately from the runtime routing ID. Validate explicit durable identity and known conflicting catalog ownership before adopting resume state. Legacy gateways without a durable field retain compatibility with a request-scoped runtime rebind. Preserve the identity across catalog churn and project it into existing scroll/persistence consumers; do not replace the viewport controller or turn-state machine.

Composer work can rebind to the current runtime only while its profile, client, client epoch and explicit viewport generation still match. A switch away and back is a handoff, not a runtime rebind. A failed identity check leaves the selected transcript and draft available and blocks sending until recovery succeeds.

## Invariants

- Recovery cannot select another conversation or create one when a current identity exists.
- Durable conversation identity and runtime routing identity have separate meanings.
- A contradictory explicit resume identity is rejected before transcript, cache or active identity adoption.
- Catalog omission cannot erase an established identity binding.
- Session/profile/client/viewport handoffs invalidate suspended work.
- Existing automatic latest selection, explicit new/open/branch operations, busy input policies and transcript ordering checks remain supported.

## Alternatives

A resolver-only fallback fix is smaller but leaves routing identity loss and composer cancellation unresolved. A full AppState state-machine rewrite would greatly expand the regression surface. The selected consolidation confines changes to identity capture, resume admission and submission rebinding.

## Validation and limits

Run regression tests before implementation using the documented ios_test command-line driver in an isolated Mac source directory. Cover missing/empty catalog, stale runtime aliases, the second-send debt path, explicit runtime rebinding and rejection, and existing handoff races. Run unit/UI coverage and CI inventory/planner checks. The reporter's live Feishu/Caddy/Tailscale deployment is unavailable, so deterministic lifecycle reproduction is distinct from reproducing that environment.

No commits, pushes, PR creation or release steps are authorized by this task's repository instructions.
