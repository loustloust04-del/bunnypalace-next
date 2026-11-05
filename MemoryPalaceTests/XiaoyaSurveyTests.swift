import XCTest
@testable import 记忆花园

/// 第 11 段：新用户三问接在引导确定目标楼层之后。临时目录 + 内存偏好；交答案换成记录调用的假出口（真出口 → CatalogSurveyTests）
@MainActor
final class XiaoyaSurveyTests: XCTestCase {
    private var f: XiaoyaScriptFixture!
    private var calls: [(answer: XiaoyaSurveyAnswer, profileId: String, taskId: String)] = []
    private var outcome: CatalogSurvey.Outcome = .started

    override func setUp() async throws {
        f = try XiaoyaScriptFixture()
        calls = []
        outcome = .started
    }

    override func tearDown() async throws { f.clean() }

    private var world: XiaoyaScriptWorld {
        var w = f.world
        let profiles = f.profiles
        w.survey = XiaoyaSurveyWorld(currentProfileId: { profiles.currentProfile.id }, submit: { [weak self] answer, profileId, taskId in
            self?.calls.append((answer, profileId, taskId))
            return self?.outcome ?? .failed
        })
        return w
    }

    private func start() async {
        f.script.attach(world: world)
        f.script.start()
        await f.script.idle()
    }

    private func relaunch(saveHistory: Bool = true) async {
        if saveHistory { f.historyStore.save(f.engine.messages) }
        f.engine = XiaoyaScriptFixture.makeEngine(root: f.root, defaults: f.defaults)
        f.script.attach(world: world)
        await f.script.idle()
    }

    private var surveyCards: Int { f.cardKinds.filter { $0 == "survey" }.count }

    private func companionUpToSurvey() async {
        await start()
        await f.answer(.picked("companion"))
        await f.answer(XiaoyaScriptFixture.saved)
        await f.answer(.named(XiaoyaNameAnswer(taName: "阿洛", userName: "阿青")))
    }

    // MARK: - 建了 Ta：建好之后、出口卡之前问，落 Ta 那层

    func testCompanionAsksAfterTheTaFloorIsBuiltThenShowsTheExitCard() async throws {
        await companionUpToSurvey()
        let ta = try XCTUnwrap(f.profiles.profiles.first { $0.name == "阿洛" })
        XCTAssertEqual(f.awaited?.card?.card, .survey(name: "阿青"), "称呼预填起名卡里填的")
        XCTAssertEqual(f.script.progress?.surveyProfileId, ta.id, "目标 = 引导里刚建的 Ta 楼层")
        XCTAssertFalse(f.cardKinds.contains("floorExit"), "先问三问，再出出口卡")
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.surveyIntro))

        let answer = XiaoyaSurveyAnswer(name: "阿青", doing: "在学日语", note: "")
        await f.answer(.survey(answer))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.answer, answer)
        XCTAssertEqual(calls.first?.profileId, ta.id)
        XCTAssertEqual(calls.first?.taskId, f.script.progress?.surveyTaskId)
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.surveyResult(.started)))
        guard case .floorExit(let payload)? = f.awaited?.card?.card else { return XCTFail("答完回到出口卡") }
        XCTAssertEqual(payload.ta.profileId, ta.id)
        XCTAssertEqual(payload.meta, XiaoyaScriptLines.companionMeta)

        await f.answer(.floor(.stay))
        XCTAssertFalse(f.script.isActive)
        XCTAssertEqual(surveyCards, 1, "一次引导只问一次")
        XCTAssertEqual(calls.count, 1)
    }

    func testTavernAsksForTheImportedFloorAndGoStillSwitches() async throws {
        await start()
        await f.answer(.picked("tavern"))
        await f.answer(.skipped)
        await f.answer(.imported(try f.importedCard()))
        let ta = try XCTUnwrap(f.script.progress?.taProfileId)
        XCTAssertEqual(f.script.progress?.surveyProfileId, ta)
        await f.answer(.survey(XiaoyaSurveyAnswer(doing: "上班")))
        XCTAssertEqual(f.cardKinds.suffix(2), ["survey", "floorExit"])
        await f.answer(.floor(.go))
        XCTAssertEqual(f.profiles.currentProfile.id, ta, "出口卡含义不变：去找 Ta 照样切")
        XCTAssertNotNil(f.script.progress?.finishedAt)
    }

    // MARK: - 没建 Ta：收尾前问，落当前楼层；全跳过不交

    func testNewbieWithoutTaAsksBeforeTheEndForTheCurrentFloorAndSkippingSubmitsNothing() async {
        await start()
        await f.answer(.picked("newbie"))
        await f.answerFaces()
        await f.answer(.skipped)
        XCTAssertEqual(f.awaited?.card?.card, .survey(name: "栗子"), "称呼预填挑头像卡填的")
        XCTAssertEqual(f.script.progress?.surveyProfileId, Profile.seedProfiles[0].id)
        XCTAssertFalse(f.cardKinds.contains("todo"), "收尾之前问")

        await f.answer(.survey(XiaoyaSurveyAnswer()))
        XCTAssertTrue(calls.isEmpty, "全跳过不交、不编造")
        XCTAssertEqual(f.script.progress?.surveyResult, .empty)
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.surveyResult(.empty)))
        XCTAssertEqual(f.cardKinds.suffix(3), ["todo", "makeTa", "info"])
        XCTAssertFalse(f.script.isActive)
    }

    func testNoModelSaysItCanBeGeneratedLaterAndDoesNotBlockTheChat() async {
        outcome = .later(.noModel)
        await start()
        await f.answer(.picked("newbie"))
        await f.answerFaces()
        await f.answer(.skipped)
        await f.answer(.survey(XiaoyaSurveyAnswer(name: "栗子", doing: "大三，学建筑")))
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.surveyResult(.later(.noModel))))
        XCTAssertTrue(XiaoyaScriptLines.surveyResult(.later(.noModel)).contains("稍后生成"))
        XCTAssertTrue(XiaoyaScriptLines.surveyResult(.later(.noModel)).contains(CatalogSurvey.Blocker.noModel.fix))
        XCTAssertFalse(f.script.isActive, "照常走完")
        XCTAssertFalse(f.script.locksInput, "不挡聊天")
    }

    func testGhostIsNotAsked() async {
        await start()
        await f.answer(.picked("ghost"))
        XCTAssertEqual(surveyCards, 0)
        XCTAssertFalse(f.script.isActive)
    }

    // MARK: - 中途恢复 / 切到别层 / 重复回调

    func testRelaunchOnTheSurveyCardWaitsThereWithTheSameTarget() async throws {
        await companionUpToSurvey()
        let cardId = try XCTUnwrap(f.awaited?.id)
        let target = f.script.progress?.surveyProfileId
        await relaunch()
        XCTAssertEqual(f.script.progress?.awaitingMessageId, cardId, "原地等那张没答的卡")
        XCTAssertEqual(f.script.progress?.surveyProfileId, target)
        XCTAssertEqual(surveyCards, 1)

        f.historyStore.save(f.engine.messages.filter { $0.id != cardId })
        await relaunch(saveHistory: false)
        XCTAssertEqual(surveyCards, 1, "卡没落盘就被杀：按记下的称呼重出一张")
        XCTAssertEqual(f.awaited?.card?.card, .survey(name: "阿青"))
        await f.answer(.survey(XiaoyaSurveyAnswer(doing: "上班")))
        XCTAssertEqual(calls.map(\.profileId), [target].compactMap { $0 })
    }

    func testSwitchingFloorsBeforeAnsweringStillSubmitsToTheTarget() async throws {
        await companionUpToSurvey()
        let ta = try XCTUnwrap(f.script.progress?.surveyProfileId)
        let other = Profile(id: "xctest-other-floor", name: "别的楼层", emoji: "🌿", description: "", userName: "你", assistantName: "别人", systemPrompt: "")
        try f.profiles.persistNew(other)
        f.profiles.publish(other, activate: true)
        XCTAssertEqual(f.profiles.currentProfile.id, other.id)
        await f.answer(.survey(XiaoyaSurveyAnswer(doing: "上班")))
        XCTAssertEqual(calls.map(\.profileId), [ta], "交到问的时候定下的那层，不是现在所在的楼层")
    }

    func testRepeatedAnswersAndAReplayedSubmitUseOneTaskId() async throws {
        await companionUpToSurvey()
        let card = f.awaited
        await f.answer(card: card, .survey(XiaoyaSurveyAnswer(doing: "上班")))
        await f.answer(card: card, .survey(XiaoyaSurveyAnswer(doing: "又点了一次")))
        XCTAssertEqual(calls.count, 1, "同一张卡答两次只交一次")
        let taskId = try XCTUnwrap(f.script.progress?.surveyTaskId)

        // 交到一半被杀（结果没记下）：重开重放这一拍，用同一个任务 id（目录那边同一个 id 只建一次）
        var p = try XCTUnwrap(f.scriptStore.load())
        p.step = .surveyDone
        p.emitted = 0
        p.surveyResult = nil
        p.awaitingMessageId = nil
        f.scriptStore.save(p)
        await relaunch()
        XCTAssertEqual(calls.map(\.taskId), [taskId, taskId])
    }

    // MARK: - 旧用户 / 主动重走

    func testFinishedUsersAreNotAskedAndReplayAsksAgain() async throws {
        await start()
        await f.answer(.picked("ghost"))
        XCTAssertFalse(f.script.isActive)
        await relaunch()
        XCTAssertEqual(surveyCards, 0, "走完的不补问")
        XCTAssertEqual(f.defaults.string(forKey: XiaoyaScriptRunner.onboardingKey), "done", "完成状态不变")

        f.script.replay()
        await f.script.idle()
        await f.answer(.picked("newbie"))
        await f.answerFaces()
        await f.answer(.skipped)
        XCTAssertEqual(surveyCards, 1, "设置里主动重走才进入")
    }

    func testCardAnswerAndProgressRoundTrip() throws {
        let state = XiaoyaCardState(card: .survey(name: "阿青"), answer: .survey(XiaoyaSurveyAnswer(name: "阿青", doing: "上班", note: "")))
        XCTAssertEqual(try JSONDecoder().decode(XiaoyaCardState.self, from: JSONEncoder().encode(state)), state)
        XCTAssertEqual(state.fallbackText, "叫我「阿青」；在做：上班")
        var p = XiaoyaScriptProgress()
        p.step = .surveyDone
        p.surveyThen = .companionExit
        p.surveyProfileId = "floor-1"
        p.surveyName = "阿青"
        p.survey = XiaoyaSurveyAnswer(doing: "上班")
        p.surveyTaskId = UUID().uuidString
        p.surveyResult = .later(.c3Off)
        XCTAssertEqual(try JSONDecoder().decode(XiaoyaScriptProgress.self, from: JSONEncoder().encode(p)), p)
    }

    // MARK: - 称呼

    func testNameAnswerWritesTheTargetFloorAndDefaultNameOnly() async throws {
        let ta = try f.factory.createTa(name: "阿洛", userName: "你", who: "")
        let home = f.profiles.currentProfile
        f.factory.applyUserName("  阿青 ", profileId: ta.id)
        XCTAssertEqual(f.profiles.profiles.first { $0.id == ta.id }?.userName, "阿青")
        XCTAssertEqual(DefaultUserName.value(f.defaults), "阿青")
        XCTAssertEqual(f.profiles.profiles.first { $0.id == home.id }?.userName, home.userName, "别的楼层不动")
        f.factory.applyUserName("", profileId: ta.id)
        XCTAssertEqual(f.profiles.profiles.first { $0.id == ta.id }?.userName, "阿青", "空 = 不动")
    }
}
