import SwiftUI

struct IslandView: View {
    @ObservedObject var state: IslandState
    // Temporary ice-blue surface (#DDF4FF).
    private let background = Color(.sRGB, red: 221 / 255, green: 244 / 255, blue: 1, opacity: 1)

    var body: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                expandedContent
                    // Content always has its final width. The surface reveals
                    // it without reflowing text at every intermediate size.
                    .frame(width: state.expandedWidth)
                    .padding(.top, state.topBand)
                    .offset(y: 6 * (1 - state.contentProgress))
                    .opacity(Double(state.contentProgress))
                    .allowsHitTesting(state.expanded && state.contentProgress > 0.9)
                    .accessibilityHidden(!state.expanded || state.contentProgress < 0.9)
            }
            .frame(width: state.surfaceWidth, height: state.surfaceHeight, alignment: .top)
            .background(background)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 8,
                bottomLeadingRadius: 16 + 12 * state.progress,
                bottomTrailingRadius: 16 + 12 * state.progress,
                topTrailingRadius: 8
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(.white)
                    Text("NotchLab").font(.system(size: 15, weight: .semibold))
                }
                Spacer()
                Text("İLK DENEME")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.4))
            }
            HStack(spacing: 12) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(background, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Küçük bir alan, yeni olasılıklar.")
                        .font(.system(size: 13, weight: .medium))
                    Text("Fareyi uzaklaştırınca ada küçülür.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            HStack {
                Text(state.pinned ? "Açık kalıyor" : "Hover ile açıldı")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Button {
                    state.pinned.toggle()
                    state.pinChanged?()
                } label: {
                    Label(state.pinned ? "Sabitlemeyi kaldır" : "Açık tut",
                          systemImage: state.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(state.pinned ? 1 : 0.7))
                .accessibilityLabel(state.pinned ? "Adanın sabitlemesini kaldır" : "Adayı açık tut")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
    }
}
