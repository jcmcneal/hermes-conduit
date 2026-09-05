import XCTest

/// Round-2 Connection Setup wizard UI coverage: the guided flow opens from the
/// login card's entry point, walks Dashboard → Credentials → Access Method,
/// supports back navigation, shows Copy Prompt on the No / I don't know
/// paths, and reaches the Tailscale branch. Everything runs offline — no
/// step performs network I/O.
final class ConnectionSetupUITests: XCTestCase {
    private enum Identity {
        static let connectionSetup = "login.connection-setup"
        static let done = "connection-setup.done"
        static let back = "setup.back"
        static let answerYes = "setup.answer-yes"
        static let answerNo = "setup.answer-no"
        static let answerUnknown = "setup.answer-unknown"
        static let copyPrompt = "setup.copy-prompt"
        static let methodTailscale = "setup.method-tailscale"
        static let stepLabel = "setup.step-label"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openSetup(_ app: XCUIApplication) {
        let serverField = app.textFields["login.server-url"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 10), "Login screen did not appear. Tree:\n\(app.debugDescription)")

        let setup = app.buttons[Identity.connectionSetup]
        XCTAssertTrue(setup.waitForExistence(timeout: 5), "Connection Setup entry point missing. Tree:\n\(app.debugDescription)")
        if !setup.isHittable { app.swipeDown() }
        XCTAssertTrue(pollHittability(of: setup, timeout: 5))
        setup.tap()
    }

    private func stepLabel(_ app: XCUIApplication, _ expected: String) {
        let label = app.staticTexts[Identity.stepLabel]
        XCTAssertTrue(
            label.waitForExistence(timeout: 5) && label.label == expected,
            "Expected step '\(expected)', saw '\(label.exists ? label.label : "none")'. Tree:\n\(app.debugDescription)"
        )
    }

    func testWizardAdvancesThroughQuestionsToTailscaleBranchAndBack() throws {
        let app = XCUIApplication()
        app.launch()
        openSetup(app)

        // Step 1: dashboard readiness, answered No → Ask Hermes guidance.
        stepLabel(app, "Step 1 of 3")
        let no = app.buttons[Identity.answerNo]
        XCTAssertTrue(no.waitForExistence(timeout: 5), "Dashboard answers missing. Tree:\n\(app.debugDescription)")
        if !no.isHittable { app.swipeUp() }
        no.tap()

        let copyPrompt = app.buttons[Identity.copyPrompt]
        XCTAssertTrue(copyPrompt.waitForExistence(timeout: 5), "Copy Prompt must appear on the No path")
        if !copyPrompt.isHittable { app.swipeUp() }
        copyPrompt.tap()
        XCTAssertTrue(
            app.staticTexts["setup.copied-confirmation"].waitForExistence(timeout: 3),
            "Copying must confirm to the user"
        )

        let continueButton = app.buttons["setup.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 3))
        if !continueButton.isHittable { app.swipeUp() }
        XCTAssertTrue(pollHittability(of: continueButton, timeout: 3))
        continueButton.tap()

        // Step 2: credentials, answered Yes.
        stepLabel(app, "Step 2 of 3")
        let yes = app.buttons[Identity.answerYes]
        XCTAssertTrue(yes.waitForExistence(timeout: 5))
        if !yes.isHittable { app.swipeUp() }
        yes.tap()

        // Step 3: access method, choose Tailscale.
        stepLabel(app, "Step 3 of 3")
        let tailscale = app.buttons[Identity.methodTailscale]
        XCTAssertTrue(tailscale.waitForExistence(timeout: 5), "Tailscale method card missing. Tree:\n\(app.debugDescription)")
        if !tailscale.isHittable { app.swipeUp() }
        XCTAssertTrue(pollHittability(of: tailscale, timeout: 3))
        tailscale.tap()

        // Tailscale branch mentions Tailscale Serve.
        let serve = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Tailscale Serve'")
        ).firstMatch
        XCTAssertTrue(serve.waitForExistence(timeout: 5), "Tailscale branch must present the Tailscale Serve path")

        // Back navigation returns through the wizard.
        let back = app.buttons[Identity.back]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        stepLabel(app, "Step 3 of 3")

        back.tap()
        stepLabel(app, "Step 2 of 3")

        let done = app.buttons[Identity.done]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(
            serverFieldAgain(app).waitForExistence(timeout: 5),
            "Done must return to the login form"
        )
    }

    func testDontKnowPathShowsCopyPromptAndCompactsStayScrollable() throws {
        let app = XCUIApplication()
        app.launch()
        openSetup(app)

        stepLabel(app, "Step 1 of 3")
        let unknown = app.buttons[Identity.answerUnknown]
        XCTAssertTrue(unknown.waitForExistence(timeout: 5))
        if !unknown.isHittable { app.swipeUp() }
        unknown.tap()

        let copyPrompt = app.buttons[Identity.copyPrompt]
        XCTAssertTrue(copyPrompt.waitForExistence(timeout: 5), "Copy Prompt must appear on the I don't know path")

        // Compact layout: the continue action below the prompt must remain
        // reachable by scrolling.
        let continueButton = app.buttons["setup.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 3))
        var hittable = continueButton.isHittable
        var attempts = 0
        while !hittable, attempts < 3 {
            app.swipeUp()
            hittable = continueButton.isHittable
            attempts += 1
        }
        XCTAssertTrue(hittable, "Continue must stay reachable on a compact iPhone layout")

        continueButton.tap()
        stepLabel(app, "Step 2 of 3")
    }

    private func serverFieldAgain(_ app: XCUIApplication) -> XCUIElement {
        app.textFields["login.server-url"]
    }

    /// XCUIElement has no waitForHittability; poll isHittable on a deadline.
    private func pollHittability(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return element.isHittable
    }
}
