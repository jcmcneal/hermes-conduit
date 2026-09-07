//
//  ConnectionSetupView.swift
//  Conduit
//
//  Guided Connection Setup wizard. The routing lives in
//  ConnectionSetupFlow (unit-tested); this view renders the model's current
//  step and forwards taps as model transitions. Round 1's TLS and Cloudflare
//  quick checks remain available as direct troubleshooting surfaces, reachable
//  from failure-driven help destinations.
//
//  The assistant is strictly opt-in: it opens only from the login card's
//  entry point or a Troubleshoot Connection action, never automatically, and
//  stores no completion state.
//

import SwiftUI
import UIKit

struct ConnectionSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var flow: ConnectionSetupFlow
    @State private var showNotSureGuidance = false
    /// The in-flight staged-test task. Cancelled on any exit from the test
    /// screen and on dismissal; late probe events are additionally dropped
    /// by the flow's generation guard, so correctness never relies on view
    /// destruction.
    @State private var testTask: Task<Void, Never>?
    private let onComplete: (ConnectionSetupResult) -> Void
    private let prober: any ConnectionSetupTesting

    init(
        initialDestination: ConnectionHelpDestination,
        initialDraft: ConnectionSetupDraft = ConnectionSetupDraft(),
        initialCloudflareAccess: CloudflareAccessCredentials? = nil,
        initialCloudflareOriginURL: String = "",
        onComplete: @escaping (ConnectionSetupResult) -> Void
    ) {
        _flow = State(initialValue: ConnectionSetupFlow(
            entry: initialDestination,
            draft: initialDraft,
            inheritedCloudflareAccess: initialCloudflareAccess,
            inheritedCloudflareOriginURL: initialCloudflareOriginURL
        ))
        self.onComplete = onComplete
        self.prober = Self.makeProber()
    }

    private static func makeProber() -> any ConnectionSetupTesting {
        #if DEBUG
        if let stub = ConnectionSetupTestProbeStub.fromLaunchArguments() { return stub }
        #endif
        return ConnectionSetupProbe()
    }

    var body: some View {
        NavigationStack {
            Group {
                switch flow.step {
                case .connectionDetails, .loginCredentials, .connectionTest, .review:
                    ConnectionSetupForm(flow: $flow, onStartTest: { startTestRun() }) { result in
                        onComplete(result)
                        dismiss()
                    }
                default:
                    ScrollView {
                        content
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .accessibilityIdentifier("connection-setup.content")
            .onChange(of: flow.step) { _, newStep in
                // Leaving the test screen for any editable step cancels the
                // probe; a success advance to Review does not.
                guard newStep != .connectionTest, newStep != .review else { return }
                stopTestRun()
            }
            .onDisappear { stopTestRun() }
            .navigationTitle("Connection Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if flow.canGoBack {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            flow.back()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .accessibilityIdentifier("setup.back")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("connection-setup.done")
                }
            }
        }
    }

    // MARK: - Staged connection test

    private func startTestRun() {
        guard let run = try? flow.draft.result(),
              let generation = flow.beginTest() else { return }
        let access = flow.cloudflareAccessForDraft()
        let prober = prober
        let flow = $flow
        testTask?.cancel()
        testTask = Task { @MainActor in
            await prober.runTest(result: run, cloudflareAccess: access, onEvent: { event in
                // Announce only events the model actually applied — dropped
                // stale events never speak.
                guard flow.wrappedValue.applyTestEvent(event, generation: generation) else { return }
                // One completion announcement per run; individual stage
                // transitions stay quiet.
                switch event {
                case .succeeded(.authentication):
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: ConnectionSetupTestState.readyMessage
                    )
                case .requiresInteractiveSignIn(.authentication):
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: ConnectionSetupTestState.interactiveReadyMessage
                    )
                case .failed(_, let failure):
                    UIAccessibility.post(notification: .announcement, argument: failure.userTitle)
                default:
                    break
                }
            })
        }
    }

    private func stopTestRun() {
        testTask?.cancel()
        testTask = nil
        flow.cancelTest()
    }

    // MARK: - Step routing

    @ViewBuilder
    private var content: some View {
        switch flow.step {
        case .dashboard: dashboardStep
        case .credentials: credentialsStep
        case .accessMethod: accessMethodStep
        case .lan: lanBranch
        case .tailscale: tailscaleBranch
        case .reverseProxy: reverseProxyBranch
        case .connectionDetails, .loginCredentials, .connectionTest, .review: EmptyView()
        case .tlsTroubleshooting: troubleshootingStep(.tls)
        case .cloudflareTroubleshooting: troubleshootingStep(.cloudflare)
        }
    }

    // MARK: - Step 1: Dashboard readiness

    private var dashboardStep: some View {
        readinessQuestion(
            progress: flow.progressLabel,
            question: "Is your Hermes dashboard running?",
            explanation: "Hermes Conduit connects to a Hermes dashboard you (or your assistant) run yourself. "
                + "The dashboard has to be up before Conduit can reach it.",
            selectedAnswer: flow.dashboardAnswer,
            onAnswer: { flow.answerDashboard($0) },
            guidance: { dashboardGuidance }
        )
    }

    @ViewBuilder
    private var dashboardGuidance: some View {
        switch flow.dashboardAnswer {
        case .no:
            AskHermesPromptView(title: ConnectionSetupPrompt.dashboardNotRunning.title, prompt: ConnectionSetupPrompt.dashboardNotRunning.text)
            continueButton("Dashboard is ready") { flow.confirmDashboardReady() }
                .accessibilityIdentifier("setup.continue")
        case .unknown:
            AskHermesPromptView(title: ConnectionSetupPrompt.dashboardUnknown.title, prompt: ConnectionSetupPrompt.dashboardUnknown.text)
            continueButton("Dashboard is ready") { flow.confirmDashboardReady() }
                .accessibilityIdentifier("setup.continue")
        default:
            EmptyView()
        }
    }

    // MARK: - Step 2: Dashboard credentials

    private var credentialsStep: some View {
        readinessQuestion(
            progress: flow.progressLabel,
            question: "Do you have your Hermes dashboard login credentials?",
            explanation: "This means the Hermes dashboard username and password you sign in with — not Tailscale, "
                + "Cloudflare, or Apple credentials.",
            selectedAnswer: flow.credentialsAnswer,
            onAnswer: { flow.answerCredentials($0) },
            guidance: { credentialsGuidance }
        )
    }

    @ViewBuilder
    private var credentialsGuidance: some View {
        switch flow.credentialsAnswer {
        case .no:
            AskHermesPromptView(title: ConnectionSetupPrompt.credentialsMissing.title, prompt: ConnectionSetupPrompt.credentialsMissing.text)
            continueButton("Credentials are ready") { flow.confirmCredentialsReady() }
                .accessibilityIdentifier("setup.continue")
        case .unknown:
            AskHermesPromptView(title: ConnectionSetupPrompt.credentialsUnknown.title, prompt: ConnectionSetupPrompt.credentialsUnknown.text)
            continueButton("Credentials are ready") { flow.confirmCredentialsReady() }
                .accessibilityIdentifier("setup.continue")
        default:
            EmptyView()
        }
    }

    // MARK: - Step 3: Access method

    private var accessMethodStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let progress = flow.progressLabel {
                stepLabel(progress)
            }
            Text("How will this iPhone or iPad reach Hermes?")
                .font(.title3.weight(.semibold))
            Text("Pick how Conduit should reach your self-hosted Hermes dashboard. You can change this later.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !flow.draft.existingServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continueButton("Use or edit current dashboard address") { flow.useExistingAddress() }
                    .accessibilityIdentifier("setup.use-existing")
            }

            methodCard(
                title: ConnectionAccessMethod.lan.displayTitle,
                supporting: "Use this when Conduit and the Hermes machine are on the same home or local network.",
                identifier: "setup.method-lan"
            ) {
                flow.selectAccessMethod(.lan)
            }

            methodCard(
                title: ConnectionAccessMethod.tailscale.displayTitle,
                supporting: "Use Tailscale when you want to reach Hermes securely while away from home.",
                badge: "Recommended for remote access",
                identifier: "setup.method-tailscale"
            ) {
                flow.selectAccessMethod(.tailscale)
            }

            methodCard(
                title: ConnectionAccessMethod.reverseProxy.displayTitle,
                supporting: "Use this if you already access Hermes through an HTTPS hostname you manage.",
                identifier: "setup.method-reverseProxy"
            ) {
                flow.selectAccessMethod(.reverseProxy)
            }

            notSureGuidance
        }
    }

    private var notSureGuidance: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showNotSureGuidance.toggle()
            } label: {
                HStack {
                    Label("I’m not sure", systemImage: "questionmark.circle")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: showNotSureGuidance ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("setup.method-notsure")

            if showNotSureGuidance {
                VStack(alignment: .leading, spacing: 10) {
                    guidanceBullet("Using Conduit at home, on the same network as the Hermes machine? Choose Same Network.")
                    guidanceBullet("Need access away from home without existing remote access? Choose Tailscale — the simplest secure option.")
                    guidanceBullet("Already operating an HTTPS domain or reverse proxy for Hermes? Choose Existing Domain.")
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.06))
    }

    // MARK: - LAN branch

    private var lanBranch: some View {
        branchShell(
            title: "Same network as Hermes",
            intro: "Here is what you will need to connect Conduit over your local network:",
            needs: [
                "The Hermes dashboard is running.",
                "You have dashboard login credentials.",
                "You know the Hermes machine’s local IP address.",
                "You know the dashboard port.",
                "This device is on the same reachable network."
            ],
            prompt: .lanDetails
        )
    }

    // MARK: - Tailscale branch

    private var tailscaleBranch: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Reach Hermes with Tailscale")
                .font(.title3.weight(.semibold))
            Text("Tailscale gives you secure access from anywhere, including the recommended Tailscale Serve path:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                numberedStep(1, "Tailscale is installed on the Hermes machine.")
                numberedStep(2, "Tailscale is installed on this iPhone or iPad.")
                numberedStep(3, "Both are signed in to the same tailnet.")
                numberedStep(4, "The Hermes dashboard is running.")
                numberedStep(5, "Hermes configures Tailscale Serve for the dashboard.")
                numberedStep(6, "Hermes tells you the address to enter into Conduit.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.06))

            Text("Conduit never installs or configures Tailscale, and it doesn’t assume an address or port — Hermes tells you what to use.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            AskHermesPromptView(title: ConnectionSetupPrompt.tailscaleServe.title, prompt: ConnectionSetupPrompt.tailscaleServe.text)
            continueButton("I have the connection details") { flow.confirmDetailsReady() }
                .accessibilityIdentifier("setup.details-ready")
        }
    }

    // MARK: - Reverse-proxy branch

    private var reverseProxyBranch: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Use your existing HTTPS domain")
                .font(.title3.weight(.semibold))
            Text("This branch is only for HTTPS infrastructure you already operate — Conduit does not guide you through creating one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                Text("You will need:")
                    .font(.subheadline.weight(.semibold))
                guidanceBullet("Your existing HTTPS Hermes dashboard URL — for example https://hermes.example.com, https://hermes.example.com:9443, or https://example.com/hermes.")
                guidanceBullet("Any custom port.")
                guidanceBullet("Any path prefix your proxy uses.")
                guidanceBullet("Your dashboard login credentials.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.06))

            Text("Conduit will not ask you to expose a raw public port, create firewall rules, or bypass certificate checks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            AskHermesPromptView(title: ConnectionSetupPrompt.reverseProxyDetails.title, prompt: ConnectionSetupPrompt.reverseProxyDetails.text)
            continueButton("I have the connection details") { flow.confirmDetailsReady() }
                .accessibilityIdentifier("setup.details-ready")
        }
    }

    // MARK: - Troubleshooting surfaces (Round-1 content retained)

    private func troubleshootingStep(_ topic: ConnectionHelpDestination) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Topic", selection: topicBinding) {
                Text(ConnectionHelpDestination.tls.displayName).tag(ConnectionHelpDestination.tls)
                Text(ConnectionHelpDestination.cloudflare.displayName).tag(ConnectionHelpDestination.cloudflare)
            }
            .font(.subheadline)
            .accessibilityIdentifier("setup.troubleshooting-picker")

            Text(topic == .tls
                ? "Checks for HTTPS and certificate problems when connecting to your dashboard."
                : "Checks for Cloudflare Access service-token problems when connecting to your dashboard.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(topic.checks.enumerated()), id: \.offset) { _, check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.conduitAccent)
                            .padding(.top, 2)
                        Text(check)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.06))
        }
    }

    private var topicBinding: Binding<ConnectionHelpDestination> {
        Binding(
            get: { flow.step == .cloudflareTroubleshooting ? .cloudflare : .tls },
            set: { flow.showTroubleshooting($0) }
        )
    }

    // MARK: - Reusable pieces

    private func readinessQuestion(
        progress: String?,
        question: String,
        explanation: String,
        selectedAnswer: ConnectionSetupAnswer?,
        onAnswer: @escaping (ConnectionSetupAnswer) -> Void,
        @ViewBuilder guidance: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let progress {
                stepLabel(progress)
            }
            Text(question)
                .font(.title3.weight(.semibold))
            Text(explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            answerRow("Yes", selected: selectedAnswer == .yes, identifier: "setup.answer-yes") {
                onAnswer(.yes)
            }
            answerRow("No", selected: selectedAnswer == .no, identifier: "setup.answer-no") {
                onAnswer(.no)
            }
            answerRow("I don’t know", selected: selectedAnswer == .unknown, identifier: "setup.answer-unknown") {
                onAnswer(.unknown)
            }

            guidance()
        }
    }

    private func answerRow(
        _ label: String,
        selected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.conduitAccent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassSurface(cornerRadius: 14, tint: .conduitAura.opacity(0.06))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func methodCard(
        title: String,
        supporting: String,
        badge: String? = nil,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.conduitAccent.opacity(0.15), in: Capsule())
                        .foregroundStyle(.conduitAccent)
                }
                Text(supporting)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassSurface(cornerRadius: 16, tint: .conduitAura.opacity(0.06))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func branchShell(
        title: String,
        intro: String,
        needs: [String],
        prompt: ConnectionSetupPrompt
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(intro)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(needs.enumerated()), id: \.offset) { _, need in
                    guidanceBullet(need)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.06))

            AskHermesPromptView(title: prompt.title, prompt: prompt.text)
            continueButton("I have the connection details") { flow.confirmDetailsReady() }
                .accessibilityIdentifier("setup.details-ready")
        }
    }

    private func numberedStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number).")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.conduitAccent)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.conduitAccent)
            .accessibilityIdentifier("setup.step-label")
    }

    private func continueButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.conduitAccent)
    }

    private func guidanceBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.conduitAccent)
                .padding(.top, 6)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Round-1 troubleshooting content (retained)

extension ConnectionHelpDestination {
    var displayName: String {
        switch self {
        case .start: return "Getting started"
        case .dashboard: return "Dashboard address"
        case .credentials: return "Credentials"
        case .network: return "Network & reachability"
        case .tls: return "HTTPS & certificates"
        case .cloudflare: return "Cloudflare Access"
        }
    }

    /// Static quick checks shown on the troubleshooting surfaces. Only the
    /// TLS and Cloudflare topics are reachable (they are the direct
    /// troubleshooting entries); the other destinations route to wizard
    /// questions, so they carry no checks. Safe by construction: never
    /// recommends exposing the dashboard to the public internet or weakening
    /// HTTPS.
    var checks: [String] {
        switch self {
        case .tls:
            return [
                "If you use your own certificate authority, install and trust its root certificate on this device (Settings → General → VPN & Device Management → Certificate Trust Settings).",
                "Check the server certificate’s expiration and validity dates.",
                "Confirm this device’s date and time are correct."
            ]
        case .cloudflare:
            return [
                "Verify the Client ID and Secret belong to a Cloudflare Access service token for this application.",
                "Make sure a Service Auth policy allows that token to reach this Access application.",
                "Or turn off \"Use Cloudflare Access service token\" to sign in interactively through the in-app browser."
            ]
        case .start, .dashboard, .credentials, .network:
            return []
        }
    }
}
