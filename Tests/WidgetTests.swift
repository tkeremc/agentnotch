import Darwin
import Foundation
@testable import AgentNotch

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
struct WidgetTests {
    static func main() {
        let tests: [(String, @MainActor () throws -> Void)] = [
            ("four columns and next row", packing),
            ("wide cards preserve order and gaps", mixedSpans),
            ("next row clears tallest card", rowHeights),
            ("narrow screens clamp columns and spans", narrowScreens),
            ("drawer width follows content and clears notch controls", dynamicWidth),
            ("viewport caps without truncating grid", viewport),
            ("editing reserves controls and catalog", editing),
            ("first run, empty list and persistence", persistence),
            ("stored identifiers are sanitized", storedIdentifiers),
            ("single-widget reorder is safe", reordering),
            ("media extends only to the left and clears on expansion", mediaGeometry),
            ("media widget persists and keeps user selections", mediaPersistence),
            ("Claude and Codex persist independently and fit the agent wing", claudeIntegration),
            ("Turkish clock follows supplied timezone", clock),
            ("file drag switches page and restores on cancel", fileDragState),
            ("page transition geometry stays continuous", pageGeometry),
            ("file drag hint stays compact until approach", fileDragHint),
            ("cancelled file drag restores page only after collapse", deferredDragRestoration)
        ] + FileShelfTests.cases + FileShelfDragTests.cases + LocalizationTests.cases + NowPlayingTests.cases
          + CodexActivityTests.cases + CodexUsageTests.cases + CodexHookInstallerTests.cases
          + CodexStoreTests.cases + ClaudeActivityTests.cases + ClaudeStoreTests.cases
          + ClaudeHookInstallerTests.cases
        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS: \(name)")
            } catch {
                failures += 1
                print("FAIL: \(name): \(error)")
            }
        }
        print("\(tests.count - failures)/\(tests.count) tests passed")
        if failures > 0 { exit(1) }
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String, line: UInt = #line) throws {
        if !condition() { throw TestFailure(description: "line \(line): \(message)") }
    }

    private static func descriptor(_ id: String, span: Int = 1,
                                   height: CGFloat = 148) -> WidgetDescriptor {
        WidgetDescriptor(id: id, span: span, height: height)
    }

    private static func layout(_ widgets: [WidgetDescriptor], width: CGFloat = 880,
                               minimumWidth: CGFloat = 0,
                               maximumHeight: CGFloat = 560,
                               editing: Bool = false) -> WidgetDrawerLayout {
        WidgetDrawerLayout(widgets: widgets, maximumWidth: width, minimumWidth: minimumWidth,
                           maximumHeight: maximumHeight, editing: editing)
    }

    private static func packing() throws {
        let result = layout((0..<5).map { descriptor("card-\($0)") })
        try expect(result.columns == 4, "880 pt should fit four columns")
        try expect(result.items.map(\.id) == (0..<5).map { "card-\($0)" }, "order changed")
        try expect(result.items.prefix(4).allSatisfy { $0.frame.minY == 0 }, "first four must share a row")
        try expect(result.items[0].frame.minX == 20, "leading inset")
        try expect(result.items[3].frame.maxX == 860, "trailing inset")
        try expect(result.items[1].frame.minX - result.items[0].frame.maxX == 12, "card gap")
        try expect(result.items[4].frame.minY == 160, "fifth card must start next row")
        try expect(result.items[4].frame.minX == 20, "next row starts at leading edge")
        try expect(result.gridHeight == 308, "two-row grid height")
    }

    private static func mixedSpans() throws {
        let result = layout([
            descriptor("a"), descriptor("b"), descriptor("c"),
            descriptor("wide", span: 2), descriptor("tail"), descriptor("next-wide", span: 2)
        ])
        let wide = result.items[3].frame
        try expect(wide.minX == 20 && wide.minY == 160, "wide card starts a new row")
        try expect(wide.width == result.items[0].frame.width * 2 + 12, "wide card spans two cells")
        try expect(result.items[4].frame.minY == 160, "later narrow card must not backfill previous row")
        try expect(result.items[4].frame.minX == wide.maxX + 12, "narrow card follows wide card")
        try expect(result.items[5].frame.minY == 320, "second wide card overflows to next row")
    }

    private static func rowHeights() throws {
        let result = layout([
            descriptor("short", height: 100), descriptor("tall", height: 180),
            descriptor("third", height: 120), descriptor("fourth", height: 140),
            descriptor("next", height: 60)
        ])
        try expect(result.items[4].frame.minY == 192, "row must clear tallest card plus gap")
        try expect(result.gridHeight == 252, "grid includes final row height")
    }

    private static func narrowScreens() throws {
        let cards = [descriptor("wide", span: 2), descriptor("narrow")]
        let single = layout(cards, width: 440)
        try expect(single.columns == 1, "narrow screen should use one column")
        try expect(single.items[0].frame.width == 201, "wide card clamps to one fixed-width column")
        try expect(single.items[1].frame.minY == 160, "narrow card follows on next row")
        try expect(single.items.allSatisfy { $0.frame.maxX <= 420 }, "cards stay inside horizontal insets")
        let double = layout(cards, width: 660)
        try expect(double.columns == 2, "intermediate screen should use two columns")
        try expect(double.items[0].frame.width == 414, "wide card fills two fixed-width columns")
        let manyCards = (0..<8).map { descriptor("card-\($0)") }
        try expect(layout(manyCards, width: 2000).columns == 4, "drawer never exceeds four columns")
        let constrained = layout(cards, width: 200)
        try expect(constrained.width == 200 && constrained.items[0].frame.width == 160,
                   "cards shrink only when screen cannot fit one normal cell")
    }

    private static func dynamicWidth() throws {
        let minimum = WidgetDrawerLayout.minimumWidth(collapsedWidth: 216)
        let one = layout([WidgetKind.clock.descriptor], minimumWidth: minimum)
        try expect(one.width == 454, "one clock reserves two cells and clears notch controls")
        try expect(one.items[0].frame.midX == one.width / 2, "single clock stays centered")
        let notchRight = one.width / 2 + 108
        let controlsLeft = one.width - 20 - 64
        try expect(controlsLeft - notchRight >= 8, "icons must stay beside the physical notch")
        let expectedWidths: [CGFloat] = [400, 454, 667, 880, 880]
        for count in 1...5 {
            let result = layout((0..<count).map { descriptor("card-\($0)") }, minimumWidth: minimum)
            try expect(result.width == expectedWidths[count - 1], "width must follow occupied columns")
            try expect(result.items.allSatisfy { $0.frame.width == 201 }, "adding cards must not resize existing cards")
        }
        let wide = layout([descriptor("wide", span: 2)], minimumWidth: minimum)
        try expect(wide.width == 454 && wide.items[0].frame.width == 414, "wide card reserves two cells")
        let gaps = layout([descriptor("a"), descriptor("b"), descriptor("c"),
                           descriptor("wide", span: 2), descriptor("d")])
        try expect(gaps.width == 667, "unused trailing column should not widen drawer")
        let editable = layout([WidgetKind.clock.descriptor], minimumWidth: minimum, editing: true)
        try expect(editable.width == one.width, "editing a single clock should keep toolbar position stable")
        let empty = layout([], minimumWidth: minimum, editing: true)
        try expect(empty.width == 400, "empty drawer still fits controls and catalog")
        let constrained = layout([WidgetKind.clock.descriptor], width: 320, minimumWidth: minimum)
        try expect(constrained.width == 320, "screen limit takes precedence over preferred minimum")
    }

    private static func viewport() throws {
        let cards = (0..<24).map { descriptor("card-\($0)") }
        let result = layout(cards)
        try expect(result.contentHeight == 560, "drawer must respect normal height cap")
        try expect(result.viewportHeight == 548, "top padding remains outside scrolling viewport")
        try expect(result.gridHeight > result.viewportHeight, "full grid remains available to scroll")
        try expect(result.items.count == 24, "cap must not discard cards")
        let shortScreen = layout(cards, maximumHeight: 320)
        try expect(shortScreen.contentHeight == 320 && shortScreen.viewportHeight == 308,
                   "screen height cap must reduce viewport")
    }

    private static func editing() throws {
        let normal = layout([WidgetKind.clock.descriptor])
        let editable = layout([WidgetKind.clock.descriptor], editing: true)
        try expect(editable.items[0].widgetHeight == 180, "widget content keeps its own height")
        try expect(editable.items[0].frame.height == 216, "editing reserves card controls")
        try expect(editable.contentHeight - normal.contentHeight == 146,
                   "editing reserves controls plus catalog")
        let empty = layout([], editing: true)
        try expect(empty.items.isEmpty && empty.gridHeight == 148, "empty drawer reserves empty-state space")
        try expect(empty.contentHeight == 290, "empty editing drawer includes catalog")

        let state = IslandState()
        var changes = 0
        state.editingChanged = { changes += 1 }
        state.isEditingWidgets = true
        state.isEditingWidgets = true
        state.isEditingWidgets = false
        try expect(changes == 2, "controller callback fires only for actual editing transitions")
    }

    private static func fileDragState() throws {
        let state = IslandState()
        state.isEditingWidgets = true
        state.beginIncomingDrag()
        try expect(state.page == .files && state.holdsOpen, "file drag selects depot and pins panel")
        try expect(!state.isEditingWidgets, "file page ends widget editing")
        state.beginIncomingDrag()
        state.isDropTargeted = true
        state.endIncomingDrag()
        try expect(state.page == .home && !state.holdsOpen && !state.isDropTargeted,
                   "cancel restores page and clears drag state")
        state.beginIncomingDrag()
        state.endIncomingDrag(accepted: true)
        try expect(state.page == .files && !state.isIncomingDrag, "accepted drop keeps depot selected")
        state.beginIncomingDrag()
        state.endIncomingDrag()
        try expect(state.page == .files, "depot was already selected before cancelled drag")
        state.page = .home
        state.isOutgoingDrag = true
        state.beginIncomingDrag()
        try expect(state.page == .home && !state.isIncomingDrag, "own outgoing drag cannot switch pages")
        state.layout = layout([], minimumWidth: 720)
        state.shelfHeight = 400
        try expect(state.canvasSize.width >= 744 && state.canvasSize.height >= state.topBand + 412,
                   "native canvas accommodates both pages")
    }

    private static func pageGeometry() throws {
        let state = IslandState()
        state.progress = 1
        let homeWidth = state.layout.width
        let homeHeight = state.layout.contentHeight
        state.page = .files
        try expect(state.surfaceWidth == homeWidth && state.contentHeight == homeHeight,
                   "selecting a page must not jump geometry ahead of the animation")
        state.pageProgress = 0.5
        try expect(state.surfaceWidth == homeWidth && state.shelfWidth == homeWidth,
                   "both pages keep home width throughout the transition")
        try expect(state.contentHeight == (homeHeight + 240) / 2,
                   "height interpolates between fixed page layouts")
        try expect(state.homePageOpacity == 0 && state.filesPageOpacity == 0,
                   "page content fades through background without ghosting two pages together")
        for frame in 0...60 {
            state.pageProgress = CGFloat(frame) / 60
            try expect(state.homePageOpacity == 0 || state.filesPageOpacity == 0,
                       "only one page is readable at every transition frame")
        }
        state.pageProgress = 1
        try expect(state.surfaceWidth == homeWidth && state.contentHeight == 240,
                   "depot keeps home width and settles to the short height")
        state.layout = layout([], minimumWidth: 500)
        try expect(state.expandedWidth == state.layout.width && state.shelfWidth == state.layout.width,
                   "depot automatically follows changes to home layout width")
        var motion = IslandMotion()
        for _ in 0..<5 { motion.advance(toward: 1, elapsed: 1.0 / 60, frequency: 34) }
        let before = motion.progress
        motion.advance(toward: 0, elapsed: 0, frequency: 34)
        try expect(abs(motion.progress - before) < 0.000001,
                   "rapid page reversal preserves its current position")
        for _ in 0..<120 { motion.advance(toward: 0, elapsed: 1.0 / 60, frequency: 34) }
        try expect(motion.progress == 0 && motion.velocity == 0, "reversed transition settles at home")
    }

    private static func fileDragHint() throws {
        let state = IslandState()
        state.hasFileDrag = true
        state.dragHintProgress = 1
        try expect(state.showsDragHint && !state.holdsOpen && state.page == .home,
                   "a distant file drag shows only a hint without opening or switching pages")
        try expect(state.surfaceHeight == state.topBand + 26 - state.collapsedBottomInset,
                   "hint sits just below the hardware notch")
        try expect(state.surfaceWidth == state.collapsedWidth + 24,
                   "hint grows the collapsed notch only slightly")
        state.beginIncomingDrag()
        state.expanded = true
        state.progress = 1
        try expect(!state.showsDragHint && state.page == .files && state.holdsOpen,
                   "approach replaces hint with the expanded depot")
        try expect(state.surfaceWidth == state.layout.width
                   && state.surfaceHeight == state.topBand + state.contentHeight,
                   "a fading hint adds no extra geometry to the open panel")
        state.endIncomingDrag()
        state.expanded = false
        state.isOutgoingDrag = true
        try expect(!state.showsDragHint, "outgoing shelf drags must not advertise incoming storage")
        state.isOutgoingDrag = false
        state.hasFileDrag = false
        state.dragHintProgress = 0
        state.progress = 0
        try expect(!state.showsDragHint && state.surfaceWidth == state.collapsedWidth,
                   "release restores the original collapsed notch")
    }

    private static func deferredDragRestoration() throws {
        let state = IslandState()
        state.expanded = true
        state.progress = 1
        state.contentProgress = 1
        state.beginIncomingDrag()
        state.endIncomingDrag()
        try expect(state.page == .files && !state.holdsOpen,
                   "retreat keeps depot visible while allowing panel to close")
        state.expanded = false
        state.progress = 0.4
        state.contentProgress = 0.2
        state.restorePageAfterCollapse()
        try expect(state.page == .files, "home must not flash during the closing animation")
        state.progress = 0
        state.restorePageAfterCollapse()
        try expect(state.page == .files, "restoration also waits for content to disappear")
        state.contentProgress = 0
        state.restorePageAfterCollapse()
        try expect(state.page == .home, "previous page is restored only when hidden")

        state.expanded = true
        state.progress = 1
        state.contentProgress = 1
        state.beginIncomingDrag()
        state.endIncomingDrag()
        state.beginIncomingDrag()
        state.endIncomingDrag()
        state.expanded = false
        state.progress = 0
        state.contentProgress = 0
        state.restorePageAfterCollapse()
        try expect(state.page == .home, "rapid retreat and reentry preserve the original page")

        state.expanded = true
        state.progress = 1
        state.contentProgress = 1
        state.beginIncomingDrag()
        state.endIncomingDrag()
        state.selectPage(.files)
        state.expanded = false
        state.progress = 0
        state.contentProgress = 0
        state.restorePageAfterCollapse()
        try expect(state.page == .files, "explicit tab choice cancels queued restoration")
    }

    private static func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "AgentNotch.WidgetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private static func persistence() throws {
        try withDefaults { defaults in
            let settings = NotchSettings(defaults: defaults)
            try expect(settings.widgets == [.clock, .media], "first run includes clock and media")
            settings.addWidget(.clock)
            try expect(settings.widgets == [.clock, .media], "adding same kind must not duplicate")
            settings.removeWidget(.clock)
            settings.removeWidget(.media)
            try expect(defaults.stringArray(forKey: "island.widgets") == [], "removal saves intentional empty list")
            try expect(NotchSettings(defaults: defaults).widgets.isEmpty, "empty list survives reload")
            settings.removeWidget(.clock)
            settings.addWidget(.clock)
            try expect(defaults.stringArray(forKey: "island.widgets") == ["clock"], "adding saves immediately")
            try expect(NotchSettings(defaults: defaults).widgets == [.clock], "added clock survives reload")
        }
    }

    private static func storedIdentifiers() throws {
        try withDefaults { defaults in
            defaults.set(["future-widget", "clock", "clock", "unknown"], forKey: "island.widgets")
            try expect(NotchSettings(defaults: defaults).widgets == [.clock], "ignore unknown IDs and deduplicate")
            defaults.set(["future-widget"], forKey: "island.widgets")
            try expect(NotchSettings(defaults: defaults).widgets.isEmpty, "valid list with unknown kinds remains empty")
            defaults.set(42, forKey: "island.widgets")
            try expect(NotchSettings(defaults: defaults).widgets == [.clock, .media], "malformed storage falls back to default widgets")
        }
    }

    private static func reordering() throws {
        try withDefaults { defaults in
            let settings = NotchSettings(defaults: defaults)
            settings.removeWidget(.media)
            for destination in [Int.min, -1, 0, 1, Int.max] {
                settings.moveWidget(.clock, to: destination)
                try expect(settings.widgets == [.clock], "single item reorder must remain valid")
            }
            settings.removeWidget(.clock)
            settings.moveWidget(.clock, to: 0)
            try expect(settings.widgets.isEmpty, "moving absent widget must not add it")
        }
    }

    private static func mediaGeometry() throws {
        let state = IslandState()
        let rightEdge = state.surfaceWidth / 2 + state.surfaceOffsetX
        state.hasMedia = true
        state.mediaProgress = 1
        try expect(state.surfaceWidth == state.collapsedWidth + 44, "artwork reserves a left wing")
        try expect(state.surfaceWidth / 2 + state.surfaceOffsetX == rightEdge,
                   "the physical notch right edge never moves when media appears")
        for frame in 0...60 {
            state.progress = CGFloat(frame) / 60
            let left = state.surfaceOffsetX - state.surfaceWidth / 2
            let right = state.surfaceOffsetX + state.surfaceWidth / 2
            try expect(left >= -state.canvasSize.width / 2 && right <= state.canvasSize.width / 2,
                       "asymmetric surface stays inside the fixed native canvas")
        }
        try expect(state.surfaceOffsetX == 0 && state.surfaceWidth == state.expandedWidth,
                   "fully expanded drawer stays centered with no residual wing")
        state.progress = 0
        state.mediaProgress = 0
        try expect(state.surfaceWidth == state.collapsedWidth && state.surfaceOffsetX == 0,
                   "removing media restores the original notch geometry")
    }

    private static func mediaPersistence() throws {
        try withDefaults { defaults in
            defaults.set(["clock"], forKey: "island.widgets")
            let settings = NotchSettings(defaults: defaults)
            try expect(settings.widgets == [.clock], "existing widget choices remain intact")
            settings.addWidget(.media)
            settings.addWidget(.media)
            try expect(NotchSettings(defaults: defaults).widgets == [.clock, .media],
                       "media can be added and survives relaunch without duplicates")
            settings.removeWidget(.media)
            try expect(NotchSettings(defaults: defaults).widgets == [.clock], "media removal is persistent")
            let result = layout([WidgetKind.media.descriptor, WidgetKind.clock.descriptor])
            try expect(result.items[0].frame.width == 414 && result.items[0].widgetHeight == 180,
                       "media owns a wide card that leaves room for transport controls")
        }
    }

    private static func claudeIntegration() throws {
        try withDefaults { defaults in
            defaults.set(["clock", "codex"], forKey: "island.widgets")
            let settings = NotchSettings(defaults: defaults)
            settings.addWidget(.claude)
            settings.addWidget(.claude)
            try expect(NotchSettings(defaults: defaults).widgets == [.clock, .codex, .claude],
                       "adding Claude preserves existing choices without duplicates")
            settings.moveWidget(.claude, to: 0)
            try expect(NotchSettings(defaults: defaults).widgets == [.claude, .clock, .codex],
                       "Claude order persists")
            settings.removeWidget(.claude)
            try expect(NotchSettings(defaults: defaults).widgets == [.clock, .codex],
                       "removing Claude leaves Codex configured")
            let result = layout([WidgetKind.codex.descriptor, WidgetKind.claude.descriptor])
            try expect(result.items.allSatisfy { $0.frame.width == 414 && $0.widgetHeight == 180 },
                       "both provider cards use their normal two-column geometry")
        }
        let state = IslandState()
        state.codexCompactAgents = [
            CodexCompactAgent(id: "codex:same", name: "Codex", indicator: .working),
            CodexCompactAgent(id: "claude:same", name: "Claude", indicator: .approval, iconName: "ClaudeMark")]
        state.hasCodexAlert = true
        state.codexAlertProgress = 1
        state.codexSlotsProgress = 2
        try expect(state.codexWingWidth == 56, "provider indicators reserve separate slots")
        for frame in 0...60 {
            state.progress = CGFloat(frame) / 60
            let right = state.surfaceOffsetX + state.surfaceWidth / 2
            try expect(right <= state.canvasSize.width / 2, "combined indicators fit the native canvas")
        }
        try expect(state.codexWingWidth == 0, "provider wing retracts after expansion")
    }

    private static func clock() throws {
        let instant = ISO8601DateFormatter().date(from: "2026-10-15T21:05:09Z")!
        let utc = ClockReadout(date: instant, timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "tr_TR"))
        try expect(utc.time == "21:05" && utc.seconds == "09", "24-hour time and padded seconds")
        try expect(utc.date == "15 Ekim 2026" && utc.weekday == "Perşembe", "Turkish date and weekday")
        let istanbul = ClockReadout(date: instant, timeZone: TimeZone(identifier: "Europe/Istanbul")!, locale: Locale(identifier: "tr_TR"))
        try expect(istanbul.time == "00:05", "timezone can cross midnight")
        try expect(istanbul.date == "16 Ekim 2026" && istanbul.weekday == "Cuma", "date follows timezone rollover")
    }
}
