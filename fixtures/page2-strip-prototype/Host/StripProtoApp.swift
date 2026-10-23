import SwiftUI
import UIKit

// 右边缘竖条切换小样（⧫ 粟粟 10-11：「放在 page3，但是只拉出来一长条 app 图案供切换」）。
// 真 UIScrollView 三段：第一页（聊天占位）｜第二页（桌面 / 全屏应用）｜一条窄竖条。
// 第二页再往左划露出竖条，应用跟着退、缩一点、长圆角；点图标切过去，点应用那边收回。
// 调手感改 `Tune`。

enum Tune {
    /// 竖条宽
    static let strip: CGFloat = 92
    /// 竖条全开时应用缩到多少
    static let appScale: CGFloat = 0.97
    /// 竖条全开时应用糊多少（0…1，系统 regular 模糊的比例）
    static let appBlur: CGFloat = 0.3
    /// 屏幕圆角（iPhone 17 Pro 量的，和正式 Page2DisplayCorner 一致）
    static let displayRadius: CGFloat = 55
    /// 松手按速度往前推多远再找最近的停靠点（秒）
    static let projection: CGFloat = 0.12
}

struct FakeApp: Identifiable, Hashable {
    let id: String
    let emoji: String
    let color: Color
    let dark: Bool
}

let fakeApps: [FakeApp] = [
    FakeApp(id: "话题盒", emoji: "💡", color: Color(red: 1.0, green: 0.984, blue: 0.965), dark: false),
    FakeApp(id: "终端", emoji: "⌨️", color: Color(red: 0.13, green: 0.12, blue: 0.11), dark: true),
    FakeApp(id: "日历", emoji: "📅", color: Color(red: 0.95, green: 0.96, blue: 0.97), dark: false),
    FakeApp(id: "记忆", emoji: "🧠", color: Color(red: 0.91, green: 0.94, blue: 0.93), dark: false),
    FakeApp(id: "书房", emoji: "📚", color: Color(red: 0.97, green: 0.94, blue: 0.89), dark: false),
    FakeApp(id: "贴纸", emoji: "🌸", color: Color(red: 0.99, green: 0.93, blue: 0.94), dark: false),
    FakeApp(id: "单词", emoji: "🔤", color: Color(red: 0.93, green: 0.95, blue: 0.99), dark: false),
    FakeApp(id: "健康", emoji: "🤍", color: Color(red: 0.98, green: 0.95, blue: 0.95), dark: false),
]

final class Shell: ObservableObject {
    @Published var current = "home"
    /// 开过的应用，最近的在前
    @Published var recents: [String] = []
    /// 竖条露出程度 0…1（滚动驱动）
    @Published var reveal: CGFloat = 0
    var closeStrip: () -> Void = {}

    func open(_ id: String) {
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        current = id
    }
    func goHome() { current = "home" }
}

@main
struct StripProtoApp: App {
    var body: some Scene {
        WindowGroup { Pager().ignoresSafeArea() }
    }
}

private struct Pager: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PagerController { PagerController() }
    func updateUIViewController(_ controller: PagerController, context: Context) {}
}

final class PagerController: UIViewController, UIScrollViewDelegate {
    private let shell = Shell()
    private let scroll = UIScrollView()
    private lazy var page1 = UIHostingController(rootView: Page1View())
    private lazy var page2 = UIHostingController(rootView: Page2View(shell: shell))
    private lazy var strip = UIHostingController(rootView: StripView(shell: shell))
    private let closer = UIView()
    /// 应用上盖一层模糊，强度用暂停的动画器按进度刮（UIKit 调模糊半径的常规做法）
    private let blur = UIVisualEffectView(effect: nil)
    private var blurAnimator: UIViewPropertyAnimator?
    private let tick = UIImpactFeedbackGenerator(style: .light)
    private var laidOut = false
    private var wasOpen = false

    private var width: CGFloat { view.bounds.width }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.16, green: 0.15, blue: 0.14, alpha: 1)
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast
        scroll.alwaysBounceVertical = false
        view.addSubview(scroll)
        for host in [page1, page2, strip] as [UIViewController] {
            addChild(host)
            scroll.addSubview(host.view)
            host.didMove(toParent: self)
            host.view.backgroundColor = .clear
        }
        page2.view.layer.cornerCurve = .continuous
        page2.view.clipsToBounds = true
        blur.isUserInteractionEnabled = false
        page2.view.addSubview(blur)
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [blur] in blur.effect = UIBlurEffect(style: .regular) }
        animator.pausesOnCompletion = true
        blurAnimator = animator
        closer.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
        scroll.addSubview(closer)
        shell.closeStrip = { [weak self] in self?.close() }

        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-open"), i + 1 < args.count {
            ["终端", "日历", args[i + 1]].forEach(shell.open)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        scroll.frame = view.bounds
        page1.view.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        page2.view.bounds = CGRect(origin: .zero, size: size)
        page2.view.center = CGPoint(x: size.width * 1.5, y: size.height / 2)
        blur.frame = CGRect(origin: .zero, size: size)
        strip.view.frame = CGRect(x: size.width * 2, y: 0, width: Tune.strip, height: size.height)
        closer.frame = CGRect(x: size.width, y: 0, width: size.width, height: size.height)
        scroll.contentSize = CGSize(width: size.width * 2 + Tune.strip, height: size.height)
        if !laidOut {
            laidOut = true
            scroll.contentOffset.x = ProcessInfo.processInfo.arguments.contains("-reveal") ? size.width + Tune.strip : size.width
        }
        apply()
    }

    @objc private func close() { scroll.setContentOffset(CGPoint(x: width, y: 0), animated: true) }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { apply() }

    private func apply() {
        guard width > 0 else { return }
        let p = min(max((scroll.contentOffset.x - width) / Tune.strip, 0), 1)
        let scale = 1 - (1 - Tune.appScale) * p
        page2.view.transform = CGAffineTransform(scaleX: scale, y: scale)
        page2.view.layer.cornerRadius = Tune.displayRadius / scale * min(p * 3, 1)
        blurAnimator?.fractionComplete = Tune.appBlur * p
        page2.view.isUserInteractionEnabled = p < 0.01
        closer.isHidden = p < 0.01
        if shell.reveal != p { shell.reveal = p }
        let open = p > 0.99
        if open, !wasOpen { tick.impactOccurred(intensity: 0.6) }
        wasOpen = open
    }

    /// 停靠点：第一页 / 第二页 / 竖条全开。按松手速度往前推一点，找最近的
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let stops = [0, width, width + Tune.strip]
        let start = scrollView.contentOffset.x
        let projected = start + velocity.x * 1000 * Tune.projection
        var target = stops.min { abs($0 - projected) < abs($1 - projected) } ?? width
        // 第一页和第二页之间一次只走一页
        if start > width, target == 0 { target = width }
        if start < width, target == width + Tune.strip { target = width }
        targetContentOffset.pointee.x = target
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { tick.prepare() }
}

// MARK: - 页面

private struct Page1View: View {
    var body: some View {
        ZStack {
            Color(red: 1.0, green: 0.984, blue: 0.965).ignoresSafeArea()
            Text("第一页 · 聊天").font(.title3).foregroundStyle(.secondary)
        }
    }
}

private struct Page2View: View {
    @ObservedObject var shell: Shell

    var body: some View {
        ZStack {
            if let app = fakeApps.first(where: { $0.id == shell.current }) {
                FullscreenApp(app: app).transition(.opacity)
            } else {
                Desktop(shell: shell).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: shell.current)
    }
}

private struct Desktop: View {
    @ObservedObject var shell: Shell

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.62, green: 0.82, blue: 0.83), Color(red: 0.36, green: 0.55, blue: 0.86)],
                           startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 24) {
                ForEach(fakeApps) { app in
                    Button { shell.open(app.id) } label: {
                        VStack(spacing: 6) {
                            AppIcon(app: app, size: 60)
                            Text(app.id).font(.caption2).foregroundStyle(.white).shadow(radius: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 120)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct FullscreenApp: View {
    let app: FakeApp

    var body: some View {
        ZStack(alignment: .topLeading) {
            app.color.ignoresSafeArea()
            HStack(spacing: 8) {
                Text(app.emoji)
                Text(app.id).font(.title3.weight(.semibold))
            }
            .foregroundStyle(app.dark ? .white : .black.opacity(0.75))
            .padding(.top, 14).padding(.leading, 22)
            Text("往左划：拉出右边竖条切换\n往右划：回第一页")
                .font(.footnote).multilineTextAlignment(.center)
                .foregroundStyle(app.dark ? .white.opacity(0.5) : .black.opacity(0.35))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AppIcon: View {
    let app: FakeApp
    let size: CGFloat

    var body: some View {
        Text(app.emoji).font(.system(size: size * 0.5))
            .frame(width: size, height: size)
            .background(app.dark ? Color(white: 0.22) : .white, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }
}

// MARK: - 竖条

private struct StripView: View {
    @ObservedObject var shell: Shell

    var body: some View {
        let p = shell.reveal
        VStack(spacing: 16) {
            item(selected: shell.current == "home", label: "桌面", action: { shell.goHome(); shell.closeStrip() }) {
                Image(systemName: "house.fill").font(.system(size: 22)).foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            Capsule().fill(Color.white.opacity(0.18)).frame(width: 28, height: 2)
            ForEach(shell.recents.prefix(6), id: \.self) { id in
                if let app = fakeApps.first(where: { $0.id == id }) {
                    item(selected: shell.current == id, label: id, action: { shell.open(id); shell.closeStrip() }) {
                        AppIcon(app: app, size: 54)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 跟着拉开从右边滑进来、淡入
        .offset(x: (1 - p) * 28)
        .opacity(Double(min(p * 1.4, 1)))
    }

    private func item<Icon: View>(selected: Bool, label: String, action: @escaping () -> Void,
                                  @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                icon()
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(selected ? 0.9 : 0), lineWidth: 2).padding(-3))
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
