import SwiftUI

struct MessagingConversationView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var owner: MessagingStore
    @StateObject private var model: MessagingConversationStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sizeCategory) private var sizeCategory
    @AppStorage(ChatTypography.preferenceKey) private var chatTextSizeRaw = ChatTypography.defaultSize.rawValue
    @State private var recipients: Set<String> = []
    @State private var showMembers = false
    @State private var showRuns = false
    @State private var viewportHeight: CGFloat = 0
    @State private var isAtBottom = true
    /// When true, the conversation host owns navigation chrome (Back / title).
    var embedsInHost: Bool = false
    var onClose: (() -> Void)? = nil
    let openSessions: (String) -> Void

    init(
        destination: MessagingDestination,
        owner: MessagingStore,
        embedsInHost: Bool = false,
        onClose: (() -> Void)? = nil,
        openSessions: @escaping (String) -> Void
    ) {
        self.owner = owner
        self.embedsInHost = embedsInHost
        self.onClose = onClose
        _model = StateObject(wrappedValue: MessagingConversationStore(destination: destination, owner: owner))
        self.openSessions = openSessions
    }

    private var chatTextSize: ChatTextSize {
        ChatTypography.resolve(rawValue: chatTextSizeRaw)
    }

    private var title: String {
        model.history?.conversation.title
            ?? owner.profiles.first { $0.id == model.destination.profileID }?.displayName
            ?? "Messages"
    }

    var body: some View {
        Group {
            if embedsInHost {
                conversationBody
            } else {
                NavigationStack {
                    conversationBody
                        .navigationTitle(title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { standaloneToolbar }
                }
            }
        }
        .environment(\.chatTextSize, chatTextSize)
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
        .onChange(of: owner.generation) { _, _ in close() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if model.pending != nil { await model.checkDelivery() }
            while !Task.isCancelled {
                await model.load()
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
            }
        }
    }

    private var conversationBody: some View {
        VStack(spacing: 0) {
            if embedsInHost {
                HStack {
                    Spacer(minLength: 0)
                    messagingActionsMenu
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            if !model.canWrite { Text(owner.availability.explanation).font(.footnote).padding() }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.history?.before != nil {
                            Button("Load earlier messages") { Task { await model.load(older: true) } }
                        }
                        if model.history?.messages.isEmpty != false {
                            ContentUnavailableView(
                                "Message \(title)",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text("This conversation stays here as your bot starts new runs.")
                            )
                        }
                        ForEach(model.history?.messages ?? []) { message in
                            messagingBubble(message)
                                .id(message.id)
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: MessagingVisibleMessages.self,
                                        value: [message.sequence: geometry.frame(in: .named("messagingScroll"))]
                                    )
                                })
                        }
                        ForEach(model.history?.runs ?? []) { run in
                            if run.status != "completed" {
                                Label(
                                    "\(profileName(run.profile)): \(run.status.replacingOccurrences(of: "_", with: " "))",
                                    systemImage: run.status == "running" ? "gearshape.2" : "clock"
                                )
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
                    if let last = model.history?.messages.last, let frame = frames[last.sequence] {
                        isAtBottom = frame.maxY <= viewportHeight + 40
                    } else if model.history?.messages.isEmpty == false {
                        isAtBottom = false
                    }
                    if let sequence = frames.filter({ $0.value.maxY > 0 && $0.value.maxY <= viewportHeight }).keys.max() {
                        Task { await model.markRead(through: sequence) }
                    }
                }
                .onChange(of: model.history?.messages.last?.id) { old, new in
                    if let new, old == nil || isAtBottom { proxy.scrollTo(new, anchor: .bottom) }
                }
            }
            if let error = model.error {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            if model.history?.conversation.archived == true {
                Button("Reopen conversation") { Task { await model.updateUserState(["archived": false]) } }.padding()
            } else {
                composer
            }
        }
        .background(Color.conduitCanvas)
    }

    @ViewBuilder
    private func messagingBubble(_ message: MessagingMessage) -> some View {
        let chat = chatMessage(from: message)
        if message.author == "user" {
            UserBubble(message: chat, gatewayResolver: nil)
        } else if let profile = owner.profiles.first(where: { $0.id == message.author }) {
            SettledAssistantMessageContent(
                message: chat,
                displayName: profile.displayName,
                avatarURL: appState.profileAvatarURL(for: profile.name),
                profileID: profile.name,
                gatewayResolver: nil,
                sizeCategory: sizeCategory,
                chatTextSize: chatTextSize
            )
            .equatable()
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            SettledAssistantMessageContent(
                message: chat,
                displayName: profileName(message.author),
                avatarURL: nil,
                profileID: message.author,
                gatewayResolver: nil,
                sizeCategory: sizeCategory,
                chatTextSize: chatTextSize
            )
            .equatable()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chatMessage(from message: MessagingMessage) -> ChatMessage {
        ChatMessage(
            id: message.id,
            role: message.author == "user" ? .user : .assistant,
            content: message.body,
            timestamp: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: message.createdAt)),
            author: message.author == "user" ? nil : message.author
        )
    }

    @ToolbarContentBuilder
    private var standaloneToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Bots") { close() }
        }
        ToolbarItem(placement: .primaryAction) {
            messagingActionsMenu
        }
    }

    private var messagingActionsMenu: some View {
        HStack {
            if participants.count == 1, let profile = participants.first {
                Button("Sessions") { openSessions(profile.name) }
            }
            Menu {
                ForEach(participants) { profile in
                    Button("\(profile.displayName) sessions") { openSessions(profile.name) }
                }
                Button("Runs") { showRuns = true }
                if let conversation = model.history?.conversation {
                    if conversation.kind == "group" {
                        Button("Members and group settings") { showMembers = true }
                    }
                    Button(conversation.pinned ? "Unpin" : "Pin") {
                        Task { await model.updateUserState(["pinned": !conversation.pinned]) }
                    }
                    Button(conversation.muted ? "Unmute" : "Mute") {
                        Task { await model.updateUserState(["muted": !conversation.muted]) }
                    }
                    Button(conversation.archived ? "Reopen" : "Archive (work continues)") {
                        Task { await model.updateUserState(["archived": !conversation.archived]) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Conversation actions")
        }
    }

    private var participants: [MessagingProfile] {
        let ids = model.history?.conversation.profiles ?? model.destination.profileID.map { [$0] } ?? []
        return owner.profiles.filter { ids.contains($0.id) }
    }

    private func profileName(_ id: String) -> String {
        owner.profiles.first { $0.id == id }?.displayName ?? id
    }

    private func close() {
        if embedsInHost {
            onClose?()
        } else {
            dismiss()
        }
    }

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
                    Label(
                        recipients.isEmpty
                            ? "To: Default responder"
                            : "To: " + recipients.sorted().map(profileName).joined(separator: ", "),
                        systemImage: "at"
                    )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.conduitPrimaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.conduitRaisedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .accessibilityLabel("Choose responders")
            }
            if model.pending != nil {
                Button("Check delivery") { Task { await model.checkDelivery() } }
                    .disabled(model.sending || !model.canWrite)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message \(title)…", text: $model.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.conduitRaisedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityIdentifier("messaging.composer")
                Button {
                    Task { await model.send(recipients: recipients.sorted()) }
                } label: {
                    if model.sending {
                        ProgressView().frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(Color.conduitAccent)
                            .frame(width: 44, height: 44)
                    }
                }
                .disabled(
                    !model.canWrite
                        || model.sending
                        || model.pending != nil
                        || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.conduitCanvas.opacity(0.98))
    }
}

private struct MessagingVisibleMessages: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
