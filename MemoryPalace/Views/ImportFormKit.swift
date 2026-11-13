import SwiftUI

/// 导入页 / 补原图页的外壳：iOS 是 List，mac 是标题栏 + 卡片滚动区
struct ImportFormPage<Content: View>: View {
    let title: String
    let isBusy: Bool
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(iOS)
        NavigationStack {
            List { content }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Theme.sidebarBg)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                            .foregroundColor(isBusy ? Theme.textMuted : Theme.branchIndicator)
                            .disabled(isBusy)
                    }
                }
        }
        #else
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.title3.weight(.medium))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: 440, idealHeight: 560)
        .background(Theme.mainBg)
        #endif
    }
}

/// 导入页 / 补原图页共用的小部件（iOS 是 List 的 Section / 行，mac 是卡片）
protocol ImportFormWidgets {}

extension ImportFormWidgets {
    @ViewBuilder
    func group<C: View>(_ title: String?, footer: String? = nil, @ViewBuilder _ rows: () -> C) -> some View {
        #if os(iOS)
        Section {
            rows()
        } header: {
            if let title { Text(title) }
        } footer: {
            if let footer { Text(footer).font(.system(size: Theme.F.caption)) }
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)
        #else
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: Theme.F.secondary, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 10) { rows() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.sidebarBg))
            if let footer {
                Text(footer)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        #endif
    }

    func resultRow(_ title: String, _ value: String, _ detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(value)
                .font(.system(size: Theme.F.secondary, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
        }
    }

    func busyGroup(_ title: String, _ text: String) -> some View {
        group(title) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text)
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    func primaryButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        #if os(iOS)
        Section {
            Button(action: action) {
                HStack { Spacer(); Text(title); Spacer() }
                    .font(.system(size: Theme.F.body, weight: .semibold))
                    .foregroundColor(.white)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .listRowBackground(enabled ? Theme.branchIndicator : Theme.textMuted)
        }
        .listRowSeparator(.hidden)
        #else
        HStack {
            Spacer()
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .tint(Theme.branchIndicator)
                .disabled(!enabled)
        }
        #endif
    }

    @ViewBuilder
    func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        #if os(iOS)
        Section {
            Button(action: action) {
                HStack { Spacer(); Text(title); Spacer() }
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.branchIndicator)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        #else
        HStack {
            Spacer()
            Button(title, action: action)
        }
        #endif
    }
}
