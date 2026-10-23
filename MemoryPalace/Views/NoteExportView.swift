import SwiftUI

/// 便签导出专用 View — 用于 ImageRenderer 渲染成 PNG（不带画布上的 scale / rotation）
struct NoteExportView: View {
    let content: String
    let style: String

    /// 和贴在对话里的同一张纸（NoteView），四周留白给投影
    var body: some View {
        NoteView(spec: NoteSpec(raw: style), text: content, width: 240, exporting: true)
            .padding(18)
    }
}
