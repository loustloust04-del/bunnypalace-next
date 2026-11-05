import SwiftUI

// MARK: - 新用户三问卡（C2/C3 v2 第 11 段）：确定目标楼层之后问一次，三问都能空；称呼预填已有的名字。
// 只交答案；答案怎么变成 wiki 是剧本 → CatalogRunner.survey 的事（目录、正文都要她批）。

struct XiaoyaSurveyCardView: View {
    let prefillName: String
    let answer: XiaoyaCardAnswer?
    let onAnswer: (XiaoyaCardAnswer) -> Void

    @State private var name = ""
    @State private var doing = ""
    @State private var note = ""
    @State private var filled = false

    private let questions = CatalogSurvey.questions

    var body: some View {
        if case .survey(let done) = answer {
            XiaoyaCardFrame(kicker: "认识一下") {
                XiaoyaSkinReader { skin in
                    XiaoyaCardSummary(text: XiaoyaCardAnswer.survey(done).summary) {
                        XiaoyaBadge(text: done.answers.isEmpty ? "–" : "✓", color: done.answers.isEmpty ? skin.inkMuted : skin.ok)
                    }
                }
                .padding(.top, 6)
            }
        } else {
            XiaoyaCardFrame(kicker: "认识一下", question: "三个小问题，都能空着") {
                field(questions[0].title, "比如：阿青", text: $name)
                    .padding(.top, -10)
                field(questions[1].title, "工作、学习、创业…一句话就行", text: $doing)
                field(questions[2].title, "（可跳过）", text: $note)
                XiaoyaHint("答案只记在这层楼的记忆里。我会先列个目录给你批，批了再写，写好的也要你再点头才进记忆。")
                XiaoyaCardActions {
                    Button("就这些") {
                        onAnswer(.survey(XiaoyaSurveyAnswer(name: trimmed(name), doing: trimmed(doing), note: trimmed(note))))
                    }
                    .buttonStyle(.xiaoya(.primary))
                    Button("都跳过") { onAnswer(.survey(XiaoyaSurveyAnswer())) }
                        .buttonStyle(.xiaoya(.secondary))
                }
            }
            .onAppear {
                guard !filled else { return }
                filled = true
                name = prefillName
            }
        }
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func field(_ label: String, _ placeholder: String, text: Binding<String>) -> some View {
        XiaoyaField(label: label) {
            XiaoyaInputBox {
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 8)
            }
        }
    }
}
