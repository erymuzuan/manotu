import Foundation
import Testing
@testable import Gimano

@Suite("CarPlay")
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

    @Test("The car map mirrors what the phone map draws, but keeps its own camera")
    func mirror() {
        let phone = MapState(styleURL: URL(string: "https://example.invalid/style.json")!)
        let car = MapState(styleURL: phone.styleURL)
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
    }
}
