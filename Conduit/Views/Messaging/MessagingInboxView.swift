import SwiftUI

/// Bots home: pin-able DM shelf plus existing groups.
struct MessagingInboxView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: MessagingStore
    @Binding var requestedAction: String?
    let openMessaging: (MessagingDestination) -> Void
    var showFeatureCard: Bool = false
    var onOpenFeatureCard: () -> Void = {}
    var pinnedSize: CGFloat = ConduitInboxMetrics.profileRailSizePhone
    var unpinnedSize: CGFloat = ConduitInboxMetrics.profileShelfUnpinnedSize
    @State private var newGroup = false
    @State private var chooseBot = false
    @State private var pendingDestination: MessagingDestination?

    private var pinnedProfiles: [MessagingProfile] {
        let known = Dictionary(uniqueKeysWithValues: store.profiles.map { ($0.id, $0) })
        return store.pinnedBotIDs.compactMap { known[$0] }
    }

    private var unpinnedProfiles: [MessagingProfile] {
        let pinned = Set(store.pinnedBotIDs)
        return store.profiles.filter { !pinned.contains($0.id) }
    }

    private var pinnedColumns: [GridItem] {
        [GridItem(.adaptive(minimum: pinnedSize + 12, maximum: pinnedSize + 28), spacing: 16)]
    }

    var body: some View {
        VStack(spacing: 12) {
            if showFeatureCard {
                MessagingFeatureCard(open: onOpenFeatureCard, dismiss: store.dismissCard)
                    .padding(.horizontal, 16)
            }
            if !store.isReady {
                Text(store.availability.explanation)
                    .font(.footnote)
                    .foregroundStyle(Color.conduitSecondaryText)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !pinnedProfiles.isEmpty {
                        LazyVGrid(columns: pinnedColumns, alignment: .leading, spacing: 16) {
                            ForEach(pinnedProfiles) { profile in
                                pinnedCell(profile)
                            }
                        }
                    }

                    if !unpinnedProfiles.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            if !pinnedProfiles.isEmpty {
                                Text("More")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.conduitSecondaryText)
                                    .padding(.bottom, 4)
                            }
                            ForEach(unpinnedProfiles) { profile in
                                unpinnedRow(profile)
                            }
                        }
                    } else if store.isReady && store.profiles.isEmpty {
                        Text("No bots are available for messaging yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical)
                    }

                    groupsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable { await store.refresh() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: requestedAction) { _, action in
            if action == "message" { chooseBot = true }
            if action == "group" { newGroup = true }
            requestedAction = nil
        }
        .sheet(isPresented: $chooseBot, onDismiss: {
            if let pendingDestination {
                openMessaging(pendingDestination)
            }
            pendingDestination = nil
        }) {
            NavigationStack {
                List(store.profiles) { profile in
                    Button(profile.displayName) {
                        pendingDestination = MessagingDestination(conversationID: nil, profileID: profile.id)
                        chooseBot = false
                    }
                }.navigationTitle("Message a bot")
            }
        }
        .sheet(isPresented: $newGroup, onDismiss: {
            if let pendingDestination {
                openMessaging(pendingDestination)
            }
            pendingDestination = nil
        }) {
            NewMessagingGroupSheet(store: store) { conversation in
                pendingDestination = MessagingDestination(conversationID: conversation.id, profileID: nil)
            }
        }
    }

    private func pinnedCell(_ profile: MessagingProfile) -> some View {
        Button {
            openDM(profile)
        } label: {
            VStack(spacing: 8) {
                AgentAvatar(
                    profileID: profile.name,
                    displayName: profile.displayName,
                    photoURL: appState.profileAvatarURL(for: profile.name),
                    size: pinnedSize,
                    state: appState.avatarState(for: profile.name)
                )
                Text(profile.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.conduitPrimaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: pinnedSize + 8)
            }
        }
        .buttonStyle(.plain)
        .disabled(!store.isReady)
        .contextMenu { pinMenu(for: profile) }
        .accessibilityLabel(profile.displayName)
        .accessibilityHint("Opens a direct message with this bot")
    }

    private func unpinnedRow(_ profile: MessagingProfile) -> some View {
        Button {
            openDM(profile)
        } label: {
            HStack(spacing: 14) {
                AgentAvatar(
                    profileID: profile.name,
                    displayName: profile.displayName,
                    photoURL: appState.profileAvatarURL(for: profile.name),
                    size: unpinnedSize,
                    state: appState.avatarState(for: profile.name)
                )
                Text(profile.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.conduitPrimaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.conduitSecondaryText)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!store.isReady)
        .contextMenu { pinMenu(for: profile) }
        .accessibilityLabel(profile.displayName)
        .accessibilityHint("Opens a direct message with this bot")
    }

    @ViewBuilder
    private var groupsSection: some View {
        let groups = store.visibleGroupConversations
        let canGroup = store.capability?.supportsGroups == true
        if canGroup || !groups.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Groups")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.conduitSecondaryText)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)

                if groups.isEmpty {
                    Text("Create a group to chat with several bots at once.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(groups) { conversation in
                        groupRow(conversation)
                    }
                }
            }
        }
    }

    private func groupRow(_ conversation: MessagingConversation) -> some View {
        Button {
            openMessaging(MessagingDestination(conversationID: conversation.id, profileID: nil))
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.2.circle.fill")
                    .font(.system(size: unpinnedSize - 4))
                    .foregroundStyle(Color.conduitAccent)
                    .frame(width: unpinnedSize, height: unpinnedSize)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(conversation.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.conduitPrimaryText)
                            .lineLimit(1)
                        if conversation.pinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.conduitSecondaryText)
                                .accessibilityHidden(true)
                        }
                        Spacer(minLength: 0)
                        Text(
                            Date(timeIntervalSince1970: conversation.updatedAt),
                            format: .relative(presentation: .numeric, unitsStyle: .abbreviated)
                        )
                        .font(.caption)
                        .foregroundStyle(Color.conduitSecondaryText)
                    }
                    Text(conversation.preview.isEmpty ? "Group conversation" : conversation.preview)
                        .font(.subheadline)
                        .foregroundStyle(Color.conduitSecondaryText)
                        .lineLimit(1)
                }
                if conversation.unread > 0 {
                    Circle()
                        .fill(Color.conduitAccent)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Unread")
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.conduitSecondaryText)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!store.isReady)
        .accessibilityLabel(conversation.title)
        .accessibilityHint("Opens this group conversation")
    }

    @ViewBuilder
    private func pinMenu(for profile: MessagingProfile) -> some View {
        Button {
            Haptics.light()
            withAnimation(ConduitMotion.response) {
                store.toggleBotPinned(profile.id)
            }
        } label: {
            Label(
                store.isBotPinned(profile.id) ? "Unpin" : "Pin",
                systemImage: store.isBotPinned(profile.id) ? "pin.slash" : "pin"
            )
        }
    }

    private func openDM(_ profile: MessagingProfile) {
        openMessaging(MessagingDestination(conversationID: nil, profileID: profile.id))
    }
}

struct NewMessagingGroupSheet: View {
    @ObservedObject var store: MessagingStore
    let created: (MessagingConversation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: Set<String> = []
    @State private var responder = ""
    @State private var saving = false
    @State private var error: String?
    @State private var requestID = UUID().uuidString
    @State private var result: MessagingConversation?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Group name", text: $name)
                Section("Bots") {
                    ForEach(store.profiles) { profile in
                        Toggle(profile.displayName, isOn: Binding(get: { members.contains(profile.id) }, set: { value in
                            if value { members.insert(profile.id); if responder.isEmpty { responder = profile.id } }
                            else { members.remove(profile.id); if responder == profile.id { responder = members.sorted().first ?? "" } }
                        }))
                    }
                }
                Picker("Default responder", selection: $responder) {
                    Text("Choose a bot").tag("")
                    ForEach(store.profiles.filter { members.contains($0.id) }) { Text($0.displayName).tag($0.id) }
                }
                Text("Every member can read this group's shared messages. Leave To: on Auto to let turn-taking choose who speaks; the default responder is only used if that call fails. Use the To: menu to address specific bots.").font(.footnote)
                if let error { Text(error).foregroundStyle(.red) }
            }.disabled(saving)
                .navigationTitle("New group")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            saving = true
                            Task {
                                do { let value = try await store.createGroup(name: name, members: members.sorted(), responder: responder, requestID: requestID); result = value; created(value); dismiss() }
                                catch { self.error = error.localizedDescription }
                                saving = false
                            }
                        }.disabled(saving || members.count < 2 || responder.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }

    }
}
