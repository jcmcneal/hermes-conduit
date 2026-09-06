import SwiftUI

/// Form rendering only: navigation and final validation stay in the flow.
struct ConnectionSetupForm: View {
    @Binding var flow: ConnectionSetupFlow
    let onStartTest: () -> Void
    let onComplete: (ConnectionSetupResult) -> Void
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case host, port, url, username, password }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch flow.step {
                    case .connectionDetails: details
                    case .loginCredentials: credentials
                    case .connectionTest: connectionTest
                    case .review: review
                    default: EmptyView()
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: focusedField) { _, field in
                guard let field else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(field, anchor: .center) }
            }
            .onChange(of: flow.step) { _, _ in focusedField = nil }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
                    .accessibilityIdentifier("setup.keyboard-done")
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(flow.draft.methodTitle).font(.title2.weight(.semibold))
            if flow.draft.usesExistingAddress || flow.accessMethod == .reverseProxy {
                Text(flow.draft.usesExistingAddress
                     ? "Review or edit your current dashboard address, including its port and path."
                     : "Paste the full HTTPS dashboard address Hermes supplied, including any port or path.")
                    .foregroundStyle(.secondary)
                labeled("Dashboard address") {
                    TextField("Dashboard address", text: fullURLBinding)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .url)
                        .submitLabel(.next)
                        .onSubmit { flow.submitDetails() }
                        .accessibilityIdentifier("setup.url")
                        .accessibilityLabel("Dashboard address")
                }.id(Field.url)
            } else {
                Text(flow.accessMethod == .lan
                     ? "Enter the local IP address and port Hermes gave you. You don’t need to type http://."
                     : "Enter the Tailscale hostname or address Hermes gave you. Tailscale Serve hostnames use HTTPS; leave the port blank unless Hermes supplied one.")
                    .foregroundStyle(.secondary)
                labeled(flow.accessMethod == .lan ? "Private LAN IP address" : "Tailscale hostname / address") {
                    TextField(flow.accessMethod == .lan ? "Local IP address" : "Tailscale host or address", text: hostBinding)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .host)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .port }
                        .accessibilityIdentifier("setup.host")
                        .accessibilityLabel(flow.accessMethod == .lan ? "Private LAN IP address" : "Tailscale hostname or address")
                }.id(Field.host)
                labeled(flow.accessMethod == .lan ? "Port" : "Port (optional)") {
                    TextField("Port supplied by Hermes", text: portBinding)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .port)
                        .accessibilityIdentifier("setup.port")
                        .accessibilityLabel(flow.accessMethod == .lan ? "Dashboard port" : "Dashboard port (optional)")
                }.id(Field.port)
                if flow.accessMethod == .tailscale,
                   !ConnectionSetupAddressBuilder.isServeHostname(flow.draft.tailscale.host) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("For a direct address, choose the scheme Hermes supplied.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Picker("Connection scheme", selection: $flow.draft.tailscaleScheme) {
                            Text("Choose scheme").tag(Optional<ConnectionSetupScheme>.none)
                            Text("HTTP").tag(Optional(ConnectionSetupScheme.http))
                            Text("HTTPS").tag(Optional(ConnectionSetupScheme.https))
                        }
                        .accessibilityIdentifier("setup.scheme")
                        .accessibilityLabel("Connection scheme")
                    }
                }
            }
            if let address = try? ConnectionSetupAddressBuilder.build(flow.draft) {
                Text(address).font(.subheadline).textSelection(.enabled)
                    .accessibilityIdentifier("setup.address-preview")
            }
            validationNotice
            nextButton("Continue") { flow.submitDetails() }
        }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Dashboard credentials").font(.title2.weight(.semibold))
            Text("Use your Hermes dashboard username and password. These are not your Tailscale, Cloudflare, or Apple credentials.")
                .foregroundStyle(.secondary)
            labeled("Dashboard username") {
                TextField("Dashboard username", text: $flow.draft.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .accessibilityIdentifier("setup.username")
                    .accessibilityLabel("Dashboard username")
            }.id(Field.username)
            labeled("Dashboard password") {
                SecureField("Dashboard password", text: $flow.draft.password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .password)
                    .submitLabel(.next)
                    .onSubmit { flow.submitCredentials() }
                    .accessibilityIdentifier("setup.password")
                    .accessibilityLabel("Dashboard password")
            }.id(Field.password)
            validationNotice
            nextButton("Test Connection") { flow.submitCredentials() }
        }
    }

    // MARK: - Round 4: staged connection test

    @ViewBuilder
    private var connectionTest: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Test connection").font(.title2.weight(.semibold))
            Text("Conduit will check the dashboard address and try your credentials now. Nothing is saved, and Conduit won’t connect yet — you’ll confirm everything on the Review screen.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ConnectionSetupStageList(state: flow.testState)

            if let failure = flow.testState.failedFailure,
               let stage = flow.testState.failedStage {
                failedTestRecovery(stage: stage, failure: failure)
            } else if flow.hasCurrentSuccessfulTest {
                // Reachable after returning Back from Review: the passing
                // result is still current, so continue without re-testing.
                Button("Continue") { flow.continueToReview() }
                    .buttonStyle(.borderedProminent)
                    .tint(.conduitAccent)
                    .accessibilityIdentifier("setup.test.continue")
            } else if !flow.testState.isRunning {
                Button("Test Connection") { onStartTest() }
                    .buttonStyle(.borderedProminent)
                    .tint(.conduitAccent)
                    .frame(maxWidth: .infinity)
                    .disabled(flow.testState.isRunning)
                    .accessibilityIdentifier("setup.test.run")
            }
        }
    }

    @ViewBuilder
    private func failedTestRecovery(stage: ConnectionSetupTestStage, failure: ConnectionFailure) -> some View {
        let plan = ConnectionSetupTestRecoveryPlan.plan(for: stage, failure: failure)
        VStack(alignment: .leading, spacing: 12) {
            // The stable classified copy — never a raw error string.
            Text(failure.userMessage)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("setup.test.failure")
            HStack(spacing: 16) {
                Button(plan.remediationLabel) {
                    flow.editAfterFailedTest(plan.remediationStep)
                }
                .buttonStyle(.borderedProminent)
                .tint(.conduitAccent)
                .accessibilityIdentifier(
                    plan.remediationStep == .connectionDetails ? "setup.test.edit-details" : "setup.test.edit-credentials"
                )
                if plan.offersRetry {
                    Button("Try Again") { onStartTest() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("setup.test.retry")
                }
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Review").font(.title2.weight(.semibold))
            // The staged result that authorizes this screen: a current
            // successful test, shown with its per-stage outcomes.
            if flow.hasCurrentSuccessfulTest {
                ConnectionSetupStageList(state: flow.testState)
                Text(ConnectionSetupTestState.readyMessage)
                    .font(.headline)
                    .accessibilityIdentifier("setup.test.ready")
            }
            // Revalidate for rendering only: a draft that stopped validating
            // after reaching Review must never silently blank the card.
            reviewContent
            Text("These settings will fill the login form. You’ll tap Connect there when you’re ready.")
                .foregroundStyle(.secondary)
            validationNotice
            Button("Use these settings") {
                if let result = flow.complete() { onComplete(result) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!reviewIsValid)
            .accessibilityIdentifier("setup.use-settings")
        }
    }

    @ViewBuilder private var reviewContent: some View {
        switch flow.reviewState() {
        case .success(let result):
            reviewValue("Connection method", flow.draft.methodTitle)
            reviewValue("Dashboard address", result.serverURL)
            reviewValue("Username", result.username)
            reviewValue("Password", "Entered")
        case .failure(let error):
            VStack(alignment: .leading, spacing: 8) {
                Text("These settings can’t be used yet. Go Back to edit them, then return here.")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(error.message).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("setup.review-invalid")
        }
    }

    private var reviewIsValid: Bool {
        guard flow.hasCurrentSuccessfulTest else { return false }
        if case .success = flow.reviewState() { return true }
        return false
    }

    @ViewBuilder private var validationNotice: some View {
        if let error = flow.validationError {
            Text(error.message).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("setup.validation")
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func reviewValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nextButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title) {
            focusedField = nil
            action()
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("setup.next")
    }

    private var fullURLBinding: Binding<String> {
        flow.draft.usesExistingAddress ? $flow.draft.existingServerURL : $flow.draft.reverseProxyURL
    }
    private var hostBinding: Binding<String> {
        flow.accessMethod == .lan ? $flow.draft.lan.host : $flow.draft.tailscale.host
    }
    private var portBinding: Binding<String> {
        flow.accessMethod == .lan ? $flow.draft.lan.port : $flow.draft.tailscale.port
    }
}

/// The staged connection-test diagnostic list: one row per stage with a
/// state marker. Meaning is carried by text and VoiceOver state words, never
/// by color alone.
struct ConnectionSetupStageList: View {
    let state: ConnectionSetupTestState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ConnectionSetupTestStage.allCases) { stage in
                ConnectionSetupStageRow(
                    stage: stage,
                    stageState: state[stage],
                    label: state.rowLabel(for: stage)
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.06))
    }
}

struct ConnectionSetupStageRow: View {
    let stage: ConnectionSetupTestStage
    let stageState: ConnectionSetupStageState
    let label: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            marker
            Text(label)
                .font(.subheadline.weight(stageState == .pending ? .regular : .semibold))
            Spacer(minLength: 0)
        }
        // One VoiceOver element per stage: the objective name plus a state
        // word, so success/failure never rides on icon or color alone.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage.objectiveLabel), \(stageState.accessibilityState)")
        .accessibilityIdentifier("setup.test.stage.\(stage.identifierName)")
    }

    @ViewBuilder
    private var marker: some View {
        switch stageState {
        case .pending:
            Image(systemName: "circle")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        case .running:
            ProgressView()
                .controlSize(.small)
                .padding(.top, 3)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
                .padding(.top, 2)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.top, 2)
        }
    }
}
