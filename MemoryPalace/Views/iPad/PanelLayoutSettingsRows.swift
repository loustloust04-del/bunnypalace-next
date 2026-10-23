import SwiftUI

/// 宽屏壳的四项设置行（面板模式 / 浮窗吸边 / 桌面排版 / dock），iPad 外观 › 宽屏布局（`WideLayoutPage`）和
/// mac Mac 工作区 › 面板共用一份（plan-mac-shape A1c 起两端共用；10-02 从外观一级页挪出，手机不露）。字号由宿主给：合流后两端都传 `settingsMetrics` 的 `m.label` / `m.caption`。
/// 文案里平台不同的那半句按平台切，别再对 mac 用户说「竖屏和手机」。
struct PanelLayoutSettingsRows: View {
    @Bindable var layout: IPadPanelLayout
    let labelFont: Font
    let captionFont: Font

    private var modeCaption: String {
        var s = "窗口：面板是一扇扇自由浮窗，可叠、点哪个到前面。全屏：侧栏和工具贴边平铺，正文让位、不被盖住；开着的工具在右栏排成一条 tab，"
        #if os(iOS)
        s += "长按 tab 能把它浮出来。竖屏和手机没有这个形态。"
        #else
        s += "右键 tab 能把它浮出来。"
        #endif
        return s
    }

    private var gridCaption: String {
        #if os(iOS)
        let head = "横屏时桌面的小组件钉在聊天两侧的格子上，格子按 iPad 系统小组件的尺寸和间距排。"
        #else
        let head = "桌面的小组件钉在聊天两侧的格子上，格子按桌面小组件的尺寸和间距排。"
        #endif
        return head + "两侧各一列：左右都能放；一侧两列：长条和大方也放得下。聊天区宽度是留完格子剩下的，两种排法一样宽。"
    }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("面板模式")
                        .font(labelFont)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Picker("", selection: $layout.mode) {
                        ForEach(IPadPanelLayout.Mode.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    #if os(macOS)
                    .pickerStyle(.menu)
                    .labelsHidden()
                    #else
                    .pickerStyle(.segmented)
                    #endif
                    .frame(width: 200)
                }
                caption(modeCaption)
            }
            .panelSettingsAnchor("leaf-appear-ipadmode")

            VStack(alignment: .leading, spacing: 8) {
                Toggle("浮窗吸边对齐", isOn: $layout.snapToEdges)
                    .font(labelFont)
                    .tint(Theme.branchIndicator)
                caption("拖浮窗到屏边或别的浮窗附近时吸上去对齐、留一道缝，并画一条辅助线。")
            }
            .panelSettingsAnchor("leaf-appear-ipadsnap")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("桌面排版")
                        .font(labelFont)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Picker("", selection: $layout.arrangement) {
                        ForEach(DesktopArrangement.allCases, id: \.self) { a in
                            Text(a.label).tag(a)
                        }
                    }
                    #if os(macOS)
                    .pickerStyle(.menu)
                    .labelsHidden()
                    #else
                    .pickerStyle(.segmented)
                    #endif
                    .frame(width: 220)
                }
                caption(gridCaption)
            }
            .panelSettingsAnchor("leaf-appear-ipadgrid")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("dock")
                        .font(labelFont)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Picker("", selection: $layout.dockSide) {
                        ForEach(DockSide.allCases, id: \.self) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    #if os(macOS)
                    .pickerStyle(.menu)
                    .labelsHidden()
                    #else
                    .pickerStyle(.segmented)
                    #endif
                    .frame(width: 140)
                }
                caption("竖 dock 贴在哪一边。只管这条图标条——工具栏始终在右边，对话列表始终从左边出来。")
            }
            .panelSettingsAnchor("leaf-appear-ipaddock")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(captionFont)
            .foregroundColor(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension View {
    /// 设置搜索的落点锚：iOS 设置页有搜索直达；mac 设置窗口（A5）接搜索前先不挂
    @ViewBuilder
    func panelSettingsAnchor(_ id: String) -> some View {
        #if os(iOS)
        self.searchAnchor(id)
        #else
        self
        #endif
    }
}
