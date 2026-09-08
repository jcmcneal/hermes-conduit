import Foundation

/// Seed prompt for agent-assisted persistent messaging setup.
/// Embeds the full checklist so setup works even when the messaging-setup skill is not loaded yet.
enum MessagingSetupPrompt {
    static let text = """
    Set up persistent bot messaging on this Hermes host.

    If the `messaging-setup` skill is available, follow it. Otherwise follow this checklist (also in https://github.com/jcmcneal/bot-coms docs/INSTALL.md § Persistent messaging). Board / bot-coms-board is NOT required.

    1. In the Hermes Python environment, install messaging:
       pip install -e "/path/to/bot-coms[messaging]"
       or: pip install "bot-coms[messaging] @ git+https://github.com/jcmcneal/bot-coms.git"
    2. bot-coms-messaging install-dashboard --hermes-root /absolute/shared-hermes-root
    3. Add bot-coms and bot-coms-messaging to plugins.enabled without removing other entries. Enable bot-coms for participating profiles as needed.
    4. Write plugin-data/bot-coms-messaging/config.json with owner-only permissions, stable UUIDs, hermes_executable, and principals from /api/auth/me (provider:user_id or provider:user_id:org_id). Do not use peer name `inbox` for a bot profile.
    5. Supervise: python -m bot_coms_messaging.worker --root /absolute/shared-hermes-root/plugin-data/bot-coms-messaging
    6. Restart the dashboard/gateway only after I confirm active work can be interrupted.
    7. Tell me to open Messaging in my client and tap Check again. Installation alone is not readiness — need API v1, eligible profiles, and a recent worker heartbeat.

    Prefer proposing exact commands and seeking approval. Do not invent principals, wipe plugins.enabled, or change approval defaults.
    """

    static let shareChecklist = """
    Enable persistent messaging on Hermes:
    1. pip install -e "/path/to/bot-coms[messaging]"
       or: pip install "bot-coms[messaging] @ git+https://github.com/jcmcneal/bot-coms.git"
       (https://github.com/jcmcneal/bot-coms)
    2. bot-coms-messaging install-dashboard --hermes-root /path/to/shared-hermes-root
    3. Enable bot-coms and bot-coms-messaging; write plugin-data/bot-coms-messaging/config.json; supervise bot-coms-messaging-worker (see bot-coms docs/INSTALL.md § Persistent messaging). Board is not required.
    4. Optional: point skills.external_dirs at bot-coms/skills so the messaging-setup skill is available.
    5. Restart the dashboard when existing work can be safely interrupted, then verify the worker.
    6. In your client, open Messaging and tap Check again.
    Installation alone does not enable messaging: the adapter must report API v1 readiness. Do not change existing session approval defaults.
    """
}
