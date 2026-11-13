import XCTest
@testable import 记忆花园

final class GardenBrowserRoutingTests: XCTestCase {
    func testAddressInputURLs() {
        XCTAssertEqual(AddressInput.url(for: "https://x.com/a?b=1")?.absoluteString, "https://x.com/a?b=1")
        XCTAssertEqual(AddressInput.url(for: "  youtube.com/watch?v=1 ")?.absoluteString, "https://youtube.com/watch?v=1")
        XCTAssertEqual(AddressInput.url(for: "www.zhihu.com")?.absoluteString, "https://www.zhihu.com")
        XCTAssertEqual(AddressInput.url(for: "localhost:3000/x")?.absoluteString, "http://localhost:3000/x")
        XCTAssertEqual(AddressInput.url(for: "192.168.1.8:7890")?.absoluteString, "http://192.168.1.8:7890")
        XCTAssertNil(AddressInput.url(for: "   "))
    }

    func testAddressInputSearches() {
        for raw in ["手冲 水温", "什么是.net", "swiftui", "a.b1", "hello world.com", "1.2.3"] {
            XCTAssertEqual(AddressInput.kind(of: raw), .search, raw)
        }
        let url = AddressInput.url(for: "手冲 水温")
        XCTAssertEqual(url?.host(), "www.google.com")
        XCTAssertEqual(URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "手冲 水温")
    }

    func testRoutingDestination() {
        let web = URL(string: "https://x.com/i/status/1")!
        XCTAssertEqual(GardenBrowserRouting.destination(for: web, mode: .inApp), .inApp)
        XCTAssertEqual(GardenBrowserRouting.destination(for: web, mode: .safari), .system)
        XCTAssertEqual(GardenBrowserRouting.destination(for: URL(string: "mailto:a@b.c")!, mode: .inApp), .system)
        XCTAssertEqual(GardenBrowserRouting.destination(for: URL(string: "tel:10086")!, mode: .inApp), .system)
        XCTAssertEqual(GardenBrowserRouting.destination(for: URL(string: "https://apps.apple.com/app/id1")!, mode: .inApp), .system)
        XCTAssertEqual(GardenBrowserRouting.destination(for: URL(string: "ticker://AAPL")!, mode: .inApp), .system)
    }
}
