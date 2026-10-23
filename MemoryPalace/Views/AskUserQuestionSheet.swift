import SwiftUI

/// 问问题（ask_user）选择卡：官端同款底部小 sheet（壳照 ThinkingSheet）。
/// 题目跨 askItems 平铺逐题呈现；单选点了即答翻页，多选勾了按确定，自由输入替代选项。
/// 最后一题答完 → resumeUserQuestion 恢复工具循环（pending 清空，sheet 自动收）。
/// X / 拖拽关闭 → 同一出口，剩余未答按跳过回灌（方案 a）。
struct AskUserQuestionSheet: View {
    let viewModel: ConversationViewModel

    @State private var pageIndex = 0
    @State private var selectedMulti: Set<Int> = []
    @State private var freeText = ""
    @FocusState private var freeTextFocused: Bool
    /// 贴内容高度的两段实测（sheet 根 VStack 高度被 detent 反向决定，只能测自然高的子块）
    @State private var headerHeight: CGFloat = 90
    @State private var bodyHeight: CGFloat = 260

    private var questions: [AskUserTool.ParsedQuestion] {
        viewModel.activeAskQuestions ?? []
    }

    var body: some View {
        // pending 被 cancel/楼层切换清空时 binding 正在收 sheet，空态兜底
        if questions.indices.contains(pageIndex) {
            content(question: questions[pageIndex])
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func content(question: AskUserTool.ParsedQuestion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部：题面左对齐大字 + 右上 X（官端布局）；多题时 X 下方缀页码
            HStack(alignment: .top, spacing: 12) {
                Text(question.question)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Button { viewModel.dismissActiveAskCard() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Theme.accent.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                    if questions.count > 1 {
                        Text("\(pageIndex + 1) / \(questions.count)")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textMuted)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

            // 选项 + 自由输入 + 确定同一列紧凑排布（官端节奏：输入行紧贴最后一个选项）；
            // 超长才滚，sheet 高度贴内容（官端是贴合卡，不是固定高）
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(question.options.indices, id: \.self) { i in
                        optionRow(question: question, index: i)
                        if i < question.options.count - 1 {
                            Divider().padding(.leading, 62)
                        }
                    }

                    Divider().padding(.leading, 62)

                    // 自由输入（官端「Type your answer…」：小灰字英文例外条款）+ 发送圈
                    HStack(spacing: 16) {
                        Image(systemName: "pencil")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Theme.accent.opacity(0.6)))
                        TextField("Type your answer…", text: $freeText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .foregroundColor(Theme.textPrimary)
                            .focused($freeTextFocused)
                            .onSubmit { submitFreeText() }
                        Button { submitFreeText() } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(freeTextTrimmed.isEmpty ? Theme.textMuted.opacity(0.5) : .white)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(freeTextTrimmed.isEmpty ? Theme.accent.opacity(0.6) : Theme.branchIndicator))
                        }
                        .buttonStyle(.plain)
                        .disabled(freeTextTrimmed.isEmpty)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)

                    if question.multiSelect {
                        Button {
                            guard !selectedMulti.isEmpty else { return }
                            submitAnswer(.options(selectedMulti.sorted()))
                        } label: {
                            Text("确定")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(selectedMulti.isEmpty ? Theme.textMuted : .white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(RoundedRectangle(cornerRadius: 21)
                                    .fill(selectedMulti.isEmpty ? Theme.accent.opacity(0.6) : Theme.branchIndicator))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 6)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
            }
        }
        .background(Theme.mainBg)
        #if os(iOS)
        .presentationDetents([.height(fittedHeight)])
        .presentationDragIndicator(.hidden)
        #else
        .frame(minWidth: 440, minHeight: 380)
        #endif
    }

    private var freeTextTrimmed: String {
        freeText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitFreeText() {
        guard !freeTextTrimmed.isEmpty else { return }
        submitAnswer(.text(freeTextTrimmed))
    }

    #if os(iOS)
    /// 贴内容的 sheet 高度：头部实测 + 列表实测，clamp 到 [220, 640]（超长内部滚动）
    private var fittedHeight: CGFloat {
        let h = headerHeight + bodyHeight + 20
        return min(max(h, 220), 640)
    }
    #endif

    @ViewBuilder
    private func optionRow(question: AskUserTool.ParsedQuestion, index: Int) -> some View {
        Button {
            if question.multiSelect {
                if selectedMulti.contains(index) { selectedMulti.remove(index) }
                else { selectedMulti.insert(index) }
            } else {
                submitAnswer(.options([index]))
            }
        } label: {
            HStack(spacing: 16) {
                Text("\(index + 1)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.accent.opacity(0.6)))
                Text(question.options[index])
                    .font(.system(size: 16))
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if question.multiSelect && selectedMulti.contains(index) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.branchIndicator)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 单题作答 → 记录 + 翻页；最后一题 → 统一出口（API 恢复工具循环 / CC 发答案帧），
    /// pending 清空 sheet 自动收。
    private func submitAnswer(_ answer: AskUserTool.AnswerValue) {
        viewModel.recordUserAnswer(answer, at: pageIndex)
        if pageIndex + 1 < questions.count {
            pageIndex += 1
            selectedMulti = []
            freeText = ""
            freeTextFocused = false
        } else {
            viewModel.completeActiveAskCard()
        }
    }
}
