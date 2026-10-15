import Foundation

// One source of truth for card positions, scroll height and native panel size.
// Packing is ordered: a wide widget starts a new row if it cannot fit.
struct WidgetDrawerLayout: Equatable {
    struct Item: Identifiable, Equatable {
        let id: String
        let frame: CGRect
        let widgetHeight: CGFloat
    }

    static let maximumWidth: CGFloat = 880
    static let cellWidth: CGFloat = 201
    static let inset: CGFloat = 20
    static let gap: CGFloat = 12
    static let toolbarButtonSize: CGFloat = 28
    static let toolbarGap: CGFloat = 8
    static let topPadding: CGFloat = 12
    static let editingControlsHeight: CGFloat = 36
    static let catalogHeight: CGFloat = 110

    let width: CGFloat
    let columns: Int
    let items: [Item]
    let gridHeight: CGFloat
    let contentHeight: CGFloat
    var viewportHeight: CGFloat { max(0, contentHeight - Self.topPadding) }

    static func minimumWidth(collapsedWidth: CGFloat) -> CGFloat {
        // Leave the centered physical notch clear of the right-hand controls.
        collapsedWidth + 2 * (inset + 2 * toolbarButtonSize + toolbarGap + 8)
    }

    init(widgets: [WidgetDescriptor], maximumWidth: CGFloat, minimumWidth: CGFloat = 0,
         maximumHeight: CGFloat, editing: Bool) {
        let limit = max(1, min(Self.maximumWidth, maximumWidth))
        let capacity = max(1, min(4, Int((limit - 2 * Self.inset + Self.gap) / (Self.cellWidth + Self.gap))))
        var occupied = 0
        var requiredColumns = 1
        for widget in widgets {
            let span = max(1, min(capacity, widget.span))
            if occupied + span > capacity { occupied = 0 }
            occupied += span
            requiredColumns = max(requiredColumns, occupied)
        }
        columns = requiredColumns
        let gridWidth = CGFloat(columns) * Self.cellWidth + CGFloat(columns - 1) * Self.gap
        let contentMinimum: CGFloat = widgets.isEmpty ? 300 : 0
        let catalogMinimum: CGFloat = editing ? 290 : 0
        width = min(limit, max(gridWidth + 2 * Self.inset, minimumWidth, contentMinimum, catalogMinimum))
        let availableWidth = max(1, width - 2 * Self.inset)
        let cellWidth = max(1, min(Self.cellWidth, (availableWidth - CGFloat(columns - 1) * Self.gap) / CGFloat(columns)))
        let leadingInset = (width - (CGFloat(columns) * cellWidth + CGFloat(columns - 1) * Self.gap)) / 2
        var column = 0
        var rowY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var placed: [Item] = []
        for widget in widgets {
            let span = max(1, min(columns, widget.span))
            if column + span > columns {
                rowY += rowHeight + Self.gap
                rowHeight = 0
                column = 0
            }
            let height = widget.height + (editing ? Self.editingControlsHeight : 0)
            placed.append(Item(id: widget.id, frame: CGRect(
                x: leadingInset + CGFloat(column) * (cellWidth + Self.gap), y: rowY,
                width: cellWidth * CGFloat(span) + Self.gap * CGFloat(span - 1), height: height
            ), widgetHeight: widget.height))
            rowHeight = max(rowHeight, height)
            column += span
        }
        items = placed
        gridHeight = widgets.isEmpty ? 148 : rowY + rowHeight
        contentHeight = min(maximumHeight, Self.topPadding + gridHeight + Self.inset
                            + (editing ? Self.catalogHeight : 0))
    }
}
