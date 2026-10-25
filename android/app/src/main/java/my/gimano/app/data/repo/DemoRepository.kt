package my.gimano.app.data.repo

import kotlinx.coroutines.delay
import my.gimano.app.core.geo.GeoMath
import my.gimano.app.core.geo.GeoPoint
import my.gimano.app.core.geo.Polyline
import my.gimano.app.core.nav.RouteGeometry
import my.gimano.app.data.model.*
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.random.Random

/** Offline, in-memory backend used for demos and when the server is unreachable. */
class DemoRepository(
    private val cannedDocs: () -> List<String> = { emptyList() },
    /** Saves demo photo bytes somewhere loadable and returns its URL (file:// in the app). */
    private val photoSink: (id: String, bytes: ByteArray) -> String = { id, _ -> "demo://photos/$id.webp" },
) : GimanoRepository {
    companion object {
        /** Contact tokens issued by demo mode: a withdrawal with one goes to demo data, never the server. */
        const val DEMO_CONTACT_TOKEN = "demo-ct-"
    }


    /** Real OSM road geometry (assets/demo-routes), loaded on first use. */
    val canned: CannedRoutes by lazy { CannedRoutes.parse(cannedDocs()) }

    private val user = User(
        "demo-user", "Pemandu Manotu", "🙂", "car", 1280, 4, "2026-01-01T00:00:00Z",
        tier = "perak", accuracy = 0.93, placesAccepted = 14, verifierVotes = 22,
        nextTier = NextTier("emas", listOf("36 more accepted places", "accuracy 95%", "account 90 days")),
    )

    private val catalog = listOf(
        p("klcc", "Suria KLCC", "mall", "Kuala Lumpur City Centre, 50088 Kuala Lumpur", 3.1579, 101.7123),
        p("pavilion", "Pavilion Kuala Lumpur", "mall", "168 Jalan Bukit Bintang, 55100 Kuala Lumpur", 3.1490, 101.7134),
        p("midvalley", "Mid Valley Megamall", "mall", "Lingkaran Syed Putra, 59200 Kuala Lumpur", 3.1176, 101.6774),
        p("klsentral", "KL Sentral", "transit_station", "Jalan Stesen Sentral, 50470 Kuala Lumpur", 3.1340, 101.6865),
        p("masjidnegara", "Masjid Negara", "mosque", "Jalan Perdana, 50480 Kuala Lumpur", 3.1418, 101.6917),
        p("batucaves", "Batu Caves", "tourism", "Gombak, 68100 Batu Caves, Selangor", 3.2379, 101.6840),
        p("klia", "KLIA Terminal 1", "airport", "64000 Sepang, Selangor", 2.7456, 101.7072),
        p("putra", "Masjid Putra", "mosque", "Persiaran Persekutuan, Presint 1, 62502 Putrajaya", 2.9360, 101.6897),
        p("sunway", "Sunway Pyramid", "mall", "3 Jalan PJS 11/15, Bandar Sunway, 47500 Petaling Jaya", 3.0731, 101.6070),
        p("1u", "1 Utama Shopping Centre", "mall", "Lebuh Bandar Utama, 47800 Petaling Jaya", 3.1502, 101.6152),
        p("ikea", "IKEA Damansara", "mall", "2 Jalan PJU 7/2, Mutiara Damansara, 47800 Petaling Jaya", 3.1574, 101.6119),
        p("hkl", "Hospital Kuala Lumpur", "hospital", "Jalan Pahang, 50586 Kuala Lumpur", 3.1716, 101.7020),
        p("petronas-ampang", "PETRONAS Jalan Ampang", "fuel", "Jalan Ampang, 50450 Kuala Lumpur", 3.1600, 101.7300, "PETRONAS"),
        p("petronas-tunrazak", "PETRONAS Jalan Tun Razak", "fuel", "Jalan Tun Razak, 50400 Kuala Lumpur", 3.1650, 101.7180, "PETRONAS"),
        p("petronas-duta", "PETRONAS Jalan Duta", "fuel", "Jalan Duta, 50480 Kuala Lumpur", 3.1720, 101.6700, "PETRONAS"),
        p("shell-bangsar", "Shell Jalan Bangsar", "fuel", "Jalan Bangsar, 59200 Kuala Lumpur", 3.1290, 101.6720, "Shell"),
        p("petron-kuching", "Petron Jalan Kuching", "fuel", "Jalan Kuching, 51200 Kuala Lumpur", 3.1830, 101.6810, "Petron"),
        p("bhp-cheras", "BHPetrol Cheras", "fuel", "Jalan Cheras, 56100 Kuala Lumpur", 3.1000, 101.7400, "BHPetrol"),
        p("caltex-pj", "Caltex SS2", "fuel", "Jalan SS 2/24, 47300 Petaling Jaya", 3.1200, 101.6200, "Caltex"),
        p("rr-dengkil", "R&R Dengkil", "rest_area", "Lebuhraya ELITE, 43800 Dengkil, Selangor", 2.8800, 101.6900),
        p("rr-ayerkeroh", "R&R Ayer Keroh", "rest_area", "Lebuhraya Utara-Selatan, 75450 Ayer Keroh, Melaka", 2.2700, 102.2900),
        p("bangsarvillage", "Bangsar Village", "mall", "1 Jalan Telawi 1, Bangsar Baru, 59100 Kuala Lumpur", 3.1306, 101.6710),
        p("pelita", "Nasi Kandar Pelita Jalan Ampang", "restaurant", "149 Jalan Ampang, 50450 Kuala Lumpur", 3.1600, 101.7240),
        p("villagepark", "Village Park Restaurant", "restaurant", "5 Jalan SS 21/37, Damansara Utama, 47400 Petaling Jaya", 3.1360, 101.6230),
        p("dangwangi", "Balai Polis Dang Wangi", "police", "Jalan Dang Wangi, 50100 Kuala Lumpur", 3.1550, 101.6990),
        p("chargev-mv", "EV charger · Mid Valley", "ev_charging", "Mid Valley City, 59200 Kuala Lumpur", 3.1180, 101.6770),
        p("masjidwilayah", "Masjid Wilayah Persekutuan", "mosque", "Jalan Duta, 50480 Kuala Lumpur", 3.1720, 101.6740),
        p("tol-sgbesi", "Plaza Tol Sungai Besi", "toll_booth", "Lebuhraya Utara-Selatan, 57000 Kuala Lumpur", 3.0560, 101.7080),
        p("penangbridge", "Jambatan Pulau Pinang", "tourism", "Pulau Pinang", 5.3550, 100.3480),
        p("jbciq", "Bangunan Sultan Iskandar CIQ", "government", "Jalan Jim Quee, 80300 Johor Bahru", 1.4630, 103.7650),
    )

    private val reports = CopyOnWriteArrayList<Report>()
    private var seededAround: GeoPoint? = null
    private val jams = CopyOnWriteArrayList<Jam>()
    private val drivers = CopyOnWriteArrayList<Driver>()
    private val routeSets = HashMap<String, Pair<CannedRouteSet, RouteRequest>>()

    private fun p(id: String, name: String, cat: String, addr: String, lat: Double, lng: Double, brand: String? = null) =
        Place(id, name, cat, addr, lat, lng, null, brand,
            phone = if (cat in setOf("restaurant", "hospital", "mall", "police")) "+60 3-2161 ${1000 + id.length * 37}" else null,
            website = if (cat == "mall") "https://example.org/${id}" else null,
            openingHours = when (cat) { "fuel", "hospital", "police", "rest_area", "toll_booth", "ev_charging" -> "24/7"; "mosque" -> "Mo-Su 05:30-22:00"; else -> "Mo-Su 10:00-22:00" },
            openNow = true,
            amenities = when (cat) { "fuel" -> listOf("toilets", "convenience_store", "card_payment", "air_pump"); "rest_area" -> listOf("toilets", "surau", "food_court", "fuel"); "mall" -> listOf("parking", "toilets", "surau", "ev_charging"); else -> listOf("toilets") },
            osmType = "node", osmId = (id.hashCode().toLong() and 0xffffff))

    private suspend fun latency() = delay(120)

    override suspend fun ensureAuth() = user
    override suspend fun updateMe(body: UpdateMeRequest) = user.copy(displayName = body.displayName ?: user.displayName, vehicle = body.vehicle ?: user.vehicle)
    override suspend fun exportMyData(): MyDataExport? = null
    override suspend fun deleteMyData() {}

    override suspend fun search(q: String, lat: Double?, lng: Double?, limit: Int, category: String?): List<PlaceSummary> {
        latency()
        val tokens = q.lowercase().split(' ', ',').filter { it.isNotBlank() }
        if (tokens.isEmpty()) return emptyList()
        val me = if (lat != null && lng != null) GeoPoint(lat, lng) else null
        return (catalog + community.values).asSequence()
            .filter { category == null || it.category == category }
            .mapNotNull { pl ->
                val hay = "${pl.name} ${pl.brand ?: ""} ${pl.category.replace('_', ' ')} ${pl.address}".lowercase()
                val score = tokens.sumOf { t -> when { pl.name.lowercase().startsWith(t) -> 3; hay.split(' ').any { it.startsWith(t) } -> 2; hay.contains(t) -> 1; else -> -100 }.toInt() }
                if (score <= 0) null else pl to score
            }
            .map { (pl, score) ->
                val d = me?.let { GeoMath.distanceM(it, GeoPoint(pl.lat, pl.lng)) }
                Triple(pl, score, d)
            }
            .sortedWith(compareByDescending<Triple<Place, Int, Double?>> { it.second }.thenBy { it.third ?: 0.0 })
            .take(limit)
            .map { (pl, _, d) -> pl.summary().copy(distanceM = d, rating = ratingOf(pl.id), reviewCount = reviewStore[pl.id].orEmpty().size) }
            .toList()
    }

    override suspend fun nearby(lat: Double, lng: Double, category: String, radius: Int): List<PlaceSummary> {
        latency()
        val me = GeoPoint(lat, lng)
        val cats = if (category == "restaurant") setOf("restaurant", "cafe", "fast_food") else if (category == "mosque") setOf("mosque", "surau") else setOf(category)
        return catalog.filter { it.category in cats }
            .map { PlaceSummary(it.id, it.name, it.category, it.address, it.lat, it.lng, GeoMath.distanceM(me, GeoPoint(it.lat, it.lng)), it.brand) }
            .sortedBy { it.distanceM }
            .take(15)
    }

    override suspend fun place(id: String): Place {
        latency()
        community[id]?.let { return it.copy(photos = photoStore[id].orEmpty().map(::settle), reviewCount = reviewStore[id].orEmpty().size, rating = ratingOf(id)) }
        val base = catalog.firstOrNull { it.id == id } ?: catalog.first()
        return base.copy(photos = photoStore[base.id].orEmpty().map(::settle), reviewCount = reviewStore[base.id].orEmpty().size, rating = ratingOf(base.id))
    }

    override suspend fun reverse(lat: Double, lng: Double): ReverseGeocode {
        val near = catalog.minByOrNull { GeoMath.distanceM(GeoPoint(lat, lng), GeoPoint(it.lat, it.lng)) }
        return if (near != null && GeoMath.distanceM(GeoPoint(lat, lng), GeoPoint(near.lat, near.lng)) < 300)
            ReverseGeocode(near.name, near.address, lat, lng)
        else ReverseGeocode(String.format(java.util.Locale.US, "%.5f, %.5f", lat, lng), "Dropped pin", lat, lng)
    }

    override suspend fun routes(req: RouteRequest): List<Route> {
        delay(350)
        // Add-a-stop: route to the stop first (demo keeps it simple: one leg).
        val target = (req.waypoints.firstOrNull() ?: req.destination).let { GeoPoint(it.lat, it.lng) }
        val set = canned.nearestTo(target) ?: return emptyList()
        val departFactor = if (req.departAt != null) 0.92 else 1.0
        val routes = canned.plan(set, req.vehicle, req.avoid, departFactor)
        routes.forEach { routeSets[it.id] = set to req }
        routes.flatMap { it.alerts }.forEach { a -> if (reports.none { it.id == a.id }) reports += a.toReport() }
                return routes
    }

    override suspend fun reroute(routeId: String, req: RerouteRequest): List<Route> {
        delay(300)
        // Demo routes are canned, so a reroute returns the same real-road route again.
        val (set, orig) = routeSets[routeId] ?: return emptyList()
        val routes = canned.plan(set, orig.vehicle, orig.avoid, 1.0, "reroute").take(1)
        routes.forEach { routeSets[it.id] = set to orig }
        return routes
    }

    override suspend fun departureTimes(oLat: Double, oLng: Double, dLat: Double, dLng: Double, vehicle: String?): List<DepartureSlot> {
        latency()
        val base = GeoMath.distanceM(GeoPoint(oLat, oLng), GeoPoint(dLat, dLng)) * 1.3 / (40 / 3.6)
        val start = Instant.now().truncatedTo(ChronoUnit.HOURS).plus(15, ChronoUnit.MINUTES)
        return (0 until 10).map { i ->
            val f = 1.0 + 0.35 * kotlin.math.sin(i / 2.0)
            DepartureSlot(start.plus(15L * i, ChronoUnit.MINUTES).toString(), base * f)
        }
    }

    /** Captured routes as geometry + the route (for street names); all demo live data sits on these. */
    private val roadNetwork: List<Pair<Route, RouteGeometry>> by lazy {
        canned.all.flatMap { it.routes }.distinctBy { it.polyline }
            .map { it to RouteGeometry(Polyline.decode(it.polyline)) }
            .filter { it.second.points.size > 1 }
    }

    private fun streetAt(route: Route, g: RouteGeometry, along: Double): String? {
        val seg = g.segmentAt(along)
        return route.maneuvers.lastOrNull { it.beginShapeIndex <= seg && !it.streetName.isNullOrBlank() }?.streetName
    }

    /**
     * Seeds demo alerts, jams and nearby drivers ON real road geometry: every coordinate is a
     * point on (or a slice of) a captured OSM route polyline — never a synthetic segment.
     * Positions near the viewport centre are preferred; with no captured road nearby the
     * map simply shows nothing rather than fake lines.
     */
    private fun seed(center: GeoPoint) {
        val s = seededAround
        if (s != null && GeoMath.distanceM(s, center) < 3_000) return
        seededAround = center
        reports.removeAll { it.id.startsWith("seed-") }
        jams.clear()
        drivers.clear()
        val net = roadNetwork
        if (net.isEmpty()) return
        val rnd = Random((center.lat * 100).toInt() * 31 + (center.lng * 100).toInt())
        val now = Instant.now()

        fun pick(minLen: Double = 0.0): Triple<Route, RouteGeometry, Double> {
            // Prefer what's on screen at the default zoom, then widen.
            for (radius in listOf(2_500.0, 8_000.0)) repeat(80) {
                val (r, g) = net[rnd.nextInt(net.size)]
                if (g.lengthM <= minLen) return@repeat
                val along = rnd.nextDouble(0.0, g.lengthM - minLen)
                if (GeoMath.distanceM(g.pointAt(along).first, center) < radius) return Triple(r, g, along)
            }
            val (r, g) = net.maxBy { it.second.lengthM }
            return Triple(r, g, rnd.nextDouble(0.0, (g.lengthM - minLen).coerceAtLeast(1.0)))
        }

        val types = listOf(
            "police" to "visible", "accident" to "minor", "hazard" to "pothole", "traffic" to "heavy",
            "hazard" to "flood", "closure" to null, "blocked_lane" to "left", "weather" to "heavy_rain", "animal" to "on_shoulder",
        )
        types.forEachIndexed { i, (t, sub) ->
            val (r, g, along) = pick()
            val (pt, brg) = g.pointAt(along)
            val age = rnd.nextLong(2, 40)
            reports += Report(
                id = "seed-$i", type = t, subtype = sub, lat = pt.lat, lng = pt.lng, heading = brg,
                street = streetAt(r, g, along),
                reportedBy = ReportedBy(listOf("Aiman", "Mei Ling", "Kavitha", "Hafiz", "Jason")[i % 5], listOf("😎", "🙂", "😴", "🤠", "😇")[i % 5]),
                createdAt = now.minusSeconds(age * 60).toString(), expiresAt = now.plusSeconds((60 - age) * 60).toString(),
                confirmations = rnd.nextInt(0, 9), thanks = rnd.nextInt(0, 5),
            )
        }
        repeat(5) { j ->
            val len = rnd.nextDouble(400.0, 1_200.0)
            val (r, g, along) = pick(minLen = len)
            val level = 1 + j % 4
            val speed = listOf(28.0, 18.0, 9.0, 3.0)[level - 1]
            jams += Jam(
                "jam-$j", level, speed, delayS = len / (speed / 3.6) - len / (50 / 3.6), lengthM = len,
                polyline = Polyline.encode(g.slice(along, along + len)), street = streetAt(r, g, along), updatedAt = now.toString(),
            )
        }
        repeat(14) {
            val (_, g, along) = pick()
            val (pt, brg) = g.pointAt(along)
            drivers += Driver(pt.lat, pt.lng, brg, listOf("🙂", "😎", "🤠")[it % 3])
        }
    }

    override suspend fun live(minLng: Double, minLat: Double, maxLng: Double, maxLat: Double): LiveResponse {
        seed(GeoPoint((minLat + maxLat) / 2, (minLng + maxLng) / 2))
        val now = Instant.now()
        reports.removeAll { Instant.parse(it.expiresAt).isBefore(now) }
        return LiveResponse(reports.toList(), jams.toList(), drivers.toList(), now.toString())
    }

    override suspend fun createReport(body: CreateReportRequest): Report {
        latency()
        val now = Instant.now()
        val ttlMin = when (body.type) { "police" -> 30L; "traffic" -> 20L; "closure" -> 24 * 60L; "weather" -> 120L; else -> 60L }
        val r = Report(UUID.randomUUID().toString(), body.type, body.subtype, body.lat, body.lng, body.heading, null,
            ReportedBy(user.displayName, user.mood), now.toString(), now.plusSeconds(ttlMin * 60).toString(), 0, 0, body.comment)
        reports += r
        return r
    }

    override suspend fun deleteReport(reportId: String) {
        latency()
        reports.removeAll { it.id == reportId }
    }

    /**
     * One seeded road issue on the demo drive SS2 → Masjid Negara (the left turn into Jalan SS 2/24, ~770 m in), so a
     * simulated drive shows the "Masih ditutup?" card (canvas NavSahkan). Demo data only, never sent anywhere.
     */
    private val demoIssues = java.util.concurrent.CopyOnWriteArrayList(listOf(
        Issue("demo-issue-ss2-24", IssueKind.TURN_NOT_ALLOWED, null, IssueState.REPORTED, 3.11778, 101.624394,
            roadName = "Jalan SS 2/24", confirmations = 1.0, createdAt = Instant.now().minusSeconds(5 * 3600).toString()),
    ))

    override suspend fun createIssue(body: CreateIssueRequest): Issue {
        latency()
        val i = Issue(UUID.randomUUID().toString(), body.kind, body.subtype, IssueState.SUSPECTED, body.lat, body.lng, body.heading, body.placeId,
            createdAt = Instant.now().toString(), confirmations = 1.0)
        demoIssues += i
        return i
    }

    override suspend fun issuesNearby(minLng: Double, minLat: Double, maxLng: Double, maxLat: Double, kinds: List<String>?): List<Issue> =
        demoIssues.filter { it.lng in minLng..maxLng && it.lat in minLat..maxLat && (kinds == null || it.kind in kinds) }

    override suspend fun voteIssue(id: String, body: IssueVoteRequest): IssueVoteResult {
        latency()
        val i = demoIssues.firstOrNull { it.id == id } ?: throw NoSuchElementException(id)
        val u = i.copy(confirmations = i.confirmations + if (body.answer == "still") 1 else 0)
        demoIssues.replaceAll { if (it.id == id) u else it }
        return IssueVoteResult(u.state, u.confirmations, 0.0, 2.0)
    }

    override suspend fun vote(reportId: String, stillThere: Boolean): Report {
        latency()
        val i = reports.indexOfFirst { it.id == reportId }
        if (i < 0) throw NoSuchElementException(reportId)
        val r = reports[i]
        val upd = if (stillThere) r.copy(confirmations = r.confirmations + 1, expiresAt = Instant.parse(r.expiresAt).plusSeconds(15 * 60).toString())
        else r.copy(expiresAt = Instant.parse(r.expiresAt).minusSeconds(10 * 60).toString())
        reports[i] = upd
        return upd
    }

    override suspend fun thank(reportId: String) {}
    override suspend fun postLocations(batch: LocationBatch) {}

    // --- Feedback (demo: kept in memory) ---------------------------------------------------
    private val feedbackStore = CopyOnWriteArrayList<FeedbackSummary>()

    override suspend fun sendFeedback(body: FeedbackRequest): FeedbackCreated {
        latency()
        val f = FeedbackSummary(UUID.randomUUID().toString(), body.category, body.message, "received", Instant.now().toString(), hasContact = body.contact != null)
        // As on the server: a report with a contact is not linked to the account (not in /me/feedback) and gets a token.
        if (body.contact == null) feedbackStore.add(0, f)
        return FeedbackCreated(f.id, f.createdAt, contactToken = if (body.contact != null) DEMO_CONTACT_TOKEN + UUID.randomUUID().toString().take(12) else null)
    }

    override suspend fun myFeedback(): List<FeedbackSummary> = feedbackStore.toList()
    override suspend fun deleteFeedbackContact(id: String, token: String?) {
        feedbackStore.replaceAll { if (it.id == id) it.copy(hasContact = false) else it }
    }
    override suspend fun deleteCrashContact(id: String, token: String) {}
    override suspend fun flagPlace(placeId: String, reason: String) {}
    override suspend fun sendCrashReport(body: CrashReportRequest): CrashCreated {
        latency()
        return CrashCreated("demo-crash-" + UUID.randomUUID().toString().take(8), contactToken = body.contact?.let { DEMO_CONTACT_TOKEN + UUID.randomUUID().toString().take(12) })
    }

    override suspend fun inbox(): List<InboxItem> {
        val now = Instant.now()
        return buildList {
            community.values.filter { it.status == "published" }.forEach { add(InboxItem("pub-${it.id}", "place_published", "Place published", "\"${it.name}\" was confirmed by 3 drivers. +20 points", now.toString(), it.id)) }
            feedbackStore.forEach { add(InboxItem("fb-${it.id}", "feedback_status", "Feedback received", it.message.take(80), it.createdAt)) }
            add(InboxItem("welcome", "announcement", "Welcome to Manotu", "Light theme, planned drives and Share my drive are here.", now.minusSeconds(86_400).toString()))
        }
    }

    // --- Community places, reviews, photos (demo) ------------------------------------------
    private val community = java.util.concurrent.ConcurrentHashMap<String, Place>()
    private val verifications = java.util.concurrent.ConcurrentHashMap<String, Int>()
    /**
     * Three sample reviews on Masjid Negara by three sample authors, each with an opaque author handle, so "Block this
     * user" can be tried in demo mode. Demo data only.
     */
    private val reviewStore = java.util.concurrent.ConcurrentHashMap<String, MutableList<Review>>().apply {
        val now = Instant.now()
        fun r(id: String, rating: Int, text: String, name: String, ref: String, hoursAgo: Long) =
            Review(id, "masjidnegara", rating, text, author = Author(name, 3, 12, authorRef = ref), helpfulCount = 2,
                createdAt = now.minusSeconds(hoursAgo * 3600).toString())
        put("masjidnegara", java.util.concurrent.CopyOnWriteArrayList(listOf(
            r("demo-rv-1", 5, "Bersih, parkir mudah selepas Isyak.", "Badak 5880", "demo-author-badak", 48),
            r("demo-rv-2", 4, "Cantik waktu malam. Parkir penuh hari Jumaat.", "Kancil 1204", "demo-author-kancil", 120),
            r("demo-rv-3", 4, "Good for visitors; the guides are friendly.", "Helang 77", "demo-author-helang", 300),
        )))
    }
    private val photoStore = java.util.concurrent.ConcurrentHashMap<String, MutableList<Photo>>()
    private val photoUploadedAt = java.util.concurrent.ConcurrentHashMap<String, Long>()

    private fun ratingOf(placeId: String): Double? = reviewStore[placeId]?.takeIf { it.isNotEmpty() }?.map { it.rating }?.average()

    /** Demo photos are "processing" for 2 s after upload, then "published". */
    private fun settle(p: Photo): Photo =
        if (p.status == "processing" && System.currentTimeMillis() - (photoUploadedAt[p.id] ?: 0) > 2_000) p.copy(status = "published") else p

    override suspend fun createPlace(body: CreatePlaceRequest): Place {
        latency()
        val id = "community-" + UUID.randomUUID().toString().take(8)
        val p = Place(
            id = id, name = body.name, category = body.category, address = body.address ?: "", lat = body.lat, lng = body.lng,
            phone = body.phone, website = body.website, openingHours = body.openingHours, amenities = body.amenities.orEmpty(),
            source = "community", status = "pending", description = body.description, addedBy = Author(user.displayName), verifiedCount = 0,
            confirmationsWeighted = 0.0, required = 3.0,
        )
        community[id] = p
        return p
    }

    override suspend fun suggestEdit(placeId: String, body: SuggestEditRequest): SuggestionCreated {
        latency()
        return SuggestionCreated("suggestion-" + UUID.randomUUID().toString().take(8))
    }

    /** Demo: weights as a Baharu voter (1 each); 3 publish the place. */
    override suspend fun verifyPlace(placeId: String, body: VerifyRequest, ts: Long?): VerifyResult {
        latency()
        val yes = if (body.answer == "yes") 1 else 0
        val n = (verifications[placeId] ?: 1) + yes
        verifications[placeId] = n
        community[placeId]?.let { p -> community[placeId] = p.copy(verifiedCount = n, confirmationsWeighted = n.toDouble(), required = 3.0, status = if (n >= 3) "published" else "pending") }
        return VerifyResult(if (n >= 3) "published" else "pending", n.toDouble(), 3.0)
    }

    /** Demo: one pending stall ~280 m north of the cell centre, already confirmed once. */
    override suspend fun pendingNearby(cell: String): List<PlaceSummary> {
        latency()
        val (lat, lng) = my.gimano.app.core.vetting.Geohash.decodeCenter(cell)
        val id = "demo-pending-$cell"
        val p = community.getOrPut(id) {
            Place(
                id = id, name = "Gerai Nasi Kerabu Mek Na", category = "restaurant", address = "", lat = lat + 0.0025, lng = lng,
                openingHours = "Mo-Sa 07:00-14:00", source = "community", status = "pending", addedBy = Author("Rusa 2368"),
                verifiedCount = 1, confirmationsWeighted = 1.0, required = 3.0,
            )
        }
        return listOf(p.summary()).filter { (verifications[id] ?: 1) < 3 }
    }

    override suspend fun contributedPlaces(): List<PlaceSummary> = community.values.map { it.summary() }

    override suspend fun reviews(placeId: String, sort: String): ReviewsPage {
        latency()
        val list = reviewStore[placeId].orEmpty().map { r -> r.copy(photos = r.photos.map(::settle)) }
        return ReviewsPage(if (sort == "helpful") list.sortedByDescending { it.helpfulCount } else list.sortedByDescending { it.createdAt })
    }

    override suspend fun createReview(placeId: String, body: ReviewRequest): Review {
        latency()
        val list = reviewStore.getOrPut(placeId) { CopyOnWriteArrayList() }
        check(list.none { it.mine }) { "one review per place" }
        val photos = body.photoIds.orEmpty().mapNotNull { pid -> photoStore[placeId]?.firstOrNull { it.id == pid } }
        val r = Review(UUID.randomUUID().toString(), placeId, body.rating.coerceIn(1, 5), body.text, photos, Author(user.displayName, user.level, 1),
            0, Instant.now().toString(), null, "published", mine = true)
        list.add(0, r)
        return r
    }

    override suspend fun updateReview(reviewId: String, body: ReviewRequest): Review {
        latency()
        reviewStore.values.forEach { list ->
            val i = list.indexOfFirst { it.id == reviewId }
            if (i >= 0) {
                val photos = body.photoIds.orEmpty().mapNotNull { pid -> photoStore[list[i].placeId]?.firstOrNull { it.id == pid } }
                val upd = list[i].copy(rating = body.rating.coerceIn(1, 5), text = body.text, photos = photos.ifEmpty { list[i].photos }, editedAt = Instant.now().toString())
                list[i] = upd
                return upd
            }
        }
        throw NoSuchElementException(reviewId)
    }

    override suspend fun deleteReview(reviewId: String) { reviewStore.values.forEach { l -> l.removeAll { it.id == reviewId } } }

    override suspend fun helpful(reviewId: String) {
        reviewStore.values.forEach { l -> val i = l.indexOfFirst { it.id == reviewId }; if (i >= 0) l[i] = l[i].copy(helpfulCount = l[i].helpfulCount + 1) }
    }

    override suspend fun flagReview(reviewId: String, reason: String) {}
    override suspend fun flagPhoto(photoId: String, reason: String) {}

    override suspend fun uploadPhoto(placeId: String, jpeg: ByteArray, caption: String?): Photo {
        delay(600)
        val id = UUID.randomUUID().toString().take(12)
        val url = photoSink(id, jpeg)
        val p = Photo(id, url, url, 0, 0, caption, Author(user.displayName), Instant.now().toString(), status = "processing")
        photoUploadedAt[id] = System.currentTimeMillis()
        photoStore.getOrPut(placeId) { CopyOnWriteArrayList() }.add(p)
        return p
    }

    override suspend fun photos(placeId: String): PhotosPage = PhotosPage(photoStore[placeId].orEmpty().map(::settle))

    // --- Share my drive (demo relay: keeps only the latest ciphertext, like the server) ---
    val demoShares = java.util.concurrent.ConcurrentHashMap<String, MutableList<my.gimano.app.data.share.SealedShare>>()

    override suspend fun createShare(expiresInMinutes: Int): my.gimano.app.data.share.ShareCreated {
        val id = UUID.randomUUID().toString().replace("-", "")
        demoShares[id] = CopyOnWriteArrayList()
        return my.gimano.app.data.share.ShareCreated(id, UUID.randomUUID().toString(), Instant.now().plusSeconds(expiresInMinutes * 60L).toString())
    }

    override suspend fun updateShare(shareId: String, writeToken: String, sealed: my.gimano.app.data.share.SealedShare) {
        demoShares[shareId]?.add(sealed)
    }

    override suspend fun deleteShare(shareId: String, writeToken: String) { demoShares.remove(shareId) }
}
