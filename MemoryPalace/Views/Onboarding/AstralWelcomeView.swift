#if os(iOS)
  import SwiftUI

  /// 首启欢迎页：摆开屏片子合拢后的最后一帧（同一份烘焙时间线和素材，同样按原尺寸居中），
  /// 开屏掀开后直接接上；按钮出现即可点，只有一个不挡点击的轻淡入。
  struct AstralWelcomeView: View {
    let onStart: () -> Void
    let onExplore: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var buttonsShown = false
    @State private var leaving = false

    var body: some View {
      VStack(spacing: 8) {
        Spacer(minLength: 0)
        Button(action: { leave(onStart) }) {
          Text("开始我们的故事")
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Capsule().fill(Theme.branchIndicator))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("astral.start")
        Button(action: { leave(onExplore) }) {
          Text("随便看看")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(Theme.textMuted)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
          .accessibilityIdentifier("astral.explore")
      }
      .disabled(leaving)
      .frame(maxWidth: 420)
      .padding(.horizontal, 28)
      .padding(.bottom, 16)
      .opacity(buttonsShown ? 1 : 0)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        Color("LaunchPaper")
          .overlay { SettledSplashFrame() }
          .ignoresSafeArea()
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("mneme atrium 记忆花园")
          .accessibilityAddTraits(.isHeader)
      }
      .onAppear {
        #if DEBUG || PERF_BENCH
          PerfHarness.mark("welcomeAppear")
        #endif
        withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.25)) { buttonsShown = true }
      }
    }

    private func leave(_ action: () -> Void) {
      guard !leaving else { return }
      leaving = true
      action()
    }
  }

  /// 开屏时间线（LaunchAnimTimeline）各层取末关键帧摆成静帧；不动画、不解码进 CGImage。
  private struct SettledSplashFrame: View {
    struct Node: Identifiable {
      let id: String
      let asset: String?
      let size: CGSize
      let anchor: UnitPoint
      let center: CGPoint
      let opacity: Double
      let rotation: Double
      let scale: Double
      let children: [Node]
    }

    private static let root: (canvas: CGSize, layers: [Node])? = {
      guard let data = NSDataAsset(name: "LaunchAnimTimeline")?.data,
        let manifest = try? JSONDecoder().decode(LaunchSplashAnimationView.Manifest.self, from: data),
        manifest.valid
      else { return nil }
      func nodes(under parent: String) -> [Node] {
        manifest.layers.filter { $0.parent == parent }.compactMap { l in
          func end(_ key: String) -> Double? { l.tracks.first { $0.keyPath == key }?.values.last }
          let size = CGSize(width: l.frame[2], height: l.frame[3])
          let anchor = UnitPoint(x: l.anchorPoint[0], y: l.anchorPoint[1])
          let x = end("position.x") ?? l.frame[0] + size.width * anchor.x
          let y = end("position.y") ?? l.frame[1] + size.height * anchor.y
          let opacity = end("opacity") ?? Double(l.opacity)
          let children = nodes(under: l.id)
          guard opacity > 0, l.asset != nil || !children.isEmpty else { return nil }
          return Node(
            id: l.id, asset: l.asset, size: size, anchor: anchor,
            center: CGPoint(
              x: x + (0.5 - anchor.x) * size.width, y: y + (0.5 - anchor.y) * size.height),
            opacity: opacity, rotation: end("transform.rotation.z") ?? l.rotation,
            scale: end("transform.scale") ?? l.scale, children: children)
        }
      }
      return (CGSize(width: manifest.canvas[0], height: manifest.canvas[1]), nodes(under: "canvas"))
    }()

    var body: some View {
      if let root = Self.root {
        ZStack(alignment: .topLeading) {
          ForEach(root.layers) { BakedLayer(node: $0) }
        }
        .frame(width: root.canvas.width, height: root.canvas.height)
      }
    }
  }

  private struct BakedLayer: View {
    let node: SettledSplashFrame.Node

    var body: some View {
      ZStack(alignment: .topLeading) {
        if let asset = node.asset { Image(asset).resizable() }
        ForEach(node.children) { BakedLayer(node: $0) }
      }
      .frame(width: node.size.width, height: node.size.height)
      .scaleEffect(node.scale, anchor: node.anchor)
      .rotationEffect(.radians(node.rotation), anchor: node.anchor)
      .opacity(node.opacity)
      .position(node.center)
    }
  }
#endif
