import SwiftUI

/// CC Bridge 手机配对。
/// macOS：从本机 hub 的 GET /pair（仅 loopback）拿 {u: ws://LAN_IP:端口/cc, t: token} 生成二维码——
///        token/IP 永远是 hub 真值，配置变了二维码自动跟着对。找哪个 hub 见 `PairingEndpoint`（外部 7890 / 内嵌端口）。
/// iOS：扫码 → 写 ccBridgeBaseURLOverride + Keychain token → 立即重连。
struct CCPairPayload: Codable {
    var mpcc: Int
    var u: String?        // 主地址（家里 LAN 直连）
    var u2: String?       // 备地址（Tailscale，出门）
    var u3: String?       // 自建中继（wss://，开着代理 VPN 也能连；#068）
    var p3: String?       // 中继自签证书的 SPKI sha256（base64）；正规证书没有
    var t: String

    /// 只认 wss 的中继地址（中继看得到明文，必须 TLS）
    var relayURL: URL? {
        guard let u3, let url = URL(string: u3), url.scheme == "wss", url.host != nil else { return nil }
        return url
    }

    static func parse(_ string: String) -> CCPairPayload? {
        guard let data = string.data(using: .utf8),
              let p = try? JSONDecoder().decode(CCPairPayload.self, from: data),
              p.mpcc == 1 else { return nil }
        guard p.u?.hasPrefix("ws") == true || p.relayURL != nil else { return nil }
        return p
    }
}

/// 连 hub 的候选地址。扫码 / 手动填写都写这几个键，读也只走这里（#068 收口，以前 ContentView / 语音 / Agora 各读各的）。
enum CCBridgeEndpoints {
    static let overrideKey = "ccBridgeBaseURLOverride"
    static let backupKey = "ccBridgeBaseURLBackup"
    static let relayKey = "ccBridgeRelayURL"
    static let relayPinKey = "ccBridgeRelayPin"

    /// 扫码整体替换：二维码里没带的字段清掉——重新配对不会把新口令发给旧中继
    static func save(_ p: CCPairPayload, defaults: UserDefaults = .standard) {
        func put(_ value: String?, _ key: String) {
            if let value, !value.isEmpty { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        put(p.u, overrideKey)
        put(p.u2, backupKey)
        put(p.relayURL?.absoluteString, relayKey)
        put(p.relayURL == nil ? nil : p.p3, relayPinKey)
    }

    /// 手填主 / 备地址：换了目标就把扫码存的中继和 pin 一起清掉，不然旧中继还在竞速、会收到新口令
    static func saveManual(primary: String, backup: String, defaults: UserDefaults = .standard) {
        let oldPrimary = defaults.string(forKey: overrideKey) ?? ""
        let oldBackup = defaults.string(forKey: backupKey) ?? ""
        if primary != oldPrimary || backup != oldBackup {
            defaults.removeObject(forKey: relayKey)
            defaults.removeObject(forKey: relayPinKey)
        }
        defaults.set(primary, forKey: overrideKey)
        defaults.set(backup, forKey: backupKey)
    }

    /// [主, 备, 中继]。includeRelay=false 给中继不转的路径（/agora 等，中继一期只放 /cc 和 /health）。
    /// 什么都没配时才补默认本机地址（fallbackToLocal=false 时不补）；只配了中继不补，免得本机 hub 抢走竞速
    static func configuredURLs(includeRelay: Bool = true, fallbackToLocal: Bool = true, defaults: UserDefaults = .standard) -> [URL] {
        let override = defaults.string(forKey: overrideKey) ?? ""
        let backup = defaults.string(forKey: backupKey) ?? ""
        let relay = relayURL(defaults: defaults)
        var urls = [override, backup].filter { !$0.isEmpty }.compactMap(URL.init(string:))
        if override.isEmpty, relay == nil, fallbackToLocal, let local = URL(string: APIProvider.ccBridge.baseURL) { urls.insert(local, at: 0) }
        if includeRelay, let relay { urls.append(relay) }
        return urls
    }

    static func relayURL(defaults: UserDefaults = .standard) -> URL? {
        guard let s = defaults.string(forKey: relayKey), let url = URL(string: s), url.scheme == "wss", url.host != nil else { return nil }
        return url
    }

    /// 只对中继那台主机（同 host + 端口）返回 pin；别的地址照常走系统证书校验
    static func relayPin(host: String, port: Int, defaults: UserDefaults = .standard) -> String? {
        guard let relay = relayURL(defaults: defaults), relay.host?.lowercased() == host.lowercased(),
              (relay.port ?? 443) == port,
              let pin = defaults.string(forKey: relayPinKey), !pin.isEmpty else { return nil }
        return pin
    }
}

#if os(macOS)
import CoreImage.CIFilterBuiltins

/// Mac 端：配对弹窗。二维码只在弹窗存续期间存在——60s 倒计时自动销毁、
/// 检测到手机连上（hub mp 数超过基线）自动销毁、手动关也销毁。每次配对现场生成。
struct CCPairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: NSImage?
    @State private var pairURL: String?
    @State private var failed = false
    @State private var remaining = 60
    @State private var baselineMP: Int?
    @State private var paired = false
    /// 二维码从哪个端口拿的（外部 hub 7890 / 内嵌 hub 的随机端口），配对成功轮询 /health 也用它
    @State private var port: Int?
    /// 取不到二维码时说哪一句（`PairingEndpoint.failureText`）
    @State private var failureText: String?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            Text(paired ? "配对成功 ✓" : "扫码配对")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            if paired {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(Theme.branchIndicator)
                    .padding(.vertical, 30)
            } else if let qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .background(Color.white)
                    .cornerRadius(10)
                if let pairURL {
                    Text(pairURL)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                }
                Text("手机端：设置 → 我的电脑 → 扫码配对 · \(remaining)s 后销毁")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted.opacity(0.8))
            } else if failed {
                Text(failureText ?? "取不到配对信息——hub 没在跑？稍等再试")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
                    .padding(.vertical, 30)
            } else {
                ProgressView().controlSize(.small).padding(.vertical, 80)
            }

            Button(paired ? "完成" : "关闭") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 18).padding(.vertical, 7)
                .background(Capsule().fill(Theme.accent.opacity(0.6)))
        }
        .padding(24)
        .frame(width: 300)
        .background(Theme.mainBg)
        .task { await load() }
        .onReceive(tick) { _ in
            guard !paired, qrImage != nil else { return }
            remaining -= 1
            if remaining <= 0 { dismiss(); return }   // 倒计时到 → 销毁
            if remaining % 2 == 0 { Task { await checkPaired() } }
        }
    }

    private func load() async {
        // Phase 2：/pair 强制 token。外部 hub 走 HubTokenStore（macOS 首次自动 bootstrap 读 launchd plist），
        // 内嵌 hub 走它自己的 Keychain 口令和端口（#046 刀 2）
        let hub = CCHubProcess.shared
        let external = await hub.refreshExternalHub()
        let endpoint = PairingEndpoint.resolve(externalHub: external,
                                               externalToken: external ? HubTokenStore.get() : nil,
                                               embeddedPort: hub.state == .running ? hub.port : nil,
                                               embeddedToken: hub.currentToken)
        guard case .ready(let port, let token) = endpoint,
              let url = URL(string: "http://127.0.0.1:\(port)/pair?token=\(token)") else {
            failureText = endpoint.failureText
            failed = true
            return
        }
        self.port = port
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let raw = String(decoding: data, as: UTF8.self)
            guard let payload = CCPairPayload.parse(raw), let img = Self.makeQR(raw) else { failed = true; return }
            qrImage = img
            pairURL = payload.u
            baselineMP = await fetchMPCount()   // 记基线，手机连上 mp 数会超过它
        } catch { failed = true }
    }

    /// 手机扫码后会用新配置连 hub → mp 连接数超过弹窗打开时的基线 → 视为配对成功，销毁二维码
    private func checkPaired() async {
        guard let base = baselineMP, let mp = await fetchMPCount() else { return }
        if mp > base {
            paired = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() }
        }
    }

    private func fetchMPCount() async -> Int? {
        guard let port, let url = URL(string: "http://127.0.0.1:\(port)/health"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["mp"] as? Int
    }

    private static func makeQR(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: ci.extent.width, height: ci.extent.height))
    }
}
#endif

/// 扫码配对落地：整体替换候选地址 + Keychain token → 立即重连。所有扫码入口共用这一份（#068 收口）。
/// 返回给她看的一句结果。
enum CCPairingApply {
    static func apply(_ p: CCPairPayload, providerManager: ProviderManager?) -> String {
        let primary = p.u.flatMap(URL.init(string:))
        guard primary != nil || p.relayURL != nil else { return "二维码里的地址不合法" }
        // 主=LAN（家里直连），备=Tailscale（出门），中继=开着代理 VPN 也能连。连接时三个并发竞速，谁先通连谁。
        CCBridgeEndpoints.save(p)
        if let pm = providerManager { pm.setApiKey(p.t, for: "cc-bridge") }
        else { _ = KeychainStore.set(p.t, account: "cc-bridge", sync: false) }
        providerManager?.reload()
        // 显式重新配对：先断掉旧连接再握手——同地址换了 pin / 口令时，旧 TLS / WS 不能接着用
        CCBridgeWebSocketClient.shared.disconnect()
        CCBridgeWebSocketClient.shared.connect(urls: CCBridgeEndpoints.configuredURLs(), token: p.t.isEmpty ? nil : p.t)
        let routes = [primary != nil ? "LAN" : nil, p.u2 != nil ? "Tailscale" : nil, p.relayURL != nil ? "中继" : nil].compactMap { $0 }
        return routes.count > 1 ? "已配对 ✓ \(routes.joined(separator: "+"))" : "已配对 ✓ \(p.u ?? p.u3 ?? "")"
    }
}

#if os(iOS)
import AVFoundation

/// iOS 端：全屏扫码 sheet。扫到合法 payload 回调并自动关；左上角 × 随时可退（onboarding 技术线也会开它，不能困死人）。
struct CCPairScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onPaired: (CCPairPayload) -> Void
    @State private var denied = false

    var body: some View {
        ZStack {
            if denied {
                VStack(spacing: 12) {
                    Text("需要相机权限来扫码")
                        .foregroundColor(Theme.textPrimary)
                    Button("去设置打开") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.mainBg)
            } else {
                QRScannerRepresentable { code in
                    guard let payload = CCPairPayload.parse(code) else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onPaired(payload)
                    dismiss()
                }
                .ignoresSafeArea()
                VStack {
                    Spacer()
                    Text("对准 Mac 上的配对二维码")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.5)))
                        .padding(.bottom, 40)
                }
            }
            // 关闭钮：黑半透明圆底，相机画面/权限被拒屏上都看得见
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(.black.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 20)
                    .padding(.top, 8)
                    Spacer()
                }
                Spacer()
            }
        }
        .onAppear {
            AVCaptureDevice.requestAccess(for: .video) { ok in
                if !ok { DispatchQueue.main.async { denied = true } }
            }
        }
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerVC {
        let vc = QRScannerVC()
        vc.onCode = onCode
        return vc
    }
    func updateUIViewController(_ vc: QRScannerVC, context: Context) {}
}

final class QRScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var fired = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.first(where: { $0 is AVCaptureVideoPreviewLayer })?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !fired,
              let obj = objects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr, let code = obj.stringValue else { return }
        // 只对合法 payload 停机退出；扫到无关二维码继续扫
        guard CCPairPayload.parse(code) != nil else { return }
        fired = true
        session.stopRunning()
        onCode?(code)
    }
}
#endif
