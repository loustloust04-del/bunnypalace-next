#if os(iOS)
  import SwiftUI

  struct AstralIdentityView: View {
    let choices: [AstralIdentityChoice]
    let onSelect: (String) -> Void
    let onBack: () -> Void
    let onSkip: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var selecting = false

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack {
            Button(action: onBack) {
              Image(systemName: "chevron.left")
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("返回欢迎页")
            Spacer()
            Text("01 / 06").font(.caption.monospacedDigit()).foregroundStyle(AstralPalette.mint)
            Spacer()
            Button("跳过", action: onSkip)
              .frame(minWidth: 44, minHeight: 44)
              .font(.subheadline)
          }
          .foregroundStyle(.white)

          VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sparkle")
              .font(.system(size: 35, weight: .ultraLight))
              .foregroundStyle(AstralPalette.mint)
              .shadow(color: AstralPalette.mint.opacity(0.4), radius: 18)
              .accessibilityHidden(true)
            Text("你是哪种园丁？")
              .font(.largeTitle.weight(.medium))
              .foregroundStyle(.white)
              .accessibilityAddTraits(.isHeader)
            Text("选一个贴近此刻的你。\n之后随时可以改变。")
              .font(.body)
              .foregroundStyle(.white.opacity(0.7))
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.vertical, 12)

          VStack(spacing: 12) {
            ForEach(choices) { choice in
              Button {
                guard !selecting else { return }
                selecting = true
                onSelect(choice.id)
              } label: {
                HStack(spacing: 16) {
                  VStack(alignment: .leading, spacing: 6) {
                    Text(choice.title).font(.headline).foregroundStyle(.white)
                    Text(choice.detail).font(.subheadline).foregroundStyle(.white.opacity(0.65))
                  }
                  .fixedSize(horizontal: false, vertical: true)
                  Spacer(minLength: 0)
                  Image(systemName: "arrow.up.right")
                    .font(.subheadline)
                    .foregroundStyle(AstralPalette.mint)
                }
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 24))
                .overlay {
                  RoundedRectangle(cornerRadius: 24)
                    .stroke(
                      AstralPalette.mint.opacity(choice.id == "newbie" ? 0.5 : 0.16), lineWidth: 1)
                }
              }
              .buttonStyle(.plain)
              .disabled(selecting)
            }
          }
        }
        .padding(24)
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 18)
      }
      .background {
        AstralPalette.ink.ignoresSafeArea()
          .overlay(alignment: .topTrailing) {
            Circle().fill(AstralPalette.mint.opacity(0.07))
              .frame(width: 250, height: 250).blur(radius: 80).offset(x: 90, y: -90)
          }
      }
      .preferredColorScheme(.dark)
      .onAppear {
        selecting = false
        withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.55)) { appeared = true }
      }
    }
  }
#endif
