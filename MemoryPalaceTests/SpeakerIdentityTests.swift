import XCTest
@testable import 记忆花园

final class SpeakerIdentityTests: XCTestCase {
    func person(_ name: String, _ vector: [Float], count: Int = 10) -> SpeakerIdentity {
        SpeakerIdentity(id: name, name: name, role: .owner, vectors: Array(repeating: vector, count: count), sampleHashes: [])
    }
    func testMatchStatesAndEnrollmentGate() {
        let owner = person("本人", [1, 0])
        XCTAssertEqual(SpeakerMatcher.match([1, 0], identities: [owner]).status, .matched)
        XCTAssertEqual(SpeakerMatcher.match([0.87, sqrt(1 - 0.87 * 0.87)], identities: [owner]).status, .likely)
        XCTAssertEqual(SpeakerMatcher.match([0, 1], identities: [owner]).status, .unknown)
        XCTAssertEqual(SpeakerMatcher.match([1, 0], identities: [owner, person("熟人", [1, 0])]).status, .ambiguous)
        XCTAssertEqual(SpeakerMatcher.match([1, 0], identities: [person("未就绪", [1, 0], count: 9)]).status, .unavailable)
        XCTAssertEqual(SpeakerMatcher.match([1, 0, 0], identities: [owner]).status, .unavailable)
    }
    func testFiniteNormalizedVectorsAndCue() throws {
        XCTAssertNil(SpeakerMatcher.normalized([.nan])); XCTAssertNil(SpeakerMatcher.normalized([0, 0]))
        XCTAssertEqual(try XCTUnwrap(SpeakerMatcher.normalized([3, 4]))[0], 0.6, accuracy: 0.0001)
        XCTAssertNil(SpeakerMatcher.centroid([[1], [1, 0]]))
        XCTAssertNil(SpeakerMatch(status: .unavailable).cue)
        XCTAssertFalse(SpeakerMatch(status: .ambiguous, name: "不该出现").cue!.contains("不该出现"))
    }
    func testNoModelAndResetIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sentinel = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let store = SpeakerIdentityStore(root: root)
        let result = await store.recognize(url: root.appendingPathComponent("absent.wav"))
        XCTAssertEqual(result.status, .unavailable)
        do { try await store.add(name: "本人", role: .owner); XCTFail("requires model") }
        catch SpeakerIdentityError.noModel {}
        try await store.resetAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        let people = try await store.identities(); XCTAssertTrue(people.isEmpty)
    }
    func testRealONNXEnrollmentAndDuplicate() async throws {
        guard let path = ProcessInfo.processInfo.environment["MP_SPEAKER_TEST_FIXTURES"] else {
            throw XCTSkip("需要显式传入官方公开 ONNX / WAV 探针目录")
        }
        let fixtures = URL(fileURLWithPath: path), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerIdentityStore(root: root)
        try await store.importModel(fixtures.appendingPathComponent("model.onnx"), reset: false)
        try await store.add(name: "公开测试音频", role: .owner)
        let first = try await store.identities()[0]
        try await store.enroll(url: fixtures.appendingPathComponent("one.wav"), id: first.id)
        do { try await store.enroll(url: fixtures.appendingPathComponent("one.wav"), id: first.id); XCTFail("duplicate") }
        catch SpeakerIdentityError.duplicate {}
        try await store.enroll(url: fixtures.appendingPathComponent("two.wav"), id: first.id)
        try await store.add(name: "另一公开样本", role: .familiar)
        let other = try await store.identities()[1]
        try await store.enroll(url: fixtures.appendingPathComponent("other.wav"), id: other.id)
        let people = try await store.identities()
        XCTAssertEqual(people[0].vectors.count, 2); XCTAssertFalse(people[0].ready)
        let v = people[0].vectors[0]
        XCTAssertEqual(v.reduce(Float(0)) { $0 + $1 * $1 }, 1, accuracy: 0.001)
        XCTAssertGreaterThan(SpeakerMatcher.similarity(v, people[0].vectors[1]), SpeakerMatcher.similarity(v, people[1].vectors[0]))
        try await store.remove(id: first.id)
        let remaining = try await store.identities(); XCTAssertEqual(remaining.count, 1)
        try await store.resetAll()
        let empty = try await store.identities(); XCTAssertTrue(empty.isEmpty)
    }
}
