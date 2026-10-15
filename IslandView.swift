import SwiftUI
import UniformTypeIdentifiers

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

private struct WidgetDrawerView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var settings: NotchSettings
    @State private var draggedWidget: WidgetKind?
    private static let dragType = UTType(exportedAs: "com.local.NotchLab.widget")

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                if settings.widgets.isEmpty {
                    emptyState
                } else {
                    widgetGrid
                }
                if state.isEditingWidgets {
                    catalog
                }
            }
            .padding(.bottom, WidgetDrawerLayout.inset)
        }
        .frame(height: state.layout.viewportHeight)
        .padding(.top, WidgetDrawerLayout.topPadding)
        .foregroundStyle(settings.foregroundColor)
        .onChange(of: state.isEditingWidgets) { _, _ in draggedWidget = nil }
    }

    private var widgetGrid: some View {
        ZStack(alignment: .topLeading) {
            ForEach(state.layout.items) { item in
                if let widget = WidgetKind(rawValue: item.id) {
                    arrangedWidget(widget, item: item)
                        .frame(width: item.frame.width, height: item.frame.height, alignment: .top)
                        .offset(x: item.frame.minX, y: item.frame.minY)
                }
            }
        }
        .frame(width: state.layout.width, height: state.layout.gridHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private func arrangedWidget(_ widget: WidgetKind, item: WidgetDrawerLayout.Item) -> some View {
        if state.isEditingWidgets {
            VStack(spacing: 8) {
                widgetCard(widget, height: item.widgetHeight)
                editingControls(widget)
                    .frame(height: 28)
            }
            .onDrag {
                draggedWidget = widget
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: Self.dragType.identifier,
                                                    visibility: .ownProcess) { completion in
                    completion(Data(widget.rawValue.utf8), nil)
                    return nil
                }
                return provider
            }
            .onDrop(of: [Self.dragType], isTargeted: nil) { providers in
                guard !providers.isEmpty, let source = draggedWidget,
                      let target = settings.widgets.firstIndex(of: widget) else { return false }
                settings.moveWidget(source, to: target)
                draggedWidget = nil
                return true
            }
        } else {
            widgetCard(widget, height: item.widgetHeight)
        }
    }

    private func widgetCard(_ widget: WidgetKind, height: CGFloat) -> some View {
        widgetContent(widget)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height, alignment: .topLeading)
        .background(settings.foregroundColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(settings.foregroundColor.opacity(state.isEditingWidgets ? 0.18 : 0.065),
                              style: StrokeStyle(lineWidth: 1, dash: state.isEditingWidgets ? [4, 4] : []))
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func widgetContent(_ widget: WidgetKind) -> some View {
        switch widget {
        case .clock:
            // The entire drawer is removed when closed, suspending its timeline.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ClockWidgetView(settings: settings, date: context.date,
                                animates: state.expanded && !state.isEditingWidgets)
            }
        }
    }

    private func editingControls(_ widget: WidgetKind) -> some View {
        let index = settings.widgets.firstIndex(of: widget) ?? 0
        return HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(settings.foregroundColor.opacity(0.4))
                .help("Sıralamak için sürükle")
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            control("Öne taşı", symbol: "arrow.left", enabled: index > 0) {
                settings.moveWidget(widget, to: index - 1)
            }
            control("Arkaya taşı", symbol: "arrow.right", enabled: index < settings.widgets.count - 1) {
                settings.moveWidget(widget, to: index + 1)
            }
            control("\(widget.title) widget’ını kaldır", symbol: "minus", enabled: true) {
                settings.removeWidget(widget)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 5)
    }

    private func control(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
                .background(settings.foregroundColor.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.25)
        .help(title)
        .accessibilityLabel(title)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(settings.foregroundColor.opacity(0.4))
            Text("Çekmecen boş")
                .font(.system(size: 13, weight: .medium))
            if state.isEditingWidgets {
                Text("Başlamak için aşağıdan bir widget ekle.")
                    .font(.system(size: 11))
                    .foregroundStyle(settings.foregroundColor.opacity(0.55))
            } else {
                Button("Widget ekle") { state.isEditingWidgets = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(settings.foregroundColor.opacity(0.1), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: state.layout.gridHeight)
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Widget ekle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(settings.foregroundColor.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(WidgetKind.allCases) { widget in
                        catalogEntry(widget)
                    }
                }
            }
        }
        .padding(.horizontal, WidgetDrawerLayout.inset)
        .padding(.top, 20)
        .frame(height: WidgetDrawerLayout.catalogHeight, alignment: .topLeading)
    }

    private func catalogEntry(_ widget: WidgetKind) -> some View {
        let added = settings.widgets.contains(widget)
        return Button {
            settings.addWidget(widget)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: widget.symbol)
                    .font(.system(size: 19, weight: .light))
                VStack(alignment: .leading, spacing: 4) {
                    Text(widget.title).font(.system(size: 12, weight: .medium))
                    Text(widget.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(settings.foregroundColor.opacity(0.55))
                }
                Spacer(minLength: 10)
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 17))
            }
            .padding(.horizontal, 14)
            .frame(width: 250, height: 58)
            .background(settings.foregroundColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(added)
        .opacity(added ? 0.55 : 1)
        .accessibilityLabel(added ? "\(widget.title), zaten eklendi" : "\(widget.title) widget’ını ekle")
    }
}

struct ClockReadout {
    let time: String
    let seconds: String
    let weekday: String
    let date: String
    let shortDate: String

    init(date: Date, timeZone: TimeZone = .autoupdatingCurrent) {
        let locale = Locale(identifier: "tr_TR")
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone)
        time = date.formatted(style.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        seconds = date.formatted(style.second(.twoDigits))
        weekday = date.formatted(style.weekday(.wide))
        self.date = date.formatted(style.day().month(.wide).year())
        shortDate = date.formatted(style.day().month(.wide))
    }
}

// Clock content knows nothing about panel geometry or hover ownership.
private struct ClockWidgetView: View {
    @ObservedObject var settings: NotchSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let date: Date
    let animates: Bool

    var body: some View {
        let readout = ClockReadout(date: date)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(readout.time)
                    .font(.system(size: 44, weight: .light, design: .rounded))
                    .tracking(-1.5)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: false))
                    .animation(digitAnimation, value: readout.time)
                    .accessibilityLabel("Saat \(readout.time)")
                if settings.showsSeconds {
                    Text(readout.seconds)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(settings.foregroundColor.opacity(0.4))
                        .contentTransition(.numericText(countsDown: false))
                        .animation(digitAnimation, value: readout.seconds)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 12)
            Rectangle()
                .fill(settings.foregroundColor.opacity(0.08))
                .frame(height: 1)
                .accessibilityHidden(true)
                .padding(.bottom, 10)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(readout.weekday)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(settings.foregroundColor.opacity(0.8))
                Spacer(minLength: 0)
                Text(readout.shortDate)
                    .font(.system(size: 11))
                    .foregroundStyle(settings.foregroundColor.opacity(0.5))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(readout.date), \(readout.weekday)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .foregroundStyle(settings.foregroundColor)
    }

    private var digitAnimation: Animation? {
        reduceMotion || !settings.animationsEnabled || !animates
            ? nil : .smooth(duration: 0.24 / settings.animationSpeed)
    }
}
