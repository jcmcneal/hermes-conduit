# Persistent bot messaging alongside Hermes sessions

Status: Detailed implementation proposal; no application, plugin, server configuration, or deployment changes are authorized by this document.

Prepared: 2026-09-08.

## 1. Outcome and accepted product decisions

Conduit supports two independent conversation paths in one app:

- **Sessions:** the current profile → session sheet → existing/new chat flow, using Hermes session creation, resumption, and prompt submission.
- **Messages:** persistent bot DMs and group conversations, backed by a Hermes messaging service that uses bot-coms for delivery and wakeups.

A user can message one bot without naming or creating a channel. Selecting a bot opens its DM; the first send creates the durable conversation if necessary. Groups use the same messaging infrastructure with multiple participants. “Channel” is an optional future product concept, not a prerequisite or a V1 label.

Messaging is optional and gated by the connected Hermes instance. Without it, existing sessions continue to work. A dismissible, polished feature card explains the benefit and offers setup. Use “Enable messaging” and “Install on Hermes,” not paid-upgrade language unless an actual commercial tier is introduced.

When messaging is ready, the main inbox shows bot DMs, groups, and existing sessions. The bot rail opens DMs; session access remains explicit and easy to reach. Installing messaging never converts, renames, merges, or deletes existing sessions.

## 2. Evidence and implementation baseline

Inspected local sources:

- `Conduit/Views/InboxView.swift`: the current working tree renders `ProfileShelf` on Chats. Profile selection opens `ProfileSessionsSheet`; switching profiles uses the existing application profile-switch path. Sheet dismissal precedes session navigation to avoid pushing during dismissal.
- `Conduit/Services/AppShellState.swift`: owns Inbox/Conversation presentation and generation-fenced open requests; does not own session runtime identity.
- `Conduit/Services/HermesClient.swift`: `createSession` calls `session.create` with profile scope; `sendPrompt` calls `prompt.submit`. Submission acknowledgments distinguish streaming, steering, redirection, and queueing. Lost acknowledgments require reconciliation rather than blind retry.
- `Conduit/Services/KanbanService.swift`: provides a precedent for typed plugin HTTP access through `DashboardJSONRequester` / `DashboardTicketBridge`, independent of the selected chat profile.
- `Conduit/Views/SidebarTab.swift`: persisted Sessions/Cron/Kanban values are compatibility-sensitive.
- `docs/superpowers/specs/2026-09-06-session-identity-design.md`: session identity includes profile ownership, durable stored identity, and runtime aliases. Preserve those admission rules.
- `/Users/jason/projects/bot-coms/README.md`: core bot-coms is local POSIX spool messaging, with at-least-once delivery and idempotency support. The sibling board package owns assignments, workflow gates, and recovery.
- `/Users/jason/projects/bot-coms/src/bot_coms/doorbell.py`: current default wake creates fresh Hermes sessions and explicitly avoids arbitrary previous-session continuation.
- `/Users/jason/projects/bot-coms/src/bot_coms/wake_worker.py`: durable wake queries drain serially per peer; failures leave pending work recoverable.
- `/Users/jason/projects/bot-coms/docs/NON_GOALS.md`: core does not provide HTTP transport, GUI, global ordering, or multi-host clustering.

The inbox redesign is present as uncommitted work at planning time. Its earlier plan is not an exact description of the current shelf implementation. Re-read current code before implementation; do not overwrite unrelated changes or restart that redesign.

All API names, payloads, types, migrations, and new file names below are **proposals**, not claims about available Hermes features. This plan does not verify a deployed instance, installed plugin versions, or current admin installation support.

## 3. Scope

### Required for the initial public release

1. Capability discovery and explicit unavailable/error states.
2. Feature discovery, setup status, and a manual installation fallback.
3. Persistent one-bot DMs and multi-profile groups.
4. Combined inbox with All / Messages / Sessions filters.
5. Explicit mention routing and one default responder per group.
6. Durable message history, idempotent sends, ordered events, and reconnection recovery.
7. Fresh Hermes runs supplied with bounded conversation context.
8. Participant attribution, queued/running/needs-attention state, and final replies.
9. Server-owned read state and messaging notification navigation where supported.
10. Existing session behavior preserved and regression-tested.

Admin one-tap installation is conditional on a supported server management API. The release must provide an honest fallback rather than invent installation support.

### Deferred

- Nested thread UI, named channels, multiple human group members, public groups, and external guests.
- Automatically making every bot respond to every message.
- Multiple independent concurrent runs for the same peer; retain current serialization initially.
- Editing/deleting sent messages, branching messaging conversations, or importing session transcripts into DMs.
- Cross-host bot-coms delivery, running the spool on the phone, and always-running mobile connections.
- Voice, attachments, reactions, and arbitrary tool interactions in Messages unless explicitly implemented end to end. Existing Sessions retain their capabilities.
- Bringing the full board assignment/review workflow into every casual DM.
- Billing, subscriptions, and paid entitlement checks.

## 4. Main screen and navigation

### 4.1 Messaging unavailable and never enabled

Preserve the current profile shelf and session sheet flow. Keep the existing new-session action, search, Scheduled, Boards, Projects, profile management, and settings.

Add one dismissible card in the main Chats area:

> Give your bots a shared inbox
> Keep ongoing DMs and bring multiple bots into group conversations.
> Enable messaging

Use the app's character artwork and restrained accent treatment. Do not add locks to existing features, fabricated prices, “Pro” badges, trial countdowns, or blocked Messages tabs. Dismissal is persisted per server/account and card revision; it does not reset on every launch. Settings → Messaging remains available after dismissal.

### 4.2 Messaging ready

Adapt the shelf to a compact horizontal profile rail above the conversation list. This frees the main screen for the combined inbox without changing the familiar profile identity treatment.

Layout:

```text
Inbox                                       +
[PM]          [SWE]          [Designer]
All             Messages             Sessions

Designer                                  2m
Here's the revised session picker…          •

Conduit development                      12m
[PM · SWE · Designer] SWE is working…

Fix notification routing                  1h
Session · SWE

PM                                 Yesterday
The release checklist is ready.
```

Row rules:

- DM: profile avatar, profile display name, latest visible message preview, activity time, unread marker.
- Group: up to three participant avatars plus a count, group name, attributed preview or confirmed run status, activity time, unread marker.
- Session: existing session title and avatar with `Session · <profile>` subtitle. Preserve session pin/archive/delete semantics.
- Use backend activity timestamps; loading, polling, opening, and delivery acknowledgments do not bump activity.
- Do not infer running from session selection or apply the open session's turn state to other rows.
- Show unread only where server data supports it. Never fabricate unread for legacy session rows.
- Long text truncates accessibly; accessibility labels include row kind, participant, activity, and unread state.

All combines authorized messaging conversations across profiles with sessions for the currently selected session workspace. Until a cross-profile session index exists, show an explicit `Sessions: <profile>` scope chip. Messages is account-wide within this Hermes instance; Sessions retains the existing profile scope and tools. Do not present All as an exhaustive cross-profile session history.

For mixed sorting, add/verify a raw server timestamp for session summaries. If legacy session data provides only display labels, render separate Messages and Sessions sections within All instead of guessing chronological order. Stable tie-break by kind and durable ID. Keep pin ordering deterministic; absent comparable server pin metadata, pin sections remain kind-specific.

### 4.3 Profile rail behavior

- Ready, eligible profile: open its existing DM or an unsaved empty DM destination. Do not create a session or conversation merely by tapping.
- Profile not configured for messaging: open a profile action sheet with Sessions and an admin-visible Set up messaging action; explain that the bot is not ready. Never silently reroute a message to another bot.
- Messaging unavailable: preserve today's profile-switch → session-sheet behavior.
- Ready-mode DM selection does not change `AppState.activeProfile`; that variable remains the session workspace. Highlight the DM participant separately from workspace selection.
- Provide a visible Sessions action in the DM header. It switches the session workspace through the existing guarded path, then opens that profile's session sheet.
- Group headers offer Members and Runs. Access to Sessions is through a selected member's actions or the main Sessions filter, since a group has no single owning profile.
- Profile context menus may offer Message and Sessions, but neither essential path relies on a long press.

### 4.4 Plus, search, and destinations

When ready, Plus offers Message a bot, New group, and New session. New session uses an explicit profile choice or clearly labels the current workspace. When unavailable, retain the current direct new-session action.

Search follows the selected inbox filter. V1 Messages search matches names and server-provided previews; do not imply full-history search. All search shows scoped results with the same session-scope chip.

Scheduled, Boards, Projects, settings, and existing deep links remain reachable. Preserve `SidebarTab` persisted raw values; inbox filters are a new preference, scoped by server/account. Do not overload the session source filter.

### 4.5 First-use, restoration, and capability transitions

After successful setup, show “Messaging is ready” and an explicit Start a DM action. Do not open a bot conversation automatically, create empty DMs for every profile, or move the user away from an active session.

Only switch rail behavior after authoritative ready state, with the first-use explanation visible. Apply layout changes at the inbox, not by replacing an open session screen.

Persist a typed return destination: session identity versus messaging conversation ID. Migrate existing return preferences without rewriting session resume identity. A missing/forbidden/archived messaging destination returns to the inbox with an explanation; it never opens a similarly named conversation.

On iPad, use the same typed selection in the persistent detail pane. Compact transitions must dismiss sheets before navigation and reject superseded opens.

## 5. DM and group experience

### 5.1 DM lifecycle

A DM is unique per server installation, authenticated principal, and immutable profile ID. The server enforces uniqueness transactionally. Profile display-name changes preserve identity; deleting and recreating a profile with the same name does not inherit an old DM.

If Hermes does not expose immutable profile identities, add an installation-scoped profile identity registry before implementing this guarantee; do not use mutable display names as durable keys.

Opening a DM fetches its existing identity/history or presents an unsaved draft. First send atomically creates/resolves the DM and records the message. Concurrent first sends from two devices resolve to one DM. Two intentional messages remain two messages; retrying the same client message ID does not duplicate either.

An archived DM remains the same identity. Selecting its bot shows the archived conversation with an explicit Reopen action; reopening preserves history. Archive affects the user's inbox, not membership or in-flight work. V1 archive does not cancel runs; explain this in the archive action when work is active. Cancellation is separate.

### 5.2 Group creation and membership

New group asks for a name, at least two eligible bot profiles, and a default responder. One-bot selection offers Start DM. “Multiple human members” is not implied: V1 groups contain the signed-in user and selected bots.

Creation snapshots participant IDs and returns a durable ID. Edits use an expected membership revision to prevent stale overwrites. Authorized users can rename, add/remove profiles, and change default responder. Removing the default responder requires selecting a replacement in the same mutation.

Adding a bot explicitly grants it access to the group's prior shared history; show this in the member-add sheet. Removal stops future routing and queued unstarted work for that member. Already-running work receives cancellation and loses permission to publish new content after removal; preserve earlier messages with historical attribution. Recheck authorization at execution and publication, not just initial send.

### 5.3 Addressing and response rules

- DM messages target the single profile automatically.
- Unaddressed group messages target the current default responder.
- Structured mention chips target the explicitly selected profiles. Multiple explicit recipients are supported, with one dispatch per unique recipient.
- Store recipients as profile IDs; visible `@names` are presentation, not the authority for routing.
- Capture membership revision and recipient set on acceptance. Membership changes do not silently retarget accepted messages.
- Quoted text, code blocks, and bot replies containing `@names` do not trigger routing.
- Bot replies do not automatically wake every group member. Delegation is an explicit tool operation carrying causation IDs and server limits.
- A user message submitted while its recipient is busy is queued in V1; do not implicitly steer a different live run.

### 5.4 Conversation screen

Reuse visual primitives for avatars, Markdown, code, links, tool disclosure, and decision cards where they accept explicit data/context. Keep a separate MessagingConversationView and state owner; do not put group history into the active session transcript.

Every bot output identifies its author. Show pending local sends, accepted messages, queued recipient runs, active work, waiting-for-approval, failure, and cancellation accurately. A delivery acknowledgment is not a bot answer or successful task completion.

Text-only composition is sufficient for V1. Hide unsupported attachment/voice actions in Messages and keep them available in Sessions. Preserve draft and scroll state per server/account/conversation (or unsaved DM profile key). Capability loss and recoverable send errors preserve draft text.

Nested threads are deferred, but each run/reply carries a triggering message ID. Interleaved group replies display “Replying to…” where needed. A Runs sheet shows per-recipient execution and links to a supported session inspection route only when a verified mapping exists.

Approval cards require explicit run/profile/decision identity and server-authorized actions. If the integration cannot securely return a decision to the originating run, expose a supported Open in Hermes destination and a Needs attention state; do not render nonfunctional approval buttons.

## 6. Capability and setup state machine

### 6.1 Proposed discovery contract

Use an authenticated core Hermes capability endpoint that remains available when the plugin is absent. Adapt to an existing audited endpoint if one exists; otherwise core Hermes work is required. A plugin endpoint alone cannot reliably distinguish absent, disabled, unauthorized, and unsupported.

Proposed payload:

```json
{
  "server_id": "installation-id",
  "messaging": {
    "provider": "bot-coms",
    "state": "ready",
    "api_version": 1,
    "plugin_version": "server-reported-version",
    "features": ["dm", "groups", "events", "read_state"],
    "can_manage": false,
    "setup_actions": [],
    "eligible_profiles": ["immutable-profile-id"],
    "revision": "opaque-capability-revision"
  }
}
```

A ready state means compatible endpoints, enabled plugin, configured storage, and functional routing/wake prerequisites—not merely an installed Python package. Readiness can be partial per profile; one eligible profile is sufficient for DMs, two for groups.

Client states: unknown/loading, unsupported server, missing, disabled, needs update, needs configuration, setting up, ready, temporarily unavailable, forbidden. Server setup states and client network states remain distinct.

- Missing/disabled/configuration: show the matching setup action.
- Unsupported legacy server: preserve sessions; sheet explains the required server update/manual path.
- 401: request reauthentication through the normal flow.
- 403: explain permissions; never interpret as missing plugin.
- Timeout/5xx: mark unavailable; never offer reinstall as the automatic fix.
- Unknown incompatible API version: disable messaging mutations and show update guidance.
- Profile-specific failure: disable that participant; do not disable unrelated healthy DMs.

Cache last-known capability per server/account for presentation only. Never let stale ready state authorize a write. Refresh after login, foreground, reconnect, setup completion, and an explicit Retry. Bound refresh frequency and reject results from old connection generations.

### 6.2 Feature sheet

Title: “A shared inbox for your bots.” Benefits: ongoing DMs, group collaboration, work that can continue while the app is closed. Qualify background operation on the server's configured worker/recovery support; installation alone must not promise uninterrupted execution.

Show the connected server name, readiness result, required action, and exact operation scope. For an authorized admin, the primary action is Install on Hermes / Enable messaging / Update messaging / Finish setup. For non-admins, show instructions to share with the administrator; never send them automatically.

The user must see that installation modifies the server, which package/dependencies will be installed, and whether a restart is required before invoking the action. The explicit installation tap authorizes the displayed operation; no repeated confirmation screens for unchanged scope.

### 6.3 Managed setup

1. Read server capability and management permissions.
2. Obtain a server-generated setup plan with trusted package identity, target version, dependencies, configuration changes, restart requirement, and revision/hash.
3. Present that concrete plan in the feature sheet.
4. On Install/Enable, submit its ID and an idempotency key.
5. Server validates permission and unchanged plan, executes an allowlisted setup operation, and returns a durable job ID.
6. Observe job stages: queued, installing, configuring, awaiting restart, verifying, complete, failed.
7. Persist job association; app closure/relaunch resumes status observation without reinstalling.
8. Re-fetch capability after completion; unlock only when ready.

Never accept a client-provided arbitrary shell command, package URL, or untrusted repository as the installer input. Server must own package provenance and supported versions. A stale setup plan requires refreshing the displayed changes, not silently widening authorization.

A restart that could interrupt active work must be deferred or explicitly included in the user's chosen action with the affected work visible. Do not silently restart the gateway during a live session. Failure does not auto-uninstall dependencies or erase existing messaging data; report partial state and retry only remaining safe steps.

### 6.4 Manual fallback

If managed setup is unavailable, display version-matched instructions from the plugin/server's trusted installation documentation. Verify exact commands during implementation; this plan does not freeze an unverified command sequence. Provide Copy instructions and Check again. Do not execute shell commands on the phone or launch an agent to install the plugin silently.

## 7. Backend architecture

```text
Conduit
  ├─ Existing Hermes session APIs → existing sessions
  └─ Authenticated Messaging API
       ├─ conversation/message/read-state database
       ├─ transactional dispatch outbox
       ├─ bot-coms transport → peer wake adapter → Hermes run
       ├─ run/output adapter → authorized shared replies
       └─ ordered events → live updates + notification adapter
```

Keep bot-coms core reusable. Put product-specific conversation semantics in a messaging adapter/service with its own storage boundaries. The board package remains optional for assignments and review workflows; ordinary messages must not require a slice registration or acceptance gate.

The existing generic wake prompt mentions `team_inbox`/board handling. A dedicated messaging envelope type and wake handler must load a conversation message and context directly; do not route casual DMs through that board-specific prompt unmodified.

Hermes/backend integration must expose a supported run launch/output lifecycle. CLI wake currently establishes a fresh session but does not by itself provide a reliable mapping into Conduit's live transcript or approval actions. Implement and verify this bridge explicitly.

The app never reads spool files or SQLite databases directly and never owns worker liveness. Server recovery continues after the phone closes.

## 8. Data model and identity

Use migration-managed durable storage. Minimum logical entities:

| Entity | Required fields / invariants |
|---|---|
| Conversation | ID, kind dm/group, principal owner, title, default responder, created/activity times, membership revision, record revision |
| Participant | Conversation ID, immutable profile ID, role, joined/left sequence; authorization is checked against current membership |
| Message | ID, conversation ID, authoritative sequence, actor kind/ID, body, client message ID, reply-to ID, created time, visibility |
| Dispatch | ID, accepted message ID, recipient profile ID, membership revision, idempotency key, state, retry metadata |
| Run | ID, dispatch ID, attempt, profile ID, status, timestamps, verified Hermes session reference when available |
| Run output | Stable output ID, run ID, message association, delta revision/finalization state |
| Read state | Principal + conversation, monotonic last-read sequence |
| User conversation state | Principal + conversation, archived, pinned, muted, optional pin order |
| Outbox | Durable delivery/publication operation, causation ID, attempts, next retry, terminal failure |
| Event | Stable event ID, scoped cursor, entity ID/revision, type, timestamp |
| Setup job | Plan ID, authorized actor, idempotency key, stages, result; managed by server administration |

Unique constraints: one DM per owner/profile; one accepted message per owner/conversation/client-message-ID; one initial dispatch per message/recipient; one output publication per stable run output ID. A retry attempt is linked to the existing dispatch rather than manufacturing a second user message.

Use server installation ID + authenticated principal to scope client caches. Connection URL alone is insufficient if a server is replaced behind the same hostname. Runtime session IDs are execution references, never messaging conversation identities.

Represent root conversation/thread identity explicitly in envelope metadata without repurposing profile IDs or spool peer IDs. V1 may use one root thread per conversation, but multiple future threads must not require rebuilding message identity.

## 9. Proposed Messaging API

Namespace below is illustrative: `/api/plugins/bot-coms/messaging/v1`. Select the final namespace with backend maintainers after auditing extension points.

| Operation | Proposed endpoint | Behavior |
|---|---|---|
| List conversations | GET `/conversations?cursor=...&limit=...` | Authorized summaries, raw timestamps, read state, status, next cursor |
| Resolve existing DM | GET `/dms/{profile_id}` | Read-only; returns existing ID or absent; does not create |
| First DM send | POST `/dms/{profile_id}/messages` | Atomically ensure DM + accept first message |
| Create group | POST `/conversations` | Kind/group, name, members, responder; idempotent |
| Read detail | GET `/conversations/{id}` | Membership, revision, user state, supported actions |
| Read history | GET `/conversations/{id}/messages?before=...` | Stable sequence pagination and snapshot high-water mark |
| Send message | POST `/conversations/{id}/messages` | Client ID, body, recipient IDs, expected membership revision |
| Reconcile send | GET `/conversations/{id}/messages/by-client-id/{id}` | Resolve ambiguous acknowledgment without duplicate send |
| Reconcile first send | GET `/dms/{profile_id}/messages/by-client-id/{id}` | Works before client knows the new conversation ID |
| Update group | PATCH `/conversations/{id}` | Revision-checked rename/membership/responder mutation |
| Update inbox state | PATCH `/conversations/{id}/user-state` | Archive/pin/mute for authenticated user |
| Mark read | PUT `/conversations/{id}/read-state` | Monotonic sequence advancement |
| Observe events | GET `/events?after=...` | Authenticated replayable stream or equivalent supported subscription |
| Read runs | GET `/conversations/{id}/runs` | Per-recipient status and permitted actions |
| Cancel run | POST `/runs/{id}/cancel` | Idempotent request; cancellation result is authoritative |
| Retry run | POST `/runs/{id}/retry` | Explicit new attempt, authorized and deduplicated |

Responses return canonical entities and revisions, not only `ok`. Send acceptance returns message ID, conversation ID, authoritative sequence, dispatches, and current status. An accepted response means durable recording; it does not promise execution or completion.

Typed errors distinguish forbidden, profile unavailable, stale membership, archived/reopen required, incompatible API, rate/budget limit, unknown send outcome, and temporary backend failure. Apply bounded page/body sizes. Cursor expiry triggers snapshot reconciliation rather than silently skipping events.

## 10. Send, execution, and recovery protocol

1. Composer creates and durably preserves a client message ID with pending text before submitting. No persistent offline-send queue in V1: a disconnected composer retains its draft and asks the user to send after reconnect.
2. Server authenticates, validates current membership/recipients and body limits, and resolves the client ID.
3. In one database transaction, append the user message, create recipient dispatches, update activity, and write outbox entries.
4. Outbox publishes envelopes to bot-coms using stable idempotency keys. Marking delivery and retries must tolerate crashes between spool publication and database bookkeeping.
5. Wake adapter claims the dispatch, rechecks authorization, and starts a fresh Hermes run with the intended profile and bounded context.
6. Context includes the new message, recipient instructions, shared history through a recorded sequence, and a versioned summary if needed. Never load another DM's/private session's history.
7. Record launch/run identity before acknowledging a launch. The launch adapter must support reconciliation of “launched but status write failed”; otherwise this is a release blocker for automatic launch retries.
8. Stream authorized output under stable output IDs, and persist final replies in the shared log. Keep private reasoning, internal receipts, credentials, and unrelated delegation output out of the user message stream.
9. Publish status/message events transactionally and reconcile inbox summaries/read state.
10. Recover pending outbox, stale leases, and known incomplete attempts after restart. Distinguish execution finished, final reply persisted, and notification delivered.

At-least-once transport does not guarantee exactly-once external actions. Deduplicate delivery, run launch, and reply publication at their boundaries. Never automatically replay potentially completed external side effects after an ambiguous run failure; mark Needs attention or reconcile with the tool's own idempotency contract.

Current per-peer serialization is acceptable for V1. Show Queued when another conversation occupies the peer. Define fair queue ordering, maximum active duration, cancellation, retry limits, and deployment-configurable delegation/turn budgets. One group cannot trigger unbounded bot-to-bot wake loops. Source/causation IDs must survive delegations, and each delegation must remain within the authorized participant set unless separately approved by the server's existing policy.

Context summaries are server artifacts tied to a covered sequence range. They never replace the authoritative message log. Fresh runs can consume a summary plus recent messages; a long-lived DM does not require an unbounded model context or a permanently resident process.

## 11. Events, read state, and notifications

Use server sequences for conversation order and a replayable account event cursor for synchronization. Capture snapshot high-water mark and subscribe/replay from it so changes between loading and listening are not lost. Merge by identity/revision; duplicate events are harmless. Reordered updates cannot regress finalized output or run terminal states.

Events include message accepted/updated/finalized, run state changed, membership changed, user state changed, and readiness changed. Document which changes update activity and unread. Internal receipts and token deltas do not independently increase unread counts.

Advance read state only when the conversation is visible, foregrounded, and the relevant message is actually presented/read under the chosen viewport policy. Do not mark all history read merely because a push opens the screen. Multi-device updates use max(last-read-sequence).

Add a versioned messaging push payload with server/account association, conversation ID, message ID or sequence, and optional run ID. Existing session push payloads keep their meaning. On tap, authenticate and revalidate access before opening the typed messaging destination. Do not put a conversation ID into `session_id`.

Use the existing notifier infrastructure only after its contract is extended and verified. Coalesce streaming activity into useful final-reply, failure, or approval notifications; honor mute settings and existing preview privacy preferences. Reconcile unread from the backend after receiving a push rather than incrementing blindly.

Push is optional for basic messaging readiness but required before advertising phone alerts. Without push, live updates and foreground reconciliation still work and the feature sheet reflects that limit.

## 12. Conduit implementation boundaries

Proposed additions:

- `Conduit/Models/MessagingModels.swift`: typed capabilities, conversations, participants, messages, runs, events, errors.
- `Conduit/Services/MessagingService.swift`: typed HTTP operations through the authenticated dashboard bridge.
- `Conduit/Services/MessagingStore.swift`: server/account-owned list/detail state, mutation reconciliation, revisions, pagination, event cursor.
- `Conduit/Services/MessagingCapabilityStore.swift`: capability refresh, connection fencing, setup state.
- `Conduit/Services/MessagingSetupService.swift`: optional server-managed setup jobs and manual fallback metadata.
- `Conduit/Services/MessagingDraftStore.swift`: scoped drafts/pending send IDs and migration from unsaved DM key to durable conversation ID.
- `Conduit/Views/Messaging/MessagingConversationView.swift`, `MessagingComposer.swift`, `MessagingRow.swift`, `MessagingFeatureSheet.swift`, `MessagingSetupView.swift`, `NewGroupSheet.swift`, `GroupMembersSheet.swift`, `MessagingRunsSheet.swift`.

Adapt existing `InboxView`, profile rail/shelf, `RootView`, `SidebarLayout`, and `AppShellState`. Introduce a typed destination such as existing-session versus messaging-conversation, while leaving existing session identity admission and recovery owned by `AppState`.

Avoid adding messaging runtime ownership to the already-large session `AppState`. Reuse pure rendering components by passing explicit inputs; extract components only when the messaging screen needs them. Do not share a mutable composer context between a DM, group, and session.

Every async operation captures server ID, principal, connection generation, and destination identity. Session profile-switch fences still apply to session actions; messaging fetches must not be canceled merely because the user changes the unrelated session workspace. Logout/server replacement clears or locks all prior-account state before displaying incoming-account data.

Inspect whether the dashboard bridge supports event streaming. If it does not, add a supported authenticated subscription through Hermes or use bounded incremental polling with cursors; do not assume WebKit JSON requests can stream SSE. Stop foreground polling on background; backend work continues independently.

## 13. Failure and degraded behavior

| Situation | Required behavior |
|---|---|
| Plugin absent, no prior messaging | Existing session UI plus dismissible feature card |
| Discovery pending | Preserve last stable layout; avoid upgrade-card flicker |
| Server temporarily offline | Cached summaries/history labeled offline; retain drafts; no new dispatch |
| Plugin disabled after use | Keep authorized cached message rows marked unavailable; Sessions remain usable |
| Authorization revoked | Remove inaccessible cached content immediately when known; do not preserve sensitive history as readable offline |
| One profile unavailable | Explain on its DM and recipient chips; reject affected sends, preserve other conversations |
| Send accepted but acknowledgment lost | Reconcile client ID before retry; retain pending state |
| First-send race across devices | One DM, distinct accepted user messages, no duplicate dispatch |
| Worker launch ambiguous | Reconcile recorded run; no blind duplicate launch |
| Worker crashes | Recover state; surface failed/needs attention if safe resumption is unproven |
| Member removed mid-run | Cancel/revoke publication, preserve prior attribution |
| Event cursor expires | Refetch snapshot plus new cursor; retain unsent draft |
| Setup interrupted by app close | Resume setup job observation |
| Setup fails halfway | Show actual remaining steps and safe retry; no destructive rollback |
| Legacy server | Sessions unchanged; manual/update guidance |

## 14. Authorization and privacy requirements

Messaging visibility belongs to the authenticated user and explicit conversation membership, not to whichever profile Conduit last selected. Every list/read/send/run/setup endpoint enforces server-side authorization. Knowing a conversation or run ID is not permission.

Installation is an admin operation distinct from sending messages. Setup must not modify unrelated profiles, enable write tools globally, change approval defaults, or install coding-agent integrations just to support chat. Present required profile enablement concretely.

Each dispatched run receives only shared conversation context and the intended profile's authorized configuration. Adding a group member does not expose other members' private DMs or historical sessions. Logs record IDs, revisions, timing, and state transitions without message text, tokens, credentials, or private reasoning by default.

Define storage retention and user-data deletion with the server implementation before release. V1 archive is not deletion. A server uninstall preserves data unless the administrator chooses a separate, explicit data-removal operation.

## 15. Delivery phases and dependencies

### Phase 0 — Contract and integration audit

- Audit core capability discovery, plugin HTTP extension hooks, authenticated principal/profile identities, admin install support, launch/output/approval hooks, and notification routing.
- Verify bot-coms plugin dependencies needed for messaging; isolate from board workflow requirements.
- Freeze API v1 schema, identity rules, error taxonomy, event cursor contract, and minimum compatible versions.
- Decide storage location/migration owner, worker reconciliation mechanism, and default queue/turn limits.
- Record actual source versions and contract fixtures in an audit document.

Exit: a demonstrated headless send → correct profile wake → attributed persisted reply with safe retry semantics, or explicit backend blockers. Do not start with a visually complete inbox that has no executable backend contract.

### Phase 1 — Capability and discovery UI

- Add typed capability state and fixtures.
- Add feature card, sheet, dismissal preference, setup status, and manual fallback.
- Preserve legacy profile/session navigation exactly.
- Add managed setup only if Phase 0 verifies support.

Exit: old server, absent, disabled, unauthorized, offline, and ready fixtures render correctly; no setup operation occurs without the displayed user action.

### Phase 2 — Durable backend DM vertical slice

- Implement conversation/message storage and atomic first send.
- Add outbox, messaging wake adapter, explicit run mapping, bounded context, final reply publication, and reconciliation.
- Add read/list/event endpoints and author attribution.
- Fault-inject acceptance/dispatch/launch/publication crashes.

Exit: two clients see the same DM and replies across restarts; repeated requests do not create duplicate runs or messages at verified boundaries.

### Phase 3 — Conduit DM experience

- Add messaging service/store, typed navigation, text composer, history, draft migration, and status states.
- Implement profile tap → DM, Sessions header action, and first-use transition.
- Preserve existing session resume, approval, voice, branching, and profile-switch behavior.

Exit: user can start a DM without creating a channel, close the app during work, return, and see the result.

### Phase 4 — Groups and combined inbox

- Implement membership revisions, default responder, structured mentions, multi-recipient dispatch, group creation/settings, and per-run attribution.
- Add compact rail, All/Messages/Sessions, scoped session labeling, deterministic ordering, and archive/pin/mute behavior.
- Add group context consent and removal semantics.

Exit: two profiles can respond to targeted requests without cross-conversation history leakage or automatic response loops.

### Phase 5 — Notifications, setup completion, and release hardening

- Extend notifier payloads where supported; validate deep links, read reconciliation, and mute/privacy behavior.
- Finish admin-managed setup on supported servers, including deferred restart and reconnect verification.
- Verify API compatibility gates, migration/rollback behavior, accessibility, dynamic type, dark mode, and iPad layouts.
- Publish version-matched installation and troubleshooting instructions.

Exit: release checklist below passes. Ship capability-gated so incomplete servers never advertise readiness.

## 16. Verification plan

Backend integration tests must cover meaningful failure boundaries rather than only serialization helpers:

- Concurrent first sends resolve one DM; duplicate client IDs resolve one message and recipient dispatch.
- Crash after message commit/before spool publication; after spool publication/before outbox acknowledgment; after launch/before bookkeeping; after final output/before publication acknowledgment.
- Duplicate/reordered events; cursor expiry; snapshot/event race; monotonic read state across devices.
- Unauthorized conversation lookup, forged recipient IDs, profile deletion/recreation, stale membership, removed member output, and account isolation.
- Peer busy across multiple conversations, bounded retry, cancellation races, and explicit delegation limits.
- Summary context boundaries and absence of private-session leakage.
- Installation plan replay, changed plan rejection, insufficient admin privilege, interrupted job, deferred restart, and readiness failure after nominal install success.

Conduit tests:

- Unknown/missing/disabled/ready/offline/forbidden capability transitions and stale connection responses.
- Legacy tap → profile switch → session sheet → chat, including failed switch and delayed sheet dismissal.
- Ready tap → DM without creating anything until send; explicit Sessions action retains original behavior.
- A → B → A messaging navigation and server/account switch races reject stale responses.
- Unsaved DM draft/pending-ID migration, lost send acknowledgment, scene recreation, and group draft isolation.
- Mixed inbox scope labels, timestamp fallback sections, row-kind routing, filter persistence, and no fabricated session unread/running states.
- Deep links into session versus messaging, revoked access, archived DM reopen, and feature loss while a conversation is open.

Manual end-to-end matrix:

1. Legacy Hermes, no plugin: existing flows and feature discovery.
2. Modern Hermes, plugin absent: admin/manual setup routes.
3. Plugin installed but disabled or partially configured.
4. One eligible profile: persistent DM, groups unavailable with explanation.
5. Multiple eligible profiles: explicit mentions, default responder, concurrent queued work.
6. App background/termination during run; foreground recovery and optional push navigation.
7. Plugin disabled/server restarted during send.
8. Non-admin account and revoked conversation access.
9. Large history with pagination, Dynamic Type, VoiceOver, dark appearance, iPhone and split-view iPad.

Use existing project build/test scripts after implementation; this planning change does not require an application build. Add visual verification for new screens during their implementation rather than tests that merely mirror static view declarations.

## 17. Release acceptance checklist

- [ ] Existing session creation/resume/profile switching and supported tools remain operational without bot-coms.
- [ ] No DM requires a channel name or group-creation step.
- [ ] Existing sessions never become bot-coms messages through migration.
- [ ] Profile rail behavior is clearly introduced and both paths remain discoverable.
- [ ] Messaging readiness is authoritative and versioned; installed-only does not unlock incomplete endpoints.
- [ ] Feature card can be dismissed; Settings retains setup access.
- [ ] Setup is truthful about server changes, permission, restart, and manual fallback.
- [ ] DMs are unique under concurrent creation and use durable profile identity.
- [ ] Groups route only to explicit recipients/default responder and show authors correctly.
- [ ] Accepted messages survive server restart and phone closure.
- [ ] Delivery/launch/publication ambiguity is reconciled; no unsupported exactly-once claims.
- [ ] A long-lived conversation can span multiple fresh Hermes runs with bounded context.
- [ ] All list accurately labels session scope and does not guess timestamps or unread.
- [ ] Messaging history/drafts/events cannot cross accounts, servers, or conversations.
- [ ] Profile/membership revocation prevents new unauthorized execution/publication.
- [ ] Notifications and decision actions are capability-gated and correctly routed.
- [ ] API/DB versions and server dependencies are documented; schema upgrades preserve data.

## 18. Remaining implementation decisions

These are engineering audit outcomes, not unresolved product approval questions:

1. Exact Hermes extension points and whether a core management endpoint already exists.
2. Trusted package distribution identity, minimum versions, and dependency closure for the messaging adapter.
3. Source of immutable profile/principal/server IDs and necessary migrations.
4. Supported way to launch a run and obtain durable session/output/approval mappings.
5. Streaming transport supported by the authenticated dashboard bridge.
6. Exact recovery scheduling, queue fairness, retry ceilings, delegation limits, and context budget defaults.
7. Raw session activity timestamps and whether a future unified server inbox index is warranted.
8. Notifier support and documented behavior on installations without push.

Product defaults are settled for this plan: coexistence with Sessions; persistent DMs without channel setup; groups for multiple bots; profile rail opens DMs when ready; explicit Sessions access; discoverable optional installation; no invented paid tier.

## 19. Implementation record (2026-09-08)

The first implementation now lives in Conduit and `server/bot-coms-messaging/`. No live plugin installation, configuration change, dashboard restart, model invocation, or deployment was performed.

Implemented:

- Discovery through the existing authenticated plugin hub, with separate companion API readiness and a manual setup sheet. Missing/disabled/incompatible/offline/forbidden states preserve Sessions.
- Messaging inbox, eligible-profile DM rail, All/Messages/Sessions sections with explicit session scope, plus actions, persistent text DMs, groups, explicit recipient selection, group editing, run status/cancellation, pin/archive/mute, and monotonic read state.
- Separate native messaging service/state/drafts; durable pending send IDs, first-send reconciliation, connection generation fencing, and no reuse of session runtime identity for messaging.
- Companion authenticated FastAPI adapter, migration-versioned SQLite store, atomic first-send/message/dispatch transactions, account/profile allowlists, stable configured identities, pagination, event cursor API, and recipient/membership validation.
- Actual bot-coms spool delivery and per-peer inherited process locks; fresh quiet Hermes CLI execution, bounded context, private diagnostics, cancellation/revocation, and conservative interruption recovery.
- Readiness depends on a recent worker heartbeat. Shared instance plugin enablement is rechecked at runtime, not only at router mount.

Audited local source revisions: Hermes `6e2b8e070d`; bot-coms `422918b`. Tests exercise adapters against temporary data, including real spool operations and an inert substitute CLI executable; they are not proof of a live deployment's model/provider configuration.

Implementation choices and remaining release work:

- Final namespace is `/api/plugins/bot-coms-messaging/v1`; the companion is a separate dashboard extension. bot-coms core and board sources remain unchanged.
- Actual Hermes install routes do not provide the reviewed resumable setup-job contract. Setup uses the documented manual fallback. Automatic installation is not advertised.
- V1 uses foreground polling and final replies. It does not advertise streaming, push, attachments, voice, or mobile approval actions. Those require their specific server/notifier contracts and end-to-end validation.
- Group recipient selection is an explicit recipient menu; typed `@names` do not silently route. A richer inline mention-chip editor remains a presentation follow-up.
- The dedicated messaging spool serializes messaging runs per peer, not runs from the existing board spool. A shared execution policy across those systems remains integration work.
- Context uses a bounded recent shared-history window; durable summarized context, nested threads, and proactive delegation are not implemented.
- Messaging currently opens a dedicated full-screen conversation surface. Automatic typed messaging restoration after process termination, native push deep links, and the persistent iPad messaging detail pane remain follow-ups; message history itself remains durable.
- Worker diagnostics retain the CLI runtime ID on the server, but verified in-app session inspection and approval routing are not exposed.
- Production package distribution, a live installation smoke test, retention/deletion UX, and the complete release checklist remain outstanding. Treat this as the core integration, not a completed public rollout.

See the companion README for installation, authorization, worker supervision, storage, compatibility, and exact test commands.

Verification for this implementation:

- Xcode simulator build and 39 selected unit tests passed: 10 messaging tests, 4 shell-state tests, 25 return-surface regression tests.
- Two simulator UI tests passed: direct DM open/send/return and missing-plugin setup discovery with the original session shelf preserved.
- Nineteen companion backend tests passed, including real SQLite/spool operations, concurrent first sends, idempotency, private subprocess diagnostics, account/server consistency, revocation, plugin disablement, bounded Unicode history, and crash recovery at publication/ack boundaries.
- Simulator inbox and DM screenshots were inspected. Markdown uses the existing renderer; its selectable text views are tested through their actual accessibility surface.
- `git diff --check` and Python compilation passed.
- Regression fix: selecting the current unsaved default return surface now persists the explicit choice without requesting navigation.

The full application suite, production model invocation, installation on a live server, and release deployment were not run. Dependencies for backend tests were installed only in an isolated `/tmp` environment.
