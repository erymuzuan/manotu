namespace Gimano.Core.Contracts;

// ---- Auth & profile -------------------------------------------------------

public sealed record DeviceAuthRequest(string DeviceId, Platform Platform, string? Locale);
public sealed record DeviceAuthResponse(string Token, Guid UserId, string DisplayName);

public sealed record UserDto(Guid Id, string DisplayName, string Mood, Vehicle Vehicle, int Points, int Level, DateTimeOffset JoinedAt,
    Tier Tier = Tier.Baharu, double? Accuracy = null, int PlacesAccepted = 0, int VerifierVotes = 0, NextTierDto? NextTier = null,
    DateTimeOffset? SuspendedUntil = null);

public sealed record NextTierDto(Tier Name, IReadOnlyList<string> Missing);

// ---- Identity (docs/identity-and-reputation.md) -------------------------------------------

public sealed record RegisterRequest(string PublicKey, Platform Platform, string? Locale);
/// <summary>Either {userId, ts, sig} (known account) or {publicKey, ts, sig} (recovery: the account that owns the key).</summary>
public sealed record TokenRequest(Guid? UserId, long Ts, string Sig, string? PublicKey = null);
public sealed record TokenResponse(string Token, Guid UserId, string DisplayName);
public sealed record AttachKeyRequest(string PublicKey, string? SigByOldKey);
public sealed record PatchMeRequest(string? DisplayName, string? Mood, Vehicle? Vehicle, string? Locale);

// ---- Saved places ---------------------------------------------------------

public sealed record SavedPlaceDto(Guid Id, SavedPlaceKind Kind, string Name, FavoriteIcon Icon, double Lat, double Lng, string Address, string? PlaceId, int SortOrder);
public sealed record SavePlaceRequest(string Name, double Lat, double Lng, string? Address, string? PlaceId, FavoriteIcon? Icon = null);
public sealed record PatchPlaceRequest(string? Name, FavoriteIcon? Icon, double? Lat, double? Lng, string? Address, int? SortOrder);
public sealed record RecentDto(Guid Id, string Name, string Address, double Lat, double Lng, string? PlaceId, DateTimeOffset LastUsedAt);

// ---- Search & places ------------------------------------------------------

public sealed record PlaceSummary(
    string Id, string Name, PlaceCategory Category, string Address, double Lat, double Lng, double? DistanceM, string? Brand,
    PlaceSource Source = PlaceSource.Osm, PlaceStatus? Status = null, double? Rating = null, int ReviewCount = 0, string? ThumbnailUrl = null,
    double? ConfirmationsWeighted = null, double? Required = null, ChainGroup? ChainGroup = null, bool? OpenNow = null,
    double? AnchorDistanceM = null, PlaceBadge? Badge = null, bool HeldForReview = false, PlaceScreeningDto? Screening = null);

/// <summary>
/// A place's open complaint, for the card/list badge: "Dilaporkan tutup · sahkan?" (suspected place_closed_perm),
/// "Tutup sementara sehingga …" (until), "Waktu mungkin berubah" (place_hours_wrong). The app words it from kind+state.
/// </summary>
public sealed record PlaceBadge(Guid IssueId, IssueKind Kind, IssueState State, string Label, string? Until = null);

/// <summary>Several results of one chain ("FamilyMart · 12 berdekatan"): <c>countNearby</c> = outlets within 10 km of the search origin.</summary>
public sealed record ChainGroup(string Key, string Name, int CountNearby);

public sealed record PlaceDto(
    string Id, string Name, PlaceCategory Category, string Address, double Lat, double Lng, double? DistanceM, string? Brand,
    string? Phone, string? Website, string? OpeningHours, bool? OpenNow,
    IReadOnlyList<string> Amenities, IReadOnlyDictionary<string, string> Tags, string? OsmType, long? OsmId,
    PlaceSource Source = PlaceSource.Osm, PlaceStatus? Status = null, double? Rating = null, int ReviewCount = 0, string? ThumbnailUrl = null,
    string? Description = null, AddedBy? AddedBy = null, int VerifiedCount = 0, IReadOnlyList<PhotoDto>? Photos = null,
    PlaceBadge? Badge = null, NavigationPoint? NavigationPoint = null, bool HeldForReview = false, PlaceScreeningDto? Screening = null,
    double? ConfirmationsWeighted = null, double? Required = null);

/// <summary>
/// Route here instead of the display pin. source: confirmed (a confirmed place_entrance_wrong, IssueId set), osm_entrance
/// (an OSM entrance node; Kind = its entrance=* value) or outline (the outline point nearest the closest named road).
/// </summary>
public sealed record NavigationPoint(double Lat, double Lng, Guid? IssueId, string Source = "confirmed", string? Kind = null);

/// <param name="AuthorRef">Opaque, stable per-author id for on-device blocking (AuthorHandles); null when the author deleted their account.</param>
public sealed record AddedBy(string DisplayName, string? AuthorRef = null);

// ---- Community places --------------------------------------------------------

/// <param name="NotDuplicateOf">The id from a 409 "Is it already on the map?" that the user said is a different place.</param>
public sealed record CreatePlaceRequest(
    string Name, PlaceCategory? Category, double Lat, double Lng, string? Address, string? Description,
    string? Phone, string? Website, string? OpeningHours, IReadOnlyList<string>? Amenities, string? NotDuplicateOf = null);

/// <summary>Ask a person to review a place the AI check didn't accept (once per place).</summary>
public sealed record AppealPlaceRequest(string? Note);

/// <summary>
/// The AI check, for the owner (absent for other viewers). state: none | checking | passed | held | rejected | skipped;
/// reasons: fixed codes the apps translate; canAppeal: rejected and not yet appealed.
/// </summary>
public sealed record PlaceScreeningDto(Community.ScreeningState State, IReadOnlyList<string> Reasons, bool CanAppeal, bool Appealed);

public sealed record PatchCommunityPlaceRequest(
    string? Name, PlaceCategory? Category, double? Lat, double? Lng, string? Address, string? Description,
    string? Phone, string? Website, string? OpeningHours, IReadOnlyList<string>? Amenities);

public sealed record SuggestEditRequest(
    string? Name, PlaceCategory? Category, double? Lat, double? Lng, string? Address, string? Phone, string? Website,
    string? OpeningHours, string? Description, bool? Closed, string? Comment);

public sealed record SuggestionAccepted(Guid SuggestionId);

public sealed record ProximityClaim(string Cell, int WithinM);
public sealed record AttestationClaim(Platform Platform, string Token);
public sealed record VerifyPlaceRequest(
    Identity.VoteAnswer? Answer, bool? NameCorrect, bool? LocationCorrect, ProximityClaim? Proximity, AttestationClaim? Attestation,
    // Legacy shape (pre-vetting apps): {exists, correctLocation}
    bool? Exists = null, bool? CorrectLocation = null);
public sealed record VerifyResult(PlaceStatus Status, double ConfirmationsWeighted, double Required);

// ---- Reviews & photos ----------------------------------------------------------

/// <param name="AuthorRef">Opaque, stable per-author id for on-device blocking (see <see cref="AddedBy"/>).</param>
public sealed record ReviewAuthor(string DisplayName, int Level, int ReviewCount, string? AuthorRef = null);

public sealed record ReviewDto(
    Guid Id, string PlaceId, int Rating, string? Text, IReadOnlyList<PhotoDto> Photos, ReviewAuthor Author,
    int HelpfulCount, DateTimeOffset CreatedAt, DateTimeOffset? EditedAt, ReviewStatus Status, bool HeldForReview = false);

public sealed record ReviewsPage(IReadOnlyList<ReviewDto> Reviews, string? Next);

public sealed record CreateReviewRequest(int Rating, string? Text, IReadOnlyList<Guid>? PhotoIds);

public sealed record PatchReviewRequest(int? Rating, string? Text, IReadOnlyList<Guid>? PhotoIds);

public sealed record FlagRequest(FlagReason Reason);

public sealed record PhotoDto(
    Guid Id, string? Url, string? ThumbUrl, int Width, int Height, string? Caption, AddedBy UploadedBy, DateTimeOffset CreatedAt,
    PhotoStatus Status = PhotoStatus.Published);

public sealed record PhotosPage(IReadOnlyList<PhotoDto> Photos, string? Next);

/// <param name="CorrectedQuery">Set when nothing matched the query as typed and the results are for this spelling instead (off with exact=true).</param>
/// <param name="NoMatch">True when nothing matched (results empty); see suggestions.</param>
public sealed record SearchResponse(IReadOnlyList<PlaceSummary> Results, string? CorrectedQuery = null,
    IReadOnlyList<SearchSuggestion>? Suggestions = null, bool NoMatch = false, SearchInterpretation? Interpretation = null);

/// <summary>
/// A did-you-mean place (label, query, placeId, lat, lng, distanceM) or a nearby category (label, query, category, count within 5 km).
/// </summary>
public sealed record SearchSuggestion(string Label, string? Query = null, PlaceCategory? Category = null, string? PlaceId = null,
    double? Lat = null, double? Lng = null, double? DistanceM = null, int? Count = null);

/// <summary>
/// How the query was understood. kind: text | category | brand_area | category_area | street | address | postcode | coordinates | plus_code.
/// </summary>
public sealed record SearchInterpretation(string Kind, string Normalized, IReadOnlyList<PlaceCategory>? Categories = null,
    string? Area = null, double? AreaLat = null, double? AreaLng = null);

/// <summary>GET /geocode/reverse ("Pilih pada peta"): name/address as before, plus the street-level label and places within 50 m.</summary>
public sealed record ReverseGeocodeResponse(string Name, string Address, double Lat, double Lng,
    string? Label = null, string? HouseNumber = null, string? Street = null, string? Area = null, string? City = null, string? Postcode = null,
    IReadOnlyList<PlaceSummary>? Nearby = null);

// ---- Routing --------------------------------------------------------------

/// <summary>A route point. Waypoints may carry a display <c>Name</c> (used for the leg's <c>to.name</c>).</summary>
public sealed record LatLng(double Lat, double Lng, string? PlaceId = null, string? Name = null);
public sealed record AvoidOptions(bool Tolls = false, bool Highways = false, bool Ferries = false);

/// <param name="IgnoreIssues">"Lalu juga": confirmed issues not to avoid for this trip only.</param>
/// <param name="Store">false (Events, docs/events.md §6): stateless. Nothing is cached (no reroute), ids start with
/// <c>x-</c>, and up to 25 waypoints are allowed. Omitted/true keeps the default behaviour.</param>
public sealed record RouteRequest(
    LatLng Origin, LatLng Destination, IReadOnlyList<LatLng>? Waypoints, Vehicle? Vehicle,
    AvoidOptions? Avoid, DateTimeOffset? DepartAt, int? Alternatives, IReadOnlyList<Guid>? IgnoreIssues = null,
    bool? Store = null)
{
    /// <summary>Default true; only an explicit <c>"store": false</c> makes the request stateless.</summary>
    [System.Text.Json.Serialization.JsonIgnore] public bool Stored => Store ?? true;
}

/// <summary>POST /routes/match: a drawn line (2–5000 points, in drawing order) to snap to roads. Stateless.</summary>
public sealed record RouteMatchRequest(IReadOnlyList<MatchPoint?>? Points, Vehicle? Vehicle);

public sealed record MatchPoint(double Lat, double Lng);

/// <param name="Polyline">Encoded, precision 6 (same as routes).</param>
/// <param name="Unmatched">Inclusive input-point index ranges that matched no road.</param>
public sealed record RouteMatchResponse(string Polyline, double DistanceM, double DurationS, IReadOnlyList<UnmatchedRange> Unmatched);

public sealed record UnmatchedRange(int FromIndex, int ToIndex);

/// <summary><c>NextStopIndex</c>: index into the original waypoints of the next stop not yet reached (default 0).</summary>
public sealed record RerouteRequest(double Lat, double Lng, double? Heading, int? NextStopIndex = null);

public sealed record RoutesResponse(IReadOnlyList<RouteDto> Routes);

/// <param name="Reasons">Why this route is offered (empty when it is the only one shown).</param>
/// <param name="ViaRoads">Main roads (≥ 2 km) that only this route of the shown ones uses, longest first, at most 2.</param>
/// <param name="Hidden">Set on alternatives not worth offering; they come after the shown ones (a "Show anyway" list).</param>
public sealed record RouteDto(
    string Id, RouteLabel Label, double DurationS, double DistanceM, double TrafficDurationS,
    string Summary, string TrafficDescription, Vehicle Vehicle,
    bool HasTolls, decimal? TollEstimateMyr, bool TollFareComplete, IReadOnlyList<TollOnRoute> Tolls,
    string Polyline, double[] Bbox, IReadOnlyList<RouteLeg> Legs,
    IReadOnlyList<TrafficSegment> TrafficSegments, IReadOnlyList<AlertOnRoute> Alerts, IReadOnlyList<RouteIssue>? Issues = null,
    NavigationPoint? Arrival = null, IReadOnlyList<RouteReason>? Reasons = null, IReadOnlyList<string>? ViaRoads = null,
    RouteHidden? Hidden = null);

/// <summary>
/// An issue relevant to a route. avoided = true: a confirmed closure/no-road the route goes around ("Mengelak Jln X");
/// avoided = false: a suspected or warn-only issue the route passes (show a warning; distanceAlongRouteM says where).
/// </summary>
public sealed record RouteIssue(Guid Id, IssueKind Kind, string? Subtype, IssueState State, bool Avoided, string Summary,
    int Confirmations, DateTimeOffset LastEvidenceAt, IssueSegment? Segment, double Lat, double Lng, double? DistanceAlongRouteM);

// ---- Issues (docs/complaints.md) ----------------------------------------------------

public sealed record IssueSegment(long WayId, int Seq, string? Name, string? Highway, IssueDirection Direction);

/// <param name="Payload">Kind-specific: until (yyyy-MM-dd), openingHours, navLat/navLng, name/category/phone/website,
/// duplicateOf, toLat/toLng (turn), from/to + chosen/taken (odd_route), trace [[lat,lng],…] (new_road).</param>
public sealed record CreateIssueRequest(IssueKind? Kind, string? Subtype, double Lat, double Lng, double? Heading, string? PlaceId,
    Vehicle? Vehicle, string? DurationHint, IssueSource? Source, System.Text.Json.Nodes.JsonObject? Payload);

public sealed record IssueVoteRequest(IssueAnswer? Answer, ProximityClaim? Proximity);

public sealed record IssueVoteResult(IssueState State, double ConfirmationsWeighted, double RefutationsWeighted, double Required);

public sealed record IssueDto(
    Guid Id, IssueKind Kind, string? Subtype, IssueState State, IssueSource Source, double Lat, double Lng, IssueDirection Direction,
    IssueSegment? Segment, string? PlaceId, Vehicle? Vehicle, string Summary,
    double ConfirmationsWeighted, double RefutationsWeighted, double Required, int StillVotes, int ClearedVotes, double Confidence,
    DateTimeOffset CreatedAt, DateTimeOffset LastEvidenceAt, DateTimeOffset? ExpiresAt, DateTimeOffset? ConfirmedAt,
    AddedBy? ReportedBy, bool Mine, IssueAnswer? MyVote, IReadOnlyDictionary<string, string> Payload, bool Merged = false);

public sealed record IssuesResponse(IReadOnlyList<IssueDto> Issues);

public sealed record RouteLeg(double DurationS, double DistanceM, LegEnd To, IReadOnlyList<ManeuverDto> Maneuvers);

public sealed record LegEnd(double Lat, double Lng, string? Name);

/// <param name="DistanceAlongRouteM">Metres from the route start to the plaza (its first booth along the route), for the "toll ahead" alert.</param>
public sealed record TollOnRoute(string PlazaId, string Name, string? Highway, double Lat, double Lng, decimal? FareMyr, TollSystem System, string? Source,
    double? DistanceAlongRouteM = null);

public sealed record ManeuverDto(
    ManeuverType Type, string Instruction, string? StreetName, string? ExitNumber, string? RoadRef,
    double DistanceM, double DurationS, int BeginShapeIndex, int EndShapeIndex,
    string? VerbalPre, string? VerbalPost);

public sealed record TrafficSegment(int FromIndex, int ToIndex, int Level);

public sealed record DepartureSlot(DateTimeOffset DepartAt, double DurationS);
public sealed record DepartureTimesResponse(IReadOnlyList<DepartureSlot> Slots);

// ---- Reports / alerts -----------------------------------------------------

public sealed record ReportedBy(string DisplayName, string Mood);

public record ReportDto(
    Guid Id, ReportType Type, string? Subtype, double Lat, double Lng, double? Heading, string? Street,
    ReportedBy ReportedBy, DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt, int Confirmations, int Thanks);

/// <summary><c>AlertOnRoute = Report + {distanceAlongRouteM}</c></summary>
public sealed record AlertOnRoute(
    Guid Id, ReportType Type, string? Subtype, double Lat, double Lng, double? Heading, string? Street,
    ReportedBy ReportedBy, DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt, int Confirmations, int Thanks,
    double DistanceAlongRouteM)
{
    public static AlertOnRoute From(ReportDto r, double along) => new(
        r.Id, r.Type, r.Subtype, r.Lat, r.Lng, r.Heading, r.Street, r.ReportedBy, r.CreatedAt, r.ExpiresAt,
        r.Confirmations, r.Thanks, Math.Round(along, 1));
}

public sealed record CreateReportRequest(
    ReportType Type, string? Subtype, double Lat, double Lng, double? Heading, string? Comment,
    double? EndLat = null, double? EndLng = null);

public sealed record VoteRequest(bool StillThere);

// ---- Live -----------------------------------------------------------------

public sealed record JamDto(Guid Id, int Level, double SpeedKmh, double DelayS, double LengthM, string Polyline, string? Street, DateTimeOffset UpdatedAt);
public sealed record DriverDto(double Lat, double Lng, double Heading, string Mood);
public sealed record LiveResponse(IReadOnlyList<ReportDto> Alerts, IReadOnlyList<JamDto> Jams, IReadOnlyList<DriverDto> Drivers, DateTimeOffset ServerTime);

// ---- Location pings -------------------------------------------------------

public sealed record LocationPoint(double Lat, double Lng, double? SpeedKmh, double? Heading, double? AccuracyM, DateTimeOffset? Ts);
public sealed record LocationBatch(string? RouteId, IReadOnlyList<LocationPoint> Points);

// ---- Feedback ---------------------------------------------------------------

public sealed record FeedbackContext(
    string? AppVersion, string? Platform, string? OsVersion, string? DeviceModel, string? Locale,
    double? Lat, double? Lng, string? RouteId, string? PlaceId);

public sealed record DeviceScreenInfo(int? WidthPx, int? HeightPx, double? Density, int? WidthDp, int? HeightDp);

/// <summary>Consented device info (feedback: only when ticked; crash reports: always, shown in the preview).</summary>
public sealed record DeviceInfo(
    string? AppVersion, int? AppBuild, string? Platform, string? OsVersion, int? ApiLevel, string? DeviceModel, string? Manufacturer,
    DeviceScreenInfo? Screen, string? Locale, string? Theme, string? DataMode);

/// <summary>Coarse location, rounded to 2 dp on the phone (and again on the server).</summary>
public sealed record CoarseLocation(double Lat, double Lng);

/// <summary>Volunteered contact for ONE report: encrypted at rest, never linked to the pseudonym, auto-deleted.</summary>
public sealed record ContactDetails(string? Email, string? Whatsapp, bool Consent);

/// <param name="Context">Legacy 0.1.0 shape, mapped to Device/Location/RouteId/PlaceId.</param>
public sealed record CreateFeedbackRequest(
    FeedbackCategory Category, string Message, int? Rating = null, FeedbackScreen? Screen = null, FeedbackContext? Context = null,
    string? Screenshot = null, DeviceInfo? Device = null, CoarseLocation? Location = null, ContactDetails? Contact = null,
    string? RouteId = null, string? PlaceId = null);

public enum CrashKind { Crash, Anr, Native, Hang }

public sealed record CrashReportRequest(
    DateTimeOffset? OccurredAt, CrashKind Kind, string Exception, string? Message, string? Stack, string? Threads,
    string? Screen, long? UptimeS, DeviceInfo? Device, ContactDetails? Contact);

/// <param name="ContactToken">Only when a contact was stored: the capability to withdraw it (the report is then not linked to the account).</param>
public sealed record CrashReportCreated(Guid Id, string Signature, string? ContactToken = null);

/// <param name="ContactToken">Only when a contact was stored: the capability to withdraw it (the report is then not linked to the account).</param>
public sealed record FeedbackCreatedResponse(Guid Id, DateTimeOffset CreatedAt, string? ContactToken = null);

public sealed record FeedbackSummary(Guid Id, FeedbackCategory Category, string Message, FeedbackStatus Status, DateTimeOffset CreatedAt, bool HasContact = false);

// ---- Inbox (public contributions only) ----------------------------------------------------

public sealed record InboxItemDto(
    Guid Id, InboxKind Kind, string Title, string Body, string? RefType, string? RefId, DateTimeOffset CreatedAt,
    bool Read, int Count = 1);

public sealed record InboxPage(IReadOnlyList<InboxItemDto> Items, string? Next, int Unread);

public sealed record InboxReadRequest(DateTimeOffset UpTo);
