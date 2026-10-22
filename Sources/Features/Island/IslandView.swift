import SwiftUI

struct IslandView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var settings: NotchSettings
    @ObservedObject var shelf: FileShelfStore
    @ObservedObject var media: NowPlayingStore
    @ObservedObject var codex: CodexStore
    @ObservedObject var claude: ClaudeStore

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
                    .padding(.horizontal, WidgetDrawerLayout.inset)
                    .frame(width: state.expandedWidth, height: state.topBand)
                    .opacity(Double(state.contentProgress))
                    .allowsHitTesting(state.expanded && state.contentProgress > 0.9)
                    .accessibilityHidden(!state.expanded || state.contentProgress < 0.9)

                compactMedia
                compactCodexAlert

                HStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                    Text(settings.localization.text(.islandDropPrompt))
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(settings.foregroundColor.opacity(0.85))
                .frame(height: IslandState.dragHintHeight)
                .padding(.top, state.topBand - state.collapsedBottomInset)
                .opacity(Double(state.dragHintProgress * (1 - state.progress)))
                .allowsHitTesting(false)
                .accessibilityHidden(!state.showsDragHint)
            }
            .frame(width: state.surfaceWidth, height: state.surfaceHeight, alignment: .top)
            .background(settings.backgroundColor)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 16 + 12 * state.progress,
                bottomTrailingRadius: 16 + 12 * state.progress,
                topTrailingRadius: 0
            ))
            .offset(x: state.surfaceOffsetX)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, settings.localization.locale)
    }

    @ViewBuilder
    private var expandedContent: some View {
        if state.expanded || state.contentProgress > 0 {
            ZStack(alignment: .top) {
                if state.page == .home || state.pageProgress < 1 {
                    WidgetDrawerView(state: state, settings: settings, media: media, codex: codex, claude: claude)
                        .frame(width: state.layout.width, height: state.layout.contentHeight)
                        .opacity(Double(state.homePageOpacity))
                        .allowsHitTesting(state.page == .home && state.homePageOpacity > 0.9)
                        .accessibilityHidden(state.page != .home || state.homePageOpacity < 0.9)
                }
                if state.page == .files || state.pageProgress > 0 {
                    FileShelfView(state: state, settings: settings, store: shelf)
                        .frame(width: state.shelfWidth, height: state.shelfHeight)
                        .opacity(Double(state.filesPageOpacity))
                        .allowsHitTesting(state.page == .files && state.filesPageOpacity > 0.9)
                        .accessibilityHidden(state.page != .files || state.filesPageOpacity < 0.9)
                }
            }
        } else {
            Color.clear
        }
    }

    private var compactMedia: some View {
        Button {
            state.openMedia?()
        } label: {
            MediaArtworkView(artwork: media.snapshot?.artwork, size: 22, cornerRadius: 5)
                .frame(width: IslandState.mediaWingWidth, height: state.topBand - state.collapsedBottomInset)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: state.surfaceWidth, alignment: .leading)
        .opacity(Double(state.mediaProgress * max(0, 1 - state.progress * 2)))
        .allowsHitTesting(state.hasMedia && !state.expanded)
        .accessibilityHidden(!state.hasMedia || state.expanded)
        .help(settings.localization.text(.mediaOpenPlayer))
        .accessibilityLabel(settings.localization.text(.mediaOpenPlayer))
    }

    private var toolbar: some View {
        HStack(spacing: WidgetDrawerLayout.toolbarGap) {
            pageButton(.home, symbol: "house", title: settings.localization.text(.islandHome))
            pageButton(.files, symbol: "tray", title: settings.localization.text(.islandFiles))
            Spacer(minLength: 0)
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
            .help(state.isEditingWidgets ? settings.localization.text(.islandFinishEditing) : settings.localization.text(.islandEditWidgets))
            .accessibilityLabel(state.isEditingWidgets ? settings.localization.text(.islandFinishEditing) : settings.localization.text(.islandEditWidgets))
            .opacity(Double(state.homePageOpacity))
            .allowsHitTesting(state.page == .home && state.homePageOpacity > 0.9)
            .accessibilityHidden(state.page != .home || state.homePageOpacity < 0.9)
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
            .help(settings.localization.text(.islandSettingsHelp))
            .accessibilityLabel(settings.localization.text(.islandOpenSettings))
        }
        .foregroundStyle(settings.foregroundColor)
    }

    private var compactCodexAlert: some View {
        HStack(spacing: 0) {
            ForEach(state.codexCompactAgents) { agent in
                let statusTitle = settings.localization.text(agent.iconName == "ClaudeMark" && agent.indicator == .connectionIssue
                    ? .claudeRepairHint : agent.indicator.title)
                let provider = agent.iconName == "ClaudeMark" ? "Claude" : "Codex"
                let identity = agent.role.map { "\(provider) · \(settings.localization.text($0.title))" } ?? provider
                let description = agent.name == provider ? "\(identity) · \(statusTitle)"
                    : "\(identity) · \(agent.name) · \(statusTitle)"
                Button { state.openCodex?() } label: {
                    CompactAgentMark(iconName: agent.iconName, isSubagent: agent.role == .subagent,
                        foreground: settings.foregroundColor,
                        background: settings.backgroundColor, statusSymbol: agent.indicator.symbol,
                        statusColor: agent.indicator == .working ? .green
                            : agent.indicator == .failed ? .red : .orange,
                        animates: agent.indicator == .working && settings.animationsEnabled)
                        .frame(width: IslandState.codexWingWidth,
                               height: state.topBand - state.collapsedBottomInset)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(description)
                .accessibilityLabel(description)
            }
        }
        .frame(width: state.codexWingWidth, alignment: .leading)
        .clipped()
        .frame(width: state.surfaceWidth, alignment: .trailing)
        .opacity(Double(state.codexAlertProgress * max(0, 1 - state.progress * 2)))
        .allowsHitTesting(state.hasCodexAlert && !state.expanded)
        .accessibilityHidden(!state.hasCodexAlert || state.expanded)
    }

    private func pageButton(_ page: IslandPage, symbol: String, title: String) -> some View {
        let selection = page == .home ? 1 - state.pageProgress : state.pageProgress
        return Button { state.selectPage(page) } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: WidgetDrawerLayout.toolbarButtonSize, height: WidgetDrawerLayout.toolbarButtonSize)
                .background {
                    Circle().fill(settings.foregroundColor.opacity(0.07 + 0.11 * Double(selection)))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(state.page == page ? [.isSelected] : [])
        .disabled(state.isIncomingDrag || state.isOutgoingDrag)
    }
}


/// Shape communicates hierarchy; the provider mark and status stay independent.
struct CompactAgentMark: View {
    let iconName: String
    let isSubagent: Bool
    let foreground: Color
    let background: Color
    let statusSymbol: String
    let statusColor: Color
    let animates: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isSubagent {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(width: 18, height: 18)
                    .overlay(alignment: .topLeading) {
                        providerMark(size: 13)
                            .padding(1)
                            .background(background, in: Circle())
                            .offset(x: -5, y: -3)
                    }
            } else {
                providerMark(size: 18)
            }
        }
        .frame(width: 18, height: 18)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: statusSymbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, options: .repeating,
                    isActive: animates && !reduceMotion)
                .frame(width: 11, height: 11)
                .background(background, in: Circle())
                .offset(x: 3, y: 3)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private func providerMark(size: CGFloat) -> some View {
        Image(iconName)
            .resizable()
            .scaledToFit()
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
    }
}
