import XCTest

/// Round-4 Connection Setup UI coverage: the staged connection-test screen
/// between credentials and Review. Both tests run against the deterministic
/// stub probe selected by the `-CONNECTION_SETUP_TEST_RESULT` launch
/// argument (DEBUG-only) — no test depends on a real Hermes server.
final class ConnectionSetupTestConnectionUITests: XCTestCase {
    private enum Identity {
        static let answerYes = "setup.answer-yes"
        static let methodLan = "setup.method-lan"
        static let detailsReady = "setup.details-ready"
        static let next = "setup.next"
        static let back = "setup.back"
        static let testRun = "setup.test.run"
        static let testContinue = "setup.test.continue"
        static let stageServer = "setup.test.stage.server"
        static let stageDashboard = "setup.test.stage.dashboard"
        static let stageAuthentication = "setup.test.stage.authentication"
        static let useSettings = "setup.use-settings"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testStagedTestSuccessShowsAllStagesAndEnablesHandoff() {
        let app = XCUIApplication()
        app.launchArguments += ["-CONNECTION_SETUP_TEST_RESULT", "success"]
        app.launch()

        walkToTestScreen(app)
        tapVisible(app.buttons[Identity.testRun], in: app)

        // On success the wizard advances to Review, which shows every passed
        // stage plus the ready message. The password is never rendered as
        // text anywhere.
        XCTAssertTrue(app.staticTexts["setup.test.ready"].waitForExistence(timeout: 5))
        XCTAssertTrue(row(app, Identity.stageServer).exists)
        XCTAssertTrue(row(app, Identity.stageDashboard).exists)
        XCTAssertTrue(row(app, Identity.stageAuthentication).exists)
        XCTAssertFalse(app.staticTexts["round4-private-fixture"].exists)

        // The Round-3 typed handoff is unchanged: fields populate, nothing
        // connects automatically.
        tapVisible(app.buttons[Identity.useSettings], in: app)
        let server = app.textFields["login.server-url"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        XCTAssertEqual(server.value as? String, "http://192.168.1.28:9119")
        XCTAssertEqual(app.textFields["login.username"].value as? String, "round4-user")
        XCTAssertTrue(app.buttons["Connect"].isEnabled)
        XCTAssertFalse(app.staticTexts["Connecting..."].exists)
    }

    func testAuthenticationFailureKeepsPriorStagesAndOffersEditCredentials() {
        let app = XCUIApplication()
        app.launchArguments += ["-CONNECTION_SETUP_TEST_RESULT", "auth:authenticationRejected"]
        app.launch()

        walkToTestScreen(app)
        tapVisible(app.buttons[Identity.testRun], in: app)

        // The failed test stays on the test screen: the two successful
        // stages remain visible, and the classified credential guidance
        // appears with Edit Credentials as the primary recovery action.
        XCTAssertTrue(app.staticTexts["setup.test.failure"].waitForExistence(timeout: 5))
        XCTAssertTrue(row(app, Identity.stageServer).exists)
        XCTAssertTrue(row(app, Identity.stageDashboard).exists)
        XCTAssertTrue(row(app, Identity.stageAuthentication).exists)
        let failure = app.staticTexts["setup.test.failure"]
        XCTAssertEqual(
            failure.label,
            "Hermes rejected that username or password. Check your dashboard credentials and try again."
        )
        XCTAssertTrue(app.buttons["setup.test.edit-credentials"].exists)
        // Retry exists but is never the primary action after rejected
        // credentials.
        XCTAssertTrue(app.buttons["setup.test.retry"].exists)

        tapVisible(app.buttons["setup.test.edit-credentials"], in: app)
        let username = app.textFields["setup.username"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        XCTAssertEqual(username.value as? String, "round4-user", "Edits return to the entered credentials")
    }

    func testRateLimitedTestOffersNoRetryAction() {
        let app = XCUIApplication()
        app.launchArguments += ["-CONNECTION_SETUP_TEST_RESULT", "auth:rateLimited"]
        app.launch()

        walkToTestScreen(app)
        tapVisible(app.buttons[Identity.testRun], in: app)

        XCTAssertTrue(app.staticTexts["setup.test.failure"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["setup.test.retry"].exists,
            "Rate limiting must not invite an immediate retry"
        )
        XCTAssertTrue(app.buttons["setup.test.edit-credentials"].exists)
    }

    func testInteractiveSignInOutcomeShowsBrowserSignInAndHandsOff() {
        // A dashboard whose discovery redirects to a sign-in page ends the
        // staged test in the supported interactive outcome. The terminal
        // event AUTO-ADVANCES the flow to Review, so the assertions below
        // run against Review directly: server and dashboard pass,
        // authentication shows "Browser sign-in required" (never "Login
        // successful"), and Use These Settings performs the normal Round-3
        // handoff back to LoginView — where the user taps Connect and the
        // existing WebView flow runs. No real browser login is automated
        // here.
        let app = XCUIApplication()
        app.launchArguments += ["-CONNECTION_SETUP_TEST_RESULT", "auth:interactiveSignInRequired"]
        app.launch()

        walkToTestScreen(app)
        tapVisible(app.buttons[Identity.testRun], in: app)

        // Review, reached by auto-advance, shows the browser-based sign-in
        // explanation and the interactive authentication row.
        let interactiveReady = app.staticTexts["setup.test.interactive-ready"]
        XCTAssertTrue(interactiveReady.waitForExistence(timeout: 5))
        XCTAssertTrue(
            interactiveReady.label.contains("browser-based sign-in"),
            "Got: \(interactiveReady.label)"
        )
        XCTAssertFalse(
            app.staticTexts["setup.test.ready"].exists,
            "The native ready message must not appear for interactive auth"
        )
        let authRow = row(app, Identity.stageAuthentication)
        XCTAssertTrue(authRow.exists)
        XCTAssertTrue(authRow.label.contains("Browser sign-in required"), "Got: \(authRow.label)")
        XCTAssertFalse(
            authRow.label.contains("Login successful"),
            "Interactive auth must never claim the user signed in"
        )

        // Back from Review shows the still-current outcome on the test
        // screen with a Continue action that returns to Review.
        tapVisible(app.buttons[Identity.back], in: app)
        XCTAssertTrue(app.buttons[Identity.testContinue].waitForExistence(timeout: 5))
        XCTAssertTrue(
            row(app, Identity.stageAuthentication).label.contains("Browser sign-in required")
        )
        tapVisible(app.buttons[Identity.testContinue], in: app)
        XCTAssertTrue(app.staticTexts["setup.test.interactive-ready"].waitForExistence(timeout: 5))

        // The Round-3 typed handoff is unchanged: fields populate, nothing
        // connects automatically.
        tapVisible(app.buttons[Identity.useSettings], in: app)
        let server = app.textFields["login.server-url"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        XCTAssertEqual(server.value as? String, "http://192.168.1.28:9119")
        XCTAssertEqual(app.textFields["login.username"].value as? String, "round4-user")
        XCTAssertTrue(app.buttons["Connect"].isEnabled)
        XCTAssertFalse(app.staticTexts["Connecting..."].exists)
    }

    // MARK: - Walk helpers

    /// Opens setup and walks Dashboard → Credentials → LAN → details →
    /// credentials, landing on the staged test screen.
    private func walkToTestScreen(_ app: XCUIApplication) {
        let serverField = app.textFields["login.server-url"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 10), "Login screen did not appear. Tree:\n\(app.debugDescription)")
        let setup = app.buttons["login.connection-setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        if !setup.isHittable { app.swipeDown() }
        setup.tap()

        tapVisible(app.buttons[Identity.answerYes], in: app)
        tapVisible(app.buttons[Identity.answerYes], in: app)
        tapVisible(app.buttons[Identity.methodLan], in: app)
        tapVisible(app.buttons[Identity.detailsReady], in: app)

        let host = app.textFields["setup.host"]
        tapVisible(host, in: app)
        host.typeText("192.168.1.28")
        let port = app.textFields["setup.port"]
        tapVisible(port, in: app)
        port.typeText("9119")
        dismissKeyboard(app)
        tapVisible(app.buttons[Identity.next], in: app)

        let username = app.textFields["setup.username"]
        tapVisible(username, in: app)
        username.typeText("round4-user")
        let password = app.secureTextFields["setup.password"]
        tapVisible(password, in: app)
        password.typeText("round4-private-fixture")
        tapVisible(app.buttons[Identity.next], in: app)

        XCTAssertTrue(app.buttons[Identity.testRun].waitForExistence(timeout: 5), "Test screen did not appear. Tree:\n\(app.debugDescription)")
        XCTAssertTrue(row(app, Identity.stageServer).exists)
        XCTAssertTrue(row(app, Identity.stageDashboard).exists)
        XCTAssertTrue(row(app, Identity.stageAuthentication).exists)
    }

    /// Stage rows are single combined accessibility elements, so query by
    /// identifier across element types.
    private func row(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tapVisible(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<6 {
            if element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
        element.tap()
    }

    /// Tap the keyboard toolbar's Done control when present, so a Continue
    /// button that would sit behind the keyboard window is tapped for real.
    private func dismissKeyboard(_ app: XCUIApplication) {
        let done = app.buttons["setup.keyboard-done"]
        guard done.waitForExistence(timeout: 2) else { return }
        done.tap()
    }
}
