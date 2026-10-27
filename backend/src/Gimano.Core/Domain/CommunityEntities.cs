using Gimano.Core.Contracts;
using NetTopologySuite.Geometries;

namespace Gimano.Core.Domain;

/// <summary>A place added by a Gimano user (always public; private places never reach the server). Id is "c" + 32 hex.</summary>
public sealed class CommunityPlace
{
    public string Id { get; set; } = NewId();
    public required string Name { get; set; }
    public PlaceCategory Category { get; set; } = PlaceCategory.Other;
    public required Point Location { get; set; }
    public string Address { get; set; } = "";
    public string? Description { get; set; }
    public string? Phone { get; set; }
    public string? Website { get; set; }
    public string? OpeningHours { get; set; }
    public List<string> Amenities { get; set; } = [];
    public string Country { get; set; } = "MY";
    /// <summary>Kept for "my contributions", owner edits and owner-visible pending places; null after the owner deleted their account.</summary>
    public Guid? OwnerId { get; set; }
    public User? Owner { get; set; }
    public PlaceStatus Status { get; set; } = PlaceStatus.Pending;
    public int VerifiedCount { get; set; }
    public int RejectedCount { get; set; }
    /// <summary>Weighted "yes" needed (by the contributor's tier at creation: baharu 3, perak 2, emas 0 = immediate).</summary>
    public double RequiredConfirmations { get; set; } = 3;
    public double WeightedYes { get; set; }
    public double WeightedNo { get; set; }
    /// <summary>Emas places randomly sent for local audit while already published.</summary>
    public bool AuditOpen { get; set; }
    /// <summary>Rural places allow 5 km proximity for verification (1 km in towns).</summary>
    public bool Rural { get; set; }
    public DateTimeOffset? ResolvedAt { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
    /// <summary>Reports by users ("Report this place"); 3 hide it pending moderation, like reviews and photos.</summary>
    public int FlagCount { get; set; }
    /// <summary>Near a restricted area or with sensitive words: hidden until a maintainer decides (docs/api.md "Restricted areas").</summary>
    public bool HeldForReview { get; set; }

    // AI check (docs/api.md "Community places", Gimano.Core.Community.PlaceScreening).
    public Community.ScreeningState ScreeningState { get; set; }
    /// <summary>Reason codes, comma-separated (e.g. "spam" or "private_home").</summary>
    public string? ScreeningReasons { get; set; }
    public Community.ScreeningConfidence? ScreeningConfidence { get; set; }
    public DateTimeOffset? ScreenedAt { get; set; }
    /// <summary>Passed the check while still waiting for confirmations: shown in search with "not verified yet".</summary>
    public bool Listed { get; set; }
    /// <summary>The nearby place the contributor said this is not (answer to "Is it already on the map?").</summary>
    public string? SaidDifferentFrom { get; set; }
    /// <summary>The owner's note when asking a person to review a rejected place (once per place).</summary>
    public string? AppealNote { get; set; }
    public DateTimeOffset? AppealedAt { get; set; }
    /// <summary>Warnings the owner tagged (alcohol, gambling, tobacco), comma-separated (docs/content-safety.md "Place warnings").</summary>
    public string? OwnerWarnings { get; set; }
    /// <summary>All warnings shown: the owner's tags plus the AI check's sensitive_* codes and the brand watchlist, comma-separated.</summary>
    public string? Warnings { get; set; }

    public static string NewId() => "c" + Guid.CreateVersion7().ToString("N");
    public static bool IsCommunityId(string id) => id.Length == 33 && id[0] == 'c';
}

/// <summary>
/// A vetting vote. While the place is pending, <see cref="VoterId"/> is set (only to prevent double votes).
/// On resolution the row is unlinked: VoterId → null, VoterHash = hmac_sha256(perPlaceSalt, voterId), time → day.
/// Verifier identities are never returned by any API.
/// </summary>
public sealed class PlaceVote
{
    public long Id { get; set; }
    public required string PlaceId { get; set; }
    public Guid? VoterId { get; set; }
    public byte[]? VoterHash { get; set; }
    public Identity.VoteAnswer Answer { get; set; }
    public bool? NameCorrect { get; set; }
    public bool? LocationCorrect { get; set; }
    public double Weight { get; set; }
    /// <summary>Only the boolean attestation verdict (null = not checked / not configured).</summary>
    public bool? AttestationOk { get; set; }
    public DateTimeOffset? CreatedAt { get; set; }
    public DateOnly Day { get; set; }
}

/// <summary>Per-place salt for unlinking votes; deleted 30 days after the place resolves.</summary>
public sealed class PlaceSalt
{
    public required string PlaceId { get; set; }
    public required byte[] Salt { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? ResolvedAt { get; set; }
}

/// <summary>Raised when an audited Emas place fails its audit; a moderator sets Upheld.</summary>
public sealed class PlaceDispute
{
    public long Id { get; set; }
    public required string PlaceId { get; set; }
    public Guid? ContributorId { get; set; }
    public bool? Upheld { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? ResolvedAt { get; set; }
}

/// <summary>A pseudonym's Ed25519 public key. The newest non-revoked key is current.</summary>
public sealed class UserKey
{
    public long Id { get; set; }
    public Guid UserId { get; set; }
    public required byte[] PublicKey { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? RevokedAt { get; set; }
}

/// <summary>An iOS App Attest key attested for this pseudonym (public key + sign counter only).</summary>
public sealed class AppAttestKey
{
    public required string KeyId { get; set; }
    public Guid UserId { get; set; }
    public required byte[] PublicKey { get; set; }
    public long Counter { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public enum SuggestionStatus { Pending, Applied, Rejected }

/// <summary>A suggested edit to any place (OSM or community). OSM suggestions are map-data feedback for curators.</summary>
public sealed class PlaceSuggestion
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public required string PlaceId { get; set; }
    public Guid? UserId { get; set; }
    public required SuggestEditRequest Changes { get; set; }
    public SuggestionStatus Status { get; set; } = SuggestionStatus.Pending;
    public DateTimeOffset? AppliedAt { get; set; }
    public long[] StreetWayIds { get; set; } = [];
    public string? StreetOriginalName { get; set; }
    public int Confirmations { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public sealed class Review
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public required string PlaceId { get; set; }
    public Guid? UserId { get; set; }
    public User? User { get; set; }
    public int Rating { get; set; }
    public string? Text { get; set; }
    public ReviewStatus Status { get; set; } = ReviewStatus.Published;
    public int HelpfulCount { get; set; }
    public int FlagCount { get; set; }
    /// <summary>Sensitive words (security details): hidden until a maintainer decides.</summary>
    public bool HeldForReview { get; set; }
    /// <summary>Public content safety check (docs/content-safety.md): state, reason codes, the appeal. Default None = never checked.</summary>
    public Community.ContentState ModerationState { get; set; }
    public string? ModerationReasons { get; set; }
    public DateTimeOffset? ModeratedAt { get; set; }
    /// <summary>The author's note when asking a person to review a rejected item (once per item); shown only to maintainers.</summary>
    public string? AppealNote { get; set; }
    /// <summary>Private evidence images sent with the appeal (media keys, comma-separated); maintainers only, deleted 30 days after the decision.</summary>
    public string? AppealEvidence { get; set; }
    public DateTimeOffset? AppealedAt { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? EditedAt { get; set; }
}

public sealed class ReviewHelpful
{
    public Guid ReviewId { get; set; }
    public Guid UserId { get; set; }
}

public sealed class ReviewFlag
{
    public Guid ReviewId { get; set; }
    public Guid UserId { get; set; }
    public FlagReason Reason { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public sealed class Photo
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public required string PlaceId { get; set; }
    public Guid? ReviewId { get; set; }
    public Guid? UserId { get; set; }
    public User? User { get; set; }
    public string? Caption { get; set; }
    public PhotoStatus Status { get; set; } = PhotoStatus.Processing;
    /// <summary>Media keys (content hashes) of the processed WebP and its thumbnail.</summary>
    public string? Key { get; set; }
    public string? ThumbKey { get; set; }
    /// <summary>Temporary key of the original upload; deleted after processing.</summary>
    public string? UploadKey { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
    public string? RejectReason { get; set; }
    public int FlagCount { get; set; }
    /// <summary>Public content safety check (docs/content-safety.md): state, reason codes, the appeal. Default None = never checked.</summary>
    public Community.ContentState ModerationState { get; set; }
    public string? ModerationReasons { get; set; }
    public DateTimeOffset? ModeratedAt { get; set; }
    /// <summary>The author's note when asking a person to review a rejected item (once per item); shown only to maintainers.</summary>
    public string? AppealNote { get; set; }
    /// <summary>Private evidence images sent with the appeal (media keys, comma-separated); maintainers only, deleted 30 days after the decision.</summary>
    public string? AppealEvidence { get; set; }
    public DateTimeOffset? AppealedAt { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

/// <summary>One report of a community place per user (POST /places/{id}/flag).</summary>
public sealed class PlaceFlag
{
    public required string PlaceId { get; set; }
    public Guid UserId { get; set; }
    public FlagReason Reason { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

/// <summary>
/// One report of an OSM (map data) place per user (POST /places/{id}/flag): the public OSM id, the reason and the warnings the user
/// suggests (alcohol, gambling, tobacco). No location and nothing else; deleted with the account. Shown to maintainers.
/// </summary>
public sealed class OsmPlaceFlag
{
    public required string PlaceId { get; set; }
    public Guid UserId { get; set; }
    public FlagReason Reason { get; set; }
    /// <summary>Suggested warnings, comma-separated (alcohol, gambling, tobacco); null when none.</summary>
    public string? SuggestedWarnings { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public enum AppealKind { Review, Photo, Place }

public enum AppealStatus { Pending, Approved, Denied }

/// <summary>
/// An appeal from POST /api/v1/appeals (docs/content-safety.md "Appeals"): the refused text the user chose to resubmit, the reason codes,
/// the compulsory note and up to three private evidence images. One per (user, refusal id). The text, note and images are deleted 30 days
/// after the decision (the row stays so the same refusal can't be appealed twice) and with the account. Never published.
/// </summary>
public sealed class ContentAppeal
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    /// <summary>The client's id of the refusal (a UUID the app made when the content was refused). For photo appeals it is the id of the refused photo.</summary>
    public Guid RefusalId { get; set; }
    public Guid UserId { get; set; }
    public AppealKind Kind { get; set; }
    public required string PlaceId { get; set; }
    /// <summary>Review appeals: the rating the refused review carried.</summary>
    public int? Rating { get; set; }
    public string? Text { get; set; }
    /// <summary>Reason codes of the refusal, comma-separated.</summary>
    public string? Reasons { get; set; }
    public string Note { get; set; } = "";
    /// <summary>Media keys of the evidence images (appeals/{id}/{n}), comma-separated.</summary>
    public string? EvidenceKeys { get; set; }
    public AppealStatus Status { get; set; } = AppealStatus.Pending;
    /// <summary>Review appeals, once approved: the review that was created.</summary>
    public Guid? ReviewId { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? DecidedAt { get; set; }
    /// <summary>Set when the text, note and images were deleted (30 days after the decision).</summary>
    public DateTimeOffset? ScrubbedAt { get; set; }
}

public sealed class PhotoFlag
{
    public Guid PhotoId { get; set; }
    public Guid UserId { get; set; }
    public FlagReason Reason { get; set; }
}

/// <summary>Inland water areas (OSM natural=water, waterway=riverbank, landuse=reservoir closed ways) for the "not in water" check.</summary>
public sealed class WaterArea
{
    public long Id { get; set; }
    public long OsmWayId { get; set; }
    public required Polygon Geom { get; set; }
}

/// <summary>
/// Where a driver should arrive for a map place (docs/api.md "Arriving at the entrance"): an OSM entrance node on the
/// building outline (<c>osm_entrance</c>), else the outline point nearest the closest named road (<c>outline</c>).
/// Rebuilt by every import. A confirmed place_entrance_wrong correction still wins.
/// </summary>
public sealed class PlaceEntrance
{
    public required string PlaceId { get; set; }
    public required Point Location { get; set; }
    public required string Source { get; set; }
    /// <summary>OSM entrance=* value (main, yes, service, …) for osm_entrance; null for outline.</summary>
    public string? Kind { get; set; }
}

/// <summary>
/// Military, strategic and other sensitive sites where no community content is accepted (docs/api.md "Restricted areas").
/// OSM rows are rebuilt by every import; curated rows (shelters, safe houses, sites OSM doesn't tag) are kept and are
/// checked on the server only: <see cref="Public"/> = false is never sent to phones.
/// </summary>
public sealed class RestrictedArea
{
    public long Id { get; set; }
    /// <summary>OSM way id (positive) or relation id (negative); null for curated rows.</summary>
    public long? OsmId { get; set; }
    public bool Curated { get; set; }
    public bool Public { get; set; } = true;
    public required Polygon Geom { get; set; }
}

/// <summary>A notification about the user's own public contributions (privacy rule: nothing private). Kept 90 days.</summary>
public sealed class InboxItem
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public Guid UserId { get; set; }
    public InboxKind Kind { get; set; }
    public required string Title { get; set; }
    public string Body { get; set; } = "";
    /// <summary>The place name / status the text is about, so Title/Body can be re-rendered in the reader's language.</summary>
    public string? Subject { get; set; }
    public string? RefType { get; set; }
    public string? RefId { get; set; }
    /// <summary>Daily aggregation key, e.g. "report_thanked:2026-10-23" ("24 drivers thanked you").</summary>
    public string? AggregateKey { get; set; }
    public int Count { get; set; } = 1;
    /// <summary>content_* items: the place the review/photo belongs to, the fixed reason codes (comma-separated) and whether an appeal is still open.</summary>
    public string? PlaceId { get; set; }
    public string? Reasons { get; set; }
    public bool? CanAppeal { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

/// <summary>
/// One AI rejection of a review, photo or report note (nothing else: no text, no image). Counted for the "3 rejections in 24 h pause
/// posting for 24 h" rule together with rejected places; rows older than two days are deleted.
/// </summary>
public sealed class ContentRejection
{
    public long Id { get; set; }
    public Guid UserId { get; set; }
    public DateTimeOffset At { get; set; }
}

/// <summary>Broadcast to everyone (inserted by operators; see docs/api.md "Inbox").</summary>
public sealed class Announcement
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public required string Title { get; set; }
    public string Body { get; set; } = "";
    public string? TitleMs { get; set; }
    public string? BodyMs { get; set; }
    public string? Url { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? ExpiresAt { get; set; }
}

/// <summary>An OSM house address (addr:housenumber + addr:street) for street-level search and reverse geocoding. Public map data.</summary>
public sealed class StreetAddress
{
    /// <summary>OSM id with type prefix ("n123", "w456").</summary>
    public required string Id { get; set; }
    public required string HouseNumber { get; set; }
    public required string Street { get; set; }
    public string? Postcode { get; set; }
    public string? City { get; set; }
    public string Country { get; set; } = "MY";
    public required Point Location { get; set; }
}

/// <summary>
/// Anonymous zero-result search counts (docs/api.md "Search misses"): scrubbed query text, ~11 km cell, ISO week, count.
/// No user, token, IP or exact location. Rows with count &lt; 5 are dropped after their week.
/// </summary>
public sealed class SearchMiss
{
    public required string Query { get; set; }
    /// <summary>"3.1,101.6" (lat/lng floored to 0.1°) or "" when the search had no location.</summary>
    public required string Cell { get; set; }
    /// <summary>ISO week, "2026-W43".</summary>
    public required string Week { get; set; }
    public int Count { get; set; }
}

/// <summary>An OSM administrative boundary (admin_level 4–8) for "which city is this point in" (reverse geocoding). Public map data.</summary>
public sealed class AdminArea
{
    public long Id { get; set; }
    public required string Name { get; set; }
    public int AdminLevel { get; set; }
    public required MultiPolygon Geom { get; set; }
}
