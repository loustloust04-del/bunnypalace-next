import Foundation
import SwiftUI

/// askOnce 弹卡中心（OpenMinis OffloadPermissionManager 同构，按 MP 架构原生实现）：
/// 工具循环 / 发送路径 `await request(...)` 挂起，UI 观察 `pendingRequest` 弹小卡，
/// 用户点允许/不允许 resume；30s 超时自动拒（带超时竞态守卫）。
@MainActor
@Observable
final class PermissionPromptCenter {
    static let shared = PermissionPromptCenter()
    private init() {}

    #if DEBUG
    /// **测试专用**：造一个不共享的中心。
    /// 单测跑在宿主 app 里，`PermissionPromptHost` 挂在根视图上盯着 `shared`——
    /// 往 `shared` 塞一张卡，宿主会真的把 sheet 弹出来并回调 `markPresented`，
    /// 「还没 present」这种前提在 `shared` 上根本立不住。产品代码一律用 `shared`。
    init(isolatedForTesting: Bool) { _ = isolatedForTesting }
    #endif

    struct Request: Identifiable {
        let id = UUID()
        let domain: PermissionDomain
        /// 卡上多显示一行（run_command 的命令预览）；nil = 只显示域说明
        let detail: String?
        /// 非 nil = 加密值确认卡（plan-secure-ask），值是「【a】【b】」；每次都问，不落对话授权
        let secretLabels: String?
        /// 审批卡（粟粟 10-03）：工具调用的完整信息；非 nil 且正看着那个对话 → 卡出在对话底部，不弹窗
        var approval: Approval? = nil
        /// true = 这张由对话里的审批卡显示（宿主不弹 sheet、不超时）；离开对话会改回 false 走弹窗
        var inline = false
        let continuation: CheckedContinuation<Decision, Never>
    }

    /// 审批卡要的信息：哪个对话、哪个工具、完整参数、能不能选「本对话都允许」
    struct Approval: Equatable {
        let conversationId: String
        let toolName: String
        let argumentsJSON: String
        /// askOnce 路径 true；加密值每次都问 → false
        let conversationGrant: Bool
    }

    /// 正在看的对话（聊天页设）：审批卡只在这个对话里出；切走时挂着的卡改走弹窗
    var visibleConversationId: String? {
        didSet {
            guard var req = pendingRequest, req.inline, req.approval?.conversationId != visibleConversationId else { return }
            req.inline = false
            pendingRequest = req
            presentedId = nil
            armPresentationFallback(req.id)
        }
    }

    private(set) var pendingRequest: Request?

    /// 已经真的 present 到屏幕上的那张卡（`markPresented` 打点）。计时从这里才开始。
    /// 对外只读：探针/诊断要能区分「卡挂着但还没露脸」和「已经露脸在等人点」。
    private(set) var presentedId: UUID?

    /// 当前这张卡挂着的计时器（兜底表 + 露脸后的作答表）。
    /// **结清时必须 cancel**：以前不 cancel，每问一次就漏一个睡着的 Task，
    /// 卡早答完了它还要醒一次（靠 id 守卫空转）。
    private var timers: [Task<Void, Never>] = []

    private func cancelTimers() {
        timers.forEach { $0.cancel() }
        timers.removeAll()
    }

    /// 卡片露脸之后给用户多少秒作答
    static var answerTimeout: TimeInterval = 30
    /// 兜底：`decide()` 之后这么久还没 present（被别的 sheet 挡死/宿主没挂上），
    /// 也按 timedOut 收口，免得工具循环永久挂着
    static var presentationTimeout: TimeInterval = 60

    /// allowed / denied = 老弹窗语义（记进对话授权）；卡上的「允许这一次 / 拒绝」只管这一次；
    /// modified = 改过参数再允许（只管这一次，粟粟 10-03：这次只有跑命令能改）
    enum Decision: Equatable { case allowed, denied, timedOut, allowedOnce, deniedOnce, modified(String) }

    /// 问一次。同域并发**在同一轮工具循环里**确实不会发生（`ConversationViewModel` 的
    /// `for call in calls` 是顺序 await，grant 在下一次迭代前就写库了）。但**跨轮会**：
    /// 超时那条故意不落档（「下次再问」），模型拿到 `permission_denied：…超时` 后重试同一个工具，
    /// 下一轮就会再弹一张。T6b 诊断：codex「点了允许却收到超时」最可能就是这个序列
    /// ——第一张没弹出来 → 30s 超时 → 模型重试 → 第二张弹出来 → 他点的是第二张。
    func request(_ domain: PermissionDomain, detail: String? = nil) async -> Bool {
        await decide(domain, detail: detail) == .allowed
    }

    /// 三态：超时（30s 没人答——常见于卡根本没弹出来）**不该被当成用户拒绝写进对话授权**，调用方别持久化。
    ///
    /// 计时（T6c ① 修完的样子）：`decide()` 只起**兜底**表（`presentationTimeout` 60s，
    /// 卡根本没 present 时收口）；真正给用户作答的 `answerTimeout` 30s 由
    /// `markPresented` 在卡片 `onAppear` 时才起。以前两者合一、从 `decide()` 起表，
    /// 卡还没弹出来就在烧秒数——那就是 BUG-9「点了允许却收到超时」的根因。
    func decide(_ domain: PermissionDomain, detail: String? = nil, secretLabels: String? = nil,
                approval: Approval? = nil) async -> Decision {
        // 前一张卡还挂着（理论不该发生）：等它结清再问，避免覆盖丢 continuation
        while pendingRequest != nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await withCheckedContinuation { continuation in
            var req = Request(domain: domain, detail: detail, secretLabels: secretLabels, continuation: continuation)
            req.approval = approval
            // 正看着这个对话：卡出在对话底部，不弹窗、不超时（粟粟 10-03）
            req.inline = approval != nil && approval?.conversationId == self.visibleConversationId
            self.cancelTimers()
            self.pendingRequest = req
            self.presentedId = nil
            if !req.inline { self.armPresentationFallback(req.id) }
        }
    }

    /// 只挂**兜底**表：真正的 30s 作答表等 markPresented 才起（T6c ①）
    private func armPresentationFallback(_ id: UUID) {
        let fallback = Self.presentationTimeout
        timers.append(Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(fallback * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard self.pendingRequest?.id == id, self.presentedId != id else { return }
            print("[Permission] 卡片 \(fallback)s 没能 present（多半被别的 sheet 挡了），按超时收口")
            self.finish(id, .timedOut)
        })
    }

    /// 对话里的审批卡出现了：不起作答表（卡在眼前不超时；停止 / 切楼层 / 离开对话另有收口）
    func markPresentedInline(_ id: UUID) {
        guard let req = pendingRequest, req.id == id, req.inline else { return }
        cancelTimers()
        presentedId = id
    }

    /// 卡上的按钮
    func respond(to requestId: UUID, decision: Decision) {
        guard let req = pendingRequest, req.id == requestId else { return }
        finish(req.id, decision)
    }

    /// 停止 / 切楼层：这个对话挂着的卡算拒绝这一次，工具循环不挂死
    func cancel(conversationId: String) {
        guard let req = pendingRequest, req.approval?.conversationId == conversationId else { return }
        finish(req.id, .deniedOnce)
    }

    /// 卡片内容真的出现在屏幕上了（`PermissionPromptSheet.onAppear` 调）。
    /// **30s 作答表从这里起**——以前从 `decide()` 起表，卡还没弹出来就在烧秒数，
    /// 于是「点了允许却收到超时」（BUG-9，见 t6b-report §3）。幂等：重复调只起一次表。
    func markPresented(_ id: UUID) {
        guard let req = pendingRequest, req.id == id, presentedId != id else { return }
        presentedId = id
        let answer = Self.answerTimeout
        timers.append(Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(answer * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard self.pendingRequest?.id == req.id else { return }
            self.finish(req.id, .timedOut)
        })
    }

    private func finish(_ id: UUID, _ decision: Decision) {
        guard let req = pendingRequest, req.id == id else { return }
        cancelTimers()
        pendingRequest = nil
        presentedId = nil
        req.continuation.resume(returning: decision)
    }

    func respond(to requestId: UUID, allowed: Bool) {
        guard let req = pendingRequest, req.id == requestId else {
            // 点到一张已经结清的卡（超时清掉了 / 已答过）：以前这里静默 return，
            // 现场什么痕迹都不留，事后没法判断「用户到底点没点」（T6b 查 BUG-9 时卡在这）。
            // 只加日志，不改语义。
            print("[Permission] respond 落空：requestId=\(requestId) 已不是当前挂起的卡"
                  + "（pending=\(pendingRequest?.id.uuidString ?? "nil")）——多半是 30s 超时先清掉了")
            return
        }
        finish(req.id, allowed ? .allowed : .denied)
    }
}
