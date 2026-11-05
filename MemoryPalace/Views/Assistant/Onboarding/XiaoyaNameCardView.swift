import SwiftUI

// MARK: - 起名卡（小样 nameCard：⑪ 陪伴线 / 小白「建一个 Ta」）
// Ta 的名字必填、不预填（H8：不把吉祥物名写进 Ta 的名字）；称呼、一句话设定选填。
// 只交答案，建楼层是 P4（OnboardingFloorFactory.createTa）的事。

struct XiaoyaNameCardView: View {
    let answer: XiaoyaCardAnswer?
    /// 「Ta 怎么称呼你」预填默认称呼（小白线挑名字卡写过就是那个，§11-7：陪伴线不重复问）
    var prefillUserName = ""
    let onAnswer: (XiaoyaCardAnswer) -> Void

    @State private var taName = ""
    @State private var userName = ""
    @State private var who = ""

    private var trimmedTa: String { taName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        if case .named(let named) = answer {
            XiaoyaCardFrame(kicker: "起名") {
                XiaoyaCardSummary(text: XiaoyaCardAnswer.named(named).summary) {
                    XiaoyaInitialAvatar(name: named.taName, size: 30)
                }
                .padding(.top, 6)
            }
        } else {
            XiaoyaCardFrame(kicker: "起名", question: "Ta 叫什么？") {
                XiaoyaField(label: "Ta 的名字") {
                    XiaoyaInputBox { plainField("比如：阿洛", text: $taName) }
                }
                .padding(.top, -10)
                XiaoyaField(label: "Ta 怎么称呼你", optionalNote: "（选填）") {
                    XiaoyaInputBox { plainField("比如：粟粟 / 宝", text: $userName) }
                }
                XiaoyaField(label: "Ta 是个什么样的人", optionalNote: "（选填，一句话就行）") {
                    XiaoyaInputBox { plainField("温柔、嘴硬、喜欢下雨天…", text: $who) }
                }
                XiaoyaHint("名字和称呼写进 Ta 的楼层，在 Ta 楼层的「Prompt」页顶上看得到、随时改；我还是叫\(AssistantPrompts.assistantName)。")
                XiaoyaCardActions {
                    Button("建好 Ta 的楼层") {
                        onAnswer(.named(XiaoyaNameAnswer(
                            taName: trimmedTa,
                            userName: userName.trimmingCharacters(in: .whitespacesAndNewlines),
                            who: who.trimmingCharacters(in: .whitespacesAndNewlines))))
                    }
                    .buttonStyle(.xiaoya(.primary))
                    .disabled(trimmedTa.isEmpty)
                }
            }
            .onAppear { if userName.isEmpty { userName = prefillUserName } }
        }
    }

    private func plainField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .padding(.vertical, 8)
    }
}
