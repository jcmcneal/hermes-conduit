import XCTest

final class MessagingUITests: XCTestCase {
    func testMissingPluginOffersSetupAndPreservesTheSessionShelf() {
        let app = XCUIApplication()
        app.launchArguments += ["-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-uitest.example", "-CONDUIT_UI_TEST_INBOX_FIXTURE", "multi-profile", "-CONDUIT_UI_TEST_MESSAGING", "-CONDUIT_UI_TEST_MESSAGING_MISSING", "-conduit.messaging.discovery.v1.ui-test-messaging", "NO"]
        app.launch()
        let enable = app.buttons["messaging.enable"]
        XCTAssertTrue(enable.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.segmentedControls.firstMatch.exists)
        enable.tap()
        XCTAssertTrue(app.staticTexts["A shared inbox for your bots"].waitForExistence(timeout: 5))
        let setup = XCTAttachment(screenshot: app.screenshot()); setup.name = "Optional messaging setup"; setup.lifetime = .keepAlways; add(setup)
        XCTAssertFalse(app.buttons["Install on Hermes"].exists, "Do not offer an unsupported installer")
        app.buttons["Close"].tap()
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
    }

    func testMessagingInboxOpensDMAndSendsWithoutSessionSheet() {
        let app = XCUIApplication()
        app.launchArguments += ["-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-uitest.example", "-CONDUIT_UI_TEST_INBOX_FIXTURE", "multi-profile", "-CONDUIT_UI_TEST_MESSAGING"]
        app.launch()
        let designer = app.buttons.matching(NSPredicate(format: "label == %@", "Designer")).firstMatch
        XCTAssertTrue(designer.waitForExistence(timeout: 10), app.debugDescription)
        let inbox = XCTAttachment(screenshot: app.screenshot()); inbox.name = "Messaging inbox"; inbox.lifetime = .keepAlways; add(inbox)
        designer.tap()
        let composer = app.textFields["messaging.composer"]
        let multiline = app.textViews["messaging.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5) || multiline.exists, app.debugDescription)
        let field = composer.exists ? composer : multiline
        field.tap(); field.typeText("Looks good")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@ OR label == %@", "Looks good", "Looks good")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let chat = XCTAttachment(screenshot: app.screenshot()); chat.name = "Persistent DM"; chat.lifetime = .keepAlways; add(chat)
        app.buttons["Inbox"].tap()
        XCTAssertTrue(designer.waitForExistence(timeout: 5))
    }
}
