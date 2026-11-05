import SwiftUI

// MARK: - 说明卡（小样 infoCard：⑬ ⑭ 以后在哪儿找我）

struct XiaoyaInfoCardView: View {
    private var place: String {
        #if os(macOS)
        "右栏"
        #else
        " gardenOS 桌面上的"
        #endif
    }

    var body: some View {
        XiaoyaCardFrame {
            XiaoyaSkinReader { skin in
                HStack(spacing: 12) {
                    Image("xiaoya-cameo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 46, height: 46)
                    Text("以后在**任何楼层**打开\(place)「\(AssistantPrompts.assistantName)」app，都是在这儿跟我说话——同一段对话、同一份记忆。忘了怎么用，回来问我。")
                        .font(.system(size: XiaoyaCardFont.small + 1))
                        .foregroundStyle(skin.inkSoft)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
