//
//  ConnectionSetupSettingsTests.swift
//  Conduit
//
//  Round 5: the Settings current-connection entry into the Connection Setup
//  wizard. Covers the semantic entry destination (question-free, seeded from
//  the current configuration), the interactive-auth path that must never be
//  blocked by meaningless password fields, the unchanged-settings Done offer,
//  cancel safety, and the pure apply plan whose writes never touch the live
//  connection.
//

import XCTest
@testable import Conduit

final class ConnectionSetupSettingsTests: XCTestCase {
    private let currentURL = "https://hermes.example:9443/hermes"

    private func seededFlow(password: String) -> ConnectionSetupFlow {
        ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(
                existingServerURL: currentURL,
                username: password.isEmpty ? "" : "eric",
                password: password
            )
        )
    }

    // MARK: - Entry destinations

    func testEntryStepMappingForCurrentConnection() {
        XCTAssertEqual(ConnectionSetupFlow.entryStep(for: .currentConnection), .connectionDetails)
        XCTAssertEqual(
            ConnectionSetupFlow(entry: .currentConnection, draft: ConnectionSetupDraft(
                existingServerURL: currentURL, username: "eric", password: "fixture"
            )).step,
            .connectionDetails
        )
    }

    func testPasswordlessCurrentConnectionEntryOpensTheStagedTestDirectly() {
        // An interactive-auth deployment legitimately has no stored password.
        // Never park the user on a meaningless password field, and never make
        // an already-connected user answer the first-run readiness questions.
        let flow = ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(existingServerURL: currentURL)
        )
        XCTAssertEqual(flow.step, .connectionTest)
        XCTAssertTrue(flow.enteredFromCurrentConnection)
        XCTAssertNil(flow.progressLabel, "The Settings entry sits outside the numbered first-run sequence")
    }

    // MARK: - Existing native-auth connection

    func testSeededNativeConnectionReachesTheTestWithoutRetypingAndPreservesTheExactAddress() throws {
        var flow = seededFlow(password: "fixture")
        XCTAssertEqual(flow.step, .connectionDetails)

        // Both screens are prefilled from the seeded configuration; no
        // first-run question ever appears.
        flow.submitDetails()
        XCTAssertEqual(flow.step, .loginCredentials)
        XCTAssertEqual(flow.draft.username, "eric")
        XCTAssertEqual(flow.draft.password, "fixture")
        flow.submitCredentials()
        XCTAssertEqual(flow.step, .connectionTest)

        StagedTestDriver.runSuccessfulTest(on: &flow)
        XCTAssertEqual(flow.step, .review)
        XCTAssertTrue(flow.testedSettingsUnchanged, "An untouched seeded configuration is unchanged")

        let result = try XCTUnwrap(flow.complete())
        XCTAssertEqual(
            result.serverURL, currentURL,
            "Scheme, host, port, and path prefix must all survive the round trip"
        )
    }

    func testEditedAddressIsNeverTreatedAsUnchanged() throws {
        var flow = seededFlow(password: "fixture")
        flow.draft.existingServerURL = "https://new.example/hermes"
        flow.submitDetails()
        flow.submitCredentials()
        XCTAssertEqual(flow.step, .connectionTest)
        StagedTestDriver.runSuccessfulTest(on: &flow)
        XCTAssertEqual(flow.step, .review)

        XCTAssertFalse(flow.testedSettingsUnchanged, "A deliberate edit must be applied, not dismissed as Done")
        let result = try XCTUnwrap(flow.complete())
        XCTAssertEqual(result.serverURL, "https://new.example/hermes")
    }

    // MARK: - Cancel safety

    func testBackingOutBeforeReviewCanNeverProduceAConfigurationToApply() {
        var flow = seededFlow(password: "fixture")
        flow.draft.existingServerURL = "https://new.example/hermes"
        flow.submitDetails()

        // The user dismisses the wizard here. Only Review can hand off a
        // configuration, so a cancelled edit can never persist anything.
        XCTAssertNil(flow.complete())
        XCTAssertNil(flow.validationError, "An abandoned edit leaves no error behind")
    }

    func testUnchangedDetectionRequiresACurrentTest() {
        var flow = seededFlow(password: "fixture")
        XCTAssertFalse(flow.testedSettingsUnchanged, "Untested settings are never Done-eligible")
        flow.draft.accessMethod = .reverseProxy
        XCTAssertFalse(flow.testedSettingsUnchanged)
    }

    // MARK: - Interactive auth from Settings

    func testInteractiveAuthDeploymentTestsAndCompletesWithoutAnyPassword() throws {
        var flow = ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(existingServerURL: currentURL)
        )
        XCTAssertEqual(flow.step, .connectionTest)

        let generation = try XCTUnwrap(flow.beginTest())
        for event in StagedTestDriver.successEvents.dropLast(2) {
            XCTAssertTrue(flow.applyTestEvent(event, generation: generation))
        }
        XCTAssertTrue(flow.applyTestEvent(.started(.authentication), generation: generation))
        XCTAssertTrue(flow.applyTestEvent(.requiresInteractiveSignIn(.authentication), generation: generation))
        XCTAssertEqual(flow.step, .review)

        XCTAssertTrue(flow.testedSettingsUnchanged, "The untouched interactive deployment is Done-eligible")
        let result = try XCTUnwrap(flow.complete())
        XCTAssertEqual(result.serverURL, currentURL, "The address-only configuration completes the handoff")
        XCTAssertTrue(result.username.isEmpty)
        XCTAssertTrue(result.password.isEmpty)
    }

    func testInteractiveOutcomeDoesNotRelaxAcceptanceForNativeSuccess() throws {
        // The credentialsRequired relaxation is bound to the interactive
        // outcome: a full native success with empty credentials is
        // impossible, and any other validation failure stays a failure.
        var flow = ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(existingServerURL: currentURL)
        )
        flow.draft.existingServerURL = "not a url"
        flow.draft.username = ""
        XCTAssertEqual(flow.step, .connectionTest)
        StagedTestDriver.runSuccessfulTest(on: &flow)
        XCTAssertEqual(flow.step, .review, "The staged test advanced before the address was corrupted")
        XCTAssertEqual(
            flow.reviewState(), .failure(.policy(.invalidURL)),
            "A broken address is never accepted, interactively or otherwise"
        )
        XCTAssertNil(flow.complete())
    }

    func testInheritedCloudflareTokenAppliesDuringInteractiveDiscovery() throws {
        let access = try XCTUnwrap(CloudflareAccessCredentials.from(clientID: "id", clientSecret: "secret"))
        let flow = ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(existingServerURL: currentURL),
            inheritedCloudflareAccess: access,
            inheritedCloudflareOriginURL: currentURL
        )
        XCTAssertEqual(try XCTUnwrap(flow.cloudflareAccessForDraft()), access,
                       "The same-origin token must reach discovery even with no credentials in the draft")
    }

    func testTestConfigurationPreservesTheAddressWithoutRequiringCredentials() throws {
        let draft = ConnectionSetupDraft(existingServerURL: currentURL, username: "", password: "")
        let configuration = try draft.testConfiguration()
        XCTAssertEqual(configuration.serverURL, currentURL)
        XCTAssertTrue(configuration.username.isEmpty)
        XCTAssertTrue(configuration.password.isEmpty)
        XCTAssertThrowsError(try draft.result(), "Full acceptance stays strict for empty credentials")
    }

    // MARK: - Seeding

    func testWizardCredentialsSeedOnlyMatchingUnprotectedRecords() {
        let matching = DashboardCredentials(
            baseURL: currentURL, username: "eric", password: "fixture", requiresFaceID: false
        )
        let seeded = ConnectionSetupSeeding.wizardCredentials(for: currentURL, saved: matching)
        XCTAssertEqual(seeded?.username, "eric")
        XCTAssertEqual(seeded?.password, "fixture")

        let faceID = DashboardCredentials(
            baseURL: currentURL, username: "eric", password: "fixture", requiresFaceID: true
        )
        let protected = ConnectionSetupSeeding.wizardCredentials(for: currentURL, saved: faceID)
        XCTAssertEqual(protected?.username, "eric")
        XCTAssertEqual(protected?.password, "", "A Face ID-protected record keeps its password back")

        let foreign = DashboardCredentials(
            baseURL: "https://other.example", username: "eric", password: "fixture", requiresFaceID: false
        )
        XCTAssertNil(ConnectionSetupSeeding.wizardCredentials(for: currentURL, saved: foreign))
        XCTAssertNil(ConnectionSetupSeeding.wizardCredentials(for: currentURL, saved: nil))
    }

    // MARK: - Apply plan (pure policy)

    private let savedCredentials = DashboardCredentials(
        baseURL: "https://hermes.example:9443/hermes",
        username: "eric",
        password: "fixture",
        requiresFaceID: true
    )

    func testUnchangedResultProducesAnEmptyPlan() {
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: currentURL, username: "eric", password: "fixture"),
            currentDashboardURL: currentURL,
            savedCredentials: savedCredentials,
            savedCloudflareAccess: nil
        )
        XCTAssertTrue(plan.isEmpty)
        XCTAssertFalse(plan.clearsSavedCredentials)
    }

    func testChangedURLRemembersTheAddressAndReplacesExistingSavedCredentials() {
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: "https://new.example/hermes", username: "eric", password: "next"),
            currentDashboardURL: currentURL,
            savedCredentials: savedCredentials,
            savedCloudflareAccess: nil
        )
        XCTAssertEqual(plan.dashboardURLToRemember, "https://new.example/hermes")
        XCTAssertEqual(
            plan.credentialsToSave,
            DashboardCredentials(
                baseURL: "https://new.example/hermes",
                username: "eric",
                password: "next",
                requiresFaceID: true
            ),
            "The replacement preserves the saved Face ID preference"
        )
        XCTAssertFalse(plan.clearsSavedCredentials)
    }

    func testPlanNeverCreatesCredentialsWhenNoneWereSaved() {
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: "https://new.example", username: "eric", password: "next"),
            currentDashboardURL: currentURL,
            savedCredentials: nil,
            savedCloudflareAccess: nil
        )
        XCTAssertEqual(plan.dashboardURLToRemember, "https://new.example")
        XCTAssertNil(plan.credentialsToSave, "An explicit apply never starts persisting credentials the user never saved")
        XCTAssertFalse(plan.clearsSavedCredentials)
    }

    func testCredentiallessApplyToANewURLClearsStaleSavedCredentials() {
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: "https://new.example", username: "", password: ""),
            currentDashboardURL: currentURL,
            savedCredentials: savedCredentials,
            savedCloudflareAccess: nil
        )
        XCTAssertTrue(plan.clearsSavedCredentials, "The applied configuration cannot use the old password; keeping it would send it to the new address")
        XCTAssertNil(plan.credentialsToSave)
    }

    func testCredentiallessApplyToTheSameURLKeepsSavedCredentials() {
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: currentURL, username: "", password: ""),
            currentDashboardURL: currentURL,
            savedCredentials: savedCredentials,
            savedCloudflareAccess: nil
        )
        XCTAssertTrue(plan.isEmpty, "Testing the current address interactively changes nothing")
        XCTAssertFalse(plan.clearsSavedCredentials)
    }

    func testSameOriginPathMoveRewritesTheCloudflareTokenWithoutCopyingAcrossOrigins() throws {
        let access = try XCTUnwrap(CloudflareAccessCredentials.from(clientID: "id", clientSecret: "secret"))
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: "https://hermes.example:9443/team", username: "eric", password: "fixture"),
            currentDashboardURL: currentURL,
            savedCredentials: nil,
            savedCloudflareAccess: access
        )
        XCTAssertEqual(
            plan.cloudflareTokenRewrite,
            ConnectionSetupApplication.CloudflareAccessRewrite(access: access, origin: "https://hermes.example:9443/team"),
            "A path-only move is same-origin: the token is re-bound to the new normalized URL"
        )
    }

    func testCrossOriginApplyLeavesTheCloudflareTokenUntouched() throws {
        let access = try XCTUnwrap(CloudflareAccessCredentials.from(clientID: "id", clientSecret: "secret"))
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: "https://new.example", username: "eric", password: "fixture"),
            currentDashboardURL: currentURL,
            savedCredentials: nil,
            savedCloudflareAccess: access
        )
        XCTAssertNil(plan.cloudflareTokenRewrite, "A service token is never copied to another origin nor deleted from its own")
    }

    func testApplicationDescriptionIsRedacted() {
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: "https://new.example", username: "eric", password: "super-secret"),
            currentDashboardURL: currentURL,
            savedCredentials: savedCredentials,
            savedCloudflareAccess: nil
        )
        XCTAssertFalse(String(describing: plan).contains("super-secret"))
        XCTAssertFalse(String(reflecting: plan).contains("super-secret"))
    }
}
