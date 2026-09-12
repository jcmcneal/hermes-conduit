import Foundation
import XCTest
@testable import Conduit

final class InterfaceOrientationTests: XCTestCase {
    private func appInfoDictionary() throws -> [String: Any] {
        // Resolve the executable hosting the app type so product renames and
        // configuration-specific bundle identifiers keep testing the real app.
        let bundle = Bundle(for: AppState.self)
        let infoData = try Data(contentsOf: bundle.bundleURL.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        )
    }

    func testUniversalOrientationsRemainPortraitOnlyForIPhone() throws {
        let info = try appInfoDictionary()
        XCTAssertEqual(
            info["UISupportedInterfaceOrientations"] as? [String],
            ["UIInterfaceOrientationPortrait"]
        )
    }

    func testIPadOrientationsIncludeBothLandscapeDirections() throws {
        let info = try appInfoDictionary()
        XCTAssertEqual(
            info["UISupportedInterfaceOrientations~ipad"] as? [String],
            [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight"
            ]
        )
        XCTAssertNil(info["UIRequiresFullScreen"])
    }
}
