import Foundation
import SwiftUI

/// 2026-06-16 🔴破限事故迁移：检测同时勾上"渲染时"+"发送 API 时"且替换为空的 regex script，
/// 弹一次性 alert 让粟粟决定怎么办。详见 `docs/plan-fix-regex-markdownonly-trap.md`。
///
/// 这个 bug 的指纹：markdownOnly && promptOnly && replaceString=="" → 渲染时 25 楼+全空气泡。
/// 用户意图通常是"只擦发送给 AI 的"，markdownOnly=true 是默认值陷阱，不是真心要双开。
enum RegexHygiene {

    static let shownKey = "regexHygieneAlertShown.v1"

    struct Hit: Identifiable, Hashable {
        let presetId: String
        let presetName: String
        let scriptId: String
        let scriptName: String
        var id: String { "\(presetId)/\(scriptId)" }
    }

    /// 扫描所有预设，找命中"双开+替空"指纹的 script。
    static func detectDoubleOnEmptyReplace(in presets: [Preset]) -> [Hit] {
        var hits: [Hit] = []
        for preset in presets {
            for script in preset.regexScripts where !script.disabled {
                if script.markdownOnly && script.promptOnly && script.replaceString.isEmpty {
                    hits.append(Hit(
                        presetId: preset.id,
                        presetName: preset.name,
                        scriptId: script.id,
                        scriptName: script.scriptName
                    ))
                }
            }
        }
        return hits
    }

    /// 一键修复：把命中 script 的 markdownOnly 改 false（保留 promptOnly=true）。
    /// 写回 PresetManager 触发 persist。
    static func applyFix(hits: [Hit], presetManager: PresetManager) {
        let scriptIds = Set(hits.map(\.scriptId))
        for var preset in presetManager.presets {
            var changed = false
            for i in preset.regexScripts.indices where scriptIds.contains(preset.regexScripts[i].id) {
                preset.regexScripts[i].markdownOnly = false
                changed = true
            }
            if changed { presetManager.save(preset) }
        }
    }
}

// MARK: - ViewModifier

/// 启动后挂在根 view 上，检测命中 → 弹一次性 alert。
/// ⚠️ 显式注入 PresetManager 不走 @Environment：modifier 在 App 顶层挂载时 env 传播时序
/// 在 .id(currentProfile.id) 重建链路下不可靠（task fired 时 env 还是 nil 实测踩过），
/// 让 App 直接传引用进来 100% 拿到 instance。
struct RegexHygieneCheckModifier: ViewModifier {
    let presetManager: PresetManager
    @State private var hits: [RegexHygiene.Hit] = []
    @State private var showAlert = false

    func body(content: Content) -> some View {
        content
            .task {
                let shown = UserDefaults.standard.bool(forKey: RegexHygiene.shownKey)
                print("[RegexHygiene] task fired shown=\(shown) presetCount=\(presetManager.presets.count)")
                guard !shown else { return }
                let found = RegexHygiene.detectDoubleOnEmptyReplace(in: presetManager.presets)
                print("[RegexHygiene] detect hits=\(found.count) — \(found.map { "\($0.presetName)/\($0.scriptName)" })")
                guard !found.isEmpty else { return }
                hits = found
                showAlert = true
                print("[RegexHygiene] showAlert=true")
            }
            .alert("检测到可能误配的正则脚本", isPresented: $showAlert) {
                Button("一键修复（关掉「渲染时」）") {
                    RegexHygiene.applyFix(hits: hits, presetManager: presetManager)
                    UserDefaults.standard.set(true, forKey: RegexHygiene.shownKey)
                }
                Button("我自己去改") {
                    UserDefaults.standard.set(true, forKey: RegexHygiene.shownKey)
                }
                Button("以后再说", role: .cancel) {
                    // 不写 flag，下次启动还会提醒
                }
            } message: {
                Text(buildMessage())
            }
    }

    private func buildMessage() -> String {
        let list = hits.prefix(5)
            .map { "• \($0.presetName) → \($0.scriptName)" }
            .joined(separator: "\n")
        let suffix = hits.count > 5 ? "\n… 等共 \(hits.count) 条" : ""
        return """
        以下 \(hits.count) 条 regex 同时勾上「渲染时」+「发送 API 时」且替换为空字符串，会让楼层气泡也被擦空（2026-06-16 事故根因）。

        \(list)\(suffix)

        点「一键修复」=保留「发送 API 时」、关掉「渲染时」（楼层显示恢复正常，发送给 AI 的内容仍被擦）。
        """
    }
}

extension View {
    func regexHygieneCheck(presetManager: PresetManager) -> some View {
        modifier(RegexHygieneCheckModifier(presetManager: presetManager))
    }
}
