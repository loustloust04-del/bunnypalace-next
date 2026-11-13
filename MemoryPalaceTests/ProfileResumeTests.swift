import XCTest
@testable import 记忆花园

final class ProfileResumeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var store: ProfileResume!

    override func setUp() {
        super.setUp()
        suite = "xctest-profile-resume-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        store = ProfileResume(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testSaveThenReadBackPerProfile() {
        store.save(.init(page: 0, conversationId: "c1"), for: "a")
        store.save(.init(page: 2, conversationId: ""), for: "b")
        XCTAssertEqual(store.spot(for: "a"), .init(page: 0, conversationId: "c1"))
        XCTAssertEqual(store.spot(for: "b"), .init(page: 2, conversationId: ""))
    }

    func testSaveOverwritesSameProfile() {
        store.save(.init(page: 0, conversationId: "c1"), for: "a")
        store.save(.init(page: 1, conversationId: "c2"), for: "a")
        XCTAssertEqual(store.spot(for: "a"), .init(page: 1, conversationId: "c2"))
    }

    func testClearOnlyRemovesThatProfile() {
        store.save(.init(page: 0, conversationId: "c1"), for: "a")
        store.save(.init(page: 1, conversationId: "c2"), for: "b")
        store.clear("a")
        XCTAssertNil(store.spot(for: "a"))
        XCTAssertEqual(store.spot(for: "b"), .init(page: 1, conversationId: "c2"))
    }

    func testUnknownProfileReturnsNil() {
        XCTAssertNil(store.spot(for: "nobody"))
        store.save(.init(page: 1, conversationId: ""), for: "a")
        XCTAssertNil(store.spot(for: "nobody"))
    }

    func testPersistsAcrossInstances() {
        store.save(.init(page: 0, conversationId: "c1"), for: "a")
        XCTAssertEqual(ProfileResume(defaults: defaults).spot(for: "a"), .init(page: 0, conversationId: "c1"))
    }
}
