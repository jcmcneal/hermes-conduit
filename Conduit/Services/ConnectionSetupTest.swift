//
//  ConnectionSetupTest.swift
//  Conduit
//
//  Round 4 of the Connection Setup assistant: a staged connection test that
//  runs before the user accepts the wizard's settings. The state model is
//  SwiftUI-free and reducer-driven so stage transitions, invalidation, and
//  stale-result handling are unit-testable without hosting a view.
//
//  The probe ORCHESTRATES the production authentication machinery — it never
//  reimplements URL construction, request bodies, Cloudflare headers, or
//  status classification. Stage 1 (transport) and stage 2 (Hermes dashboard
//  confirmation) ride on the same provider-discovery request the normal
//  login flow performs first; stage 3 is the full native connect (password
//  login + ws-ticket mint) for password-capable dashboards. A dashboard that
//  answers discovery with an unauthenticated redirect to a sign-in page has
//  proven everything the probe can test and ends the run in the supported
//  `requiresInteractiveSignIn` outcome: no native login, no ticket, no
//  WebView — the actual sign-in happens in LoginView after the handoff.
//  The milestone for "Login successful" is exactly the milestone normal
//  login reaches before it would commit anything — and the probe commits
//  nothing: no cookie store write, no Keychain, no AppState mutation, no
//  websocket, no screen changes. The resulting ticket and transaction
//  cookies are discarded here.
//

import Foundation
import os

/// The sequential stages of a setup connection test. One source of truth for
/// ordering, copy, and accessibility state.
enum ConnectionSetupTestStage: Equatable, CaseIterable, Identifiable {
    case server
    case dashboard
    case authentication

    var id: Self { self }

    /// The stable objective label: what pending and failed rows show, and
    /// what success confirms. Used for VoiceOver too, so a row's meaning
    /// never depends on icon or color alone.
    var objectiveLabel: String {
        switch self {
        case .server: return "Dashboard reachable"
        case .dashboard: return "Hermes dashboard found"
        case .authentication: return "Authentication"
        }
    }

    /// The in-progress phrase for the row currently being checked.
    var runningLabel: String {
        switch self {
        case .server: return "Checking server…"
        case .dashboard: return "Checking dashboard…"
        case .authentication: return "Authenticating…"
        }
    }

    /// The confirmation phrase for a passed stage.
    var successLabel: String {
        switch self {
        case .server: return "Dashboard reachable"
        case .dashboard: return "Hermes dashboard found"
        case .authentication: return "Login successful"
        }
    }

    /// Stable identifier fragment (UI-test handles), not user-facing.
    var identifierName: String {
        switch self {
        case .server: return "server"
        case .dashboard: return "dashboard"
        case .authentication: return "authentication"
        }
    }
}

/// Per-stage result of the staged test.
enum ConnectionSetupStageState: Equatable {
    case pending
    case running
    case succeeded
    /// The dashboard answered, but authentication must continue
    /// interactively in the browser after the handoff. A supported terminal
    /// outcome — explicitly NOT a success (the user has not authenticated)
    /// and NOT a failure (nothing went wrong).
    case requiresInteractiveSignIn
    case failed(ConnectionFailure)

    /// VoiceOver state word, so success/failure is never communicated by
    /// icon or color alone.
    var accessibilityState: String {
        switch self {
        case .pending: return "waiting"
        case .running: return "checking"
        case .succeeded: return "passed"
        case .requiresInteractiveSignIn: return "browser sign-in required"
        case .failed: return "failed"
        }
    }
}

/// One probe progress report, applied to `ConnectionSetupTestState` by the
/// flow model. Carries the classified failure, never raw errors or server
/// response text.
enum ConnectionSetupTestEvent: Equatable {
    case started(ConnectionSetupTestStage)
    case succeeded(ConnectionSetupTestStage)
    /// Terminal supported outcome: the dashboard requires interactive
    /// (browser) sign-in. Emitted once, at the authentication stage, after
    /// server and dashboard have succeeded. No password login, ticket mint,
    /// or WebView follows inside the probe.
    case requiresInteractiveSignIn(ConnectionSetupTestStage)
    case failed(ConnectionSetupTestStage, ConnectionFailure)
}

/// The staged test's state: one source of truth for all three stages.
/// Prior successes stay successful when a later stage fails; untouched
/// future stages stay pending. SwiftUI never infers any of this from button
/// titles or local booleans.
struct ConnectionSetupTestState: Equatable {
    var server = ConnectionSetupStageState.pending
    var dashboard = ConnectionSetupStageState.pending
    var authentication = ConnectionSetupStageState.pending

    /// The completion announcement (one per run, not per stage transition).
    static let readyMessage = "This connection is ready to use."

    /// The interactive-auth completion announcement and Review copy. The
    /// user has NOT authenticated: the message says what happens next
    /// instead of claiming success. Never may this state render "Login
    /// successful".
    static let interactiveReadyMessage = "This dashboard uses browser-based sign-in. "
        + "Conduit will open the sign-in page after you return to the login screen."

    subscript(stage: ConnectionSetupTestStage) -> ConnectionSetupStageState {
        get {
            switch stage {
            case .server: return server
            case .dashboard: return dashboard
            case .authentication: return authentication
            }
        }
        set {
            switch stage {
            case .server: server = newValue
            case .dashboard: dashboard = newValue
            case .authentication: authentication = newValue
            }
        }
    }

    /// Pure reducer: folds one probe event into the state. Stage progress is
    /// monotonic within a run — a terminal stage never reverts — so
    /// out-of-order or duplicate events degrade gracefully instead of
    /// corrupting the list.
    mutating func apply(_ event: ConnectionSetupTestEvent) {
        switch event {
        case .started(let stage):
            guard self[stage] == .pending else { return }
            self[stage] = .running
        case .succeeded(let stage):
            guard self[stage] == .running else { return }
            self[stage] = .succeeded
        case .requiresInteractiveSignIn(let stage):
            guard self[stage] == .pending || self[stage] == .running else { return }
            self[stage] = .requiresInteractiveSignIn
        case .failed(let stage, let failure):
            guard self[stage] == .pending || self[stage] == .running else { return }
            self[stage] = .failed(failure)
        }
    }

    var allSucceeded: Bool {
        ConnectionSetupTestStage.allCases.allSatisfy { self[$0] == .succeeded }
    }

    var isRunning: Bool {
        ConnectionSetupTestStage.allCases.contains { self[$0] == .running }
    }

    /// The staged test ended in the supported interactive-auth outcome:
    /// server and dashboard succeeded, and authentication stopped at
    /// "browser sign-in required" — never a success, never a failure.
    var requiresInteractiveSignIn: Bool {
        server == .succeeded
            && dashboard == .succeeded
            && authentication == .requiresInteractiveSignIn
    }

    /// The first failed stage in run order, if any.
    var failedStage: ConnectionSetupTestStage? {
        ConnectionSetupTestStage.allCases.first { stage in
            if case .failed = self[stage] { return true }
            return false
        }
    }

    /// The classified failure of `failedStage`.
    var failedFailure: ConnectionFailure? {
        guard let stage = failedStage, case .failed(let failure) = self[stage] else { return nil }
        return failure
    }

    /// The visible row label for a stage in its current state.
    func rowLabel(for stage: ConnectionSetupTestStage) -> String {
        switch self[stage] {
        case .running: return stage.runningLabel
        case .succeeded: return stage.successLabel
        case .requiresInteractiveSignIn: return "Browser sign-in required"
        case .pending, .failed: return stage.objectiveLabel
        }
    }

    /// The complete VoiceOver label for a stage row.
    func accessibilityLabel(for stage: ConnectionSetupTestStage) -> String {
        "\(stage.objectiveLabel), \(self[stage].accessibilityState)"
    }
}

/// What the wizard offers after a failed stage: the step that owns the
/// failed inputs, and whether an immediate retry may be offered. Pure so the
/// recovery policy is unit-testable — in particular, rate limiting is a
/// password-login throttle and must never invite an immediate retry.
struct ConnectionSetupTestRecoveryPlan: Equatable {
    let remediationStep: ConnectionSetupStep
    let remediationLabel: String
    let offersRetry: Bool

    static func plan(
        for stage: ConnectionSetupTestStage,
        failure: ConnectionFailure
    ) -> ConnectionSetupTestRecoveryPlan {
        switch stage {
        case .server, .dashboard:
            return ConnectionSetupTestRecoveryPlan(
                remediationStep: .connectionDetails,
                remediationLabel: "Edit Connection Details",
                offersRetry: failure != .rateLimited
            )
        case .authentication:
            // Retry is never the primary action after rejected credentials:
            // blind retries feed the rate limiter. Edit comes first.
            return ConnectionSetupTestRecoveryPlan(
                remediationStep: .loginCredentials,
                remediationLabel: "Edit Credentials",
                offersRetry: failure != .rateLimited
            )
        }
    }
}

/// Performs the staged connection test. MainActor-isolated so progress
/// events apply to the flow model synchronously and in order, exactly like
/// every other wizard state mutation.
@MainActor
protocol ConnectionSetupTesting {
    func runTest(
        result: ConnectionSetupResult,
        cloudflareAccess: CloudflareAccessCredentials?,
        onEvent: @escaping (ConnectionSetupTestEvent) -> Void
    ) async
}

/// The production probe. Reuses `NativeAuthClient` unchanged for every
/// request — including its redirect policy, Cloudflare header application,
/// transport policy, and status classification via
/// `ConnectionFailureClassifier`. A password-capable dashboard sees exactly
/// one discovery request, one password-login attempt, and one ticket mint;
/// an interactive-auth dashboard sees exactly one discovery request and
/// nothing else.
struct ConnectionSetupProbe: ConnectionSetupTesting {
    private static let logger = Logger(subsystem: "com.milim.relay", category: "connection-setup-test")

    /// Test-only seam: routes the real client through a URLProtocol stub.
    /// Production callers leave this nil.
    var sessionConfiguration: URLSessionConfiguration?

    func runTest(
        result: ConnectionSetupResult,
        cloudflareAccess: CloudflareAccessCredentials?,
        onEvent: @escaping (ConnectionSetupTestEvent) -> Void
    ) async {
        let client = NativeAuthClient(
            baseURL: result.serverURL,
            cloudflareAccess: cloudflareAccess,
            sessionConfiguration: sessionConfiguration
        )

        // Stages 1 and 2 share one request — the same provider discovery the
        // login flow performs first. A transport error proves nothing about
        // the server and fails at the server stage; a typed discovery answer
        // means an HTTP response DID arrive, so transport is proven and the
        // failure belongs to the dashboard stage.
        onEvent(.started(.server))
        let discovery: AuthProviderDiscoveryResult
        do {
            discovery = try await client.authProviderDiscovery()
        } catch {
            guard !Self.wasCancelled(error) else { return }
            if let authError = error as? AuthClientError {
                if case .invalidURL = authError {
                    Self.reportFailure(.server, ConnectionFailureClassifier.classify(authError), to: onEvent)
                    return
                }
                onEvent(.succeeded(.server))
                onEvent(.started(.dashboard))
                Self.reportFailure(.dashboard, ConnectionFailureClassifier.classify(authError), to: onEvent)
                return
            }
            Self.reportFailure(.server, ConnectionFailureClassifier.classify(error), to: onEvent)
            return
        }
        onEvent(.succeeded(.server))

        // Stage 2: the discovery answer must identify a Hermes dashboard
        // with the authentication shape the probe can exercise. An arbitrary
        // website answering 200 (unrecognized body) and a recognizable
        // provider answer with no password provider are both NOT Hermes
        // password dashboards — and neither is the interactive-auth signal,
        // which only the redirect classification above may produce.
        onEvent(.started(.dashboard))
        switch discovery {
        case .interactiveSignInRequired:
            // The dashboard requires interactive (browser) sign-in. The
            // probe has verified everything it can — transport and dashboard
            // identity plus the expected auth behavior — and reports the
            // supported terminal outcome. It stays side-effect-free: no
            // native login attempt, no ticket mint, no WebView, no
            // cookie/Keychain writes. The actual sign-in happens in
            // LoginView over the normal handoff.
            onEvent(.succeeded(.dashboard))
            onEvent(.started(.authentication))
            onEvent(.requiresInteractiveSignIn(.authentication))
            return
        case .unrecognized:
            Self.reportFailure(.dashboard, .unexpectedServerResponse, to: onEvent)
            return
        case .providers(let providers):
            guard HermesProviderCheck.supportsPassword(providers) else {
                Self.reportFailure(.dashboard, .unexpectedServerResponse, to: onEvent)
                return
            }
        }
        onEvent(.succeeded(.dashboard))

        // Stage 3: the full native credential proof — password login plus
        // the ws-ticket mint that proves the session is actually usable.
        // This is the exact milestone normal login requires before it would
        // commit cookies. The transaction (ticket + transaction cookies) is
        // deliberately discarded: the test persists nothing and connects
        // nothing.
        onEvent(.started(.authentication))
        do {
            // Deliberately discarded: commitCookies() is never called, so
            // the transaction never reaches the shared cookie store.
            _ = try await client.connect(username: result.username, password: result.password)
            onEvent(.succeeded(.authentication))
        } catch {
            guard !Self.wasCancelled(error) else { return }
            Self.reportFailure(.authentication, ConnectionFailureClassifier.classify(error), to: onEvent)
        }
    }

    private static func reportFailure(
        _ stage: ConnectionSetupTestStage,
        _ failure: ConnectionFailure,
        to onEvent: (ConnectionSetupTestEvent) -> Void
    ) {
        // The classification is a semantic enum — safe at public privacy;
        // credentials, tickets, and response bodies are never logged.
        logger.error("Connection test failed at \(stage.objectiveLabel, privacy: .public): \(String(describing: failure), privacy: .public)")
        onEvent(.failed(stage, failure))
    }

    private static func wasCancelled(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}

#if DEBUG
/// UI-test-only probe stub: deterministic staged outcomes selected by the
/// `-CONNECTION_SETUP_TEST_RESULT` launch argument, so UI tests never depend
/// on a real Hermes server. Compiled out of release builds; production code
/// never references it.
struct ConnectionSetupTestProbeStub: ConnectionSetupTesting {
    enum Script: String {
        case success
        case interactiveSignInRequired = "auth:interactiveSignInRequired"
        case serverHostNotFound = "server:hostNotFound"
        case dashboardUnexpected = "dashboard:unexpectedServerResponse"
        case authRejected = "auth:authenticationRejected"
        case authRateLimited = "auth:rateLimited"

        func run(_ onEvent: (ConnectionSetupTestEvent) -> Void) {
            switch self {
            case .success:
                onEvent(.started(.server))
                onEvent(.succeeded(.server))
                onEvent(.started(.dashboard))
                onEvent(.succeeded(.dashboard))
                onEvent(.started(.authentication))
                onEvent(.succeeded(.authentication))
            case .interactiveSignInRequired:
                onEvent(.started(.server))
                onEvent(.succeeded(.server))
                onEvent(.started(.dashboard))
                onEvent(.succeeded(.dashboard))
                onEvent(.started(.authentication))
                onEvent(.requiresInteractiveSignIn(.authentication))
            case .serverHostNotFound:
                onEvent(.started(.server))
                onEvent(.failed(.server, .hostNotFound))
            case .dashboardUnexpected:
                onEvent(.started(.server))
                onEvent(.succeeded(.server))
                onEvent(.started(.dashboard))
                onEvent(.failed(.dashboard, .unexpectedServerResponse))
            case .authRejected:
                onEvent(.started(.server))
                onEvent(.succeeded(.server))
                onEvent(.started(.dashboard))
                onEvent(.succeeded(.dashboard))
                onEvent(.started(.authentication))
                onEvent(.failed(.authentication, .authenticationRejected))
            case .authRateLimited:
                onEvent(.started(.server))
                onEvent(.succeeded(.server))
                onEvent(.started(.dashboard))
                onEvent(.succeeded(.dashboard))
                onEvent(.started(.authentication))
                onEvent(.failed(.authentication, .rateLimited))
            }
        }

        static func fromLaunchArguments() -> ConnectionSetupTestProbeStub? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-CONNECTION_SETUP_TEST_RESULT"),
                  index + 1 < arguments.count,
                  let script = Script(rawValue: arguments[index + 1]) else { return nil }
            return ConnectionSetupTestProbeStub(script: script)
        }
    }

    let script: Script

    static func fromLaunchArguments() -> ConnectionSetupTestProbeStub? {
        Script.fromLaunchArguments()
    }

    func runTest(
        result: ConnectionSetupResult,
        cloudflareAccess: CloudflareAccessCredentials?,
        onEvent: @escaping (ConnectionSetupTestEvent) -> Void
    ) async {
        script.run(onEvent)
    }
}
#endif
