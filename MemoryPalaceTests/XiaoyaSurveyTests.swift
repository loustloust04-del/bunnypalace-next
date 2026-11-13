import XCTest
@testable import 记忆花园

/// 第 11 段：新用户三问接在引导确定目标楼层之后。临时目录 + 内存偏好；交答案换成记录调用的假出口（真出口 → CatalogSurveyTests）
@MainActor
final class XiaoyaSurveyTests: XCTestCase {
    private var f: XiaoyaScriptFixture!
    private var calls: [(answer: XiaoyaSurveyAnswer, profileId: String, taskId: String)] = []
    private var outcome: CatalogSurvey.Outcome = .started
    private var nameApplications: [String] = []
    private var nameFactory: OnboardingFloorFactory?

    override func setUp() async throws {
        f = try XiaoyaScriptFixture()
        calls = []
        outcome = .started
        nameApplications = []
        nameFactory = nil
    }

    override func tearDown() async throws { f.clean() }

    private var world: XiaoyaScriptWorld {
        var w = f.world
        let profiles = f.profiles
        let factory = f.factory
        w.survey = XiaoyaSurveyWorld(currentProfileId: { profiles.currentProfile.id },
                                    applyUserName: { [weak self] name, profileId in
            self?.nameApplications.append(name)
            try (self?.nameFactory ?? factory).applyUserName(name, profileId: profileId)
        }, submit: { [weak self] answer, profileId, taskId in
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
        await f.answer(.survey(XiaoyaSurveyAnswer(name: "目标新称呼", doing: "上班")))
        XCTAssertEqual(calls.map(\.profileId), [ta], "交到问的时候定下的那层，不是现在所在的楼层")
        XCTAssertEqual(f.profiles.profiles.first { $0.id == ta }?.userName, "目标新称呼")
        XCTAssertEqual(DefaultUserName.value(f.defaults), "目标新称呼")
        XCTAssertEqual(f.profiles.currentProfile, other, "保存目标称呼不切层，也不改后来切到的楼层")
    }

    func testRepeatedAnswersAndAReplayedSubmitUseOneTaskId() async throws {
        await companionUpToSurvey()
        let card = f.awaited
        await f.answer(card: card, .survey(XiaoyaSurveyAnswer(name: "问卷旧名", doing: "上班")))
        await f.answer(card: card, .survey(XiaoyaSurveyAnswer(doing: "又点了一次")))
        XCTAssertEqual(calls.count, 1, "同一张卡答两次只交一次")
        let taskId = try XCTUnwrap(f.script.progress?.surveyTaskId)
        let target = try XCTUnwrap(f.profiles.profiles.first { $0.id == f.script.progress?.surveyProfileId })
        XCTAssertEqual(target.userName, "问卷旧名")
        f.profiles.switchTo(target)
        try f.profiles.renameCurrent(userName: "通用页新名", assistantName: "")
        let renamedFile = try Data(contentsOf: profileFile)

        // 交到一半被杀（结果没记下）：重开重放这一拍，用同一个任务 id（目录那边同一个 id 只建一次）
        var p = try XCTUnwrap(f.scriptStore.load())
        p.step = .surveyDone
        p.emitted = 0
        p.surveyResult = nil
        p.awaitingMessageId = nil
        f.scriptStore.save(p)
        await relaunch()
        XCTAssertEqual(calls.map(\.taskId), [taskId, taskId])
        XCTAssertEqual(nameApplications, ["问卷旧名"], "已接受答案的恢复只能续种子任务")
        XCTAssertEqual(f.profiles.currentProfile.userName, "通用页新名")
        XCTAssertEqual(DefaultUserName.value(f.defaults), "通用页新名")
        XCTAssertEqual(try Data(contentsOf: profileFile), renamedFile, "恢复不再保存问卷旧称呼")
    }

    func testRelaunchWithAnUnacceptedAnswerStillSavesItsNameBeforeSubmitting() async throws {
        await companionUpToSurvey()
        let answer = XiaoyaSurveyAnswer(name: "待接受称呼", doing: "上班")
        var p = try XCTUnwrap(f.scriptStore.load())
        p.step = .surveyDone
        p.emitted = 0
        p.awaitingMessageId = nil
        p.pendingSurvey = answer
        XCTAssertNil(p.survey)
        f.scriptStore.save(p)

        await relaunch()
        XCTAssertEqual(nameApplications, [answer.name])
        XCTAssertEqual(f.profiles.profiles.first { $0.id == p.surveyProfileId }?.userName, answer.name)
        XCTAssertEqual(DefaultUserName.value(f.defaults), answer.name)
        XCTAssertEqual(f.script.progress?.survey, answer)
        XCTAssertNil(f.script.progress?.pendingSurvey)
        XCTAssertEqual(calls.count, 1)
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
        p.survey = nil
        p.surveyResult = nil
        p.surveyTaskId = nil
        p.pendingSurvey = XiaoyaSurveyAnswer(name: "尚未保存", doing: "上班")
        XCTAssertEqual(try JSONDecoder().decode(XiaoyaScriptProgress.self, from: JSONEncoder().encode(p)), p)
    }

    // MARK: - 称呼

    private var profileFile: URL {
        BlobStore.path(forKey: "savedProfiles", root: f.root.appendingPathComponent("blobs"))
    }

    func testFirstSubmissionSavesTheCurrentTargetBeforeAcceptingTheAnswer() async throws {
        await start()
        await f.answer(.picked("newbie"))
        await f.answerFaces()
        await f.answer(.skipped)
        let before = f.profiles.currentProfile
        let answer = XiaoyaSurveyAnswer(name: "  阿青 \n", doing: "上班")
        await f.answer(.survey(answer))

        XCTAssertEqual(calls.map(\.profileId), [before.id])
        XCTAssertEqual(nameApplications, [answer.name])
        XCTAssertEqual(f.profiles.currentProfile.userName, "阿青")
        XCTAssertEqual(f.profiles.currentProfile.assistantName, before.assistantName)
        XCTAssertEqual(f.profiles.currentProfile.userPersona, before.userPersona)
        XCTAssertEqual(DefaultUserName.value(f.defaults), "阿青")
        let saved = try JSONDecoder().decode([Profile].self, from: Data(contentsOf: profileFile))
        XCTAssertEqual(saved.first { $0.id == before.id }, f.profiles.currentProfile)
        XCTAssertEqual(f.script.progress?.survey, answer)
        XCTAssertNil(f.script.progress?.pendingSurvey)
    }

    func testReadOnlyNameSaveReopensTheSurveyWithoutAcceptingAndCanBeResubmitted() async throws {
        await companionUpToSurvey()
        let target = try XCTUnwrap(f.profiles.profiles.first { $0.id == f.script.progress?.surveyProfileId })
        f.profiles.switchTo(target)
        let readOnly = ProfileManager(container: f.container, profiles: f.profiles.profiles, currentProfile: target,
                                      loadError: CocoaError(.fileReadNoPermission),
                                      root: f.root.appendingPathComponent("blobs"), defaults: f.defaults, sideEffectsEnabled: false)
        nameFactory = OnboardingFloorFactory(profiles: readOnly, presets: f.presets, cards: f.cards, defaults: f.defaults)
        let fileBefore = try Data(contentsOf: profileFile)
        let profilesBefore = readOnly.profiles
        let defaultBefore = DefaultUserName.value(f.defaults)
        let mirrorBefore = f.defaults.string(forKey: "userName")
        let answer = XiaoyaSurveyAnswer(name: "待保存称呼", doing: "上班")
        await f.answer(.survey(answer))

        XCTAssertEqual(readOnly.currentProfile, target)
        XCTAssertEqual(readOnly.profiles, profilesBefore)
        XCTAssertEqual(f.profiles.currentProfile, target)
        XCTAssertEqual(try Data(contentsOf: profileFile), fileBefore)
        XCTAssertEqual(DefaultUserName.value(f.defaults), defaultBefore)
        XCTAssertEqual(f.defaults.string(forKey: "userName"), mirrorBefore)
        try assertSurveySaveWasNotAccepted(name: answer.name)

        nameFactory = nil
        await f.answer(.survey(answer))
        XCTAssertEqual(f.profiles.currentProfile.userName, answer.name)
        XCTAssertEqual(DefaultUserName.value(f.defaults), answer.name)
        XCTAssertEqual(f.script.progress?.survey, answer)
        XCTAssertEqual(calls.count, 1, "失败没有排种子，重新答卡保存成功后才排")
    }

    func testFailedNameWriteKeepsNamesAndFileUnchangedAndCanBeResubmitted() async throws {
        await companionUpToSurvey()
        let target = try XCTUnwrap(f.profiles.profiles.first { $0.id == f.script.progress?.surveyProfileId })
        f.profiles.switchTo(target)
        let profilesBefore = f.profiles.profiles
        let fileBefore = try Data(contentsOf: profileFile)
        let defaultBefore = DefaultUserName.value(f.defaults)
        let mirrorBefore = f.defaults.string(forKey: "userName")
        let blobs = f.root.appendingPathComponent("blobs")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blobs.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blobs.path) }
        let answer = XiaoyaSurveyAnswer(name: "待保存称呼", doing: "上班")
        await f.answer(.survey(answer))

        XCTAssertEqual(f.profiles.currentProfile, target)
        XCTAssertEqual(f.profiles.profiles, profilesBefore)
        XCTAssertEqual(try Data(contentsOf: profileFile), fileBefore)
        XCTAssertEqual(DefaultUserName.value(f.defaults), defaultBefore)
        XCTAssertEqual(f.defaults.string(forKey: "userName"), mirrorBefore)
        try assertSurveySaveWasNotAccepted(name: answer.name)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blobs.path)
        await relaunch()
        XCTAssertEqual(f.awaited?.card?.card, .survey(name: answer.name), "恢复后仍可答卡保存")
        await f.answer(.survey(answer))
        XCTAssertEqual(f.profiles.currentProfile.userName, answer.name)
        XCTAssertEqual(DefaultUserName.value(f.defaults), answer.name)
        XCTAssertEqual(f.script.progress?.survey, answer)
        XCTAssertEqual(calls.count, 1)
    }

    private func assertSurveySaveWasNotAccepted(name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(f.script.progress?.step, .survey, file: file, line: line)
        XCTAssertEqual(f.awaited?.card?.card, .survey(name: name), file: file, line: line)
        XCTAssertNil(f.awaited?.card?.answer, file: file, line: line)
        XCTAssertNil(f.script.progress?.survey, file: file, line: line)
        XCTAssertNil(f.script.progress?.surveyTaskId, file: file, line: line)
        XCTAssertNil(f.script.progress?.surveyResult, file: file, line: line)
        XCTAssertTrue(calls.isEmpty, file: file, line: line)
        let saved = try XCTUnwrap(f.scriptStore.load(), file: file, line: line)
        XCTAssertNil(saved.survey, file: file, line: line)
        XCTAssertNil(saved.surveyTaskId, file: file, line: line)
        XCTAssertNil(saved.surveyResult, file: file, line: line)
    }

    func testNameAnswerWritesTheTargetFloorAndDefaultNameOnly() async throws {
        let ta = try f.factory.createTa(name: "阿洛", userName: "你", who: "")
        let home = f.profiles.currentProfile
        try f.factory.applyUserName("  阿青 ", profileId: ta.id)
        XCTAssertEqual(f.profiles.profiles.first { $0.id == ta.id }?.userName, "阿青")
        XCTAssertEqual(DefaultUserName.value(f.defaults), "阿青")
        XCTAssertEqual(f.profiles.profiles.first { $0.id == home.id }?.userName, home.userName, "别的楼层不动")
        try f.factory.applyUserName("", profileId: ta.id)
        XCTAssertEqual(f.profiles.profiles.first { $0.id == ta.id }?.userName, "阿青", "空 = 不动")
    }

    func testMissingTargetThrowsWithoutChangingTheDefaultOrSavedProfiles() throws {
        let ta = try f.factory.createTa(name: "阿洛", userName: "你", who: "")
        let profilesBefore = f.profiles.profiles
        let fileBefore = try Data(contentsOf: profileFile)
        let defaultBefore = DefaultUserName.value(f.defaults)
        XCTAssertThrowsError(try f.factory.applyUserName("阿青", profileId: "missing-floor")) { error in
            guard case .floorMissing? = error as? OnboardingFloorFactory.Failure else {
                return XCTFail("应返回目标楼层缺失错误：\(error)")
            }
        }
        XCTAssertEqual(f.profiles.profiles, profilesBefore)
        XCTAssertEqual(try Data(contentsOf: profileFile), fileBefore)
        XCTAssertEqual(DefaultUserName.value(f.defaults), defaultBefore)
        try f.factory.applyUserName(" \n", profileId: ta.id)
        XCTAssertEqual(try Data(contentsOf: profileFile), fileBefore, "空称呼不写盘")
        XCTAssertEqual(DefaultUserName.value(f.defaults), defaultBefore)
    }
}
