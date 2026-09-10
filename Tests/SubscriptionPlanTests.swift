import XCTest
@testable import Codenotch

final class SubscriptionPlanTests: XCTestCase {
    func testKnownTiersKeepTheProvidersOwnNames() {
        XCTAssertEqual(SubscriptionPlan.display("plus"), "Plus")
        XCTAssertEqual(SubscriptionPlan.display("pro"), "Pro")
        XCTAssertEqual(SubscriptionPlan.display("max"), "Max")
        XCTAssertEqual(SubscriptionPlan.display("max_5x"), "Max 5x")
        XCTAssertEqual(SubscriptionPlan.display("max-20x"), "Max 20x")
        XCTAssertEqual(SubscriptionPlan.display("team"), "Team")
        XCTAssertEqual(SubscriptionPlan.display("lite"), "Lite")
        XCTAssertEqual(SubscriptionPlan.display("extra_usage"), "Extra")
        XCTAssertEqual(SubscriptionPlan.display("goat"), "GOAT")
        XCTAssertEqual(SubscriptionPlan.display("go"), "Go")
        XCTAssertEqual(SubscriptionPlan.display("free"), "Free")
    }

    func testEmptyAndGenericSubscriptionAreNotShown() {
        XCTAssertNil(SubscriptionPlan.display(nil))
        XCTAssertNil(SubscriptionPlan.display(""))
        XCTAssertNil(SubscriptionPlan.display("  "))
        XCTAssertNil(SubscriptionPlan.display("subscription"))
    }

    func testUnknownSlugsAreTitleCasedRatherThanInvented() {
        XCTAssertEqual(SubscriptionPlan.display("coding_plan_max"), "Max")
        XCTAssertEqual(SubscriptionPlan.display("hobby"), "Hobby")
    }
}
