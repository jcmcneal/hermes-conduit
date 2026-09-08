import SwiftUI

struct MessagingConversationView: View {
    @ObservedObject var owner: MessagingStore
    @StateObject private var model: MessagingConversationStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var recipients: Set<String> = []
    @State private var showMembers = false
    @State private var showRuns = false
    @State private var viewportHeight: CGFloat = 0
    @State private var isAtBottom = true
    let openSessions: (String) -> Void

    init(destination: MessagingDestination, owner: MessagingStore, openSessions: @escaping (String) -> Void) {
        self.owner = owner
        _model = StateObject(wrappedValue: MessagingConversationStore(destination: destination, owner: owner))
        self.openSessions = openSessions
    }
    private var title: String {
        model.history?.conversation.title ?? owner.profiles.first { $0.id == model.destination.profileID }?.displayName ?? "Messages"
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !model.canWrite { Text(owner.availability.explanation).font(.footnote).padding() }
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.history?.before != nil {
                            Button("Load earlier messages") { Task { await model.load(older: true) } }
                        }
                        if model.history?.messages.isEmpty != false {
                            ContentUnavailableView("Message \(title)", systemImage: "bubble.left.and.bubble.right", description: Text("This conversation stays here as your bot starts new runs."))
                        }
                        ForEach(model.history?.messages ?? []) { message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.author == "user" ? "You" : profileName(message.author)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                MarkdownText(source: message.body)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: MessagingVisibleMessages.self, value: [message.sequence: geometry.frame(in: .named("messagingScroll"))])
                            })
                        }
                        ForEach(model.history?.runs ?? []) { run in
                            if run.status != "completed" {
                                Label("\(profileName(run.profile)): \(run.status.replacingOccurrences(of: "_", with: " "))", systemImage: run.status == "running" ? "gearshape.2" : "clock")
                                    .font(.footnote).foregroundStyle(.secondary)
                                if !run.detail.isEmpty { Text(run.detail).font(.footnote) }
                            }
                        }
                    }.padding(20)
                }
                .coordinateSpace(name: "messagingScroll")
                .background(GeometryReader { geometry in
                    Color.clear.onAppear { viewportHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, height in viewportHeight = height }
                })
                .onPreferenceChange(MessagingVisibleMessages.self) { frames in
                    guard scenePhase == .active else { return }
                    // Lazy rows may be constructed offscreen. Mark only a message whose end
                    // is actually within the viewport, not merely one whose view appeared.
                    if let last = model.history?.messages.last, let frame = frames[last.sequence] {
                        isAtBottom = frame.maxY <= viewportHeight + 40
                    } else if model.history?.messages.isEmpty == false { isAtBottom = false }
                    if let sequence = frames.filter({ $0.value.maxY > 0 && $0.value.maxY <= viewportHeight }).keys.max() {
                        Task { await model.markRead(through: sequence) }
                    }
                }
                .onChange(of: model.history?.messages.last?.id) { old, new in
                    if let new, old == nil || isAtBottom { proxy.scrollTo(new, anchor: .bottom) }
                }
                }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal) }
                if model.history?.conversation.archived == true {
                    Button("Reopen conversation") { Task { await model.updateUserState(["archived": false]) } }.padding()
                } else {
                    composer
                }
            }
            .background(Color.conduitCanvas)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Inbox") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    HStack {
                    if participants.count == 1, let profile = participants.first {
                        Button("Sessions") { dismiss(); openSessions(profile.name) }
                    }
                    Menu {
                        ForEach(participants) { profile in
                            Button("\(profile.displayName) sessions") { dismiss(); openSessions(profile.name) }
                        }
                        Button("Runs") { showRuns = true }
                        if let conversation = model.history?.conversation {
                            if conversation.kind == "group" { Button("Members and group settings") { showMembers = true } }

                            Button(conversation.pinned ? "Unpin" : "Pin") { Task { await model.updateUserState(["pinned": !conversation.pinned]) } }
                            Button(conversation.muted ? "Unmute" : "Mute") { Task { await model.updateUserState(["muted": !conversation.muted]) } }
                            Button(conversation.archived ? "Reopen" : "Archive (work continues)") { Task { await model.updateUserState(["archived": !conversation.archived]) } }
                        }
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Conversation actions")
                    }
                }
            }
        }
        .sheet(isPresented: $showMembers) {
            if let conversation = model.history?.conversation {
                MessagingGroupSettingsSheet(model: model, owner: owner, conversation: conversation)
            }
        }
        .sheet(isPresented: $showRuns) {
            NavigationStack {
                List(model.history?.runs ?? []) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(profileName(run.profile)).font(.headline)
                        Text(run.status.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.secondary)
                        if !run.detail.isEmpty { Text(run.detail).font(.footnote) }
                        if ["queued", "running"].contains(run.status) {
                            Button("Cancel run", role: .destructive) { Task { await model.cancelRun(run.id) } }
                        }
                    }
                }.navigationTitle("Runs")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showRuns = false } } }
            }
        }
        .onChange(of: model.draft) { _, _ in model.saveDraft() }
        .onChange(of: owner.generation) { _, _ in dismiss() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if model.pending != nil { await model.checkDelivery() }
            while !Task.isCancelled {
                await model.load()
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
            }
        }
    }
    private var participants: [MessagingProfile] {
        let ids = model.history?.conversation.profiles ?? model.destination.profileID.map { [$0] } ?? []
        return owner.profiles.filter { ids.contains($0.id) }
    }
    private func profileName(_ id: String) -> String { owner.profiles.first { $0.id == id }?.displayName ?? id }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.history?.conversation.kind == "group" {
                Menu {
                    ForEach(participants) { profile in
                        Toggle(profile.displayName, isOn: Binding(get: { recipients.contains(profile.id) }, set: { value in
                            if value { recipients.insert(profile.id) } else { recipients.remove(profile.id) }
                        }))
                    }
                } label: {
                    Label(recipients.isEmpty ? "Default responder" : recipients.sorted().map(profileName).joined(separator: ", "), systemImage: "at")
                        .font(.footnote)
                }
            }
            if model.pending != nil {
                Button("Check delivery") { Task { await model.checkDelivery() } }.disabled(model.sending || !model.canWrite)
            }
            HStack(alignment: .bottom) {
                TextField("Message \(title)…", text: $model.draft, axis: .vertical).lineLimit(1...6)
                    .padding(12).background(Color.conduitRaisedSurface, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("messaging.composer")
                Button {
                    Task { await model.send(recipients: recipients.sorted()) }
                } label: {
                    if model.sending { ProgressView().frame(width: 44, height: 44) }
                    else { Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).frame(width: 44, height: 44) }
                }.disabled(!model.canWrite || model.sending || model.pending != nil || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send message")
            }
        }.padding(16)
    }
}

private struct MessagingVisibleMessages: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
