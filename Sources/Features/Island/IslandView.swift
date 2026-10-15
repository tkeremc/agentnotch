import SwiftUI

struct IslandView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var settings: NotchSettings

    var body: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                expandedContent
                    // Reveal a fully laid-out drawer; never reflow cards during hover.
                    .frame(width: state.expandedWidth, height: state.contentHeight, alignment: .top)
                    .mask(alignment: .top) {
                        GeometryReader { geometry in
                            Rectangle()
                                .frame(height: geometry.size.height * state.contentProgress)
                        }
                    }
                    .padding(.top, state.topBand)
                    .opacity(Double(state.contentProgress))
                    .allowsHitTesting(state.expanded && state.contentProgress > 0.9)
                    .accessibilityHidden(!state.expanded || state.contentProgress < 0.9)

                toolbar
                    .padding(.trailing, WidgetDrawerLayout.inset)
                    .frame(width: state.expandedWidth, height: state.topBand, alignment: .trailing)
                    .opacity(Double(state.contentProgress))
                    .allowsHitTesting(state.expanded && state.contentProgress > 0.9)
                    .accessibilityHidden(!state.expanded || state.contentProgress < 0.9)
            }
            .frame(width: state.surfaceWidth, height: state.surfaceHeight, alignment: .top)
            .background(settings.backgroundColor)
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

    @ViewBuilder
    private var expandedContent: some View {
        if state.expanded || state.contentProgress > 0 {
            WidgetDrawerView(state: state, settings: settings)
        } else {
            Color.clear
        }
    }

    private var toolbar: some View {
        HStack(spacing: WidgetDrawerLayout.toolbarGap) {
            Button {
                state.isEditingWidgets.toggle()
            } label: {
                Image(systemName: state.isEditingWidgets ? "checkmark" : "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: WidgetDrawerLayout.toolbarButtonSize, height: WidgetDrawerLayout.toolbarButtonSize)
                    .background(settings.foregroundColor.opacity(state.isEditingWidgets ? 0.16 : 0.07),
                                in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(state.isEditingWidgets ? "Düzenlemeyi bitir" : "Widget’ları düzenle")
            .accessibilityLabel(state.isEditingWidgets ? "Düzenlemeyi bitir" : "Widget’ları düzenle")
            Button {
                state.openSettings?()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: WidgetDrawerLayout.toolbarButtonSize, height: WidgetDrawerLayout.toolbarButtonSize)
                    .background(settings.foregroundColor.opacity(0.07), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("leagent notch ayarları")
            .accessibilityLabel("leagent notch ayarlarını aç")
        }
        .foregroundStyle(settings.foregroundColor)
    }
}
