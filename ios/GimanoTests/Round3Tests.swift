import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Gimano

private typealias OH = OpeningHours
private func r(_ a: String, _ b: String) -> OH.Range { OH.Range("\(a)-\(b)")! }

@Suite("Opening hours → OSM opening_hours")
struct OpeningHoursTests {
    @Test("Weekdays + Saturday + Sunday off")
    func typicalShop() {
        var h = OH.uniform([r("08:00", "18:00")], on: [.mo, .tu, .we, .th, .fr])
        h.days[.sa] = [r("08:00", "13:00")]
        #expect(h.osm == "Mo-Fr 08:00-18:00; Sa 08:00-13:00; Su off")
    }

    @Test("Every day the same uses Mo-Su; all day every day is 24/7")
    func everyDay() {
        #expect(OH.uniform([r("07:00", "23:00")]).osm == "Mo-Su 07:00-23:00")
        #expect(OH.allDay.osm == "24/7")
    }

    @Test("Split shifts (lunch break) and overnight ranges")
    func splitAndOvernight() {
        #expect(OH.uniform([r("07:00", "12:00"), r("14:00", "22:00")]).osm == "Mo-Su 07:00-12:00,14:00-22:00")
        // Mamak open late, past midnight.
        #expect(OH.uniform([r("18:00", "02:00")]).osm == "Mo-Su 18:00-02:00")
    }

    @Test("Two-day groups use commas, three or more use a range, scattered days are listed")
    func dayGrouping() {
        var h = OH.uniform([r("09:00", "17:00")], on: [.mo, .tu, .we, .th])
        h.days[.fr] = [r("09:00", "12:00"), r("14:30", "17:00")] // Friday prayers break
        h.days[.sa] = [r("10:00", "14:00")]
        h.days[.su] = [r("10:00", "14:00")]
        #expect(h.osm == "Mo-Th 09:00-17:00; Fr 09:00-12:00,14:30-17:00; Sa,Su 10:00-14:00")
        let scattered = OH.uniform([r("10:00", "16:00")], on: [.mo, .we, .fr])
        #expect(scattered.osm == "Mo,We,Fr 10:00-16:00; Tu,Th,Sa,Su off")
        #expect(OH.daySpec([.sa, .su, .mo]) == "Mo,Sa,Su")
        #expect(OH.daySpec([.mo, .tu, .th, .fr, .sa]) == "Mo,Tu,Th-Sa")
    }

    @Test("All closed produces an empty string")
    func allClosed() {
        #expect(OH.uniform([]).osm == "")
    }

    @Test("Round trip through the parser", arguments: [
        "Mo-Fr 08:00-18:00; Sa 08:00-13:00; Su off", "24/7", "Mo-Su 07:00-12:00,14:00-22:00",
        "Mo-Th 09:00-17:00; Fr 09:00-12:00,14:30-17:00; Sa,Su 10:00-14:00", "Mo,We,Fr 10:00-16:00; Tu,Th,Sa,Su off",
    ])
    func roundTrip(s: String) throws {
        let parsed = try #require(OH.parse(s))
        #expect(parsed.osm == s)
    }

    @Test("Parser accepts plain times and wrapping day ranges; rejects richer syntax")
    func parser() {
        #expect(OH.parse("08:00-17:00")?.osm == "Mo-Su 08:00-17:00")
        #expect(OH.parse("Fr-Mo 10:00-20:00")?.ranges(.sa) == [r("10:00", "20:00")])
        #expect(OH.parse("Fr-Mo 10:00-20:00")?.ranges(.we) == [])
        #expect(OH.parse("Mo-Fr 08:00-18:00; PH off") == nil)
        #expect(OH.parse("sunrise-sunset") == nil)
        #expect(OH.Range("25:00-26:00") == nil)
        #expect(OH.Range("08:00-24:00")?.close == 1440)
    }
}

@Suite("Rating summary")
struct RatingSummaryTests {
    private func review(_ n: Int) -> Review {
        Review(id: UUID().uuidString, placeId: "p", rating: n, text: nil, photos: nil, author: PersonRef(displayName: "A"),
               helpfulCount: 0, createdAt: .now, editedAt: nil, status: nil)
    }

    @Test("Distribution and mean; fewer than 3 reviews shows New")
    func summary() {
        let s = RatingSummary.make(reviews: [5, 4, 4, 1].map(review))
        #expect(s.distribution == [1, 0, 0, 2, 1])
        #expect(s.average == 3.5)
        #expect(!s.isNew)
        #expect(RatingSummary.make(reviews: [5, 5].map(review)).isNew)
        // The server's mean and count win when present.
        let server = RatingSummary.make(reviews: [5].map(review), serverAverage: 4.2, serverCount: 37)
        #expect(server.average == 4.2 && server.count == 37 && !server.isNew)
    }
}

@Suite("Photos on the device")
struct ImageProcessingTests {
    private func bigImageData(withGPS: Bool) throws -> Data {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f
        }()).image { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 500, y: 500, width: 1000, height: 1000))
        }
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.heic.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if withGPS { props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 3.1579, kCGImagePropertyGPSLongitude: 101.7123] }
        CGImageDestinationAddImage(dest, img.cgImage!, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test("HEIC → JPEG ≤ 2048 px for upload, with GPS metadata stripped")
    func uploadJPEG() throws {
        let heic = try bigImageData(withGPS: true)
        let jpeg = try #require(ImageProcessing.uploadJPEG(heic))
        let src = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        #expect(CGImageSourceGetType(src) as String? == UTType.jpeg.identifier)
        let size = try #require(ImageProcessing.pixelSize(jpeg))
        #expect(max(size.width, size.height) == 2048)
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        #expect(props?[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test("Private photos are WebP (libwebp), ≤ 1600 px, decodable")
    func webp() throws {
        let heic = try bigImageData(withGPS: false)
        let webp = try #require(ImageProcessing.webp(heic))
        #expect(ImageProcessing.isWebP(webp))
        let size = try #require(ImageProcessing.pixelSize(webp))
        #expect(max(size.width, size.height) == 1600)
        #expect(UIImage(data: webp) != nil)
    }
}

@Suite("Private places (on device only)")
struct PrivatePlaceTests {
    private func store() throws -> LocalStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try LocalStore(path: dir.appendingPathComponent("db.sqlite").path, photosDirectory: dir.appendingPathComponent("photos"))
    }

    @Test("Saved with WebP photos, read back, included in backups, deleted with their files")
    func lifecycle() throws {
        let s = try store()
        let tiny = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { c in UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 300, height: 200)) }
        let webp = try #require(ImageProcessing.webp(tiny.pngData()!))
        let saved = try s.addPrivatePlace(PrivatePlace(id: "", name: "Gerai Pak Abu", category: .restaurant, lat: 3.1, lng: 101.6,
                                                       address: "Kg Baru", openingHours: "Mo-Su 18:00-02:00", amenities: ["toilets"]),
                                          webpPhotos: [webp])
        #expect(saved.photoFiles.count == 1 && saved.photoFiles[0].hasPrefix("photos/") && saved.photoFiles[0].hasSuffix(".webp"))
        #expect(saved.summary.isPrivate)
        #expect(FileManager.default.fileExists(atPath: s.photoURL(saved.photoFiles[0]).path))
        #expect(try s.privatePlaces().first?.amenities == ["toilets"])

        let file = try BackupService(store: s, kdfLimits: .interactive).makeBackup()
        let other = try store()
        try BackupService(store: other).restore(file, mode: .replace)
        let restored = try #require(try other.privatePlaces().first)
        #expect(restored.name == "Gerai Pak Abu")
        #expect(ImageProcessing.isWebP(try Data(contentsOf: other.photoURL(restored.photoFiles[0]))))

        try s.deletePrivatePlace(id: saved.id)
        #expect(try s.privatePlaces().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: s.photoURL(saved.photoFiles[0]).path))
    }
}

@Suite("Community places, reviews & photos (demo backend)")
struct CommunityDemoTests {
    @Test("Add a public place: pending, duplicate → 409 with the existing place, 3 confirmations publish it")
    func places() async throws {
        let repo = DemoRepository(latency: .zero)
        let p = try await repo.createPlace(NewPlace(name: "Kedai Runcit Pak Mat", category: .convenience, lat: 3.16, lng: 101.70,
                                                    openingHours: "Mo-Sa 07:00-22:00", amenities: ["cards"]))
        #expect(p.status == .pending && p.source == .community)
        do {
            _ = try await repo.createPlace(NewPlace(name: "kedai runcit pak mat", category: .convenience, lat: 3.1601, lng: 101.7001))
            Issue.record("expected a duplicate")
        } catch APIError.conflict(let body) {
            // The API's problem body: `{…, existing: PlaceSummary}`.
            let existing = try #require(DuplicatePlace.existing(in: body))
            #expect(existing.id == p.id)
        }
        let claim = ProximityClaim(cell: Geohash.encode(lat: p.lat, lng: p.lng), withinM: 1000)
        await #expect(throws: APIError.self) { try await repo.verifyPlace(id: p.id, VerifyPlaceRequest(answer: .yes, proximity: claim)) } // own place
        try await repo.simulateOtherDriversVerify(placeId: p.id, count: 3)
        let v = try await repo.place(id: p.id, near: nil)
        #expect(v.status == .published && v.verifiedCount == 3)
        #expect(try await repo.myContributions().map(\.id) == [p.id])
        let found = try await repo.search(query: "pak mat", near: LatLng(lat: 3.16, lng: 101.70), category: nil, limit: 5)
        #expect(found.first?.id == p.id)
    }

    @Test("Review with a photo: photo is WebP, one review per place, helpful toggles")
    func reviews() async throws {
        let repo = DemoRepository(latency: .zero)
        let img = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { c in UIColor.green.setFill(); c.fill(CGRect(x: 0, y: 0, width: 800, height: 600)) }
        let jpeg = try #require(ImageProcessing.uploadJPEG(img))
        let photo = try await repo.uploadPhoto(jpeg, placeId: "demo:klcc", caption: nil) { _ in }
        #expect(photo.url?.hasSuffix(".webp") == true)
        #expect(photo.status == .processing)
        let review = try await repo.createReview(placeId: "demo:klcc", NewReview(rating: 5, text: "Sedap!", photoIds: [photo.id]))
        #expect(review.photos?.first?.url?.hasSuffix(".webp") == true)
        await #expect(throws: APIError.self) { try await repo.createReview(placeId: "demo:klcc", NewReview(rating: 3)) }
        try await repo.toggleHelpful(reviewId: review.id)
        #expect(try await repo.reviews(placeId: "demo:klcc", sort: .helpful, cursor: nil).reviews.first?.helpfulCount == 1)
        try await repo.toggleHelpful(reviewId: review.id)
        #expect(try await repo.reviews(placeId: "demo:klcc", sort: .recent, cursor: nil).reviews.first?.helpfulCount == 0)
        let edited = try await repo.updateReview(id: review.id, NewReview(rating: 4, text: "Sedap, tapi sesak", photoIds: [photo.id]))
        #expect(edited.rating == 4 && edited.editedAt != nil)
    }

    @Test("Place JSON with community fields decodes")
    func decode() throws {
        let json = """
        {"id":"c1","name":"Gerai","category":"restaurant","address":"","lat":3.1,"lng":101.6,"distanceM":null,"brand":null,
         "source":"community","status":"pending","rating":null,"reviewCount":0,"thumbnailUrl":null,"phone":null,"website":null,
         "openingHours":"Mo-Su 18:00-02:00","openNow":null,"amenities":[],"tags":{},"osmType":null,"osmId":null,
         "description":"Nasi lemak","addedBy":{"displayName":"Aina"},"verifiedCount":1,
         "photos":[{"id":"ph","url":"http://h/media/abc.webp","thumbUrl":"http://h/media/abc_t.webp","width":1600,"height":1200,
                    "caption":null,"uploadedBy":{"displayName":"Aina"},"createdAt":"2026-10-23T01:00:00Z"}]}
        """
        let p = try JSON.makeDecoder().decode(Place.self, from: Data(json.utf8))
        #expect(p.summary.isCommunity && p.status == .pending && p.photos?.first?.url?.hasSuffix(".webp") == true)
    }

    @Test("409 duplicate: the existing place is read from the problem body (live shape)")
    func duplicateBody() {
        let json = #"{"type":"x","title":"Similar place nearby","status":409,"detail":"A similar place already exists nearby: Kedai Runcit Probe.","existing":{"id":"c01","name":"Kedai Runcit Probe","category":"convenience","address":"Near Balai Polis","lat":3.1526,"lng":101.7037,"distanceM":0,"brand":null,"source":"community","status":"pending","rating":null,"reviewCount":0,"thumbnailUrl":null},"traceId":"t"}"#
        let e = DuplicatePlace.existing(in: Data(json.utf8))
        #expect(e?.id == "c01" && e?.name == "Kedai Runcit Probe")
        #expect(DuplicatePlace.existing(in: Data("{}".utf8)) == nil)
    }

    @Test("Root-relative /media URLs resolve against the API host; absolute ones are kept")
    @MainActor
    func mediaURL() {
        let base = URL(string: "http://100.101.150.9:5080/api/v1/")!
        #expect(MediaURL.resolve("/media/abc.webp", apiBase: base)?.absoluteString == "http://100.101.150.9:5080/media/abc.webp")
        #expect(MediaURL.resolve("https://cdn.example/x.webp", apiBase: base)?.absoluteString == "https://cdn.example/x.webp")
        #expect(MediaURL.resolve(nil, apiBase: base) == nil)
    }

    @Test("A photo still processing on the server has no URL yet (live API shape)")
    func processingPhoto() throws {
        let json = #"{"id":"p1","url":null,"thumbUrl":null,"width":1024,"height":1024,"caption":null,"uploadedBy":{"displayName":"Gajah 4370"},"createdAt":"2026-10-23T03:18:35.0826639+00:00","status":"processing"}"#
        let photo = try JSON.makeDecoder().decode(Photo.self, from: Data(json.utf8))
        #expect(photo.url == nil && photo.status == .processing && photo.createdAt != nil)
    }
}

@Suite("Live updates")
struct LiveUpdateTests {
    @Test("JamUpdated with level 0 removes the jam")
    @MainActor
    func jamCleared() {
        let store = LiveMapStore()
        let jam = Jam(id: "j", level: 3, speedKmh: 10, delayS: 60, lengthM: 300, polyline: "", street: nil, updatedAt: .now)
        store.apply(.jamUpdated(jam))
        #expect(store.jams["j"] != nil)
        var cleared = jam
        cleared.level = 0
        store.apply(.jamUpdated(cleared))
        #expect(store.jams["j"] == nil)
    }
}
