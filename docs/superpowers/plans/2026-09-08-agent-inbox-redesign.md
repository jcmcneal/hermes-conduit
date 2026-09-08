# Agent inbox redesign implementation plan

Status: Ready for implementation as a standalone PR. No application changes have been made as part of writing this plan.

Prepared: 2026-09-08. Code inspected at `eeb5556`; recheck affected interfaces against the implementation branch before editing.

## 1. Goal and design direction

Give Conduit the approachable, quiet appearance of the supplied Grok Bot reference: a bright canvas, expressive colorful characters, a short row of prominent profile shortcuts, and a clean conversation list. Make the inbox a primary destination while preserving Conduit's existing chat, automation, and workspace capabilities.

Reference: [supplied App Store screenshot](https://is1-ssl.mzstatic.com/image/thumb/PurpleSource211/v4/3d/96/ee/3d96eeb8-c72f-de19-e86d-3576d6a1b2e9/01_work-with-many-agents.png/460x996bb.webp).

The screenshot establishes the home-screen appearance only. Chat styling, gestures, dark mode, and secondary navigation below are proposed Conduit design decisions; they are not claims about the reference app's behavior. Ignore the promotional heading, phone frame, and surrounding background when assessing the application design.

The result should feel like a place to return to conversations with familiar agents. Color belongs primarily to agent identity and meaningful state. Content sits directly on the canvas, with surfaces reserved for input, actions, and grouped information.

## 2. Scope for this PR

Ship one coherent frontend redesign using the existing Hermes contract. The central product decision is that **characters represent profiles and list rows represent conversations**. Do not present temporary delegate runs as permanent agents or disguise sessions as separate autonomous workers.

### Included

- A primary inbox destination on iPhone and compact iPad windows.
- A profile character rail using existing profile discovery, order, names, and custom photos.
- A flat session list with search, source filtering, pinning, rename, archive, and delete.
- Access to projects, scheduled jobs, Kanban, profile management, and settings.
- A shared visual system applied to the inbox, chat header, composer, transcript chrome, profile picker, and common secondary-screen surfaces.
- A restrained dark appearance and accessible layouts.
- Explicit handling of launch, foreground return, notification navigation, voice intents, profile changes, and adaptive iPad layout.
- Behavioral tests for the new navigation boundaries and visual verification of the changed surfaces.

### Deferred to later work

- A global feed combining sessions across profiles.
- Durable agent creation, agent templates, or a new agent directory.
- Global worker activity, task summaries, completed/failed badges, or unread counts that require new server data.
- Fetching every session transcript to generate list previews.
- New backend RPCs, push payloads, migrations, or notification infrastructure.
- A Kanban workflow redesign or a restructuring of settings and connection setup.
- Chat viewport, Markdown, transport, authentication, voice pipeline, or conversation identity rewrites.
- New app icons, branding changes, custom fonts, or third-party animation packages.

This narrows the earlier proposal deliberately: activity previews are valuable, but they are not a dependency for the visual and navigation redesign.

## 3. Product behavior

### 3.1 Inbox layout

From top to bottom:

1. A quiet toolbar: active-profile avatar at the leading edge, search and plus at the trailing edge. The avatar opens profile management; a menu on the navigation strip provides Settings. Accessibility labels describe the actions explicitly.
2. A horizontally scrolling profile rail. Characters are large enough to be recognizable, with the profile name underneath and a small, accessible selected treatment.
3. A compact destination strip: `Chats`, `Scheduled`, `Boards`, followed by a More menu. Map Scheduled to the existing Cron destination and Boards to Kanban; preserve stored `SidebarTab` raw values rather than changing persistence for a label refresh.
4. Conversation content, with short `Pinned` and `Recent` headings only when those groups exist.

The More menu provides Projects, Archived conversations, Filters, and Settings. When a current conversation exists, it also offers Resume conversation, revealing the restored chat without forcing a different session selection; this remains useful when search or filtering hides that row. Existing project creation and source-filter reordering remain reachable from their relevant screens. When a non-default source filter is active, display a removable filter chip above the rows; do not require opening a menu to discover that content is filtered.

The profile rail appears on Chats. Scheduled and Boards retain their own working space beneath the shared toolbar/destination strip. Search is contextual: the Chats search button activates conversation search, and other destinations expose only search they actually support. Plus likewise means New conversation on Chats, the existing supported creation action on Boards, and is absent on Scheduled unless an existing job-creation flow is available.

There is no floating composer on the inbox. Plus starts a conversation in the active profile through the existing creation action. The list remains visible with progress/error feedback until the operation can show a valid conversation destination; do not allow repeated taps to create duplicate sessions.

### 3.2 Profile rail

- Render profiles in `appState.profiles` order; fall back to the active profile if discovery is empty, matching the existing picker behavior.
- Reuse `profileDisplayName`, `profileAvatarURL`, and existing reorder persistence.
- Tapping a different profile calls the existing profile-switch operation and keeps the user in the inbox. It changes the workspace, not merely the visual filter.
- Disable competing selections while a switch is in flight. The final selected treatment follows authoritative `activeProfile`; surface a failure without labeling the destination as selected prematurely.
- Reset transient search and source filtering when changing profiles so an old query does not make the new workspace appear empty. Keep the established stored filter order.
- Show only data belonging to the active profile. Never retain the outgoing profile's rows under the incoming profile's name while refresh or rollback is pending.
- Tapping the current profile performs no network action. Profile editing and reordering live in the existing profile manager.
- With one profile, show one intentional shortcut aligned to the leading edge. Do not invent placeholder agents to fill the screenshot's three positions.
- With many profiles, scroll horizontally and bring the selected profile into view. No synthetic favorites system is needed for this PR.

### 3.3 Conversation rows

Each row contains a compact character or custom profile image, a one-line title, a secondary line, and a trailing update label. The whole row is tappable. There is no disclosure chevron, permanent rounded background, or decorative border. A subtle selection background is allowed in the persistent iPad column, and pressed feedback remains visible.

| Element | V1 data and behavior |
|---|---|
| Title | Existing session title; preserve the current title recovery behavior |
| Secondary line | Existing source label and model, omitting empty components |
| Update time | Existing `updatedLabel`, displayed separately; do not parse the display string to sort |
| Avatar | Owning profile identity; rows within a profile intentionally share an identity |
| Pin | Existing pinned state and actions |
| Selected row | Existing proven conversation identity/aliases, scoped to the active profile |
| Running indicator | Only if the existing data source proves it means a currently running turn; otherwise omit |
| Unread/completed/failed | Omitted until a reliable source exists |

`SessionSummary.isActive` must be audited before using it as a running badge. “Active session” and “agent currently executing” are not interchangeable. The current conversation's `turnState` also must not be applied to other rows.

Keep the server/catalog ordering within the pinned and unpinned groups. Preserve source filtering and current search matching. Do not add full-transcript search or arbitrary title-based identity.

Swipe/context actions retain their existing semantics and destructive confirmations. Preserve project grouping as server-owned. A Projects page should use the existing project support/capability gates rather than locally inferring membership.

### 3.4 Return behavior and migration

Keep `ChatReturnSurface` raw values `conversation` and `sessions`. Display the latter as `Inbox` in settings. Change the fallback for an absent or invalid preference to Inbox; explicitly saved Conversation and Sessions choices are preserved. This means existing users who never saved a preference will also receive the new inbox default. Record that behavior in the PR and test it intentionally.

The separate `ChatResumeBehavior` continues to decide which conversation and reading position are restored. The inbox changes presentation, not recovery authority. Existing automatic recovery may still hydrate or create a session under its established rules; the inbox view itself must not issue a create/resume request on every appearance.

| Trigger | Expected presentation |
|---|---|
| Cold launch with no saved surface preference | Inbox after authentication, without flashing chat first |
| Qualifying foreground return with Inbox preference | Inbox, unless an explicit destination or modal wins |
| Saved Conversation preference | Restored conversation using existing Continue/Latest behavior |
| Tap conversation | Open the requested conversation through the existing request path |
| Back from conversation | Inbox with its list position, current query, and filter retained |
| Tap the already selected conversation | Reveal it without unnecessarily resetting draft or viewport |
| Notification opens a session | Resolve the target using existing profile/identity guards and show its conversation |
| Voice intent | Preserve the existing voice routing and show its intended conversation/voice sheet |
| Settings/voice/other modal spans background return | Keep modal precedence; do not reveal a delayed inbox after dismissal |
| Sign out and sign in | Clear retired shell requests and account-owned transient state; no stale navigation |

Use the existing one-shot preferred-return request/claim mechanism. Update its presentation target from a drawer to an inbox; do not introduce a second independent foreground observer that competes with it.

In a persistent iPad layout, the inbox is already visible. Consuming a return request must not open a duplicate screen, clear the conversation, or replace an actively selected Boards/Scheduled page unexpectedly. Preserve the existing “sidebar already visible” policy and document it in settings copy where needed.

## 4. Visual specification

### 4.1 Tokens and components

Introduce semantic tokens in `Theme.swift` or a narrowly scoped companion file. Reuse the existing system typography and Dynamic Type support. The following are starting values, to be refined in simulator review rather than treated as pixel-test contracts.

| Token | Light starting point | Dark starting point |
|---|---|---|
| Canvas | `#FAFAF8` | `#111214` |
| Raised/input surface | `#F0F1EF` | `#202225` |
| Primary text | `#18191B` | `#F4F4F2` |
| Secondary text | `#6B6F73` | `#AAAFB5` |
| Separator | `#E4E6E3` | `#32353A` |
| Primary action | Near-black fill, white glyph | Near-white fill, dark glyph |
| Agent colors | Violet, blue, green, teal, orange, rose | Tune the same identities for contrast |

Use separate foreground and background roles for destructive actions, warnings, success, and informational content. Do not repurpose agent colors as semantic status. Check actual text contrast, including disabled and secondary text, against each surface before finalizing the palette.

Layout starting points:

- Page horizontal inset: 20 points on phone, 16 in the narrow iPad column.
- Toolbar tap targets: at least 44 by 44 points, with smaller visual glyphs.
- Profile artwork: approximately 76–84 points on phone, 56–64 in a narrow column; name below with room for two lines.
- Session artwork: approximately 40 points; row minimum height around 64–68 points at standard text size.
- Row gap: 12 points between artwork and text; 3–4 points between text lines.
- Conversation title: system body/subheadline with medium or semibold emphasis; metadata uses a scalable supporting style.
- At accessibility text sizes, allow rows to grow and move the timestamp below the title if needed. Never force a fixed row height that clips text.

Add reusable components for character artwork, profile shortcuts, conversation rows, compact icon actions, and semantic surfaces. Keep component APIs small. Avoid introducing a complete parallel theming framework.

### 4.2 Original character system

Implement a small family of original vector characters in SwiftUI `Shape`/`Path` or Canvas. Use distinct silhouettes and a minimal face. Aim for six or more shapes and a coordinated palette; exact Grok character assets are unnecessary.

- Derive appearance from the stable profile ID with an explicitly deterministic algorithm. Do not use Swift's process-randomized `hashValue`, display names, list indices, or the current runtime session ID.
- A profile's fallback character remains consistent after relaunch, rename, reordering, and runtime session rebinding.
- The custom photo remains the highest-priority appearance. Removing or failing to load it restores the character fallback.
- Preserve existing local photo storage behavior. Avoid adding account sync or changing its persistence format in this PR.
- Decorative eyes and shapes are hidden from accessibility; the containing control supplies the name, selected state, and action.
- Avoid continuous animation on list rows. Optional motion belongs to a visible, verified working state, with Reduce Motion providing a static equivalent.
- Rendering must not reread/decode the same image from disk on every streaming update. Use an appropriately scoped image cache if the new reuse exposes this cost.

Use the same profile identity across the rail, session list, profile picker, chat header, and assistant attribution. Do not assign different colors to sessions and imply that they are different agents.

### 4.3 Chat and composer

The screenshot does not show chat; use the following extension of its design language:

- Flat canvas, a clear Back/Inbox affordance in compact layout, and a plain title with compact profile identity. Preserve title-tap scroll-to-top behavior.
- Move refresh and ordinary connection diagnostics into a chat menu. Failed/disconnected/reconnecting states remain visibly actionable; reducing normal toolbar noise must not hide repair access.
- Neutral user bubble with appropriately contrasted text, no amber gradient or glow. Update attachment chips and Markdown foregrounds together: the current user subtree contains explicit white text and translucent white decorations.
- Assistant content remains directly on the canvas with readable spacing. Preserve copy, read aloud, branching, selection, timestamps, and Markdown features.
- Tool and reasoning containers use quiet supporting surfaces. Preserve expansion behavior and clearly distinguish approvals, questions, errors, and actions requiring attention.
- Composer uses one outer input surface. Keep attachment, voice, text input, and send/stop/steer/interrupt access. Remove unnecessary nested borders and glass wrappers.
- Keep a compact model/effort control and access to context/agents. At narrow widths these may move into a labeled options menu, with important busy/unsafe mode state still visible.
- Action meaning and availability continue to come from `turnState` and existing composer policies. Do not turn an unavailable, stop, steer, or interrupt action into an ordinary send for visual simplicity.
- Preserve the existing UIKit text editor, programmatic revision checks, Return-key preference, paste handling, and asynchronous attachment ownership guards.

### 4.4 Secondary screens

Apply the shared canvas and surface tokens to settings, model selection, workspace/diagnostics, voice sheets, Scheduled, and Boards. Keep their feature structure and workflows. Profile management receives the new avatar component and quieter rows.

Replace direct hardcoded foundations where they conflict with the new theme, especially the model picker and composer. Audit direct `.regularMaterial`/`.ultraThinMaterial` backgrounds in Kanban and supporting screens. Native sheets and transient controls may retain system material, but ordinary content rows should not become tinted glass cards by default.

Migrate active call sites to accurately named surface/control helpers; do not silently redefine every `conduitGlass*` helper to mean a flat fill. Retain old helpers only for deliberate remaining glass uses, then remove obsolete helpers when no longer referenced. Avoid unrelated cleanup of legacy view code.

## 5. Architecture and invariants

### 5.1 Shell and navigation ownership

Introduce a small presentation owner, provisionally `AppShellState`, scoped to the authenticated root. It owns whether Inbox or Conversation is the compact destination, the current presentation request, and the list's transient presentation state. It does not own selected session identity, recovery, transport, or turn state.

Use one explicit route into the conversation surface for row selection, New conversation, branch, project/archived/scheduled-session selection, notifications, and voice intents. Completion must be admitted against the current route request and AppState ownership before changing presentation. A superseded asynchronous open must not push an old destination after the user selected another row or navigated back.

Do not infer “show chat” from every `activeSessionId` change: startup recovery, profile switching, and runtime rebinding can change that property without expressing navigation intent. Likewise, `showSidebar = false` is not a sufficient signal that a session open succeeded.

Prefer native navigation for compact Inbox → Conversation → Back behavior. Maintain one conversation destination for the selected session; do not stack a new `ChatView` for every row tap or key the entire screen by a rotating runtime identifier. Multiple live ChatViews would compete for viewport snapshot-provider ownership.

Retain the existing iPad persistent-sidebar preference and minimum chat width. Update its compact fallback from a sheet drawer to the inbox navigation flow. Both layouts must consume the same inbox content and conversation host. When resizing replaces a host, use the state preservation rules below; never assume a SwiftUI view's `@State` survives moving between different branches.

### 5.2 Draft lifetime is an implementation prerequisite

Currently `ComposerBar` owns `ComposerDraftStore` in `@State`, alongside the live text and attachments. Popping a chat screen can destroy all of that state. Solving this is required before adopting navigation that unmounts chat.

- Move the draft store's lifetime to an authenticated-shell/session owner and inject it into ComposerBar. Keep one store, its bounded capacity, existing generation-aware submission buckets, and profile/session keys.
- Save the current live text and attachments before leaving the conversation, and restore them when mounting again. Define an explicit capture/handoff path; do not rely solely on a late `onDisappear` after the owning session has already changed.
- Ensure ordinary user edits and attachment changes cannot be lost if resize or navigation tears down the view. Use event-driven write-through or a flushable save mechanism; do not write on streaming publishes or rewrite the UIKit editor while typing.
- Retain accepted identity migration and A → B → A stale-completion protection. A failed late send must not replace a newer draft.
- Scope lifetime to the authenticated connection/account and clear it on sign-out or a connection/account replacement. Do not introduce cross-launch draft persistence in this PR.

### 5.3 Viewport and streaming lifetime

`ChatView` installs a snapshot provider on appearance and removes it on disappearance. An inbox transition must preserve the last real conversation viewport before removing its host. Use the existing coordinator/store to restore the same conversation when it returns; a same-conversation screen reappearance is not a new explicit selection or a request to follow latest.

- Capture the visible anchor before Back or a layout teardown; never save inbox geometry as chat geometry.
- Route any additional presentation-restoration request through existing profile/durable-session/generation checks. Do not create another scroll-position store or route around `ChatViewportController`.
- A notification or explicit different-session open overrides a pending same-conversation restoration.
- Background and reconnect work can settle while chat is unmounted. Reopening must render the accepted transcript and current stream without duplicates or lost reasoning.
- Keep exactly one active snapshot provider and clean up cancelled backfill/restoration tasks.
- `showSidebar` currently suppresses scheduled streaming and reasoning publication. Do not use it as the new Inbox-visible flag. Migrate remaining drawer assumptions intentionally; the shell route must not accidentally leave publication suppressed.
- If profiling shows inbox redraw work at streaming cadence, narrow observation to catalog/profile presentation. Add publication gating only with evidence and flush/resume tests; do not broaden that optimization by default.

### 5.4 Data boundaries

Derive inbox rows from `activeProfileSessions` and established pin/filter/catalog behavior. A lightweight immutable row projection is reasonable if it improves view isolation; it must not become a second authoritative catalog or attach a network fetch to each row.

Reuse conversation identity services for equivalence/selection. Do not introduce `session.id == activeSessionId` as a new universal ownership rule: this repository supports durable IDs, runtime IDs, and confirmed aliases.

Keep the current presentation cache, ordering, and refresh admission rules. New UI must not create cross-profile unions to make the inbox look populated. Unknown metadata is omitted or displayed neutrally, never fabricated.

## 6. Implementation sequence

Each phase should compile and leave a reviewable diff. Suggested new filenames are organizational guidance, not a requirement to add abstractions with no behavioral purpose. After the contract fixtures in Phase 1, prove the draft/viewport teardown and restoration approach from Phase 4 with the existing UI before spending time on full visual polish. That small feasibility check should expose lifecycle scope early.

### Phase 1 — Capture fixtures and navigation contracts

Relevant files: `RootView.swift`, `SidebarView.swift`, `SidebarLayout.swift`, `AppState.swift`, `ChatReturnSurface.swift`, `ComposerBar.swift`, `ComposerDraftStore.swift`, existing return/identity/viewport tests.

- [ ] Record baseline screenshots of Inbox-equivalent Sessions, a populated chat, composer with keyboard, profile picker, model picker, settings, and Boards using deterministic data.
- [x] Extend the existing DEBUG connected-dashboard fixture pattern for multiple profiles, long titles, pinned sessions, source filters, populated/empty lists, a long transcript, and an approval. Fixtures must not require real credentials or live gateway mutations.
- [x] Inventory all session-open and `showSidebar` call sites, including project/archived/scheduled rows, notification paths, and voice intent completion.
- [x] Add behavioral tests for draft survival through actual view teardown, same-session viewport restoration, stale open completion, and return-surface precedence. Use hosted UI/integration coverage where a pure policy test cannot prove view lifetime.
- [x] Establish the preference migration tests: explicit Conversation, explicit Sessions, absent value, invalid value.

Done when the implementation risks have reproductions/fixtures and the new behavior is unambiguous. Do not assert that changing a SwiftUI property alone proves draft or scroll preservation.

### Phase 2 — Shared visual foundations and characters

Modify: `Conduit/Theme.swift`, `Conduit/Views/ProfilePickerSheet.swift`.

Suggested additions: `Conduit/Views/Components/AgentAvatar.swift`, a small shared surface/control file if needed.

- [x] Add semantic colors, spacing, and control/surface helpers.
- [x] Implement deterministic original characters and custom-photo precedence.
- [x] Replace the drifting backdrop on redesigned routes with the new canvas.
- [x] Integrate avatars in the profile picker and provide previews/fixtures in light/dark appearances and accessibility text sizes.
- [x] Verify avatar determinism across reorder/rename/relaunch and fallback for a missing photo. Avoid pixel assertions for decorative geometry.

Done when the visual primitives render coherently on iOS 17 and iOS 26 paths and preserve existing photos/names.

### Phase 3 — Build the inbox using current data

Suggested additions: `Conduit/Views/InboxView.swift`, `ProfileRail.swift`, and `ConversationRow.swift` under Components. Extract or reuse session-list content from `SidebarView.swift`.

- [x] Implement the toolbar, profile rail, destination strip, flat rows, loading/empty/error states, and contextual actions.
- [x] Preserve search behavior, server order, pinning, all row actions, project access, archived sessions, and source filtering/reordering.
- [x] Keep search hidden until requested; opening it focuses the field, Cancel clears the query and dismisses the keyboard. Closing chat back to Inbox retains an active query.
- [x] Keep list identity and scroll position stable through harmless metadata refreshes. An intentional query/filter/profile change may reset to the relevant list top.
- [x] Implement profile switching with progress, disabled repeat actions, and rollback/error display.
- [x] Ensure empty, disconnected, refresh-failed, and “no search matches” states are distinguishable. Cached rows remain usable where existing policy permits; retry uses the established refresh/reconnect actions.
- [x] Connect Scheduled, Boards, Projects, and Settings through existing supported destinations; verify every formerly reachable feature still has an entry point.

Done when the inbox works with current catalog data and no new RPC/schema requirement.

### Phase 4 — Change the shell and preserve lifecycle state

Modify: `RootView.swift`, `SidebarLayout.swift`, `ChatReturnSurface.swift`, `AppState.swift` presentation integration, relevant settings copy, ComposerBar/store ownership.

Suggested addition: `Conduit/Services/AppShellState.swift` with a small, testable presentation policy.

- [x] Lift draft lifetime and implement capture/restore before allowing navigation to destroy ComposerBar.
- [x] Add same-conversation viewport capture/restore for chat unmount/remount using the existing coordinator.
- [x] Implement compact Inbox → Conversation navigation, Back, and system back gesture behavior. Cancelled interactive back must leave chat state intact.
- [x] Implement the Inbox default and preserve saved return preferences and the existing one-shot return precedence.
- [x] Route every explicit conversation entry through one presentation path; reject stale completions and show failed-open feedback without pushing an unrelated conversation.
- [x] Keep one conversation host and prevent automatic resume/runtime rebinding from issuing a navigation push.
- [x] Adapt persistent iPad layout with the current preference and width constraints; test crossing the threshold in both directions during a draft and during streaming.
- [x] Migrate `showSidebar`/drawer assumptions, including modal detection and settings handoff. Remove obsolete sheet-only code after all entry points are covered.
- [x] Verify sign-out, reconnect, profile-switch failure, notification-before-launch, notification-during-open, and voice-intent paths.

Done when navigation and state-lifetime regression tests pass before broad transcript/composer styling is layered on.

### Phase 5 — Extend the appearance through chat and supporting screens

Modify: `ChatView.swift`, `ComposerBar.swift`, `ModelPickerView.swift`, `ChatSupportSheets.swift`, `AuxiliaryViews.swift`, `VoiceConversationSheet.swift`, and active shared surface call sites, including Kanban.

- [x] Restyle the header and preserve its title action, refresh, diagnostics, and visible connection repair states.
- [x] Restyle user/assistant transcript chrome and update explicit foreground colors and attachment decorations together.
- [x] Simplify composer surfaces while retaining editor identity, actions, all input modes, attachments, and context/model/agent access.
- [x] Restyle reasoning/tool/approval/question containers without changing their state machines, disclosure behavior, or action meanings.
- [x] Apply common canvas/surface tokens to secondary destinations; check that nested settings and model-picker surfaces do not retain conflicting foundations.
- [x] Verify Markdown tables, code, math/Mermaid, selected text, images, and documents in both appearances.
- [x] Remove newly unused styling helpers and refresh stale comments/copy about drawers. Avoid broad unrelated refactors.

Done when the complete inbox-to-chat journey looks coherent and secondary screens use compatible colors and controls.

### Phase 6 — Validate and package the standalone PR

- [ ] Run the focused tests below and fix regressions.
- [ ] Run the repository's full CI test workflow and discovery checks required for a PR; new test classes must be discovered by `scripts/plan-tests.py`.
- [ ] Perform the visual/manual matrix below and attach representative screenshots to the PR.
- [x] Confirm no additional per-row RPCs, transcript fetches, or continuous list animations were introduced.
- [ ] Compare long-transcript/streaming fixture behavior with the baseline. Confirm no duplicate chat hosts or image decoding on each streaming publish.
- [ ] Run `git diff --check`, review the file scope, and update this plan's checkboxes and verification record to reflect actual results.
- [x] Update README/user-facing documentation only for changed navigation and defaults. No release/version bump is needed solely to prepare this PR.

Suggested PR title: `Redesign Conduit around a profile inbox`.

## 7. Verification matrix

### Behavioral tests

Extend existing suites where the responsibility already lives; create focused inbox/shell tests only for new behavior. Tests should verify user-visible outcomes or ownership contracts, not reproduce implementation constants.

| Area | Required cases | Existing anchors |
|---|---|---|
| Return preference | Absent/invalid → Inbox; preserve saved choices; claim once; modal/explicit navigation precedence; no stale request after sign-out | `ChatReturnSurfaceTests`, new hosted shell UI coverage |
| Adaptive layout | Phone compact; iPad opt-in/out; threshold crossing; no duplicate inbox/chat provider; retained draft/viewport | `SidebarLayoutTests`, hosted UI tests |
| Session routing | A then B with A finishing late; Back during an open; failure; already-selected alias; notification overrides pending inbox open | `SessionIdentityContractTests`, `AppStateChatResumeTests`, new shell integration tests |
| Drafts | Chat → Inbox → same chat; A → B → A; text plus attachments; late failed send; profile/account boundary; layout teardown | `ComposerDraftStoreTests`, `ComposerPasteTextViewTests`, hosted navigation tests |
| Transcript | Reading above bottom then Back/return; reasoning while hidden; background recovery; backfill; no jump/duplicate/lost stream | `ChatResumeCoordinatorTests`, `ChatViewportControllerTests`, `CompactResumeTranscriptTests`, `ChatViewFollowCorrectionTests` |
| Profiles/catalog | Single/many profiles; custom photo; reorder; failed switch; outgoing rows never under new profile; filters/search/pins/actions | `ProfileDiscoveryTests`, `CrossProfilePresentationCacheTests`, new inbox tests |
| Editor/actions | Return-to-send, paste, attachment completion after navigation, stop/steer/interrupt, approval/clarification access | Existing composer/turn-state/UI suites |
| Performance | Settled Markdown remains isolated; streaming does not rewrite editor; scrolling long content stays bounded | `SettledMessageIsolationTests`, `LongContextScalingFixtureTests`, `TranscriptPerformanceFixtureTests` |

Update existing UI-test helpers that open Settings through the hamburger/drawer, especially `ConnectionSetupSettingsUITests`. Preserve their original connection/session assertions; do not weaken those tests to accommodate the new navigation.

For local execution, use XcodeGen and the repository's documented `xcodebuild`/CI workflow in [CI.md](../../CI.md). Resolve an available simulator explicitly rather than hardcoding a destination that may not be installed. Exercise the minimum supported iOS path and the iOS 26 path where runtimes are available, and record any unavailable platform coverage honestly.

### Visual and manual review

- Small supported iPhone width, a larger iPhone, compact iPad window, and wide iPad with persistent sidebar enabled and disabled.
- Light, dark, standard text, an accessibility Dynamic Type size, VoiceOver, Reduce Motion, and increased contrast/reduced transparency settings.
- One profile, several profiles, long profile names, custom photo, empty catalog, pinned rows, long titles, source filter, active search, and no matches.
- Long transcript with keyboard hidden/visible; text selection; Markdown/code/table; image/document attachments; composer wrapping over multiple lines.
- Idle, running, reconnecting, disconnected with repair, approval, clarification, failed session open, and failed profile switch.
- Back gesture completes/cancels; foreground while viewing inbox/chat/settings/voice; notification and voice entry; rotation/resize during streaming and typing.

Screenshots for the PR: inbox light/dark, populated chat light/dark, composer with keyboard, accessibility-size inbox, wide iPad, settings/profile picker, and a representative Boards screen. Record a short navigation/streaming clip if still images cannot demonstrate preservation behavior.

### Definition of done

- The inbox visibly reflects the reference's whitespace, colorful identities, and flat rows using real Conduit data.
- Characters have consistent profile meaning; no fake agent activity, previews, or unread claims appear.
- Every existing core feature remains reachable, and destructive actions retain their safeguards.
- A user can type with attachments, browse the inbox, reopen the conversation, and continue without losing text, attachments, or reading position through ordinary navigation. The draft stays attached to the correct conversation.
- Notifications, voice intents, foreground recovery, and iPad resizing respect the new shell without changing conversation ownership.
- Light/dark and accessibility layouts pass visual review, with usable labels and touch targets.
- Focused regressions and required CI checks pass; unavailable checks are listed explicitly.
- The PR contains frontend behavior, supporting tests, and documentation only; backend enhancement work is separately scoped.

## 8. Follow-up opportunities

After the frontend PR ships, consider a separate activity-data contract for `lastActivityPreview`, a sortable activity timestamp, authoritative per-session run state, unread semantics/read acknowledgment, and cross-profile aggregation. Specify capability detection, legacy-gateway fallbacks, freshness, profile authorization, and notification reconciliation before adding badges or summaries to the UI.

A later product decision could make persistent agents the primary object instead of profiles. That would require defining agent identity, configuration, session ownership, and creation behavior across Hermes and Conduit. The avatar component and flat-row design can carry forward without pretending that data model exists today.

## 9. Effort and risk

Planning estimate for one experienced SwiftUI engineer: approximately 2–3 engineer-weeks for the scoped frontend PR, including implementation, lifecycle hardening, visual iteration, and verification. A visual prototype may take only a few days; it does not prove the navigation/state contracts.

The main uncertainty is draft and viewport lifetime when moving from an overlaid drawer to navigation that can unmount chat. Resolve Phase 4 early and revisit the estimate if preserving those contracts exposes additional lifecycle work. The next largest costs are applying tokens consistently across the existing surface helpers and reviewing both iOS material paths.

These are estimates, not measured task durations. Backend-dependent activity features and a full redesign of Kanban/settings are outside this estimate.

## 10. Implementation verification record

To be completed by the implementation PR author:

- Implementation base/final commit: started from `eeb5556` on `feat/agent-inbox-redesign`
- Focused test results: not run in this environment (Xcode/simctl unavailable); new suites `AppShellStateTests`, `ComposerDraftLifetimeTests`, `AgentAvatarIdentityTests` added and discovered by `plan-tests.py validate`
- Full CI/discovery results: `python3 scripts/plan-tests.py validate` OK (98 unit + 6 UI classes)
- Devices/runtime versions visually reviewed: pending local Xcode run
- Screenshot/recording links: pending
- Performance observations compared with baseline: pending
- Plan deviations and reasons: Projects sheet temporarily reuses `SessionList` in projects mode; legacy `SidebarView` remains for compatibility but MainView hosts `InboxView`. Visual polish on Kanban/model picker retained existing glass in places where not on the primary inbox/chat path.
- Remaining limitations or unavailable checks: local `xcodebuild`/simulator unavailable in the agent environment; physical-device visual matrix and full CI still required before merge.

Planning-only verification: the current navigation, draft-store lifetime, return-surface policy, profile presentation, and session-summary fields were inspected. No application build or test run was performed for this documentation-only change.
