package my.gimano.app.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import my.gimano.app.core.geo.GeoPoint

// DTOs mirror docs/api.md exactly (camelCase JSON). Unknown fields are ignored by the Json config.

@Serializable
data class DeviceAuthRequest(val deviceId: String, val platform: String = "android", val locale: String)

@Serializable
data class DeviceAuthResponse(val token: String, val userId: String, val displayName: String)

/** `POST /auth/register` (docs/identity-and-reputation.md §1). */
@Serializable
data class RegisterRequest(val publicKey: String, val platform: String = "android", val locale: String)

/**
 * `POST /auth/token`: sig = Ed25519 over "GIMANO-AUTH\n" + userId + "\n" + ts.
 * Recovery-code restore knows only the key: it sends [publicKey] instead of [userId] and signs
 * "GIMANO1-LOGIN\n" + publicKey + "\n" + ts (docs/identity-and-reputation.md §7–8).
 */
@Serializable
data class TokenRequest(val userId: String? = null, val publicKey: String? = null, val ts: Long, val sig: String)

@Serializable
data class TokenResponse(val token: String, val userId: String? = null, val displayName: String? = null)

@Serializable
data class AttachKeyRequest(val publicKey: String, val sigByOldKey: String? = null)

@Serializable
data class NextTier(val name: String = "", val missing: List<String> = emptyList())

@Serializable
data class User(
    val id: String,
    val displayName: String,
    val mood: String? = null,
    val vehicle: String? = null,
    val points: Int = 0,
    val level: Int = 1,
    val joinedAt: String? = null,
    /** baharu | perak | emas */
    val tier: String = "baharu",
    /** 0–1, null until 5 counted items. */
    val accuracy: Double? = null,
    val placesAccepted: Int = 0,
    val verifierVotes: Int = 0,
    val nextTier: NextTier? = null,
)

@Serializable
data class UpdateMeRequest(
    val displayName: String? = null,
    val mood: String? = null,
    val vehicle: String? = null,
    val locale: String? = null,
)

@Serializable
data class SavedPlace(
    val id: String,
    val kind: String, // home | work | favorite
    val name: String,
    val lat: Double,
    val lng: Double,
    val address: String = "",
    val placeId: String? = null,
    val icon: String = "star",
    val sortOrder: Int = 0,
)

/** Legacy one-time migration payload: GET /me/data/export. */
@Serializable
data class MyDataExport(val savedPlaces: List<SavedPlace> = emptyList(), val recents: List<Recent> = emptyList())

@Serializable
data class SavePlaceRequest(
    val name: String,
    val lat: Double,
    val lng: Double,
    val address: String,
    val placeId: String? = null,
)

@Serializable
data class Recent(
    val id: String,
    val name: String,
    val address: String = "",
    val lat: Double,
    val lng: Double,
    val placeId: String? = null,
    val lastUsedAt: String? = null,
)

@Serializable
data class PlaceSummary(
    val id: String,
    val name: String,
    val category: String = "other",
    val address: String = "",
    val lat: Double,
    val lng: Double,
    val distanceM: Double? = null,
    val brand: String? = null,
    val source: String = "osm",          // osm | community
    val status: String? = null,          // pending | published (community only)
    val rating: Double? = null,
    val reviewCount: Int = 0,
    val thumbnailUrl: String? = null,
    /** Vetting (pending community places): weighted confirmations so far / required to publish. */
    val confirmationsWeighted: Double? = null,
    val required: Double? = null,
    /** The place's `rural` flag widens the "nearby" radius from 1 km to 5 km. */
    val rural: Boolean = false,
    /** Tier of the contributor (only "emas" is shown, as a badge). */
    val contributorTier: String? = null,
    /** Chain this place belongs to (server groups by spacing-free name); the app collapses results that share it. */
    val chainGroup: ChainGroup? = null,
    val openNow: Boolean? = null,
    /** Complaints v1 badge (docs/api.md "Places"). */
    val badge: PlaceBadge? = null,
    /** Hidden for a moderator (near a restricted area or security details): "Sedang disemak" in My contributions. */
    val heldForReview: Boolean = false,
    /** Where a route to this place ends (its entrance); the display pin (lat/lng) is unchanged. */
    val navigationPoint: NavigationPoint? = null,
)

@Serializable
data class SearchResponse(
    val results: List<PlaceSummary> = emptyList(),
    /** Set when the server corrected the spelling ("famly mart" → "FamilyMart"); re-ask with exact=true to undo. */
    val correctedQuery: String? = null,
    /** "Mungkin anda maksudkan": shown when there are no (or few) results. */
    val suggestions: List<SearchSuggestion> = emptyList(),
    /** Nothing matched (then [suggestions] say what's nearby / did-you-mean). */
    val noMatch: Boolean = false,
    /** How the server read the query (informational). */
    val interpretation: SearchInterpretation? = null,
)

@Serializable
data class SearchInterpretation(val kind: String = "text", val normalized: String? = null, val area: String? = null)

/** Branches of the same chain: the app shows "FamilyMart · 12 berdekatan" (outlets within 10 km). */
@Serializable
data class ChainGroup(val key: String, val name: String = "", val countNearby: Int = 0)

/** A suggestion is either a new query (e.g. a category) or a place. Parsed leniently. */
@Serializable
data class SearchSuggestion(
    val label: String,
    val query: String? = null,
    val category: String? = null,
    val placeId: String? = null,
    val lat: Double? = null,
    val lng: Double? = null,
    val distanceM: Double? = null,
    val count: Int? = null,
)

@Serializable
data class Place(
    val id: String,
    val name: String,
    val category: String = "other",
    val address: String = "",
    val lat: Double,
    val lng: Double,
    val distanceM: Double? = null,
    val brand: String? = null,
    val phone: String? = null,
    val website: String? = null,
    val badge: PlaceBadge? = null,
    val openingHours: String? = null,
    val openNow: Boolean? = null,
    val amenities: List<String> = emptyList(),
    val tags: Map<String, String> = emptyMap(),
    val osmType: String? = null,
    val osmId: Long? = null,
    val source: String = "osm",
    val status: String? = null,
    val rating: Double? = null,
    val reviewCount: Int = 0,
    val thumbnailUrl: String? = null,
    val description: String? = null,
    val addedBy: Author? = null,
    val verifiedCount: Int = 0,
    val photos: List<Photo> = emptyList(),
    val confirmationsWeighted: Double? = null,
    val required: Double? = null,
    val rural: Boolean = false,
    val contributorTier: String? = null,
    /** Hidden for a moderator (docs/api.md "Restricted areas"). */
    val heldForReview: Boolean = false,
    /** Where a route to this place ends (its entrance); the display pin (lat/lng) is unchanged. */
    val navigationPoint: NavigationPoint? = null,
) {
    val isCommunity get() = source == "community"
    val isUnverified get() = isCommunity && status != "published"
    val isGold get() = contributorTier == "emas"
    fun summary() = PlaceSummary(id, name, category, address, lat, lng, distanceM, brand, source, status, rating, reviewCount, thumbnailUrl,
        confirmationsWeighted, required, rural, contributorTier, badge = badge, heldForReview = heldForReview, navigationPoint = navigationPoint)
}

@Serializable
data class Author(
    val displayName: String = "", val level: Int? = null, val reviewCount: Int? = null,
    /**
     * docs/api.md `authorRef`: opaque, stable per-contributor id (16 chars, an HMAC; not the user id or the pseudonym
     * key), the same on reviews, photos, community places and issues. Used only to block an author on this phone.
     * Absent when the author deleted their account.
     */
    val authorRef: String? = null,
)

@Serializable
data class Photo(
    val id: String,
    val url: String = "",
    val thumbUrl: String = "",
    val width: Int = 0,
    val height: Int = 0,
    val caption: String? = null,
    val uploadedBy: Author? = null,
    val createdAt: String? = null,
    val status: String? = null,   // processing | published | rejected
)

@Serializable
data class Review(
    val id: String,
    val placeId: String,
    val rating: Int,
    val text: String? = null,
    val photos: List<Photo> = emptyList(),
    val author: Author = Author(),
    val helpfulCount: Int = 0,
    val createdAt: String = "",
    val editedAt: String? = null,
    val status: String = "published",
    val mine: Boolean = false,          // client-side: written by this device's user
    /** Hidden until a moderator checks it (security details in the text). */
    val heldForReview: Boolean = false,
)

@Serializable
data class ReviewsPage(val reviews: List<Review> = emptyList(), val next: String? = null)

@Serializable
data class PhotosPage(val photos: List<Photo> = emptyList(), val next: String? = null)

@Serializable
data class ReviewRequest(val rating: Int, val text: String? = null, val photoIds: List<String>? = null)

@Serializable
data class FlagRequest(val reason: String)

@Serializable
data class CreatePlaceRequest(
    val name: String,
    val category: String,
    val lat: Double,
    val lng: Double,
    val address: String? = null,
    val description: String? = null,
    val phone: String? = null,
    val website: String? = null,
    val openingHours: String? = null,
    val amenities: List<String>? = null,
)

@Serializable
data class SuggestEditRequest(
    val name: String? = null,
    val category: String? = null,
    val lat: Double? = null,
    val lng: Double? = null,
    val phone: String? = null,
    val website: String? = null,
    val openingHours: String? = null,
    val comment: String? = null,
)

@Serializable
data class SuggestionCreated(val suggestionId: String = "")

@Serializable
data class VerifyRequest(
    /** yes | no | unsure */
    val answer: String,
    val nameCorrect: Boolean? = null,
    val locationCorrect: Boolean? = null,
    val proximity: Proximity,
    val attestation: Attestation? = null,
) {
    @Serializable data class Proximity(val cell: String, val withinM: Int)
    @Serializable data class Attestation(val platform: String = "android", val token: String)
}

@Serializable
data class VerifyResult(val status: String = "pending", val confirmationsWeighted: Double = 0.0, val required: Double = 3.0)

// --- Feedback ---------------------------------------------------------------------------------

@Serializable
data class FeedbackContext(
    val appVersion: String,
    val platform: String = "android",
    val osVersion: String,
    val deviceModel: String,
    val locale: String,
    val lat: Double? = null,
    val lng: Double? = null,
    val routeId: String? = null,
    val placeId: String? = null,
)

/** `device` block on feedback (only when the user ticked "Sertakan maklumat peranti") and crash reports. */
@Serializable
data class DeviceInfo(
    val appVersion: String,
    val appBuild: Int,
    val platform: String = "android",
    val osVersion: String,
    val apiLevel: Int,
    val deviceModel: String,
    val manufacturer: String,
    val screen: ScreenInfo,
    val locale: String,
    val theme: String,
    val dataMode: String,
    /** precise | approximate | none (never coordinates). */
    val locationPermission: String? = null,
    /** Accuracy of the last fix in metres (never the fix itself). */
    val lastFixAccuracyM: Int? = null,
) {
    @Serializable data class ScreenInfo(val widthPx: Int, val heightPx: Int, val density: Float, val widthDp: Int, val heightDp: Int)
}

/** Rounded to 2 dp on the phone; only with the separate "Sertakan lokasi kasar" tick. */
@Serializable
data class CoarseLocation(val lat: Double, val lng: Double)

/** Volunteered for ONE report only (docs/api.md "Contact details"); never prefilled, never stored beyond the outbox item. */
@Serializable
data class ContactDetails(val email: String? = null, val whatsapp: String? = null, val consent: Boolean = true)

@Serializable
data class FeedbackRequest(
    val category: String,
    val message: String,
    val rating: Int? = null,
    val screen: String,
    val device: DeviceInfo? = null,
    val location: CoarseLocation? = null,
    val contact: ContactDetails? = null,
    val routeId: String? = null,
    val placeId: String? = null,
    val screenshot: String? = null,
)

@Serializable
data class CrashReportRequest(
    val occurredAt: String,
    /** crash | anr | native | hang */
    val kind: String,
    val exception: String,
    val message: String? = null,
    val stack: String,
    val threads: String? = null,
    val screen: String? = null,
    val uptimeS: Long? = null,
    /** Opt-in (docs/api.md: default OFF, shown in the preview); null when not ticked. */
    val device: DeviceInfo? = null,
    val contact: ContactDetails? = null,
)

@Serializable
/** [contactToken]: only when the report carries a volunteered contact (it is then stored without the user id). */
data class CrashCreated(val id: String = "", val signature: String? = null, val contactToken: String? = null)

@Serializable
/** [contactToken]: returned once when the feedback carries a contact; kept on the phone to withdraw it later. */
data class FeedbackCreated(val id: String, val createdAt: String = "", val contactToken: String? = null)

@Serializable
data class FeedbackSummary(val id: String, val category: String, val message: String, val status: String = "received", val createdAt: String = "", val hasContact: Boolean = false)

@Serializable
data class ReverseGeocode(
    val name: String,
    val address: String = "",
    val lat: Double,
    val lng: Double,
    /** Known places within 50 m, nearest first: "Adakah ini …?". */
    val nearby: List<PlaceSummary> = emptyList(),
    /** "Dekat 18, Jalan SS 2/24, SS2, Petaling Jaya" (request language). */
    val label: String? = null,
    val houseNumber: String? = null,
    val street: String? = null,
    val area: String? = null,
    val city: String? = null,
    val postcode: String? = null,
)

@Serializable
data class LatLngDto(val lat: Double, val lng: Double, val placeId: String? = null, val name: String? = null)

@Serializable
data class AvoidOptions(val tolls: Boolean = false, val highways: Boolean = false, val ferries: Boolean = false)

@Serializable
data class RouteRequest(
    val origin: LatLngDto,
    val destination: LatLngDto,
    val waypoints: List<LatLngDto> = emptyList(),
    val vehicle: String = "car",
    val avoid: AvoidOptions = AvoidOptions(),
    val departAt: String? = null,
    val alternatives: Int = 2,
    /** "Lalu juga": recompute without these issues' exclusions, for this trip only. */
    val ignoreIssues: List<String>? = null,
)

@Serializable
data class RoutesResponse(val routes: List<Route> = emptyList())

@Serializable
data class Route(
    val id: String,
    val label: String = "alternative",
    val durationS: Double,
    val distanceM: Double,
    val trafficDurationS: Double? = null,
    val summary: String = "",
    val trafficDescription: String? = null,
    val vehicle: String? = null,
    val hasTolls: Boolean = false,
    val tollEstimateMyr: Double? = null,
    val tollFareComplete: Boolean = false,
    val tolls: List<TollPlaza> = emptyList(),
    /** A place destination routed to its entrance (docs/api.md "Arriving at the entrance"). */
    val arrival: NavigationPoint? = null,
    val polyline: String,
    val bbox: List<Double> = emptyList(),
    val legs: List<Leg> = emptyList(),
    val trafficSegments: List<TrafficSegment> = emptyList(),
    /** Complaints v1: issues on this route or avoided by it. */
    val issues: List<RouteIssue> = emptyList(),
    val alerts: List<AlertOnRoute> = emptyList(),
) {
    val isBest get() = label == "best"
    val effectiveDurationS get() = trafficDurationS ?: durationS
    val maneuvers get() = legs.flatMap { it.maneuvers }
}

@Serializable
data class Leg(
    val maneuvers: List<Maneuver> = emptyList(),
    val durationS: Double? = null,
    val distanceM: Double? = null,
    val to: LegTarget? = null,
)

@Serializable
data class LegTarget(val lat: Double, val lng: Double, val name: String? = null)

/**
 * Where a route to a place ends (docs/api.md "Arriving at the entrance"). source: confirmed | osm_entrance | outline;
 * kind: the OSM entrance=* value ("main" first) when known.
 */
@Serializable
data class NavigationPoint(
    val lat: Double,
    val lng: Double,
    val issueId: String? = null,
    val source: String = "osm_entrance",
    val kind: String? = null,
)

@Serializable
data class TollPlaza(
    val plazaId: String = "",
    val name: String = "",
    val highway: String? = null,
    val lat: Double = 0.0,
    val lng: Double = 0.0,
    val fareMyr: Double? = null,
    val system: String = "open",   // open | closed_entry | closed_exit
    val source: String? = null,
    /** Metres from the route start to the plaza (docs/api.md): drives the "toll ahead" alert. Absent from older servers. */
    val distanceAlongRouteM: Double? = null,
)

@Serializable
data class Maneuver(
    val type: String,
    val instruction: String = "",
    val streetName: String? = null,
    val exitNumber: String? = null,
    val roadRef: String? = null,
    val distanceM: Double = 0.0,
    val durationS: Double = 0.0,
    val beginShapeIndex: Int = 0,
    val endShapeIndex: Int = 0,
    val verbalPre: String? = null,
    val verbalPost: String? = null,
)

@Serializable
data class TrafficSegment(val fromIndex: Int, val toIndex: Int, val level: Int)

@Serializable
data class ReportedBy(val displayName: String = "", val mood: String? = null)

@Serializable
data class Report(
    val id: String,
    val type: String,
    val subtype: String? = null,
    val lat: Double,
    val lng: Double,
    val heading: Double? = null,
    val street: String? = null,
    val reportedBy: ReportedBy? = null,
    val createdAt: String,
    val expiresAt: String,
    val confirmations: Int = 0,
    val thanks: Int = 0,
    val comment: String? = null,
) {
    val point get() = GeoPoint(lat, lng)
}

/** Report + distanceAlongRouteM (flattened, as the API returns it). */
@Serializable
data class AlertOnRoute(
    val id: String,
    val type: String,
    val subtype: String? = null,
    val lat: Double,
    val lng: Double,
    val heading: Double? = null,
    val street: String? = null,
    val reportedBy: ReportedBy? = null,
    val createdAt: String,
    val expiresAt: String,
    val confirmations: Int = 0,
    val thanks: Int = 0,
    val distanceAlongRouteM: Double = 0.0,
) {
    fun toReport() = Report(id, type, subtype, lat, lng, heading, street, reportedBy, createdAt, expiresAt, confirmations, thanks)
}

@Serializable
data class RerouteRequest(val lat: Double, val lng: Double, val heading: Double?, val nextStopIndex: Int? = null)

@Serializable
data class DepartureSlot(val departAt: String, val durationS: Double)

@Serializable
data class DepartureTimesResponse(val slots: List<DepartureSlot> = emptyList())

@Serializable
data class Jam(
    val id: String,
    val level: Int,
    val speedKmh: Double = 0.0,
    val delayS: Double = 0.0,
    val lengthM: Double = 0.0,
    val polyline: String,
    val street: String? = null,
    val updatedAt: String? = null,
)

@Serializable
data class Driver(val lat: Double, val lng: Double, val heading: Double? = null, val mood: String? = null)

@Serializable
data class LiveResponse(
    val alerts: List<Report> = emptyList(),
    val jams: List<Jam> = emptyList(),
    val drivers: List<Driver> = emptyList(),
    val serverTime: String? = null,
)

@Serializable
data class CreateReportRequest(
    val type: String,
    val subtype: String? = null,
    val lat: Double,
    val lng: Double,
    val heading: Double? = null,
    val comment: String? = null,
)

@Serializable
data class VoteRequest(val stillThere: Boolean)

@Serializable
data class LocationPoint(
    val lat: Double,
    val lng: Double,
    val speedKmh: Double,
    val heading: Double?,
    val accuracyM: Double?,
    val ts: String,
)

@Serializable
data class LocationBatch(val routeId: String?, val points: List<LocationPoint>)

@Serializable
data class ProblemDetails(
    val type: String? = null,
    val title: String? = null,
    val status: Int? = null,
    val detail: String? = null,
    @SerialName("errors") val errors: JsonElement? = null,
    /** Machine-readable reason, e.g. `restricted_area` (docs/api.md "Restricted areas"). */
    val code: String? = null,
)


/**
 * Inbox: news about the user's PUBLIC contributions only (place published/rejected, report thanks,
 * review marked helpful, edit accepted, feedback status) and app announcements. GET /me/inbox.
 * Parsed leniently until the contract is final.
 */
@Serializable
data class InboxItem(
    val id: String,
    val kind: String = "announcement",
    val title: String = "",
    val body: String = "",
    val createdAt: String = "",
    val placeId: String? = null,
)
