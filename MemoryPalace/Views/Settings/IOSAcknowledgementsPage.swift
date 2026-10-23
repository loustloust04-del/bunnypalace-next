import SwiftUI

#if os(iOS)

/// 数据与折叠行在 `Acknowledgements.swift`（两端共用，按平台过滤）。
struct IOSAcknowledgementsPage: View {
    var body: some View {
        List {
            Section {
                Text(Acknowledgements.intro)
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textSecondary)
                    .listRowBackground(Theme.mainBg)
            }

            ForEach(Acknowledgements.current) { section in
                Section(section.title) {
                    ForEach(section.entries) { entry in
                        LicenseRow(entry: entry)
                            .listRowBackground(Theme.mainBg)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("开源致谢")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#endif
