# Chat history caching

Bot DMs and groups now share an in-memory history cache owned by `MessagingStore`.
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

Regular session navigation uses a separate process-local full-content cache,
bounded to 12 sessions, 6,000 messages, and 16 MiB of estimated text. It restores
the transcript and its pagination window while normal server reconciliation
continues. Full snapshots are evicted instead of dropping part of a loaded
prefix. Authoritative durable identity and profile matching prevent reused
runtime aliases from selecting another conversation. Changing connection
credentials clears these snapshots, so cross-profile flows that mint a new
ticket intentionally start cold. Pending decision controls remain governed by
the existing presentation cache and authoritative resume admission.

These caches are not written to disk and do not bypass server validation. They
improve navigation within an authenticated app session; they are not an offline
message database. Cold app launches still fetch history.

Regression coverage lives in `MessagingHistoryCacheTests`,
`MessagingTranscriptProjectionTests`, `MessagingServiceDecodingTests`, and
`SessionTranscriptCacheTests`, alongside the existing messaging, resume,
identity, pagination, and viewport suites.
