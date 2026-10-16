import AppKit
import SwiftUI

struct FileShelfView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var settings: NotchSettings
    @ObservedObject var store: FileShelfStore

    var body: some View {
        FileShelfDropDestination(isEnabled: state.page == .files && state.expanded,
                                onTargeted: { state.dropTargetChanged?($0) }, onDrop: {
            state.filesDropped?($0) ?? false
        }) {
            VStack(spacing: 12) {
                HStack {
                    Text(settings.localization.text(.fileShelfTitle)).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(settings.localization.text(.shelfItemCount, Int64(store.items.count)))
                        .font(.system(size: 11))
                        .opacity(0.5)
                }
                if let error = store.errorMessage {
                    HStack(alignment: .top) {
                        Text(error.localized(using: settings.localization)).font(.system(size: 11))
                        Spacer(minLength: 4)
                        Button { store.clearError() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .accessibilityLabel(settings.localization.text(.fileShelfDismissError))
                    }
                    .foregroundStyle(.orange)
                }
                if store.items.isEmpty {
                    emptyState
                } else {
                    ScrollView(.vertical) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 10)], spacing: 10) {
                            ForEach(store.items) { item in card(item) }
                        }
                        .padding(2)
                    }
                    Text(state.isDropTargeted ? settings.localization.text(.fileShelfDropToAdd) : settings.localization.text(.fileShelfDragToRetrieve))
                        .font(.system(size: 11))
                        .opacity(state.isDropTargeted ? 0.9 : 0.45)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(settings.foregroundColor.opacity(state.isDropTargeted ? 0.09 : 0.025),
                        in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(settings.foregroundColor.opacity(state.isDropTargeted ? 0.65 : 0.15),
                                  style: StrokeStyle(lineWidth: state.isDropTargeted ? 2 : 1, dash: [6, 5]))
                    .allowsHitTesting(false)
            }
            .foregroundStyle(settings.foregroundColor)
            .environment(\.colorScheme, .dark)
        }
        .padding(.horizontal, WidgetDrawerLayout.inset)
        .padding(.top, WidgetDrawerLayout.topPadding)
        .padding(.bottom, WidgetDrawerLayout.inset)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: state.isDropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 32, weight: .light))
                .opacity(state.isDropTargeted ? 1 : 0.5)
            Text(state.isDropTargeted ? settings.localization.text(.fileShelfDropHere) : settings.localization.text(.fileShelfDropFiles))
                .font(.system(size: 13, weight: .medium))
            Text(settings.localization.text(.fileShelfDescription))
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .opacity(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ item: FileShelfItem) -> some View {
        VStack(spacing: 5) {
            VStack(spacing: 8) {
                if let url = item.url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().scaledToFit().frame(width: 38, height: 38)
                } else {
                    Image(systemName: "doc.badge.ellipsis")
                        .font(.system(size: 30, weight: .light))
                        .frame(height: 38).opacity(0.35)
                }
                Text(item.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2).truncationMode(.middle)
                    .frame(height: 28, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .overlay {
                FileShelfDragSource(url: item.url, onBegan: {
                    state.outgoingChanged?(true)
                }, onEnded: { operation in
                    if operation.contains(.copy) { store.remove(id: item.id) }
                    store.refresh()
                    state.outgoingChanged?(false)
                })
                .accessibilityLabel(settings.localization.text(.fileShelfDragItem, item.name))
            }
            // Keep the native drag surface below the always-visible trash button.
            .padding(.top, 30)
            if !item.isAvailable {
                Text(settings.localization.text(.fileShelfInaccessible))
                    .font(.system(size: 9)).foregroundStyle(.orange)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.bottom, 10)
        .background(settings.foregroundColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            Button { store.remove(id: item.id) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .background(settings.foregroundColor.opacity(0.07), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(settings.localization.text(.fileShelfRemove))
            .accessibilityLabel(settings.localization.text(.fileShelfRemoveItem, item.name))
            .disabled(state.isOutgoingDrag)
            .padding(4)
        }
        .help(item.url?.path ?? settings.localization.text(.fileShelfInaccessible))
    }
}
