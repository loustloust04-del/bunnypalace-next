#if os(macOS)
import XCTest
@testable import 记忆花园

final class AppPathsTests: XCTestCase {
    func testNonBenchPathsExactlyMatchFileManager() {
        XCTAssertFalse(BenchIsolation.requested)
        let fm = FileManager.default
        let paths = [
            ("home", AppPaths.home, fm.homeDirectoryForCurrentUser),
            ("appSupport", AppPaths.applicationSupport, fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]),
            ("caches", AppPaths.caches, fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]),
            ("documents", AppPaths.documents, fm.urls(for: .documentDirectory, in: .userDomainMask)[0]),
            ("temporary", AppPaths.temporaryDirectory, fm.temporaryDirectory)
        ]
        for (name, actual, original) in paths {
            XCTAssertEqual(actual.absoluteString, original.absoluteString, name)
        }
    }

    func testEmptyDocumentsQueryPreservesNilFallback() {
        XCTAssertNil(KBProbe.logURL(documents: []))
    }
}
#endif
