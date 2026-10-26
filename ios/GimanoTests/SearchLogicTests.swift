import Foundation
import Testing
@testable import Gimano

@Suite("Finding places: result logic")
struct SearchLogicTests {
    @Test("Map scope follows the rotated footprint, including its edge")
    func viewport() {
        let area = "101,3;102,4;101,5;100,4"
        #expect(SearchArea.contains(area, .init(lat: 4, lng: 101)))
        #expect(SearchArea.contains(area, .init(lat: 3.5, lng: 101.5)))
        #expect(!SearchArea.contains(area, .init(lat: 3.1, lng: 101.9)))
        #expect(!SearchArea.contains("bad", .init(lat: 4, lng: 101)))
    }

    private func p(_ id: String, _ name: String, _ d: Double, brand: String? = nil, chain: String? = nil, open: Bool? = nil) -> PlaceSummary {
        PlaceSummary(id: id, name: name, category: .convenience, address: "", lat: 3.1, lng: 101.6, distanceM: d, brand: brand,
                     chainGroup: chain.map { ChainGroup(key: $0.lowercased(), name: $0, countNearby: 12) }, openNow: open)
    }

    @Test("Branches of a chain fold into one group, nearest first, where its best member ranked")
    func chains() {
        let r = [p("a", "FamilyMart", 2100, brand: "FamilyMart"), p("x", "Kedai Ali", 900),
                 p("b", "FamilyMart", 1400, chain: "FamilyMart"), p("c", "Familymart", 1600, brand: "familymart")]
        let best = SearchLogic.sections(r, sort: .bestMatch)
        #expect(best.count == 2)
        guard case .chain(let name, let places) = best[0] else { Issue.record("expected a chain first"); return }
        #expect(name == "FamilyMart" && places.map(\.id) == ["b", "c", "a"])
        #expect(best[1] == .place(r[1]))
        let near = SearchLogic.sections(r, sort: .nearest)
        #expect(near.first == .place(r[1]), "Kedai Ali (900 m) is nearest")
    }

    @Test("A single branch stays a plain row; Open now filters on openNow")
    func singleAndOpen() {
        let r = [p("a", "7-Eleven", 500, brand: "7-Eleven", open: true), p("b", "Kedai", 300, open: false), p("c", "X", 100)]
        #expect(SearchLogic.sections(r, sort: .bestMatch).count == 3)
        #expect(SearchLogic.sections(r, sort: .openNow) == [.place(r[0])])
        #expect(SearchLogic.knowsOpening(r) && !SearchLogic.knowsOpening([r[2]]))
    }

    @Test("Category hints in English and Malay")
    func hints() {
        #expect(SearchLogic.categoryHint(in: "kedai runcit pak ali") == .convenience)
        #expect(SearchLogic.categoryHint(in: "Stesen Minyak Jalan Kuching") == .fuel)
        #expect(SearchLogic.categoryHint(in: "warung mak cik") == .restaurant)
        #expect(SearchLogic.categoryHint(in: "Klinik Dr Tan") == .clinic)
        #expect(SearchLogic.categoryHint(in: "petronas") == nil)
        #expect(SearchLogic.categoryHint(in: "tolong") == nil, "whole words only")
    }

    @Test("Search response decodes the spelling fix, suggestions and chain fields; older servers still decode")
    func decode() throws {
        let new = #"{"results":[{"id":"n1","name":"FamilyMart","category":"convenience","address":"Jalan SS2/64","lat":3.1,"lng":101.6,"distanceM":1400,"brand":"FamilyMart","chainGroup":{"key":"familymart","name":"FamilyMart","countNearby":12},"openNow":true,"source":"osm","status":null,"rating":null,"reviewCount":0,"thumbnailUrl":null}],"correctedQuery":"FamilyMart","suggestions":[{"label":"Kedai runcit berdekatan","category":"convenience","count":6}]}"#
        let r = try JSON.makeDecoder().decode(SearchResponse.self, from: Data(new.utf8))
        #expect(r.correctedQuery == "FamilyMart" && r.results[0].chainGroup?.countNearby == 12 && r.results[0].openNow == true)
        #expect(SearchLogic.chainCount(r.results) == 12)
        #expect(r.suggestions?.first?.category == .convenience && r.suggestions?.first?.count == 6)
        let only = #"{"results":[{"id":"st-1","name":"Jalan SS 2/24","category":"street","address":"Petaling Jaya","lat":3.1,"lng":101.6},{"id":"pt-3.1,101.6","name":"3.1, 101.6","category":"point","address":"Near Jalan SS 2/24","lat":3.1,"lng":101.6}],"noMatch":false,"interpretation":{"kind":"street","normalized":"jalan ss2 24"}}"#
        let so = try JSON.makeDecoder().decode(SearchResponse.self, from: Data(only.utf8))
        #expect(so.results.allSatisfy(\.isSearchOnly) && so.interpretation?.kind == "street" && so.noMatch == false)
        let old = #"{"results":[]}"#
        let o = try JSON.makeDecoder().decode(SearchResponse.self, from: Data(old.utf8))
        #expect(o.correctedQuery == nil && o.suggestions == nil)
        let rev = try JSON.makeDecoder().decode(ReverseGeocode.self, from: Data(#"{"name":"Kyochon","address":"1, Jalan SS 2/64","lat":3.1,"lng":101.6}"#.utf8))
        #expect(rev.name == "Kyochon" && rev.nearby == nil)
        let rev2 = try JSON.makeDecoder().decode(ReverseGeocode.self, from: Data(#"{"name":null,"address":"18, Jalan SS2/24","lat":3.1,"lng":101.6,"nearby":[{"id":"n1","name":"FamilyMart","category":"convenience","address":"Jalan SS2/24","lat":3.1003,"lng":101.6,"distanceM":40}]}"#.utf8))
        #expect(rev2.nearby?.first?.name == "FamilyMart" && rev2.address == "18, Jalan SS2/24")
    }

    @Test("Chain initials")
    func initials() {
        #expect(SearchLogic.initials("FamilyMart") == "FM")
        #expect(SearchLogic.initials("7-Eleven") == "7E")
        #expect(SearchLogic.initials("Petronas") == "PE")
        #expect(SearchLogic.initials("kedai mak") == "KM")
    }

    @Test("A \"+\" in a query value is sent as %2B (Plus Codes), and the signature covers that exact target")
    func plusEncoding() async {
        let client = APIClient(baseURL: URL(string: "http://h/api/v1/")!, token: nil)
        let url = await client.url("search", query: [URLQueryItem(name: "q", value: "6PH57VP3+PR"), URLQueryItem(name: "q2", value: "a b")])
        #expect(url.absoluteString == "http://h/api/v1/search?q=6PH57VP3%2BPR&q2=a%20b")
        #expect(Canonical.pathAndQuery(of: url) == "/api/v1/search?q=6PH57VP3%2BPR&q2=a%20b")
    }
}
