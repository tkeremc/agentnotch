import AppKit
import SwiftUI

@MainActor
final class HoverHostingView: NSHostingView<IslandView> {
    var hoverChanged: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    // The notch stays inactive while another app has focus. Deliver the first
    // click to its SwiftUI controls instead of consuming it for activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }
}
