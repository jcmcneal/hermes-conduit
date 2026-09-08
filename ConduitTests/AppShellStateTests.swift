import XCTest
@testable import Conduit

@MainActor
final class AppShellStateTests: XCTestCase {
    func testAdmitRejectsSupersededOpenGeneration() {
        let shell = AppShellState()
        let first = shell.beginConversationOpen(sessionID: "a", reason: .rowSelection)
        let second = shell.beginConversationOpen(sessionID: "b", reason: .rowSelection)

        XCTAssertFalse(shell.admitConversationOpen(generation: first, sessionID: "a"))
        XCTAssertEqual(shell.compactRoute, .inbox)
        XCTAssertTrue(shell.admitConversationOpen(generation: second, sessionID: "b"))
        XCTAssertEqual(shell.compactRoute, .conversation)
    }

    func testShowInboxClearsPendingOpen() {
        let shell = AppShellState()
        _ = shell.beginConversationOpen(sessionID: "a", reason: .rowSelection)
        shell.showConversationWithoutOpenRequest()
        XCTAssertEqual(shell.compactRoute, .conversation)

        shell.showInbox()
        XCTAssertEqual(shell.compactRoute, .inbox)
        XCTAssertNil(shell.pendingOpen)
        XCTAssertFalse(shell.isCreatingConversation)
    }

    func testResetListTransientStateClearsSearch() {
        let shell = AppShellState()
        shell.isConversationSearchActive = true
        shell.conversationSearchText = "hello"
        shell.resetListTransientState()
        XCTAssertFalse(shell.isConversationSearchActive)
        XCTAssertEqual(shell.conversationSearchText, "")
    }

    func testReturnSurfaceSkipsWhenAlreadyShowingInbox() {
        XCTAssertFalse(
            AppShellState.shouldPresentInboxForReturnSurface(
                persistentSidebarActive: true,
                alreadyShowingInbox: false
            )
        )
        XCTAssertFalse(
            AppShellState.shouldPresentInboxForReturnSurface(
                persistentSidebarActive: false,
                alreadyShowingInbox: true
            )
        )
        XCTAssertTrue(
            AppShellState.shouldPresentInboxForReturnSurface(
                persistentSidebarActive: false,
                alreadyShowingInbox: false
            )
        )
    }
}
