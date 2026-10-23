import AppKit
import XCTest
@testable import Srez

final class ResourcesTests: XCTestCase {
    func testSummarizeIconLoadsFromResources() {
        XCTAssertNotNil(Bundle.module.image(forResource: "Summarize"))
    }
}
