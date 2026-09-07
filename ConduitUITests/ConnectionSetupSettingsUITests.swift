import XCTest

/// Round-5 Connection Setup UI coverage: the Settings entry for an
/// already-connected user. The app starts in the inert DEBUG connected stub
/// (`-CONDUIT_UI_TEST_CONNECTED_DASHBOARD`: a snapshot connection with no
/// transport), and the staged test runs against the deterministic
/// `-CONNECTION_SETUP_TEST_RESULT` stub — no test touches a real server.
final class ConnectionSetupSettingsUITests: XCTestCase {
    private enum Identity {
        static let stubDashboardURL = "https://conduit-uitest.example"
        static let settingsRow = "settings.connection-setup"
        static let urlField = "setup.url"
        static let next = "setup.next"
        static let username = "setup.username"
        static let password = "setup.password"
        static let testRun = "setup.test.run"
        static let useSettings = "setup.use-settings"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSettingsConnectionSetupTestsCurrentConnectionAndLeavesItUntouched() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", Identity.stubDashboardURL,
            "-CONNECTION_SETUP_TEST_RESULT", "success"
        ]
        app.launch()

        openSettings(app)

        // The Connection section carries the current dashboard (the Gateway
        // row) and the new Connection Setup entry.
        XCTAssertTrue(app.buttons[Identity.settingsRow].waitForExistence(timeout: 5))
        app.buttons[Identity.settingsRow].tap()

        // The wizard opens on the prefilled connection-details screen — no
        // first-run readiness questions — with the current URL preserved
        // exactly.
        let urlField = app.textFields[Identity.urlField]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5), "Wizard did not open on connection details. Tree:\n\(app.debugDescription)")
        XCTAssertEqual(urlField.value as? String, Identity.stubDashboardURL)

        tapVisible(app.buttons[Identity.next], in: app)
        let username = app.textFields[Identity.username]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        tapVisible(username, in: app)
        username.typeText("uitest-user")
        let password = app.secureTextFields[Identity.password]
        tapVisible(password, in: app)
        password.typeText("uitest-fixture")
        dismissKeyboard(app)
        tapVisible(app.buttons[Identity.next], in: app)

        // The real Round-4 staged test screen, driven by the stub.
        XCTAssertTrue(app.buttons[Identity.testRun].waitForExistence(timeout: 5), "Test screen did not appear. Tree:\n\(app.debugDescription)")
        tapVisible(app.buttons[Identity.testRun], in: app)
        XCTAssertTrue(app.staticTexts["setup.test.ready"].waitForExistence(timeout: 5))

        // Applying the changed configuration (a typed password) closes the
        // wizard and lands back on Settings. Nothing connects, no reconnect
        // fires, and the session stub is untouched.
        tapVisible(app.buttons[Identity.useSettings], in: app)
        XCTAssertTrue(app.buttons[Identity.settingsRow].waitForExistence(timeout: 5), "Wizard did not return to Settings. Tree:\n\(app.debugDescription)")

        // Unchanged URL and no previously saved credentials: applying is a
        // no-op, so no confirmation alert appears.
        XCTAssertFalse(app.alerts.firstMatch.exists, "A no-op apply must not claim to have changed settings")

        // The active connection is intact: still inside Settings, still the
        // stubbed connected session, never bounced to the login card.
        XCTAssertFalse(app.textFields["login.server-url"].exists, "The live session must never be disrupted by the wizard")
        XCTAssertTrue(app.staticTexts[Identity.stubDashboardURL].firstMatch.exists, "The Gateway row still shows the current dashboard")
    }

    // MARK: - Walk helpers

    private func openSettings(_ app: XCUIApplication) {
        let sessions = app.buttons["Open sessions"]
        XCTAssertTrue(sessions.waitForExistence(timeout: 10), "Main app shell did not appear. Tree:\n\(app.debugDescription)")
        sessions.tap()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Sidebar did not appear. Tree:\n\(app.debugDescription)")
        settings.tap()
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

    private func dismissKeyboard(_ app: XCUIApplication) {
        let done = app.buttons["setup.keyboard-done"]
        guard done.waitForExistence(timeout: 2) else { return }
        done.tap()
    }
}
