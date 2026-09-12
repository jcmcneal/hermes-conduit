# Message response bounds

Audit of local Hermes source `a6102b8d80` and bot-coms source `35e0083`, September 12, 2026. The local gateway status reports Hermes 0.21.1 with that matching core SHA. This verifies local source/runtime version metadata and isolated tests; the server selected by a particular TestFlight connection still needs to be identified.

| Request | Response bound | Database behavior |
| --- | --- | --- |
| Session REST history | Penelope requests the latest 120 rows. Server clamps limits to 500 and defaults an omitted limit to latest 500. | Modern schemas use SQL LIMIT/OFFSET before loading selected message bodies. |
| Compact WebSocket resume | Penelope sends `omit_messages: true`; current server returns no persisted transcript in the resume payload. | Live resume skips persisted history reads. Cold resume can load the active tip internally for runtime initialization. |
| Bot DM/group history | At most 100 messages and 50 run records. Approximately 1.2 MB budget for serialized messages. | SQL LIMIT 101, using the extra row to determine whether an older-page cursor is needed. |

The normal paths do not send an entire session database to the app. The session REST server applies its limit even when the caller omits one. Requesting older history remains explicit pagination.

## Limits that are not strict byte guarantees

- Session REST has a row limit, not a server response-byte cap. A page containing unusually large messages can still be large; the bridge's 24 MiB transport ceiling rejects an oversized response rather than asking the server to make it smaller.
- Bot history permits its first message even when that message exceeds the approximately 1.2 MB budget. Conversation metadata and up to 50 run records are outside that message budget. The messaging client also caps received JSON at 2 MB.
- Penelope retains a compatibility fallback to full-transcript WebSocket resume when paginated history is unavailable or incompatible. Its 4 MiB receive ceiling is a transport safeguard, not pagination. Therefore the app cannot promise a bounded page on every older-server fallback.
- Legacy read-only databases without persisted display identities may read and deduplicate one conversation's compacted history before slicing. Their REST response is still paginated, but their database work is not as lean as the modern indexed path.

## Verification

Eighteen focused Hermes tests passed with retries disabled: eight REST routing cases, five real SQLite pagination/legacy/bounded-work cases, and five compact-resume cases. Tests ran from an isolated source snapshot with temporary Hermes state. Two bot-coms tests passed for 105-message pagination and large Unicode response budgeting. No live conversation database or message content was read.

Relevant source entry points are `hermes_cli/web_routers/sessions.py:get_session_messages`, `hermes_state_messages.py:get_messages`, `tui_gateway/methods_session.py`, `tui_gateway/server.py:_live_session_payload`, and `bot_coms_messaging/store.py:history`. Client request policy is in `PersistedTranscriptWindow.swift`, `HermesClient.swift`, and `MessagingService.swift`.

A strict end-to-end byte guarantee would additionally require a server byte-budget/cursor contract and a bounded replacement for the legacy resume fallback. Those are distinct from the row-pagination guarantees verified here.
