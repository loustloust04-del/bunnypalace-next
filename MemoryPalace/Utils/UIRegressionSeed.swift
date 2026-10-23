#if (DEBUG || PERF_BENCH) && os(iOS)
import Foundation
import SwiftData

/// UI 回归套件种子（plan-perf-watch §1.1）：`--ui-regression-seed` 触发，种两个短消息对话。
/// R1 键盘对话：尾条是短 user 消息 RGTAIL（做位移锚；旧 kb 种子的尾条是 40 行思考长气泡，不适合）。
/// R2 打开对话目标：尾条 RGOPEN。
/// 真机只准写测试楼层（perf-bench-profile，`perf-run.sh seed` 切过去），否则不写——防止写进粟粟的真楼层。
enum UIRegressionSeed {
    static let markerKey = "uiRegressionSeedDone_v1"
    /// research-chat-cards §13：网页卡宿主能力桥的种子对话（单独打点，不动老种子）
    static let htmlCardMarkerKey = "uiRegressionHTMLCardSeedDone_v1"
    static let htmlCardConvId = "rg-html-conv"
    /// 表单卡（粟粟 10-03）种子对话：各种字段类型都有一项
    static let formCardMarkerKey = "uiRegressionFormCardSeedDone_v1"
    static let formCardConvId = "rg-form-conv"
    static let keyboardConvId = "rg-kb-conv"
    static let openConvId = "rg-open-conv"
    static let testProfileId = "perf-bench-profile"

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("--ui-regression-seed") }

    static func injectIfNeeded(container: ModelContainer, profileId: String) {
        guard isActive else { return }
        injectHTMLCardIfNeeded(container: container, profileId: profileId)
        injectFormCardIfNeeded(container: container, profileId: profileId)
        guard !UserDefaults.standard.bool(forKey: markerKey) else { return }
        #if !targetEnvironment(simulator)
        guard profileId == testProfileId else {
            NSLog("[UI 回归 seed] 当前楼层 \(profileId) 不是测试楼层，拒绝写入")
            return
        }
        #endif
        let ctx = ModelContext(container)
        insert(ctx, convId: keyboardConvId, title: "[RG] 键盘", count: 30, tail: "RGTAIL", profileId: profileId)
        insert(ctx, convId: openConvId, title: "[RG] 打开对话目标", count: 40, tail: "RGOPEN", profileId: profileId)
        do {
            try ctx.save()
            UserDefaults.standard.set(true, forKey: markerKey)
        } catch {
            NSLog("[UI 回归 seed] save failed: \(error)")
        }
    }

    /// 一条带按钮的网页卡：点「加待办」走 mp.todo.add（要原生确认），点「问」走 mp.ask；结果写回页面上的 #out
    static let htmlCardMessage = """
    ```html
    <!doctype html>
    <html><head><title>RG 网页卡</title></head><body>
    <button id="add" style="font-size:20px;padding:12px" onclick="mp.todo.add('RG 网页卡待办').then(function(){out.textContent='RGOK'}).catch(function(e){out.textContent='RGERR '+e.message})">加待办</button>
    <button id="ask" style="font-size:20px;padding:12px" onclick="mp.ask('RG 再出一组').then(function(){out.textContent='RGASKED'})">问</button>
    <p id="out" style="font-size:20px">RGIDLE</p>
    </body></html>
    ```
    """

    static let formCardMessage = """
    RGFORM 填一下这几项：

    ```card-ask
    {"id":"q-rg01","question":"周末出游","fields":[
    {"label":"去哪","type":"single","options":["海边","山里","市区"],"default":"山里"},
    {"label":"带谁","type":"multi","options":["猫","狗","鱼"],"required":false},
    {"label":"哪天","type":"date","default":"today"},
    {"label":"预算","type":"number","min":0,"max":2000,"step":50,"unit":"元","default":500},
    {"label":"想走多远","type":"slider","min":1,"max":10,"unit":"公里","default":3},
    {"label":"备注","placeholder":"随便写","required":false}
    ]}
    ```
    """

    private static func injectFormCardIfNeeded(container: ModelContainer, profileId: String) {
        guard !UserDefaults.standard.bool(forKey: formCardMarkerKey) else { return }
        #if !targetEnvironment(simulator)
        guard profileId == testProfileId else { return }
        #endif
        let ctx = ModelContext(container)
        let now = Date()
        ctx.insert(MessageNode(id: "\(formCardConvId)-0", role: "user", content: "RGFORMQ 帮我规划周末", contentType: "text",
                               createTime: now.addingTimeInterval(-120), parentId: nil, childrenIds: ["\(formCardConvId)-1"],
                               conversationId: formCardConvId, profileId: profileId))
        ctx.insert(MessageNode(id: "\(formCardConvId)-1", role: "assistant", content: formCardMessage, contentType: "text",
                               createTime: now.addingTimeInterval(-60), parentId: "\(formCardConvId)-0", childrenIds: [],
                               conversationId: formCardConvId, profileId: profileId))
        ctx.insert(Conversation(id: formCardConvId, title: "[RG] 表单", createTime: now, updateTime: now.addingTimeInterval(-90),
                                currentNodeId: "\(formCardConvId)-1", provider: "api", profileId: profileId))
        do {
            try ctx.save()
            UserDefaults.standard.set(true, forKey: formCardMarkerKey)
        } catch {
            NSLog("[UI 回归 seed] form card save failed: \(error)")
        }
    }

    private static func injectHTMLCardIfNeeded(container: ModelContainer, profileId: String) {
        guard !UserDefaults.standard.bool(forKey: htmlCardMarkerKey) else { return }
        #if !targetEnvironment(simulator)
        guard profileId == testProfileId else { return }
        #endif
        let ctx = ModelContext(container)
        let now = Date()
        ctx.insert(MessageNode(id: "\(htmlCardConvId)-0", role: "user", content: "RGHTML 给我一张网页卡", contentType: "text",
                               createTime: now.addingTimeInterval(-120), parentId: nil, childrenIds: ["\(htmlCardConvId)-1"],
                               conversationId: htmlCardConvId, profileId: profileId))
        ctx.insert(MessageNode(id: "\(htmlCardConvId)-1", role: "assistant", content: htmlCardMessage, contentType: "text",
                               createTime: now.addingTimeInterval(-60), parentId: "\(htmlCardConvId)-0", childrenIds: [],
                               conversationId: htmlCardConvId, profileId: profileId))
        ctx.insert(Conversation(id: htmlCardConvId, title: "[RG] 网页卡", createTime: now, updateTime: now.addingTimeInterval(-60),
                                currentNodeId: "\(htmlCardConvId)-1", provider: "api", profileId: profileId))
        do {
            try ctx.save()
            UserDefaults.standard.set(true, forKey: htmlCardMarkerKey)
        } catch {
            NSLog("[UI 回归 seed] html card save failed: \(error)")
        }
    }

    private static func insert(_ ctx: ModelContext, convId: String, title: String, count: Int, tail: String, profileId: String) {
        let now = Date()
        for i in 0..<count {
            let last = i == count - 1
            ctx.insert(MessageNode(
                id: "\(convId)-\(i)",
                role: i % 2 == (count - 1) % 2 ? "user" : "assistant",
                content: last ? tail : "回归填充消息 \(i)：撑起可翻的历史高度，再加一句让气泡两行。",
                contentType: "text",
                createTime: now.addingTimeInterval(Double(i - count) * 60),
                parentId: i == 0 ? nil : "\(convId)-\(i - 1)",
                childrenIds: last ? [] : ["\(convId)-\(i + 1)"],
                conversationId: convId,
                profileId: profileId
            ))
        }
        ctx.insert(Conversation(
            id: convId,
            title: title,
            createTime: now,
            updateTime: convId == keyboardConvId ? now : now.addingTimeInterval(-30),
            currentNodeId: "\(convId)-\(count - 1)",
            provider: "api",
            profileId: profileId
        ))
    }
}
#endif
