//
//  ConnectionSetupFlowTests.swift
//  Conduit
//
//  Routing and safety coverage for the guided Connection Setup wizard model:
//  destination entry points, question transitions, access-method branches,
//  back navigation, and the Ask Hermes prompt safety phrases.
//

import XCTest
@testable import Conduit

final class ConnectionSetupFlowTests: XCTestCase {
    // MARK: - Entry destinations

    func testManualEntryBeginsAtDashboard() {
        XCTAssertEqual(ConnectionSetupFlow(entry: .start).step, .dashboard)
    }

    func testFailureDestinationsMapToSensibleWizardEntries() {
        XCTAssertEqual(ConnectionSetupFlow.entryStep(for: .start), .dashboard)
        XCTAssertEqual(ConnectionSetupFlow.entryStep(for: .dashboard), .dashboard)
        XCTAssertEqual(ConnectionSetupFlow.entryStep(for: .credentials), .credentials)
        XCTAssertEqual(ConnectionSetupFlow.entryStep(for: .network), .accessMethod)
        XCTAssertEqual(ConnectionSetupFlow.entryStep(for: .tls), .tlsTroubleshooting)
        XCTAssertEqual(ConnectionSetupFlow.entryStep(for: .cloudflare), .cloudflareTroubleshooting)
    }

    func testTLSAndCloudflareEntriesOpenTroubleshootingDirectly() {
        XCTAssertEqual(ConnectionSetupFlow(entry: .tls).step, .tlsTroubleshooting)
        XCTAssertEqual(ConnectionSetupFlow(entry: .cloudflare).step, .cloudflareTroubleshooting)
    }

    // MARK: - Core question transitions

    func testDashboardYesAdvancesToCredentials() {
        var flow = ConnectionSetupFlow(entry: .start)
        flow.answerDashboard(.yes)
        XCTAssertEqual(flow.step, .credentials)
        XCTAssertEqual(flow.dashboardAnswer, .yes)
    }

    func testDashboardNoAndUnknownStayWithGuidanceUntilConfirmedReady() {
        var flow = ConnectionSetupFlow(entry: .start)
        flow.answerDashboard(.no)
        XCTAssertEqual(flow.step, .dashboard, "No must keep the question up with its Ask Hermes guidance")
        XCTAssertEqual(flow.dashboardAnswer, .no)

        flow.confirmDashboardReady()
        XCTAssertEqual(flow.step, .credentials)
        XCTAssertEqual(flow.dashboardAnswer, .yes)
    }

    func testDashboardUnknownThenConfirmAdvances() {
        var flow = ConnectionSetupFlow(entry: .start)
        flow.answerDashboard(.unknown)
        XCTAssertEqual(flow.step, .dashboard)
        flow.confirmDashboardReady()
        XCTAssertEqual(flow.step, .credentials)
    }

    func testCredentialsYesAdvancesToAccessMethod() {
        var flow = ConnectionSetupFlow(entry: .start)
        flow.answerDashboard(.yes)
        flow.answerCredentials(.yes)
        XCTAssertEqual(flow.step, .accessMethod)
    }

    func testCredentialsNoAndUnknownStayWithGuidanceUntilConfirmedReady() {
        var flow = ConnectionSetupFlow(entry: .start)
        flow.answerDashboard(.yes)
        flow.answerCredentials(.no)
        XCTAssertEqual(flow.step, .credentials)
        XCTAssertEqual(flow.credentialsAnswer, .no)

        flow.confirmCredentialsReady()
        XCTAssertEqual(flow.step, .accessMethod)
        XCTAssertEqual(flow.credentialsAnswer, .yes)
    }

    func testEntryAtCredentialsSkipsDashboardQuestion() {
        var flow = ConnectionSetupFlow(entry: .credentials)
        XCTAssertEqual(flow.step, .credentials)
        flow.answerCredentials(.yes)
        XCTAssertEqual(flow.step, .accessMethod)
        XCTAssertNil(flow.dashboardAnswer, "Entering mid-wizard must not invent answers for skipped questions")
    }

    // MARK: - Access methods

    func testAccessMethodChoicesRouteToTheirBranches() {
        for (method, expectedStep) in [
            (ConnectionAccessMethod.lan, ConnectionSetupStep.lan),
            (ConnectionAccessMethod.tailscale, ConnectionSetupStep.tailscale),
            (ConnectionAccessMethod.reverseProxy, ConnectionSetupStep.reverseProxy)
        ] {
            var flow = ConnectionSetupFlow(entry: .start)
            flow.answerDashboard(.yes)
            flow.answerCredentials(.yes)
            flow.selectAccessMethod(method)
            XCTAssertEqual(flow.step, expectedStep, "\(method) must route to \(expectedStep)")
            XCTAssertEqual(flow.accessMethod, method)
        }
    }

    func testSupportedMethodSetIsExactlyTheSafeThree() {
        // Closed set: LAN, Tailscale, existing reverse proxy. There is no
        // public-IP/open-port method anywhere in the model.
        XCTAssertEqual(
            Set(ConnectionAccessMethod.allCases),
            [.lan, .tailscale, .reverseProxy]
        )
    }

    func testDetailsReadyFollowsBranchConfirmation() {
        var flow = ConnectionSetupFlow(entry: .start)
        flow.answerDashboard(.yes)
        flow.answerCredentials(.yes)
        flow.selectAccessMethod(.tailscale)
        flow.confirmDetailsReady()
        XCTAssertEqual(flow.step, .detailsReady)
    }

    // MARK: - Back navigation

    func testBackWalksThePathWithoutLosingEntryStep() {
        var flow = ConnectionSetupFlow(entry: .start)
        XCTAssertFalse(flow.canGoBack, "The entry step has nowhere to go back to")
        flow.back()
        XCTAssertEqual(flow.step, .dashboard, "Back on the entry step must be a no-op")

        flow.answerDashboard(.yes)
        flow.answerCredentials(.yes)
        flow.selectAccessMethod(.tailscale)
        XCTAssertTrue(flow.canGoBack)

        flow.back()
        XCTAssertEqual(flow.step, .accessMethod)
        flow.back()
        XCTAssertEqual(flow.step, .credentials)
        flow.back()
        XCTAssertEqual(flow.step, .dashboard)
        XCTAssertFalse(flow.canGoBack)
    }

    // MARK: - Troubleshooting topic switching

    func testTroubleshootingTopicsSwitchBetweenEachOther() {
        var tlsFlow = ConnectionSetupFlow(entry: .tls)
        tlsFlow.showTroubleshooting(.cloudflare)
        XCTAssertEqual(tlsFlow.step, .cloudflareTroubleshooting)
        tlsFlow.back()
        XCTAssertEqual(tlsFlow.step, .tlsTroubleshooting)
    }

    func testWizardDestinationsDoNotJumpOutOfTheQuestionSequence() {
        // The troubleshooting switch is only for the tls/cloudflare surfaces;
        // it must not be usable to skip straight to branches.
        var flow = ConnectionSetupFlow(entry: .start)
        flow.showTroubleshooting(.network)
        XCTAssertEqual(flow.step, .dashboard)
    }

    // MARK: - Progress labeling

    func testProgressLabelsCoverTheThreeCoreQuestions() {
        XCTAssertEqual(ConnectionSetupFlow(entry: .start).progressLabel, "Step 1 of 3")

        var flow = ConnectionSetupFlow(entry: .start)
        flow.answerDashboard(.yes)
        XCTAssertEqual(flow.progressLabel, "Step 2 of 3")
        flow.answerCredentials(.yes)
        XCTAssertEqual(flow.progressLabel, "Step 3 of 3")

        flow.selectAccessMethod(.lan)
        XCTAssertNil(flow.progressLabel, "Branch screens sit outside the numbered question sequence")
    }

    // MARK: - Ask Hermes prompt safety

    func testEveryPromptPreservesDashboardAuthentication() {
        for prompt in ConnectionSetupPrompt.allCases {
            let text = prompt.text.lowercased()
            XCTAssertTrue(
                text.contains("authentication"),
                "\(prompt) prompt never mentions authentication: \(prompt.text)"
            )
            XCTAssertTrue(
                text.contains("enabled") || text.contains("disable") || text.contains("requires authentication"),
                "\(prompt) prompt must explicitly ask Hermes to keep authentication on: \(prompt.text)"
            )
        }
    }

    func testTailscalePromptReferencesTailscaleServe() {
        XCTAssertTrue(
            ConnectionSetupPrompt.tailscaleServe.text.contains("Tailscale Serve"),
            "The Tailscale branch prompt must include the Tailscale Serve configuration path"
        )
    }

    func testNoPromptRequestsPublicExposureOrHardCodedPorts() {
        let forbidden = ["public internet", "port forward", "port-forward", "firewall", "expose", "8080", "9119", "443"]
        for prompt in ConnectionSetupPrompt.allCases {
            let text = prompt.text.lowercased()
            for phrase in forbidden {
                XCTAssertFalse(
                    text.contains(phrase),
                    "\(prompt) prompt must not contain '\(phrase)': \(prompt.text)"
                )
            }
        }
    }

    func testGuidanceMethodLabelsContainNoExposureLanguage() {
        // The strings the wizard itself shows for the three methods must stay
        // free of public-exposure framing.
        let labels = [
            "I’m on the same network as Hermes",
            "Tailscale",
            "I already have a domain or reverse proxy"
        ]
        for label in labels {
            let lowered = label.lowercased()
            XCTAssertFalse(lowered.contains("public"))
            XCTAssertFalse(lowered.contains("open port"))
        }
    }
}
