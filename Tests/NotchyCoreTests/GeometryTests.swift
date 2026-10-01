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

    func testSpringSettles() {
        let s = SpringCurve(response: 0.42, dampingFraction: 0.8)
        XCTAssertEqual(s.value(at: 0), 0)
        XCTAssertGreaterThan(s.value(at: 0.35), 1, "underdamped spring overshoots")
        XCTAssertEqual(s.value(at: 2), 1, accuracy: 0.001)
        XCTAssertLessThan(s.settlingTime, 1)
    }
}
