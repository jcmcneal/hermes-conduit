//
//  ConnectionSetupView.swift
//  Conduit
//
//  Round-2 guided Connection Setup wizard. The routing lives in
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

struct ConnectionSetupView: View {
    let initialDestination: ConnectionHelpDestination

    @Environment(\.dismiss) private var dismiss
    @State private var flow: ConnectionSetupFlow

    init(initialDestination: ConnectionHelpDestination) {
        self.initialDestination = initialDestination
        _flow = State(initialValue: ConnectionSetupFlow(entry: initialDestination))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("connection-setup.content")
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
        case .detailsReady: detailsReadyStep
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

            methodCard(
                title: "I’m on the same network as Hermes",
                supporting: "Use this when Conduit and the Hermes machine are on the same home or local network.",
                identifier: "setup.method-lan"
            ) {
                flow.selectAccessMethod(.lan)
            }

            methodCard(
                title: "Tailscale",
                supporting: "Use Tailscale when you want to reach Hermes securely while away from home.",
                badge: "Recommended for remote access",
                identifier: "setup.method-tailscale"
            ) {
                flow.selectAccessMethod(.tailscale)
            }

            methodCard(
                title: "I already have a domain or reverse proxy",
                supporting: "Use this if you already access Hermes through an HTTPS hostname you manage.",
                identifier: "setup.method-reverseProxy"
            ) {
                flow.selectAccessMethod(.reverseProxy)
            }

            notSureGuidance
        }
    }

    @State private var showNotSureGuidance = false

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
                "You know the Hermes machine’s LAN IP address or local hostname.",
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

    // MARK: - Details-ready placeholder

    private var detailsReadyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Details ready")
                .font(.title3.weight(.semibold))
            Text("Collecting your Hermes address and port inside this assistant arrives in a future update.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Meanwhile, tap Done and enter your dashboard address directly in the login form — the guidance above covers exactly what to enter, and Conduit accepts custom ports and path prefixes there.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
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

    /// Static quick checks shown on the troubleshooting surfaces. Safe by
    /// construction: never recommends exposing the dashboard to the public
    /// internet or weakening HTTPS.
    var checks: [String] {
        switch self {
        case .start:
            return [
                "The dashboard address should look like https://hermes.example — include any path prefix your reverse proxy uses (for example https://example.com/hermes).",
                "Open the same address in Safari on this device. If the dashboard doesn’t load there, what you see is the same wall Conduit hits.",
                "Remote dashboards must use HTTPS. Plain HTTP works only for localhost, private LAN addresses, and Tailscale."
            ]
        case .dashboard:
            return [
                "Confirm the address points at the Hermes dashboard itself, not another service on the same host.",
                "Include custom ports (for example https://hermes.example:9119) and any reverse-proxy path prefix.",
                "If the dashboard moved or its certificate changed, re-enter the full address from scratch."
            ]
        case .credentials:
            return [
                "Conduit needs the username and password you use to sign in to the Hermes dashboard — not a Cloudflare or Tailscale account.",
                "Try signing in on the dashboard’s own web page to confirm the account still works.",
                "If the password was rejected after a dashboard change, reset it where your dashboard manages users."
            ]
        case .network:
            return [
                "Make sure the Hermes dashboard is actually running on its host machine.",
                "This device must be on the same network as the dashboard, or connected through Tailscale or a VPN. Tailscale Serve also gives you HTTPS for free.",
                "Mobile hotspots and guest Wi-Fi often block device-to-device traffic — try another network.",
                "Avoid opening the dashboard port directly to the internet; prefer Tailscale or an authenticated reverse proxy."
            ]
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
        }
    }
}
