import Foundation

// Geometry finishes before content reveals from top to bottom. Closing hides
// content and shrinks the surface together; both remain continuous on reversal.
struct IslandTransition {
    var surface = IslandMotion()
    var content = IslandMotion()

    init(expanded: Bool = false) {
        surface = IslandMotion(progress: expanded ? 1 : 0)
        content = IslandMotion(progress: expanded ? 1 : 0)
    }

    mutating func advance(expanded: Bool, elapsed: Double, speed: Double = 1) {
        let elapsed = elapsed * speed
        if expanded {
            surface.advance(toward: 1, elapsed: elapsed, frequency: 44)
            content.advance(toward: surface.progress == 1 ? 1 : 0,
                            elapsed: elapsed, frequency: 60)
        } else {
            content.advance(toward: 0, elapsed: elapsed, frequency: 76)
            surface.advance(toward: 0, elapsed: elapsed, frequency: 48)
        }
    }

    func isSettled(expanded: Bool) -> Bool {
        let target = expanded ? 1.0 : 0.0
        return surface.progress == target && surface.velocity == 0
            && content.progress == target && content.velocity == 0
    }
}
