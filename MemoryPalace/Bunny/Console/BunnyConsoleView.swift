import SwiftUI

// MARK: - [Bunny] Caelum's Console 入口（BP-007 路由到这里）
// 11-12 用户要求先一比一还原大肥兔的首页：主体是自大肥兔移植的 ConsoleView（Legacy/），
// 这里只在右上角加一个齿轮，打开新兔的网关连接 / 同步 / 黑匣子设置。

struct BunnyConsoleView: View {
    @State private var showSettings = false

    var body: some View {
        #if os(iOS)
        ConsoleView()
            .overlay(alignment: .topTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(10)
                }
                .padding(.trailing, 8)
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { BunnyConsoleSettingsView() }
            }
            .onAppear { if !BunnyGateway.isConfigured { showSettings = true } }
        #else
        Text("Caelum's Console 目前只在 iPhone 上").padding()
        #endif
    }
}
