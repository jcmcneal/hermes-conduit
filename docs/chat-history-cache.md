# Chat history caching

Bot DMs and groups share a memory and disk history cache owned by `MessagingStore`.
Opening a previously visited destination adopts its cached messages synchronously
and refreshes from the server in the background. Readers share outstanding
requests for the same destination and page cursor. Identical responses do not
publish another history update. Refreshes fill gaps and retain loaded older pages.

The cache retains at most 24 conversations and approximately 8 MB of payload.
Eviction removes a whole background snapshot; it does not truncate an open
reader's history. Connection and verified identity changes clear the cache and
cancel outstanding reads. Mutation invalidation prevents older requests from
overwriting a send receipt or resurrecting a deleted conversation. Successful
send receipts appear immediately, and queued/running replies retain one-second
polling rather than reverting to the idle four-second interval.

`MessagingTranscriptProjection` keeps the message index and prepared display
rows across view updates. It reuses one timestamp formatter and replaces only
rows whose source content or mention profile data changed. Draft and run updates
therefore do not repeat transcript conversion. Typed messaging response decoding
and JSON serialization execute outside the main actor.

Regular session navigation uses a separate memory and disk full-content cache,
bounded to 12 sessions, 6,000 messages, and 16 MiB of estimated text. It restores
the transcript and its pagination window while normal server reconciliation
continues. Full snapshots are evicted instead of dropping part of a loaded
prefix. Authoritative durable identity and profile matching prevent reused
runtime aliases from selecting another conversation. Refreshing connection tickets preserves these snapshots. Explicit account or
server replacement retires the saved namespace. Pending decision controls remain governed by
the existing presentation cache and authoritative resume admission.

Transcript snapshots are written atomically to protected, backup-excluded app cache
files on a serial background queue. They expire after seven days. Bot storage is
bounded globally to 24 conversations and 8 MB; regular sessions retain up to 12
sessions, 6,000 messages and 16 MiB per partition, with at most four partitions.
iOS may evict cache files under storage pressure; a miss falls back to normal
server pagination. Run status and pending decision authority are never restored
from these snapshots.

The currently visible session is saved through the existing coalesced transcript
flush and when the app backgrounds, not only when navigating away. Cold launch
restores the last admitted transcript before connection/network completion.
Sending and runtime controls remain synchronizing until the server verifies the
session. Notification-directed launches do not display an unrelated last chat.

The Bots catalog persists profile IDs, display names and conversation summaries
for up to seven days, bounded to four partitions and 256 KiB. A random namespace
belongs to the saved logical connection. It survives app restarts, single-use
ticket minting and cookie rotation, and also works for local connections without
session cookies. Explicit sign-in/account replacement, sign-out and server
changes retire that namespace. Verified messaging principal changes fence both
bot and regular-session cached display.

Returning to the saved connection restores catalog names and pins before network
discovery, then hydrates visited bot histories from disk. Cached conversations
can be opened read-only while discovery is pending. Fresh capabilities remain
necessary for messaging writes. Authentication failures and confirmed missing or
disabled messaging purge bot caches; transient transport failures retain them.

The regular session profile picker already restores its known profile names
from local preferences. That existing cache is separate from the Bots catalog.

Regression coverage lives in `MessagingHistoryCacheTests`,
`MessagingTranscriptProjectionTests`, `MessagingServiceDecodingTests`, and
`SessionTranscriptCacheTests`, alongside the existing messaging, resume,
identity, pagination, and viewport suites. Cold-launch coverage additionally lives
in `MessagingHistoryPersistenceTests`, `SessionTranscriptPersistenceTests`,
`AppStateTranscriptPersistenceTests`, `MessagingCatalogCacheTests`, and
`ConnectionCacheNamespaceStoreTests`.
