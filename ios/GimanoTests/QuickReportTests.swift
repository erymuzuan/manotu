import CoreGraphics
import Foundation
import Testing
@testable import Gimano

/// docs/driving.md §6.4 (boards RpDrawer / RpHold / RpDetail / RpSent) and §6.1 (live alerts ahead).
@Suite("Reporting while driving")
struct QuickReportTests {
    @Test("5 bubbles on one arc: Hazard, Police, Crash, Traffic, Closed; the rest are drawer-only")
    func layout() {
        #expect(QuickReportFan.items.map(\.type) == [.hazard, .police, .accident, .traffic, .closure])
        for t in [ReportType.blockedLane, .weather, .animal, .mapIssue] {
            #expect(!QuickReportFan.items.contains { $0.type == t }, "\(t) is in the drawer only")
        }
        #expect(QuickReportFan.holdS == 0.3)
        #expect(QuickReportFan.items.allSatisfy { $0.radius == QuickReportFan.arcRadius })
    }

    @Test("Geometry: arc of 170 pt fanning up and to the left of the button, no overlaps")
    func geometry() {
        let hazard = QuickReportFan.items[0].offset
        #expect(abs(hazard.dx) < 0.01 && abs(hazard.dy + 170) < 0.01)            // straight up
        let closure = QuickReportFan.items[4].offset
        #expect(abs(closure.dx + 170) < 0.01 && abs(closure.dy) < 0.01)          // straight left
        let crash = QuickReportFan.items[2].offset
        #expect(abs(crash.dx + 120.2) < 0.1 && abs(crash.dy + 120.2) < 0.1)
        for i in QuickReportFan.items {
            #expect(i.offset.dx <= 0.01 && i.offset.dy <= 0.01, "never below or right of the button")
        }
        for (a, b) in zip(QuickReportFan.items, QuickReportFan.items.dropFirst()) {
            #expect(hypot(a.offset.dx - b.offset.dx, a.offset.dy - b.offset.dy) > a.diameter)
        }
    }

    @Test("Hit-testing: on a bubble selects it, on the button or inside / outside the arc selects nothing")
    func hit() {
        for i in QuickReportFan.items {
            #expect(QuickReportFan.hit(i.offset) == i.type)
        }
        #expect(QuickReportFan.hit(.zero) == nil)                                  // still on the button
        #expect(QuickReportFan.hit(CGVector(dx: -20, dy: -30)) == nil)
        #expect(QuickReportFan.hit(CGVector(dx: 0, dy: -110)) == nil)              // inside the arc
        #expect(QuickReportFan.hit(CGVector(dx: -400, dy: -400)) == nil)           // far away
        #expect(QuickReportFan.hit(CGVector(dx: 60, dy: 60)) == nil)               // below / right
    }

    @Test("Detail sheet defaults: heavy for Traffic, the first option otherwise; Map issue never auto-sends; 3 s")
    func defaults() {
        #expect(ReportDefaults.defaultSubtype(.traffic) == "heavy")
        #expect(ReportDefaults.defaultSubtype(.police) == "visible")
        #expect(ReportDefaults.defaultSubtype(.accident) == "minor")
        #expect(ReportDefaults.defaultSubtype(.hazard) == "object_on_road")
        #expect(ReportDefaults.defaultSubtype(.closure) == nil)
        #expect(ReportDefaults.autoSends(.accident) && !ReportDefaults.autoSends(.mapIssue))
        #expect(ReportDefaults.autoSendS == 3)
    }

    @Test("The report carries the picked subtype and comment at the current position")
    func newReport() {
        let r = QuickReportFan.newReport(.police, subtype: "hidden", at: LatLng(lat: 3.1, lng: 101.6), heading: 90)
        #expect(r.type == .police && r.subtype == "hidden" && r.lat == 3.1 && r.lng == 101.6 && r.heading == 90 && r.comment == nil)
    }

    @Test("Each action has its own colour")
    func colours() {
        let c = QuickReportFan.items.map { QuickReportFan.colors($0.type).fill }
        #expect(Set(c).count == 5)
        #expect(QuickReportFan.colors(.hazard).fill == 0xF2B01E)
    }

    // A straight road heading due north, ~2.2 km.
    let road = [LatLng(lat: 3.0, lng: 101.0), LatLng(lat: 3.01, lng: 101.0), LatLng(lat: 3.02, lng: 101.0)]

    private func report(_ id: String, lat: Double, lng: Double = 101.0, subtype: String? = nil, heading: Double? = nil) -> Report {
        Report(id: id, type: .accident, subtype: subtype, lat: lat, lng: lng, heading: heading, street: nil, reportedBy: nil,
               createdAt: .now, expiresAt: .now.addingTimeInterval(3600), confirmations: 0, thanks: 0)
    }

    @Test("A crash reported after the route was calculated joins the trip with its along-route distance")
    func liveAlertJoinsTrip() {
        let m = LiveAlertMatcher.match(points: road, reports: [report("a", lat: 3.009, heading: 5)])
        #expect(m.count == 1)
        #expect(abs((m.first?.distanceAlongRouteM ?? 0) - 1000) < 15)
    }

    @Test("Other side, opposite heading and off-road reports are left out")
    func liveAlertFilters() {
        let m = LiveAlertMatcher.match(points: road, reports: [
            report("side", lat: 3.009, subtype: "other_side"),
            report("opposite", lat: 3.009, heading: 185),
            report("far", lat: 3.009, lng: 101.01),
            report("noHeading", lat: 3.012),
        ])
        #expect(m.map(\.id) == ["noHeading"])
    }

    @Test("The question is asked from 150 m before to 100 m after the spot")
    func askWindow() {
        #expect(!LiveAlertMatcher.asks(400) && !LiveAlertMatcher.asks(151))
        #expect(LiveAlertMatcher.asks(150) && LiveAlertMatcher.asks(0) && LiveAlertMatcher.asks(-100))
        #expect(!LiveAlertMatcher.asks(-101))
    }

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Undo window: 5 s ring, then the card closes")
    func window() {
        let q = QuickReportUndo(type: .hazard, position: LatLng(lat: 3.1, lng: 101.6), startedAt: t0)
        #expect(q.remaining(at: t0) == 5)
        #expect(q.remaining(at: t0.addingTimeInterval(1.2)) == 4)
        #expect(q.progress(at: t0.addingTimeInterval(2.5)) == 0.5)
        #expect(q.isOpen(at: t0.addingTimeInterval(4.9)))
        #expect(!q.isOpen(at: t0.addingTimeInterval(5)))
        #expect(q.remaining(at: t0.addingTimeInterval(9)) == 0)
    }

    @Test("Undo after the POST came back deletes it on the server")
    func undoSent() {
        var q = QuickReportUndo(type: .hazard, position: LatLng(lat: 3.1, lng: 101.6), startedAt: t0)
        #expect(q.sent(id: "r1") == .none)
        #expect(q.reportId == "r1")
        #expect(q.undo(at: t0.addingTimeInterval(3)) == .delete(id: "r1"))
        #expect(q.isUndone && !q.isOpen(at: t0.addingTimeInterval(3)))
        #expect(q.undo(at: t0.addingTimeInterval(3.5)) == .none, "only once")
    }

    @Test("Undo while sending cancels it, and withdraws it if the POST still comes back")
    func undoSending() {
        var q = QuickReportUndo(type: .police, position: LatLng(lat: 3.1, lng: 101.6), startedAt: t0)
        #expect(q.undo(at: t0.addingTimeInterval(1)) == .cancelSend)
        #expect(q.sent(id: "r2") == .delete(id: "r2"))
        #expect(q.sent(id: "r2") == .none)
    }

    @Test("Too late, or a failed send: nothing to undo")
    func undoLate() {
        var q = QuickReportUndo(type: .police, position: LatLng(lat: 3.1, lng: 101.6), startedAt: t0)
        _ = q.sent(id: "r3")
        #expect(q.undo(at: t0.addingTimeInterval(5.1)) == .none)
        var f = QuickReportUndo(type: .police, position: LatLng(lat: 3.1, lng: 101.6), startedAt: t0)
        f.failed()
        #expect(!f.isOpen(at: t0) && f.undo(at: t0) == .none)
    }

    @Test("Undo is a signed DELETE /reports/{id}")
    func signed() {
        #expect(SignedEndpoints.requiresSignature(method: "DELETE", path: "reports/r1"))
        #expect(!SignedEndpoints.requiresSignature(method: "DELETE", path: "reports"))
    }

    @Test("The demo store withdraws a report too")
    func demoDelete() async throws {
        let demo = DemoRepository()
        let r = try await demo.createReport(QuickReportFan.newReport(.hazard, subtype: "pothole", at: LatLng(lat: 3.15, lng: 101.7), heading: nil))
        try await demo.deleteReport(id: r.id)
        await #expect(throws: APIError.self) { try await demo.deleteReport(id: r.id) }
    }
}
