import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NotchyCore

final class GeometryTests: XCTestCase {
    // 14" MacBook Pro: 1512x982 points, 32 pt notch, 185 pt wide.
    let mbp = NotchMetrics(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                           safeAreaTop: 32, auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5, menuBarHeight: 32)

    func testNotchFromAuxiliaryAreas() {
        XCTAssertTrue(mbp.hasNotch)
        XCTAssertEqual(mbp.notchRect, CGRect(x: 663.5, y: 950, width: 185, height: 32))
        // Idle is exactly the notch, so it is invisible.
        XCTAssertEqual(mbp.idle().size, mbp.notchSize)
        XCTAssertEqual(mbp.islandRect(mbp.idle()), mbp.notchRect)
    }

    func testNoNotchGetsSyntheticPillCentredOnScreen() {
        let ext = NotchMetrics(screenFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
                               safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 25)
        XCTAssertFalse(ext.hasNotch)
        XCTAssertEqual(ext.notchRect.midX, ext.screenFrame.midX)
        XCTAssertEqual(ext.notchRect.maxY, ext.screenFrame.maxY)
        XCTAssertEqual(ext.idle(hidden: true).size.height, 0)
        // A hidden island can still be summoned from the notch area.
        XCTAssertTrue(ext.hitRect(ext.idle(hidden: true)).contains(CGPoint(x: ext.screenFrame.midX, y: ext.screenFrame.maxY - 5)))
    }

    func testStatesAreCentredOnTheNotchAndFlushWithTheTop() {
        for g in [mbp.idle(), mbp.compact(wing: 44), mbp.expanded(), mbp.bumped(mbp.compact(wing: 44))] {
            let r = mbp.islandRect(g)
            XCTAssertEqual(r.midX, mbp.notchRect.midX, accuracy: 0.001)
            XCTAssertEqual(r.maxY, mbp.screenFrame.maxY, accuracy: 0.001)
        }
        XCTAssertEqual(mbp.compact(wing: 44).size.width, 185 + 88)
        XCTAssertEqual(mbp.expanded().size.width, 485)
    }

    func testFixedPanelHoldsTheLargestStateWithShadowRoom() {
        let panel = mbp.panelFrame
        let expanded = mbp.islandRect(mbp.expanded()).insetBy(dx: -mbp.expanded().earRadius, dy: 0)
        XCTAssertTrue(panel.contains(expanded))
        XCTAssertEqual(panel.maxY, mbp.screenFrame.maxY)
        XCTAssertGreaterThanOrEqual(expanded.minY - panel.minY, NotchMetrics.shadowMargin - 1)
    }

    func testHitRectGraceIsOptIn() {
        let g = mbp.compact(wing: 44)
        let body = mbp.islandRect(g)
        let justOutside = CGPoint(x: body.maxX + 6, y: body.midY)
        XCTAssertFalse(mbp.hitRect(g).contains(justOutside), "menu bar items next to the notch must stay clickable")
        XCTAssertTrue(mbp.hitRect(g, grace: NotchMetrics.hoverGrace).contains(justOutside))
    }

    func testOneSidedWingsKeepTheNotchCovered() {
        let g = mbp.compact(left: 0, right: 70)
        let body = mbp.islandRect(g)
        XCTAssertEqual(body.minX, mbp.notchRect.minX, accuracy: 0.01, "the left edge stays on the notch")
        XCTAssertEqual(body.maxX, mbp.notchRect.maxX + 70, accuracy: 0.01)
        XCTAssertEqual(mbp.compact(left: 44, right: 44), mbp.compact(wing: 44))
        XCTAssertEqual(mbp.compact(wing: 44).offsetX, 0)
        // The lip stays within the notch's width.
        let lip = mbp.islandRect(mbp.folded())
        XCTAssertEqual(lip.minX, mbp.notchRect.minX, accuracy: 0.01)
        XCTAssertEqual(lip.width, mbp.notchRect.width, accuracy: 0.01)
        XCTAssertEqual(lip.height, mbp.notchRect.height + NotchMetrics.lipHeight, accuracy: 0.01)
    }

    func testWingsFitTheFreeMenuBar() {
        func fit(_ l: CGFloat?, _ r: CGFloat) -> WingFit {
            WingFit.fit(wing: 45, minWing: 35, single: 70, clearance: MenuBarClearance(left: l, right: r))
        }
        // Plenty of room: the usual look.
        XCTAssertEqual(fit(300, 300), WingFit(arrangement: .split, left: 45, right: 45))
        // Tight on one side: both wings shrink together so the island stays centred.
        XCTAssertEqual(fit(300, 46), WingFit(arrangement: .split, left: 40, right: 40))
        // App menus reach the notch (the screenshot case): everything moves right.
        XCTAssertEqual(fit(12, 120), WingFit(arrangement: .right, left: 0, right: 70))
        // The left can't be seen (no Accessibility): treated as taken, never covered.
        XCTAssertEqual(fit(nil, 120), WingFit(arrangement: .right, left: 0, right: 70))
        // Icons reach the notch on the right, room on the left.
        XCTAssertEqual(fit(200, 20), WingFit(arrangement: .left, left: 70, right: 0))
        // No room anywhere: fold into the lip.
        XCTAssertEqual(fit(nil, 30), WingFit(arrangement: .folded, left: 0, right: 0))
        XCTAssertEqual(fit(20, 30).arrangement, .folded)
        // No notch: an icon under the fake notch's spot. Nothing may be drawn over it.
        XCTAssertEqual(fit(120, -4).arrangement, .hidden)
        XCTAssertEqual(fit(-10, 120).arrangement, .hidden)
        // Feature off / not measured.
        XCTAssertEqual(WingFit.fit(wing: 45, minWing: 35, single: 70, clearance: .unlimited).arrangement, .split)
    }

    func testFittedIslandNeverReachesTheMeasuredItems() {
        let menusEnd = mbp.notchRect.minX - 60          // last app menu ends 60 pt before the notch
        let firstIcon = mbp.notchRect.maxX + 50         // first menu bar icon 50 pt after it
        let f = WingFit.fit(wing: 45, minWing: 35, single: 70,
                            clearance: MenuBarClearance(left: mbp.notchRect.minX - menusEnd, right: firstIcon - mbp.notchRect.maxX))
        XCTAssertEqual(f.arrangement, .split)
        let body = mbp.islandRect(mbp.compact(left: f.left, right: f.right))
        XCTAssertGreaterThanOrEqual(body.minX, menusEnd)
        XCTAssertLessThanOrEqual(body.maxX, firstIcon - WingFit.gap)
    }

    func testSpringSettles() {
        let s = SpringCurve(response: 0.42, dampingFraction: 0.8)
        XCTAssertEqual(s.value(at: 0), 0)
        XCTAssertGreaterThan(s.value(at: 0.35), 1, "underdamped spring overshoots")
        XCTAssertEqual(s.value(at: 2), 1, accuracy: 0.001)
        XCTAssertLessThan(s.settlingTime, 1)
    }
}
