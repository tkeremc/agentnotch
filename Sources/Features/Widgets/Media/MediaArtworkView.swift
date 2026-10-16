import AppKit
import SwiftUI

/// The same artwork surface is used in the player and beside the physical notch.
struct MediaArtworkView: View {
    let artwork: NSImage?
    let size: CGFloat
    var cornerRadius: CGFloat = 12
    var tint: Color = .white

    var body: some View {
        ZStack {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(LinearGradient(colors: [tint.opacity(0.13), tint.opacity(0.035)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle()
                    .strokeBorder(tint.opacity(0.07), lineWidth: 1)
                    .padding(size * 0.15)
                Circle()
                    .strokeBorder(tint.opacity(0.05), lineWidth: 1)
                    .padding(size * 0.27)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.3, weight: .medium))
                    .foregroundStyle(tint.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(artwork == nil ? 0.04 : 0.12), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}
