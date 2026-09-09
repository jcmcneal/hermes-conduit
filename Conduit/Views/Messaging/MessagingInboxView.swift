import SwiftUI

struct MessagingInboxView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: MessagingStore
    @Binding var requestedAction: String?
    let openSession: (String) -> Void
    let openProfileSessions: (String) -> Void
    let openMessaging: (MessagingDestination) -> Void
    @State private var filter = "All"
    @State private var search = ""
    @State private var newGroup = false
    @State private var showArchived = false
    @State private var chooseBot = false
    @State private var pendingDestination: MessagingDestination?

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(store.profiles) { profile in
                        Button {
                            openMessaging(MessagingDestination(conversationID: nil, profileID: profile.id))
                        } label: {
                            VStack(spacing: 6) {
                                AgentAvatar(profileID: profile.name, displayName: profile.displayName, photoURL: appState.profileAvatarURL(for: profile.name), size: 58, state: appState.avatarState(for: profile.name))
                                Text(profile.displayName).font(.caption).lineLimit(1)
                            }.frame(width: 78)
                        }.buttonStyle(.plain).disabled(!store.isReady).accessibilityLabel(profile.displayName)
                    }
                }.padding(.horizontal, 16)
            }
            Picker("Inbox filter", selection: $filter) {
                ForEach(["All", "Messages", "Sessions"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 16)
            HStack {
                TextField("Search names and previews", text: $search).textFieldStyle(.roundedBorder)
                Menu {
                    Toggle("Show archived messages", isOn: $showArchived)
                    Button("Refresh") { Task { await store.refresh() } }
                } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 44, height: 44) }
            }.padding(.horizontal, 16)
            if !store.isReady { Text(store.availability.explanation).font(.footnote).padding(.horizontal) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if filter != "Sessions" {
                        Text("Messages").font(.headline).padding(.vertical, 6)
                        ForEach(visibleMessages) { conversation in
                            Button {
                                openMessaging(
                                    conversation.kind == "dm"
                                        ? MessagingDestination(conversationID: nil, profileID: conversation.profiles.first)
                                        : MessagingDestination(conversationID: conversation.id, profileID: nil)
                                )
                            } label: { messageRow(conversation) }.buttonStyle(.plain)
                        }
                        if visibleMessages.isEmpty {
                            Text("Tap a bot to start a DM, or create a group.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical)
                        }
                    }
                    if filter != "Messages" {
                        HStack {
                            Text("Sessions: \(appState.profileDisplayName(appState.activeProfile))").font(.headline)
                            Spacer()
                            Button("Browse") { openProfileSessions(appState.activeProfile) }.font(.subheadline)
                        }.padding(.top, 14)
                        ForEach(appState.sessions.filter { !$0.isArchived && ($0.profile ?? appState.activeProfile) == appState.activeProfile && matches($0.title) }) { session in
                            Button { openSession(session.id) } label: {
                                ConversationRow(session: session, secondaryLine: "Session · " + appState.profileDisplayName(appState.activeProfile), isPinned: appState.isSessionPinned(session), isSelected: false)
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(.horizontal, 20)
            }.refreshable { await store.refresh() }
        }
        .onAppear {
            let saved = UserDefaults.standard.string(forKey: filterKey) ?? "All"
            filter = ["All", "Messages", "Sessions"].contains(saved) ? saved : "All"
        }
        .onChange(of: filter) { _, value in UserDefaults.standard.set(value, forKey: filterKey) }
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
    private var filterKey: String { "conduit.messaging.filter." + (store.capability?.scope ?? "") }
    private func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }
    private var visibleMessages: [MessagingConversation] {
        store.conversations.filter { ($0.archived == showArchived) && (matches($0.title) || matches($0.preview)) }
            .sorted { a, b in a.pinned != b.pinned ? a.pinned : (a.updatedAt == b.updatedAt ? a.id < b.id : a.updatedAt > b.updatedAt) }
    }
    private func messageRow(_ conversation: MessagingConversation) -> some View {
        HStack(spacing: 12) {
            if conversation.kind == "dm", let profile = store.profiles.first(where: { $0.id == conversation.profiles.first }) {
                AgentAvatar(profileID: profile.name, displayName: profile.displayName, photoURL: appState.profileAvatarURL(for: profile.name), size: 40, state: appState.avatarState(for: profile.name))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "person.2.circle.fill").font(.system(size: 36)).foregroundStyle(Color.conduitAccent).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(conversation.title).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(Date(timeIntervalSince1970: conversation.updatedAt), format: .relative(presentation: .numeric, unitsStyle: .abbreviated)).font(.caption).foregroundStyle(.secondary)
                }
                Text(conversation.preview.isEmpty ? (conversation.kind == "group" ? "Group conversation" : "Direct message") : conversation.preview)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            if conversation.unread > 0 { Circle().fill(Color.conduitAccent).frame(width: 8, height: 8).accessibilityLabel("Unread") }
        }.padding(.vertical, 10).contentShape(Rectangle()).accessibilityElement(children: .combine)
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
                Text("Every member can read this group's shared messages. Use the To: menu to address bots; otherwise the default responder answers.").font(.footnote)
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
