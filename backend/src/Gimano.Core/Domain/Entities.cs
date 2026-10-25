using Gimano.Core.Contracts;
using NetTopologySuite.Geometries;

namespace Gimano.Core.Domain;

public sealed class User
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    /// <summary>Legacy POST /auth/device accounts only; pseudonyms registered with a key have none.</summary>
    public string? DeviceId { get; set; }
    public Platform Platform { get; set; }
    public required string DisplayName { get; set; }
    public string Mood { get; set; } = "happy";
    public Vehicle Vehicle { get; set; } = Vehicle.Car;
    public string Locale { get; set; } = "ms-MY";
    public int Points { get; set; }
    /// <summary>Vote weight in [0.5, 2.0]; grows when the user's reports get confirmed.</summary>
    public double Reputation { get; set; } = 1.0;
    public DateTimeOffset JoinedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset LastSeenAt { get; set; } = DateTimeOffset.UtcNow;
    /// <summary>Inbox items created at or before this instant are read.</summary>
    public DateTimeOffset? InboxReadUpTo { get; set; }

    // ---- reputation ledger (docs/identity-and-reputation.md §3) ----
    public Tier Tier { get; set; } = Tier.Baharu;
    public int PlacesAccepted { get; set; }
    public int PlacesRejected { get; set; }
    public int PlacesDisputedUpheld { get; set; }
    public int VerifierVotes { get; set; }
    public int VerifierAgreed { get; set; }
    public DateTimeOffset? SuspendedUntil { get; set; }
    /// <summary>Banned by a moderator (abusive contributor): their public contributions are hidden and new ones are rejected.</summary>
    public DateTimeOffset? BannedAt { get; set; }
    public DateOnly? LastActiveDay { get; set; }
    /// <summary>Votes cast on <see cref="VotesDay"/> (≤ 20/day); kept here because resolved votes are unlinked.</summary>
    public DateOnly? VotesDay { get; set; }
    public int VotesToday { get; set; }

    public int Level => Points switch { < 100 => 1, < 500 => 2, < 2_000 => 3, < 10_000 => 4, < 50_000 => 5, _ => 6 };

    public UserDto ToDto() => new(Id, DisplayName, Mood, Vehicle, Points, Level, JoinedAt);
}

public sealed class SavedPlace
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public Guid UserId { get; set; }
    public SavedPlaceKind Kind { get; set; }
    public required string Name { get; set; }
    public required Point Location { get; set; }
    public string Address { get; set; } = "";
    public string? PlaceId { get; set; }
    public FavoriteIcon Icon { get; set; } = FavoriteIcon.Star;
    public int SortOrder { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;

    /// <summary>Home and work always carry their own icon.</summary>
    public FavoriteIcon EffectiveIcon => Kind switch
    {
        SavedPlaceKind.Home => FavoriteIcon.Home,
        SavedPlaceKind.Work => FavoriteIcon.Work,
        _ => Icon,
    };

    public SavedPlaceDto ToDto() => new(Id, Kind, Name, EffectiveIcon, Location.Y, Location.X, Address, PlaceId, SortOrder);
}

public sealed class RecentDestination
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public Guid UserId { get; set; }
    public required string Name { get; set; }
    public string Address { get; set; } = "";
    public required Point Location { get; set; }
    public string? PlaceId { get; set; }
    public DateTimeOffset LastUsedAt { get; set; } = DateTimeOffset.UtcNow;

    public RecentDto ToDto() => new(Id, Name, Address, Location.Y, Location.X, PlaceId, LastUsedAt);
}

/// <summary>A point of interest imported from OSM. Id is "{n|w|r}{osmId}", e.g. "n123456".</summary>
public sealed class Place
{
    public required string Id { get; set; }
    public required string Name { get; set; }
    public PlaceCategory Category { get; set; }
    public string? Brand { get; set; }
    public string Address { get; set; } = "";
    public required Point Location { get; set; }
    public string Country { get; set; } = "MY";
    public string? Phone { get; set; }
    public string? Website { get; set; }
    public string? OpeningHours { get; set; }
    public List<string> Amenities { get; set; } = [];
    public Dictionary<string, string> Tags { get; set; } = [];
    public required string OsmType { get; set; }
    public long OsmId { get; set; }
    public double Popularity { get; set; }
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public enum ReportStatus { Active, Expired }

public sealed class Report
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public ReportType Type { get; set; }
    public string? Subtype { get; set; }
    public required Point Location { get; set; }
    public Point? EndLocation { get; set; }
    public double? Heading { get; set; }
    public string? Street { get; set; }
    public string? Comment { get; set; }
    /// <summary>Null once the reporter deleted their account (the report stays, anonymised).</summary>
    public Guid? ReporterId { get; set; }
    public User? Reporter { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset ExpiresAt { get; set; }
    public int Confirmations { get; set; }
    public int Thanks { get; set; }
    public ReportStatus Status { get; set; } = ReportStatus.Active;
    public uint Version { get; set; }

    public ReportDto ToDto() => new(
        Id, Type, Subtype, Location.Y, Location.X, Heading, Street,
        new ReportedBy(Reporter?.DisplayName ?? "Pemandu Manotu", Reporter?.Mood ?? "happy"),
        CreatedAt, ExpiresAt, Confirmations, Thanks);
}

public sealed class ReportVote
{
    public Guid ReportId { get; set; }
    public Guid UserId { get; set; }
    public bool StillThere { get; set; }
    public double Weight { get; set; } = 1;
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

/// <summary>A road chunk (≤ ~300 m) of an OSM way, used for snapping pings and the traffic model.</summary>
public sealed class RoadSegment
{
    public long Id { get; set; }
    public long OsmWayId { get; set; }
    public int Seq { get; set; }
    public string? Name { get; set; }
    public string? Ref { get; set; }
    public required string Highway { get; set; }
    public bool Oneway { get; set; }
    public double FreeFlowKmh { get; set; }
    public double LengthM { get; set; }
    public long FromNode { get; set; }
    public long ToNode { get; set; }
    public required LineString Geom { get; set; }
}

/// <summary>Rolling 5-minute speed per road segment, maintained by the Worker.</summary>
public sealed class SegmentSpeed
{
    public long SegmentId { get; set; }
    public double MeanSpeedKmh { get; set; }
    public double FreeFlowKmh { get; set; }
    public int Samples { get; set; }
    public int DistinctUsers { get; set; }
    public int Level { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}

public sealed class Jam
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public int Level { get; set; }
    public double SpeedKmh { get; set; }
    public double DelayS { get; set; }
    public double LengthM { get; set; }
    public required LineString Geom { get; set; }
    public string? Street { get; set; }
    /// <summary>Stable identity of the merged jam: the lowest segment id in the run.</summary>
    public long AnchorSegmentId { get; set; }
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;

    public JamDto ToDto() => new(Id, Level, Math.Round(SpeedKmh, 1), Math.Round(DelayS), Math.Round(LengthM),
        Geo.Polyline.Encode(Geo.GeoMath.FromLineString(Geom)), Street, UpdatedAt);
}

public sealed class Feedback
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    /// <summary>Only for rate limiting and "My feedback"; null once the account is deleted.</summary>
    public Guid? UserId { get; set; }
    public FeedbackCategory Category { get; set; }
    public required string Message { get; set; }
    public int? Rating { get; set; }
    public FeedbackScreen? Screen { get; set; }
    /// <summary>Consented device info (jsonb).</summary>
    public DeviceInfo? Device { get; set; }
    /// <summary>Coarse location (2 dp), only with the separate consent tick.</summary>
    public double? Lat { get; set; }
    public double? Lng { get; set; }
    public string? RouteId { get; set; }
    public string? PlaceId { get; set; }
    /// <summary>Set when the status becomes done/wont_fix (drives contact deletion 30 days later).</summary>
    public DateTimeOffset? ClosedAt { get; set; }
    public byte[]? Screenshot { get; set; }
    public string? ScreenshotContentType { get; set; }
    public FeedbackStatus Status { get; set; } = FeedbackStatus.Received;
    public string? ExternalUrl { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;

    // Back-office triage (docs/back-office.md).
    public Severity? Severity { get; set; }
    public Guid? DuplicateOfId { get; set; }
    /// <summary>Linked crash group.</summary>
    public string? CrashSignature { get; set; }
    public string? TriageNote { get; set; }
    /// <summary>A maintainer shared this one screenshot with agent tokens.</summary>
    public bool ScreenshotSharedWithAgents { get; set; }
    public DateTimeOffset? UpdatedAt { get; set; }

    public FeedbackSummary ToSummary() => new(Id, Category, Message, Status, CreatedAt);
}

/// <summary>A row of data/tolls/my-toll-rates.csv, matched to OSM toll plaza place ids by the importer.</summary>
public sealed class TollRate
{
    public int Id { get; set; }
    public string? PlazaOsmId { get; set; }
    public required string Name { get; set; }
    public string? Highway { get; set; }
    public double? Lat { get; set; }
    public double? Lng { get; set; }
    public TollSystem System { get; set; }
    public string? EntryPlaza { get; set; }
    public decimal? Class0Myr { get; set; }
    public decimal? Class1Myr { get; set; }
    public DateOnly? EffectiveDate { get; set; }
    public string? SourceUrl { get; set; }
    public string? Notes { get; set; }
    public List<string> MatchedPlaceIds { get; set; } = [];
}

public enum ContactSubject { Feedback, Crash }

/// <summary>
/// Volunteered contact details for ONE report, encrypted with AES-GCM (key from config, never in the DB).
/// Keyed by the report, never by the user. Deleted 30 days after the report closes and at most 90 days after creation.
/// </summary>
public sealed class ReportContact
{
    public ContactSubject SubjectType { get; set; }
    public Guid SubjectId { get; set; }
    public required byte[] Nonce { get; set; }
    public required byte[] Ciphertext { get; set; }
    public string KeyId { get; set; } = "v1";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

/// <summary>
/// A crash group's lifecycle. Done and WontFix are closed (they start the 30-day contact clock).
/// <c>Regressed</c> = a group marked done in build n got a new crash from build n or later.
/// </summary>
public enum CrashGroupStatus { Open, Triaged, Fixing, Regressed, Done, WontFix }   // stored by name (string column)

/// <summary>One crash group per signature = sha256(exception + top 5 app frames).</summary>
public sealed class CrashGroup
{
    public required string Signature { get; set; }
    public required string Exception { get; set; }
    public int Count { get; set; }
    public DateTimeOffset FirstSeen { get; set; }
    public DateTimeOffset LastSeen { get; set; }
    public CrashGroupStatus Status { get; set; } = CrashGroupStatus.Open;
    public DateTimeOffset? ClosedAt { get; set; }

    // Back-office triage (docs/back-office.md). Platform/kind/versions come from the reports' consented device info.
    public string? Platform { get; set; }
    public CrashKind? Kind { get; set; }
    /// <summary>The latest report's scrubbed message.</summary>
    public string? Message { get; set; }
    /// <summary>The first app frame, for list titles.</summary>
    public string? TopFrame { get; set; }
    public Severity? Severity { get; set; }
    public string? FirstVersion { get; set; }
    public string? LatestVersion { get; set; }
    public int? LatestBuild { get; set; }
    /// <summary>App build the fix shipped in; a crash from this build or later reopens the group as regressed.</summary>
    public int? FixedInBuild { get; set; }
    public string? FixedInVersion { get; set; }
    /// <summary>Issue or PR on GitHub.</summary>
    public string? ExternalUrl { get; set; }
    public string? TriageNote { get; set; }
    /// <summary>Root-cause analysis written by an agent (markdown).</summary>
    public string? Analysis { get; set; }
    public string? AnalysisBy { get; set; }
    public DateTimeOffset? UpdatedAt { get; set; }

    public static bool IsClosed(CrashGroupStatus s) => s is CrashGroupStatus.Done or CrashGroupStatus.WontFix;
}

public sealed class CrashReport
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    /// <summary>Only for the per-user rate limit and DELETE /me.</summary>
    public Guid? UserId { get; set; }
    public required string Signature { get; set; }
    public CrashKind Kind { get; set; }
    public required string Exception { get; set; }
    public string? Message { get; set; }
    public string? Stack { get; set; }
    public string? Threads { get; set; }
    public string? Screen { get; set; }
    public long? UptimeS { get; set; }
    public DeviceInfo? Device { get; set; }
    public DateTimeOffset? OccurredAt { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

/// <summary>AI spend for one week (Malaysia time, from Monday): the place check's budget ledger. No content, no users.</summary>
public sealed class AiUsageWeek
{
    public DateOnly WeekStart { get; set; }
    public int Calls { get; set; }
    public long InputTokens { get; set; }
    public long OutputTokens { get; set; }
    public decimal CostUsd { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}
