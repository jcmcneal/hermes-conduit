# bot-coms-messaging companion

Persistent Conduit DMs and groups, using bot-coms as a local transport. This is the server half of the Conduit messaging implementation. It is source code to review and install on the Hermes server; creating this directory does not install or enable anything.

## Compatibility and current limits

Requires Python 3.11+, FastAPI with Pydantic 2, bot-coms 0.1+, and Hermes with:

- Explicitly enabled dashboard plugin APIs (`dashboard/manifest.json`).
- Verified dashboard identities on `request.state.session` (`provider`, `user_id`, optional `org_id`). Older identity-free token authentication is rejected.
- `hermes -p <profile> chat --in '~' -Q --max-turns N --query-file <path>` with the quiet-mode contract: only the final answer on stdout, diagnostics and session ID on stderr.

These interfaces were inspected in the local Hermes checkout on 2026-09-08. The companion uses no session-resume operation and changes no approval policies. A fresh CLI run inherits the configured profile's tools and headless approval policy. This release has final replies and run statuses; it does not advertise streaming, mobile approval actions, attachments, voice, or push. Continue using Sessions when those interfaces are needed. A denied approval or headless clarification follows the profile's existing Hermes behavior; the companion does not synthesize a mobile decision card.

One worker run per configured messaging peer is enforced with an inherited POSIX lock. Up to eight different peers may execute at once. The companion uses a **dedicated spool** and does not claim or route unrelated board messages. This serializes messaging work per peer, not other Hermes/board work using a different spool. Installations requiring one execution across all systems must coordinate their workers before deploying this version.

Historical context is the latest 100 shared messages, bounded to 48,000 characters through the triggering message. The full log persists in SQLite. Versioned summaries and nested threads are not implemented. Very old context must be restated by the user.

## Install after review

Run on the Hermes host, using its Python environment. Paths below are placeholders to substitute, not commands Conduit executes automatically:

```sh
/path/to/hermes/python -m pip install /path/to/bot-coms
/path/to/hermes/python -m pip install /path/to/hermes-conduit/server/bot-coms-messaging
```

Copy this directory's `dashboard` folder into:

```text
<shared Hermes root>/plugins/bot-coms-messaging/dashboard/
```

The resulting dashboard manifest must be readable by Hermes. Add `bot-coms` and `bot-coms-messaging` to the shared instance's existing `plugins.enabled` list while preserving all other entries. Enable bot-coms for participating profiles as required by that deployment. The companion is a dashboard plugin; it does not add model tools or require bot-coms-board. Do not enable arbitrary coding tools or change approvals to enable messaging.

Create `<shared Hermes root>/plugin-data/bot-coms-messaging/config.json` with owner-only directory/file permissions. Use generated immutable IDs and an explicit account allowlist:

```json
{
  "server_id": "generate-an-installation-uuid-once",
  "hermes_executable": "/absolute/path/to/hermes",
  "max_turns": 12,
  "run_timeout_seconds": 600,
  "profiles": [
    {
      "id": "generate-a-profile-uuid-once",
      "peer": "swe",
      "name": "swe",
      "display_name": "SWE",
      "enabled": true,
      "principals": ["provider:user-id"]
    }
  ]
}
```

Get the authenticated identity from Hermes' `/api/auth/me`. Principal format is `provider:user_id`, or `provider:user_id:org_id` when an organization ID exists. The API derives this from the verified session, never from a request header. Review the account-to-profile allowlist; messages for one account are not visible to another.

Keep `server_id` stable across restarts/upgrades. Keep profile `id` stable across display-name changes, and update `name` only when renaming the same Hermes profile. A deleted/recreated profile must receive a new ID even if its name is reused. Remove the old profile's access before replacing it. This adapter's identity registry is explicit configuration; it does not guess identity from profile display names.

Start the worker using the same Python environment:

```sh
/path/to/hermes/python -m bot_coms_messaging.worker --root /absolute/shared-hermes-root/plugin-data/bot-coms-messaging
```

Use the server's existing service manager to supervise that command. Do not attach worker lifetime to the iOS app. Schedule a dashboard restart after active work can safely be interrupted so Hermes mounts the newly enabled API. The worker initializes its own local POSIX spool; network filesystems are unsupported.

In Conduit, choose Messaging → Check again. Readiness requires authenticated access, eligible profiles, compatible API v1, and a recent worker heartbeat. Installed-only or a stopped worker does not unlock sending. There is no managed-install endpoint or fake setup job in this version.

## Data and recovery

Data lives under `plugin-data/bot-coms-messaging`, outside the removable plugin installation directory:

- `messages.sqlite` (+ WAL): messages, memberships, read state, runs, ordered events, transactional dispatch outbox.
- `spool/`: bot-coms delivery/ack state.
- `locks/`: inherited per-peer launch locks.
- `runs/<dispatch-id>/`: bounded query, final answer, and private diagnostic log. These may contain sensitive shared conversation content; keep owner-only permissions.

Accepted sends commit message and recipient dispatches in one transaction. Retries reuse a client message ID and return the existing receipt. First sends from multiple devices resolve one DM. A recorded launch interrupted before completion is marked Needs attention once its child lease is gone. It is never blindly relaunched: external tool effects may already have occurred. Cancellation signals the CLI process group; it does not undo completed effects.

Membership and account access are checked on acceptance, execution, and final publication. Group removal cancels queued/running member work. Archive only removes a conversation from the normal inbox; it does not delete history or cancel work. Reopening a DM preserves its original identity.

Back up the data directory using SQLite-aware backup/snapshot procedures. There is no automatic retention/deletion policy in this release. Disabling/uninstalling the plugin must preserve the data directory; deletion is a separate administrator operation. Native drafts and pending send IDs are stored locally per server/principal/conversation; no outbound message is sent merely because a draft exists.

## Verification

Use an isolated test environment; never run tests against live Hermes data:

```sh
python -m venv /tmp/messaging-tests
/tmp/messaging-tests/bin/python -m pip install pytest fastapi httpx /path/to/bot-coms
PYTHONPATH=server/bot-coms-messaging/src /tmp/messaging-tests/bin/python -m pytest server/bot-coms-messaging/tests -q
```

Tests exercise real SQLite transactions, real bot-coms spool delivery, an authenticated FastAPI test application, and the actual subprocess runner with an inert fake Hermes executable. They do not call a model, launch a live Hermes session, or alter server configuration. A production smoke test remains required after installation with the deployment's actual profiles and model provider.

### API identity binding

After `/v1/capabilities`, every conversation, event, and mutation request must include `expected_server` and `expected_principal` query parameters matching the returned capability identity. These are additional consistency checks, never substitutes for authentication. They prevent an old device draft from being accepted under a different account after cookie rotation or a different server after host replacement. Conduit supplies them automatically.
