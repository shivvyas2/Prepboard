import XCTest
@testable import Prepboard

final class WorkspaceTests: XCTestCase {
    // AppKit coordinates: origin at the bottom-left of the main (built-in) screen.
    let builtin = WorkspaceScreen(id: "B", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949), isBuiltin: true)
    let acer = WorkspaceScreen(id: "A", name: "Acer", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                               visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415), isBuiltin: false)
    let tv = WorkspaceScreen(id: "T", name: "TV", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                             visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055), isBuiltin: false)

    func testRankingLargestFirstAndFingerprintIsOrderIndependent() {
        XCTAssertEqual(Workspace.ranked([builtin, tv, acer]).map(\.id), ["A", "T", "B"])
        XCTAssertEqual(Workspace.fingerprint([acer, builtin]), Workspace.fingerprint([builtin, acer]))
        XCTAssertNotEqual(Workspace.fingerprint([acer, builtin]), Workspace.fingerprint([builtin]))
    }

    func testExternalBeatsBuiltinOnEqualArea() {
        let ext = WorkspaceScreen(id: "E", name: "E", frame: builtin.frame.offsetBy(dx: 1512, dy: 0), visibleFrame: builtin.visibleFrame.offsetBy(dx: 1512, dy: 0), isBuiltin: false)
        XCTAssertEqual(Workspace.ranked([builtin, ext]).map(\.id), ["E", "B"])
    }

    func testUnitRectMeasuresFromTopLeft() {
        // Top half of the Acer: in AppKit the top half has the higher y.
        let f = Workspace.frame(for: UnitRect(x: 0, y: 0, w: 1, h: 0.5), in: acer.visibleFrame)
        XCTAssertEqual(f, CGRect(x: 1512, y: 707.5, width: 2560, height: 707.5))
        XCTAssertEqual(Workspace.unitRect(for: f, in: acer.visibleFrame), UnitRect(x: 0, y: 0, w: 1, h: 0.5))
    }

    func testUnitRectClampsWindowsHangingOffScreen() {
        let r = Workspace.unitRect(for: CGRect(x: 1400, y: -100, width: 800, height: 600), in: acer.visibleFrame)
        XCTAssertGreaterThanOrEqual(r.x, 0); XCTAssertLessThanOrEqual(r.x + r.w, 1.0001)
        XCTAssertGreaterThanOrEqual(r.y, 0); XCTAssertLessThanOrEqual(r.y + r.h, 1.0001)
    }

    func testScreenIndexByLargestOverlap() {
        let ranked = Workspace.ranked([builtin, acer, tv])
        XCTAssertEqual(Workspace.screenIndex(for: CGRect(x: 1400, y: 100, width: 800, height: 600), in: ranked), 0) // mostly on the Acer
        XCTAssertEqual(Workspace.screenIndex(for: CGRect(x: -500, y: 100, width: 400, height: 300), in: ranked), 1)  // TV
        XCTAssertEqual(Workspace.screenIndex(for: CGRect(x: 100, y: 100, width: 400, height: 300), in: ranked), 2)   // built-in
    }

    func testRecommendationsByScreenCount() {
        XCTAssertEqual(Workspace.recommended(screenCount: 1, claudeAvailable: true).map(\.name), ["Focus"])
        XCTAssertEqual(Workspace.recommended(screenCount: 2, claudeAvailable: true).map(\.name), ["Code + Reference", "Study", "Focus"])
        XCTAssertEqual(Workspace.recommended(screenCount: 3, claudeAvailable: true).first?.name, "Command Center")
        let first = Workspace.recommended(screenCount: 2, claudeAvailable: true)[0]
        XCTAssertEqual(first.slots.first, WorkspaceSlot(content: .main(.practice), screen: 0, rect: .full))
        XCTAssertTrue(first.slots.contains { $0.content == .claude && $0.screen == 1 })
    }

    func testClaudeSlotsBecomeDocumentsWithoutClaude() {
        let l = Workspace.recommended(screenCount: 2, claudeAvailable: false)[0]
        XCTAssertFalse(l.slots.contains { $0.content == .claude })
        XCTAssertTrue(l.slots.contains { $0.content == .section(.documents) })
    }

    func testPlacementsFallBackToLastScreenAndCaptureRoundTrips() {
        let l = Workspace.recommended(screenCount: 3, claudeAvailable: true)[0]
        let two = Workspace.ranked([acer, builtin])
        let placed = Workspace.placements(for: l, on: two)
        XCTAssertEqual(placed.count, l.slots.count)
        XCTAssertTrue(placed.allSatisfy { p in two.contains { $0.visibleFrame.contains(CGPoint(x: p.frame.midX, y: p.frame.midY)) } })

        let three = Workspace.ranked([acer, builtin, tv])
        let back = Workspace.capture(name: "x", windows: Workspace.placements(for: l, on: three), screens: three)
        XCTAssertEqual(back.slots, l.slots)
    }

    func testStorePersistsLayoutsAndDismissals() {
        let d = UserDefaults(suiteName: "WorkspaceTests-\(UUID())")!
        let store = WorkspaceStore(defaults: d)
        let l = Workspace.recommended(screenCount: 2, claudeAvailable: true)[1]
        store.setLayout(l, for: "A|B")
        store.saveNamed(WorkspaceLayout(name: "Mine", slots: l.slots))
        store.dismiss("A|B|T")

        let again = WorkspaceStore(defaults: d)
        XCTAssertEqual(again.layout(for: "A|B"), l)
        XCTAssertEqual(again.named.map(\.name), ["Mine"])
        XCTAssertTrue(again.isDismissed("A|B|T"))
        again.deleteNamed("Mine")
        XCTAssertTrue(WorkspaceStore(defaults: d).named.isEmpty)
    }
}
