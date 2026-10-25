import AVFoundation
import CarPlay
import Foundation
import Testing
import UIKit
@testable import Gimano

// CarPlay regression tests that run without a head unit (docs/driving.md §5). They cover the decisions the car scene
// makes (CarPlayLogic.swift) and the shared drive it follows. They do NOT show that Apple granted the CarPlay
// entitlement or that a head unit shows the templates: that needs the approved profile and the CarPlay Simulator / a car.

/// 2 km east on Jalan Satu, left onto Jalan Dua for 1 km north, arriving at a mall whose main entrance is 25 m west
/// (on the left) of the road's end.
@MainActor
private enum CarFixture {
    static let start = LatLng(lat: 3.10, lng: 101.68)
    static let corner = Geo.offset(start, northM: 0, eastM: 2000)
    static let end = Geo.offset(corner, northM: 1000, eastM: 0)
    static let entrance = Geo.offset(end, northM: 0, eastM: -25)
    static let pin = Geo.offset(end, northM: 10, eastM: -70)

    static func route(id: String = "car-1", arrival: Bool = true) -> Route {
        let pts = TestGeometry.densify([start, corner, end], stepM: 50)
        let ci = TestGeometry.cornerIndices(corners: [start, corner, end], in: pts)[0]
        let m = [
            Maneuver(type: .depart, instruction: "Head east", streetName: "Jalan Satu", exitNumber: nil, roadRef: nil, distanceM: 2000,
                     durationS: 120, beginShapeIndex: 0, endShapeIndex: ci, verbalPre: nil, verbalPost: nil),
            Maneuver(type: .left, instruction: "Turn left", streetName: "Jalan Dua", exitNumber: nil, roadRef: nil, distanceM: 1000,
                     durationS: 60, beginShapeIndex: ci, endShapeIndex: pts.count - 1, verbalPre: nil, verbalPost: nil),
            Maneuver(type: .arrive, instruction: "Arrive", streetName: nil, exitNumber: nil, roadRef: nil, distanceM: 0, durationS: 0,
                     beginShapeIndex: pts.count - 1, endShapeIndex: pts.count - 1, verbalPre: nil, verbalPost: nil),
        ]
        let toll = Geo.offset(start, northM: 0, eastM: 1500)
        return Route(id: id, label: "best", durationS: 180, distanceM: 3000, trafficDurationS: nil, summary: "Via Jalan Satu",
                     trafficDescription: nil, vehicle: .car, hasTolls: true, tollEstimateMyr: 2.1, tollFareComplete: true,
                     tolls: [TollPlaza(plazaId: "t1", name: "Plaza Tol Satu", highway: nil, lat: toll.lat, lng: toll.lng, fareMyr: 2.1,
                                       system: "open", source: nil, distanceAlongRouteM: 1500)],
                     polyline: Polyline.encode(pts), bbox: [101.68, 3.10, 101.70, 3.11], legs: [RouteLeg(maneuvers: m)],
                     trafficSegments: [], alerts: [],
                     arrival: arrival ? NavigationPoint(lat: entrance.lat, lng: entrance.lng, issueId: nil, source: .osmEntrance, kind: "main") : nil)
    }

    static func session(_ r: Route = route(), voice: VoiceGuide? = nil) -> NavigationSession {
        let v = voice ?? { let v = VoiceGuide(); v.mode = .off; v.usesAudio = false; return v }()
        return NavigationSession(destination: Destination(name: "Mid Valley", address: "", location: pin, placeId: "w1"), route: r,
                                 vehicle: .car, avoid: AvoidOptions(), repo: DemoRepository(latency: .zero), voice: v)
    }

    static func fix(_ p: LatLng, kmh: Double = 60, course: Double = 90, at t: Date = .now) -> LocationFix {
        LocationFix(coordinate: p, speedKmh: kmh, course: course, accuracyM: 5, timestamp: t)
    }
}

@Suite("CarPlay: scene and map surface")
@MainActor
struct CarPlayTests {
    @Test("The app declares the CarPlay template scene")
    func sceneManifest() throws {
        let manifest = try #require(Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any])
        let configs = try #require(manifest["UISceneConfigurations"] as? [String: Any])
        let car = try #require(configs["CPTemplateApplicationSceneSessionRoleApplication"] as? [[String: Any]])
        #expect(car.first?["UISceneClassName"] as? String == "CPTemplateApplicationScene")
        #expect((car.first?["UISceneDelegateClassName"] as? String)?.hasSuffix(".CarPlaySceneDelegate") == true)
        #expect(NSClassFromString(car.first?["UISceneDelegateClassName"] as? String ?? "") != nil)
    }

    @Test("The car map mirrors what the phone map draws, but keeps its own camera and style")
    func mirror() {
        let phone = MapState(styleURL: URL(string: "https://example.invalid/dark.json")!)
        let car = MapState(styleURL: URL(string: "https://example.invalid/light.json")!)
        phone.routes = [RouteLine(id: "r", points: [LatLng(lat: 3.1, lng: 101.6), LatLng(lat: 3.2, lng: 101.7)], selected: true, traffic: [])]
        phone.tolls = [LatLng(lat: 3.15, lng: 101.65)]
        phone.lastMetres = LastMetres(blue: [LatLng(lat: 3.2, lng: 101.7), LatLng(lat: 3.2001, lng: 101.7)], grey: [])
        phone.restrictedAreas = [[LatLng(lat: 1, lng: 1), LatLng(lat: 1, lng: 2), LatLng(lat: 2, lng: 2)]]
        phone.navigationPuck = true
        phone.setCamera(.navigation)
        car.setCamera(.trackNorth(zoom: 15))
        var revision = -1
        car.mirror(from: phone, restrictedRevision: &revision)
        #expect(car.routes == phone.routes && car.tolls == phone.tolls && car.lastMetres == phone.lastMetres)
        #expect(car.restrictedAreas.count == 1 && revision == phone.restrictedRevision)
        #expect(car.navigationPuck)
        #expect(car.camera == .trackNorth(zoom: 15))
        #expect(car.styleURL.lastPathComponent == "light.json")
    }

    static let sizes: [(String, CGSize)] = [
        ("minimum", CGSize(width: 748, height: 456)), ("standard", CGSize(width: 800, height: 480)),
        ("720p", CGSize(width: 1280, height: 720)), ("wide", CGSize(width: 1920, height: 720)), ("portrait", CGSize(width: 768, height: 1024)),
    ]

    @Test("Display sizes: the arrow stays clear of the guidance panel and in the lower part of every car screen")
    func arrowOnEverySize() {
        for (name, size) in Self.sizes {
            let panel = CarMapLayout.guidanceWidth(screenWidth: size.width)
            #expect(panel <= 340 && panel >= size.width * 0.15, "\(name)")
            for mode in DriveCameraMode.allCases {
                let p = CarMapLayout.arrowPoint(size: size, puckY: mode.puckY)
                #expect(p.x > panel + 40 && p.x < size.width - 40, "\(name) \(mode)")
                #expect(p.y >= size.height * 0.55 && p.y <= size.height * 0.85, "\(name) \(mode)")
            }
        }
    }

    @Test("Day / night: the head unit's appearance picks the map style")
    func dayNight() {
        let light = URL(string: "https://example.invalid/light.json")!, dark = URL(string: "https://example.invalid/dark.json")!
        #expect(CarMapLayout.styleURL(carIsDark: true, light: light, dark: dark) == dark)
        #expect(CarMapLayout.styleURL(carIsDark: false, light: light, dark: dark) == light)
    }

    @Test("The map surface lays out on minimum, standard and wide screens with the © OSM line inside")
    func surfaceLayout() throws {
        for (name, size) in Self.sizes {
            let vc = CarMapViewController(state: MapState(styleURL: URL(string: "https://example.invalid/light.json")!))
            vc.view.frame = CGRect(origin: .zero, size: size)
            vc.view.layoutIfNeeded()
            let label = try #require(vc.view.subviews.compactMap { $0 as? UILabel }.first, "\(name)")
            #expect(vc.view.bounds.contains(label.frame), "\(name)")
            #expect(label.text?.contains("OpenStreetMap") == true)
            vc.coordinator.stopDisplayLink()
        }
    }
}

@Suite("CarPlay: lifecycle, routing and guidance")
@MainActor
struct CarDriveTests {
    @Test("Connect mid-drive, disconnect, reconnect: the drive goes on on the phone and the car restores the maneuver")
    func reconnect() {
        let nav = CarFixture.session()
        defer { nav.stop() }
        nav.handle(CarFixture.fix(Geo.offset(CarFixture.start, northM: 0, eastM: 300)))
        var car = CarDriveSync()
        #expect(car.update(CarNavSnapshot(nav)) == [.startSession, .showManeuvers, .updateEstimates])
        #expect(car.update(CarNavSnapshot(nav)) == [.updateEstimates])
        var alerts: [CarAlertSpec] = []
        CarPlayController.attachHooks(to: nav) { alerts.append($0) }

        // The car disconnects; the phone keeps driving past the turn.
        CarPlayController.detachHooks(from: nav)
        #expect(nav.onTollAhead == nil && nav.motion.onTinjau == nil)
        nav.handle(CarFixture.fix(Geo.offset(CarFixture.start, northM: 0, eastM: 1900), at: .now.addingTimeInterval(60)))
        nav.handle(CarFixture.fix(Geo.offset(CarFixture.corner, northM: 300, eastM: 0), course: 0, at: .now.addingTimeInterval(90)))
        #expect(!nav.isStopped && nav.progress?.upcomingIndex == 2)
        #expect(alerts.isEmpty)

        // A new car scene picks the drive up again at the current maneuver.
        var again = CarDriveSync()
        #expect(again.update(CarNavSnapshot(nav)) == [.startSession, .showManeuvers, .updateEstimates])
        let shown = CarPlayController.maneuvers(for: nav)
        #expect(shown.first?.instructionVariants.first == "Main entrance on your left")
    }

    @Test("Maneuver updates replace the guidance panel; the next maneuver shows its road")
    func maneuverUpdates() {
        let nav = CarFixture.session()
        defer { nav.stop() }
        var car = CarDriveSync()
        nav.handle(CarFixture.fix(Geo.offset(CarFixture.start, northM: 0, eastM: 300)))
        _ = car.update(CarNavSnapshot(nav))
        #expect(CarPlayController.maneuvers(for: nav).first?.instructionVariants.first == "Jalan Dua")
        nav.handle(CarFixture.fix(Geo.offset(CarFixture.start, northM: 0, eastM: 600), at: .now.addingTimeInterval(20)))
        #expect(car.update(CarNavSnapshot(nav)) == [.updateEstimates])
        nav.handle(CarFixture.fix(Geo.offset(CarFixture.corner, northM: 200, eastM: 0), course: 0, at: .now.addingTimeInterval(120)))
        #expect(car.update(CarNavSnapshot(nav)) == [.showManeuvers, .updateEstimates])
    }

    @Test("Off-route: recalculating pauses the car's trip; the new route resumes it with new maneuvers")
    func reroute() {
        let nav = CarFixture.session()
        defer { nav.stop() }
        var car = CarDriveSync()
        nav.handle(CarFixture.fix(Geo.offset(CarFixture.start, northM: 0, eastM: 300)))
        _ = car.update(CarNavSnapshot(nav))
        nav.reroute(from: CarFixture.fix(Geo.offset(CarFixture.start, northM: 200, eastM: 300)))
        #expect(nav.isRerouting)
        #expect(car.update(CarNavSnapshot(nav)) == [.pause])
        #expect(car.update(CarNavSnapshot(nav)) == [])
        let snap = CarNavSnapshot(sessionID: ObjectIdentifier(nav), routeId: "car-2", upcomingIndex: 1, thenIndex: nil, isRerouting: false,
                                  arrived: false, arrivalText: nil, approachingAlertId: nil, alongM: 0)
        #expect(car.update(snap) == [.showManeuvers, .updateEstimates])
        // setRoute (what a reroute ends with) keeps the drive and gives the car the new route's maneuvers.
        let nav2 = CarFixture.session()
        defer { nav2.stop() }
        var car2 = CarDriveSync()
        nav2.handle(CarFixture.fix(Geo.offset(CarFixture.start, northM: 0, eastM: 300)))
        _ = car2.update(CarNavSnapshot(nav2))
        nav2.setRoute(CarFixture.route(id: "car-3"))
        #expect(CarNavSnapshot(nav2).routeId == "car-3")
        #expect(car2.update(CarNavSnapshot(nav2)) == [.showManeuvers, .updateEstimates])
    }

    @Test("Stop from the car or from the phone: the car's trip is cancelled once and its hooks removed")
    func stop() {
        for _ in ["car", "phone"] {
            let nav = CarFixture.session()
            var car = CarDriveSync()
            nav.handle(CarFixture.fix(Geo.offset(CarFixture.start, northM: 0, eastM: 300)))
            _ = car.update(CarNavSnapshot(nav))
            nav.stop()   // "End" in the car calls model.stopNavigation(), the same as Stop on the phone
            #expect(car.update(nil) == [.cancelSession])
            #expect(car.update(nil) == [])
            #expect(!car.hasSession)
        }
    }

    @Test("Arrival: the final step names the entrance side, then the trip finishes with an alert that dismisses itself")
    func arrival() {
        let nav = CarFixture.session()
        defer { nav.stop() }
        var car = CarDriveSync()
        nav.handle(CarFixture.fix(Geo.offset(CarFixture.corner, northM: 500, eastM: 0), course: 0))
        _ = car.update(CarNavSnapshot(nav))
        #expect(CarPlayController.maneuvers(for: nav).first?.instructionVariants.first == "Main entrance on your left")
        nav.handle(CarFixture.fix(Geo.offset(CarFixture.corner, northM: 985, eastM: 0), kmh: 10, course: 0, at: .now.addingTimeInterval(60)))
        #expect(nav.arrived)
        #expect(car.update(CarNavSnapshot(nav)) == [.finishAndShowArrival])
        #expect(car.update(CarNavSnapshot(nav)) == [])
        let spec = CarAlertSpec.arrived(text: nav.arrivalInfo?.text ?? "")
        #expect(spec.subtitle == "Main entrance on your left · 25 m from the road")
        #expect(spec.seconds > 0)
        #expect(car.update(nil) == [.dismissArrival])
    }

    @Test("\"Still there?\" in the car at most once per alert and once per 2 km")
    func stillThereSpacing() {
        var car = CarDriveSync()
        let id = ObjectIdentifier(NSObject.self)
        func snap(_ alert: String?, _ along: Double) -> CarNavSnapshot {
            CarNavSnapshot(sessionID: id, routeId: "r", upcomingIndex: 1, thenIndex: nil, isRerouting: false, arrived: false,
                           arrivalText: nil, approachingAlertId: alert, alongM: along)
        }
        #expect(car.update(snap("a", 100)).contains(.stillThere("a")))
        #expect(!car.update(snap("a", 150)).contains(.stillThere("a")))
        #expect(!car.update(snap("b", 1500)).contains(.stillThere("b")))
        #expect(car.update(snap("c", 2200)).contains(.stillThere("c")))
    }
}

@Suite("CarPlay: one voice")
@MainActor
struct CarAudioTests {
    @Test("With the car connected a toll is said once (phone voice) and only shown in the car")
    func noDoublePrompts() {
        let voice = VoiceGuide()
        voice.usesAudio = false
        voice.mode = .on
        var said: [String] = []
        voice.onSpeak = { text, _ in said.append(text) }
        let nav = CarFixture.session(voice: voice)
        defer { nav.stop() }
        var shown: [CarAlertSpec] = []
        CarPlayController.attachHooks(to: nav) { shown.append($0) }
        var car = CarDriveSync()
        nav.handle(CarFixture.fix(Geo.offset(CarFixture.start, northM: 0, eastM: 200), kmh: 90))
        _ = car.update(CarNavSnapshot(nav))
        said.removeAll()
        for (k, e) in [600.0, 700, 800].enumerated() {
            nav.handle(CarFixture.fix(Geo.offset(CarFixture.start, northM: 0, eastM: e), kmh: 90, at: .now.addingTimeInterval(Double(k + 1) * 5)))
            _ = car.update(CarNavSnapshot(nav))
        }
        #expect(said.filter { $0.contains("toll") }.count == 1)
        #expect(shown.count == 1 && shown.first?.title == "Satu toll")
    }

    @Test("Ducking: a voice-prompt session that ducks other audio and is released after each prompt")
    func ducking() {
        #expect(VoiceGuide.category == .playback)
        #expect(VoiceGuide.audioMode == .voicePrompt)
        #expect(VoiceGuide.options.contains(.duckOthers))
        #expect(VoiceGuide.options.contains(.interruptSpokenAudioAndMixWithOthers))
    }

    @Test("A phone call silences prompts; missed prompts are not replayed; prompts resume after the call")
    func interruptions() {
        let voice = VoiceGuide()
        voice.usesAudio = false
        var said: [String] = []
        voice.onSpeak = { text, _ in said.append(text) }
        voice.handleInterruption(began: true)
        voice.speak("Turn left", kind: .guidance)
        voice.speak("Toll ahead", kind: .alert)
        #expect(said.isEmpty)
        voice.handleInterruption(began: false)
        #expect(said.isEmpty)
        voice.speak("Turn right")
        #expect(said == ["Turn right"])
        #expect(!VoiceGuide.shouldSpeak(mode: .alertsOnly, kind: .guidance, interrupted: false))
        #expect(VoiceGuide.shouldSpeak(mode: .alertsOnly, kind: .alert, interrupted: false))
        #expect(!VoiceGuide.shouldSpeak(mode: .off, kind: .alert, interrupted: false))
    }
}

@Suite("CarPlay: distraction-safe controls")
@MainActor
struct CarControlsTests {
    @Test("Lists respect CarPlay's item and section limits and ours (12)")
    func listLimits() {
        let sections = [Array(1...3), [], Array(10...19), Array(20...30)]
        let clamped = CarListLimits.clamp(sections, maxItems: 6, maxSections: 10)
        #expect(clamped.flatMap { $0 } == [1, 2, 3, 10, 11, 12])
        #expect(CarListLimits.clamp(sections, maxItems: 100, maxSections: 2).count == 2)
        #expect(CarListLimits.clamp(sections, maxItems: 100, maxSections: 10).flatMap { $0 }.count == 12)
        #expect(CarListLimits.clamp([[Int]](), maxItems: 6, maxSections: 2).isEmpty)
    }

    @Test("No keyboard while driving")
    func keyboard() {
        #expect(CarInputPolicy.allowsKeyboard(speedKmh: 0))
        #expect(CarInputPolicy.allowsKeyboard(speedKmh: 4.9))
        #expect(!CarInputPolicy.allowsKeyboard(speedKmh: 5))
        #expect(!CarInputPolicy.allowsKeyboard(speedKmh: 60))
    }

    @Test("Every car alert dismisses itself within 10 s; only Still there? has two buttons")
    func alertsAutoDismiss() {
        let r = CarFixture.route()
        let toll = TollTracker.place(r.tolls!, on: RouteGeometry(route: r))[0]
        let all: [CarAlertSpec] = [.toll(toll, distanceM: 900), .tinjau("Traffic 4.8 km ahead"), .stillThere(type: .police, distanceM: 400),
                                   .reminder, .restricted, .reportSent, .arrived(text: "Main entrance on your left · 25 m from the road")]
        for a in all {
            #expect(a.seconds > 0 && a.seconds <= 10, "\(a.title)")
            #expect(!a.title.isEmpty)
        }
        #expect(all.filter { $0.secondary != nil }.count == 1)
        #expect(CarAlertSpec.toll(toll, distanceM: 900).subtitle == "900 m · RM 2.10")
        #expect(CarAlertSpec.restricted.seconds == 3)
        #expect(CarAlertSpec.reminder.seconds == 5)
    }

    @Test("Templates stay within CarPlay's depth limit; the report grid has ≤ 8 one-tap buttons")
    func depth() {
        // Map (1) → Where to? (2) → Search (3) is the deepest flow.
        #expect(!CarTemplateStack.mustPopToRoot(beforePushingOnto: 2))
        #expect(!CarTemplateStack.mustPopToRoot(beforePushingOnto: 4))
        #expect(CarTemplateStack.mustPopToRoot(beforePushingOnto: 5))
        #expect(CarPlayController.reportTypes.count <= 8)
        #expect(Set(CarPlayController.reportTypes).count == CarPlayController.reportTypes.count)
    }

    @Test("Trip previews label tolls")
    func tollLabels() {
        #expect(CarPlayController.tollText(.none) == "No tolls")
        #expect(CarPlayController.tollText(.complete(2.1)) == "Tolls RM 2.10")
        #expect(CarPlayController.tollText(.from(4)) == "Tolls from RM 4.00")
    }
}

@Suite("CarPlay: privacy")
@MainActor
struct CarPrivacyTests {
    @Test("Where to? lists only on-device saved places and recents; private and pin ids never reach a route request")
    func destinations() {
        let saved = [
            SavedPlace(id: "1", kind: .work, name: "Office", lat: 3.1, lng: 101.6, address: "KL", placeId: "w9"),
            SavedPlace(id: "2", kind: .home, name: "Rumah", lat: 3.0, lng: 101.5, address: "PJ"),
            SavedPlace(id: "3", kind: .favorite, name: "Secret spot", lat: 3.2, lng: 101.7, address: "", placeId: "private:abc"),
            SavedPlace(id: "4", kind: .favorite, name: "Kampung", lat: 3.3, lng: 101.8, address: "", placeId: "pin:3.3,101.8"),
        ]
        let recents = (0..<12).map { Recent(id: "r\($0)", name: "Recent \($0)", address: "", lat: 3, lng: 101, placeId: $0 == 0 ? "private:x" : "n\($0)") }
        let groups = CarDestination.make(saved: saved, recents: recents)
        #expect(groups.first?.map(\.kind) == [.home, .work])
        let all = groups.flatMap { $0 }
        #expect(!all.contains { $0.title == "Secret spot" })
        #expect(!all.contains { $0.destination.placeId?.hasPrefix("private:") == true || $0.destination.placeId?.hasPrefix("pin:") == true })
        #expect(all.filter { $0.kind == .recent }.count <= 8)
        #expect(all.contains { $0.title == "Kampung" && $0.destination.placeId == nil })
    }

    @Test("The car scene's code sends nothing but a search query, a public report and the phone's own route requests")
    func carCodeCallsNoUploads() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Gimano/CarPlay")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count >= 4)
        for f in files {
            let src = try String(contentsOf: f, encoding: .utf8)
            for call in src.components(separatedBy: "repo.").dropFirst() {
                #expect(call.hasPrefix("search("), "\(f.lastPathComponent): repo.\(call.prefix(30))")
            }
            for forbidden in ["privatePlaces", "plannedDrives", "store.", "backup", "upload", "sendLocations", "URLSession"] {
                #expect(!src.contains(forbidden), "\(f.lastPathComponent) mentions \(forbidden)")
            }
        }
    }
}
