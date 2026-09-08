import SwiftUI

struct MessagingFeatureCard: View {
    let open: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title2).foregroundStyle(Color.conduitAccent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Give your bots a shared inbox").font(.headline)
                Text("Keep ongoing DMs and bring multiple bots into group conversations.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Enable messaging", action: open).font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("messaging.enable")
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").frame(width: 32, height: 32) }
                .accessibilityLabel("Dismiss messaging introduction")
        }
        .padding(16).background(Color.conduitRaisedSurface, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct MessagingFeatureSheet: View {
    @ObservedObject var store: MessagingStore
    let server: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 46)).foregroundStyle(Color.conduitAccent).accessibilityHidden(true)
                    Text("A shared inbox for your bots").font(.largeTitle.bold())
                    benefit("Ongoing DMs", "Return to the same conversation with a bot, across separate runs.", "person.crop.circle")
                    benefit("Group conversations", "Bring profiles together and mention the ones you want to hear from.", "person.2")
                    benefit("Work on your server", "With a configured worker, conversations can continue while Conduit is closed.", "server.rack")
                    Divider()
                    Text(server).font(.headline).textSelection(.enabled)
                    Text(store.availability.explanation).foregroundStyle(.secondary)
                    if store.isReady {
                        Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                    } else {
                        Text("Set up on Hermes").font(.headline)
                        Text("Your server administrator needs to install bot-coms and the bot-coms-messaging companion, enable them, and configure the participating profiles and worker. Existing sessions keep working during setup.")
                        Text("This server does not provide a reviewed, resumable messaging installer. Conduit cannot install it automatically here.")
                            .font(.footnote).foregroundStyle(.secondary)
                        ShareLink(item: Self.instructions) { Label("Share setup checklist", systemImage: "square.and.arrow.up") }
                        Button { Task { await store.refresh() } } label: {
                            if store.isRefreshing { ProgressView() } else { Label("Check again", systemImage: "arrow.clockwise") }
                        }.buttonStyle(.borderedProminent).disabled(store.isRefreshing)
                    }
                }.padding(24)
            }
            .navigationTitle("Messaging").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
    private func benefit(_ title: String, _ description: String, _ symbol: String) -> some View {
        Label { VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(description).foregroundStyle(.secondary) } }
        icon: { Image(systemName: symbol).frame(width: 24) }
    }
    static let instructions = """
    Enable Conduit messaging on Hermes:
    1. Install bot-coms in the Hermes Python environment.
    2. Install the bot-coms-messaging companion from Conduit's server/bot-coms-messaging directory, following its README.
    3. Enable both plugins and configure stable profile IDs, access, and the messaging worker.
    4. Restart the dashboard when existing work can be safely interrupted, then verify the worker.
    5. In Conduit, open Messaging and tap Check again.
    Installation alone does not enable messaging: the adapter must report API v1 readiness. Do not change existing session approval defaults.
    """
}

/// Settings creates its own read-only discovery owner; it never runs an installer.
struct MessagingSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var store = MessagingStore()
    var body: some View {
        MessagingFeatureSheet(store: store, server: appState.connection?.baseUrl ?? "Hermes")
            .task(id: appState.dashboardTicketBridge.map(ObjectIdentifier.init)) {
                store.connect(requester: appState.dashboardTicketBridge, scope: appState.connection?.baseUrl ?? "")
                await store.refresh()
            }
    }
}
