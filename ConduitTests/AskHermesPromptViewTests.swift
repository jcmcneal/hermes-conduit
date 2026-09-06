//
//  AskHermesPromptViewTests.swift
//  Conduit
//
//  Deterministic coverage for the Copy Prompt confirmation race: when a
//  second copy tap replaces the confirmation task, SwiftUI cancels the
//  first task's sleep — and that cancellation must NOT clear the second
//  tap's fresh confirmation. The sleep is injected, so both outcomes are
//  exercised without real timers.
//

import XCTest
@testable import Conduit

final class AskHermesPromptViewTests: XCTestCase {
    func testCancelledConfirmationWindowDoesNotClearCopied() async {
        // The real cancellation mechanism: the window's own Task.sleep is
        // cancelled mid-sleep (as SwiftUI does when a second tap replaces
        // the task). Deterministic — cancellation during the sleep always
        // throws, so no timing is involved.
        var cleared = false
        let window = Task {
            await AskHermesPromptView.runCopiedConfirmation(
                duration: .seconds(3600),
                onExpire: { cleared = true }
            )
        }
        window.cancel()
        await window.value
        XCTAssertFalse(
            cleared,
            "A cancelled confirmation task must not clear the replacement tap's fresh confirmation"
        )
    }

    func testUncancelledConfirmationWindowClearsCopiedOnExpiry() async {
        // The active (uncancelled) confirmation task is the only thing that
        // may reset `copied`, and it does so when its window expires.
        var cleared = false
        await AskHermesPromptView.runCopiedConfirmation(
            duration: .seconds(0),
            onExpire: { cleared = true }
        )
        XCTAssertTrue(
            cleared,
            "An uncancelled confirmation task must clear the copied flag on expiry"
        )
    }
}
