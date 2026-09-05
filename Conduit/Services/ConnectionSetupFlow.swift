//
//  ConnectionSetupFlow.swift
//  Conduit
//
//  The guided Connection Setup wizard's state model. Deliberately SwiftUI-free
//  so the routing rules — entry destinations, question transitions, access
//  method branches, back navigation — are unit-testable without hosting a
//  view. The view layer renders whatever step the model is on and never makes
//  routing decisions itself.
//

import Foundation

/// The answer offered on each guided readiness question.
enum ConnectionSetupAnswer: Equatable {
    case yes
    case no
    case unknown
}

/// Supported ways for this device to reach a self-hosted Hermes dashboard.
/// Deliberately a closed set: there is no public-IP/open-port path, and
/// Conduit supports self-hosted Hermes only.
enum ConnectionAccessMethod: Equatable, CaseIterable {
    case lan
    case tailscale
    case reverseProxy
}

/// One screen of the guided flow.
enum ConnectionSetupStep: Equatable {
    // The three core questions.
    case dashboard
    case credentials
    case accessMethod

    // Access-method branch screens (informational shells this round).
    case lan
    case tailscale
    case reverseProxy
    case detailsReady

    // Direct troubleshooting surfaces (failure-driven entries).
    case tlsTroubleshooting
    case cloudflareTroubleshooting
}

/// Copyable "Ask Hermes" prompts. Each prompt asks Hermes to keep dashboard
/// authentication enabled — enforced by `ConnectionSetupFlowTests`, which pin
/// the safety phrases and forbid exposure/port language.
enum ConnectionSetupPrompt: CaseIterable {
    case dashboardNotRunning
    case dashboardUnknown
    case credentialsMissing
    case credentialsUnknown
    case lanDetails
    case tailscaleServe
    case reverseProxyDetails

    var title: String {
        switch self {
        case .dashboardNotRunning: return "Ask Hermes to set up the dashboard"
        case .dashboardUnknown: return "Ask Hermes to check the dashboard"
        case .credentialsMissing: return "Ask Hermes to set up dashboard credentials"
        case .credentialsUnknown: return "Ask Hermes to check your dashboard sign-in"
        case .lanDetails: return "Ask Hermes for your connection details"
        case .tailscaleServe: return "Ask Hermes to configure Tailscale Serve"
        case .reverseProxyDetails: return "Ask Hermes to confirm your HTTPS address"
        }
    }

    var text: String {
        switch self {
        case .dashboardNotRunning:
            return "Please set up or start the Hermes dashboard for me. Make sure it requires authentication, "
                + "and tell me which port it is using when it is ready. Do not disable authentication."
        case .dashboardUnknown:
            return "Please check whether the Hermes dashboard is currently running. If it is, tell me which port it uses. "
                + "If it is not running, set it up or start it. Make sure dashboard authentication remains enabled."
        case .credentialsMissing:
            return "Please check the authentication configuration for my Hermes dashboard. "
                + "If dashboard login credentials have not been configured yet, set them up securely and tell me what "
                + "username and password I should use with Hermes Conduit. Do not disable authentication."
        case .credentialsUnknown:
            return "Does my Hermes dashboard require authentication? If so, tell me what username and password I should "
                + "use with Hermes Conduit. If authentication is not configured, set it up securely. Do not disable authentication."
        case .lanDetails:
            return "Please make sure the Hermes dashboard is reachable from other devices on my local network, then tell me "
                + "the local IP address or hostname and the dashboard port I should use with Hermes Conduit. "
                + "Keep dashboard authentication enabled."
        case .tailscaleServe:
            return "Please check whether the Hermes dashboard is running. Make sure Tailscale is available on this machine, "
                + "then configure Tailscale Serve so I can securely access the dashboard from my iPhone or iPad. "
                + "Keep dashboard authentication enabled. When it is ready, tell me the hostname/address and port I should use "
                + "with Hermes Conduit."
        case .reverseProxyDetails:
            return "Please confirm the HTTPS URL I should use to access the Hermes dashboard through my existing reverse proxy, "
                + "including any custom port or path prefix. Also confirm that dashboard authentication remains enabled."
        }
    }
}

/// The wizard's state: a navigation path of steps plus the answers collected
/// along the way. All mutations are explicit transitions so tests can drive
/// the exact routing contract.
struct ConnectionSetupFlow: Equatable {
    private(set) var path: [ConnectionSetupStep]
    private(set) var dashboardAnswer: ConnectionSetupAnswer?
    private(set) var credentialsAnswer: ConnectionSetupAnswer?
    private(set) var accessMethod: ConnectionAccessMethod?

    /// The screen currently presented.
    var step: ConnectionSetupStep { path.last ?? .dashboard }

    var canGoBack: Bool { path.count > 1 }

    /// "Step N of 3" for the core questions; `nil` on branch and
    /// troubleshooting screens, which sit outside the numbered sequence.
    var progressLabel: String? {
        switch step {
        case .dashboard: return "Step 1 of 3"
        case .credentials: return "Step 2 of 3"
        case .accessMethod: return "Step 3 of 3"
        case .lan, .tailscale, .reverseProxy, .detailsReady,
             .tlsTroubleshooting, .cloudflareTroubleshooting:
            return nil
        }
    }

    init(entry: ConnectionHelpDestination = .start) {
        path = [Self.entryStep(for: entry)]
    }

    /// Failure-driven Round-1 destinations land at sensible parts of the
    /// assistant; `.tls` and `.cloudflare` stay direct troubleshooting
    /// surfaces rather than wizard questions.
    static func entryStep(for destination: ConnectionHelpDestination) -> ConnectionSetupStep {
        switch destination {
        case .start, .dashboard: return .dashboard
        case .credentials: return .credentials
        case .network: return .accessMethod
        case .tls: return .tlsTroubleshooting
        case .cloudflare: return .cloudflareTroubleshooting
        }
    }

    mutating func back() {
        guard canGoBack else { return }
        path.removeLast()
    }

    /// Answering Yes moves on; No / I don't know keep the question on screen
    /// with its Ask Hermes guidance until the user confirms readiness.
    mutating func answerDashboard(_ answer: ConnectionSetupAnswer) {
        dashboardAnswer = answer
        if answer == .yes {
            advance(to: .credentials)
        }
    }

    /// The "Dashboard is ready" continuation after the No / I don't know
    /// guidance.
    mutating func confirmDashboardReady() {
        answerDashboard(.yes)
    }

    mutating func answerCredentials(_ answer: ConnectionSetupAnswer) {
        credentialsAnswer = answer
        if answer == .yes {
            advance(to: .accessMethod)
        }
    }

    /// The continuation after the credentials No / I don't know guidance.
    mutating func confirmCredentialsReady() {
        answerCredentials(.yes)
    }

    mutating func selectAccessMethod(_ method: ConnectionAccessMethod) {
        accessMethod = method
        advance(to: step(for: method))
    }

    /// "I have the connection details" on a branch screen. This round lands
    /// on an honest placeholder; the details form itself is later work.
    mutating func confirmDetailsReady() {
        advance(to: .detailsReady)
    }

    /// Topic switching on the troubleshooting surfaces (TLS ⇄ Cloudflare).
    /// Ignored for wizard destinations, which route through the questions.
    mutating func showTroubleshooting(_ destination: ConnectionHelpDestination) {
        guard destination == .tls || destination == .cloudflare else { return }
        advance(to: Self.entryStep(for: destination))
    }

    func step(for method: ConnectionAccessMethod) -> ConnectionSetupStep {
        switch method {
        case .lan: return .lan
        case .tailscale: return .tailscale
        case .reverseProxy: return .reverseProxy
        }
    }

    private mutating func advance(to step: ConnectionSetupStep) {
        guard step != self.step else { return }
        path.append(step)
    }
}
