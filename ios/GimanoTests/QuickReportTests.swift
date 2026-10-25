import CoreGraphics
import Foundation
import Testing
@testable import Gimano

/// docs/driving.md §6.4 (boards NavLaporTahan / NavLaporPilih / NavLaporHantar).
@Suite("Hold-to-report")
struct QuickReportTests {
    @Test("8 actions: Hazard, Police, Accident inside; Traffic, Closure, Blocked lane, Weather, Animal outside; no Map issue")
    func layout() {
        let inner = QuickReportFan.items.filter { $0.ring == 0 }.map(\.type)
        let outer = QuickReportFan.items.filter { $0.ring == 1 }.map(\.type)
        #expect(inner == [.hazard, .police, .accident])
        #expect(outer == [.traffic, .closure, .blockedLane, .weather, .animal])
        #expect(!QuickReportFan.items.contains { $0.type == .mapIssue })
        #expect(QuickReportFan.holdS == 0.3)
    }

    @Test("Geometry matches the board: inner ring 122 pt, outer 228 pt, fanning up and to the left of the button")
    func geometry() {
        let hazard = QuickReportFan.items[0].offset
        #expect(abs(hazard.dx) < 0.01 && abs(hazard.dy + 122) < 0.01)            // straight up
        let accident = QuickReportFan.items[2].offset
        #expect(abs(accident.dx + 122) < 0.01 && abs(accident.dy) < 0.01)        // straight left
        let police = QuickReportFan.items[1].offset                               // board: (-86, -86)
        #expect(abs(police.dx + 86) < 1 && abs(police.dy + 86) < 1)
        let closure = QuickReportFan.items[4].offset                              // board: (-87, -211)
        #expect(abs(closure.dx + 87) < 1.5 && abs(closure.dy + 211) < 1.5)
        for i in QuickReportFan.items {
            #expect(i.offset.dx <= 0.01 && i.offset.dy <= 0.01, "never below or right of the button")
        }
        // Bubbles in the same ring don't overlap.
        for ring in 0...1 {
            let r = QuickReportFan.items.filter { $0.ring == ring }
            for (a, b) in zip(r, r.dropFirst()) {
                #expect(hypot(a.offset.dx - b.offset.dx, a.offset.dy - b.offset.dy) > a.diameter)
            }
        }
    }

    @Test("Hit-testing: on a bubble selects it, on the button or outside the fan selects nothing")
    func hit() {
        for i in QuickReportFan.items {
            #expect(QuickReportFan.hit(i.offset) == i.type)
            #expect(QuickReportFan.hit(CGVector(dx: i.offset.dx + 20, dy: i.offset.dy - 20)) == i.type, "generous target")
        }
        #expect(QuickReportFan.hit(.zero) == nil)                                  // still on the button
        #expect(QuickReportFan.hit(CGVector(dx: -20, dy: -30)) == nil)
        #expect(QuickReportFan.hit(CGVector(dx: 0, dy: -175)) == nil)              // between the rings
        #expect(QuickReportFan.hit(CGVector(dx: -400, dy: -400)) == nil)           // far away
        #expect(QuickReportFan.hit(CGVector(dx: 60, dy: 60)) == nil)               // below / right
    }

    @Test("Sent at once at the current position with no subtype")
    func newReport() {
        let r = QuickReportFan.newReport(.police, at: LatLng(lat: 3.1, lng: 101.6), heading: 90)
        #expect(r.type == .police && r.subtype == nil && r.lat == 3.1 && r.lng == 101.6 && r.heading == 90 && r.comment == nil)
    }

    @Test("Each action has its own colour")
    func colours() {
        let c = QuickReportFan.items.map { QuickReportFan.colors($0.type).fill }
        #expect(Set(c).count == 8)
        #expect(QuickReportFan.colors(.hazard).fill == 0xF2B01E)
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
        let r = try await demo.createReport(QuickReportFan.newReport(.hazard, at: LatLng(lat: 3.15, lng: 101.7), heading: nil))
        try await demo.deleteReport(id: r.id)
        await #expect(throws: APIError.self) { try await demo.deleteReport(id: r.id) }
    }
}
