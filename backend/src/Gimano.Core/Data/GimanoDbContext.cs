using Gimano.Core.Domain;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;
using Npgsql;

namespace Gimano.Core.Data;

public sealed class GimanoDbContext(DbContextOptions<GimanoDbContext> options) : DbContext(options)
{
    public DbSet<User> Users => Set<User>();
    public DbSet<SavedPlace> SavedPlaces => Set<SavedPlace>();
    public DbSet<RecentDestination> Recents => Set<RecentDestination>();
    public DbSet<Place> Places => Set<Place>();
    public DbSet<Report> Reports => Set<Report>();
    public DbSet<ReportVote> ReportVotes => Set<ReportVote>();
    public DbSet<RoadSegment> RoadSegments => Set<RoadSegment>();
    public DbSet<SegmentSpeed> SegmentSpeeds => Set<SegmentSpeed>();
    public DbSet<Jam> Jams => Set<Jam>();
    public DbSet<Feedback> Feedback => Set<Feedback>();
    public DbSet<PlaceFlag> PlaceFlags => Set<PlaceFlag>();
    public DbSet<TollRate> TollRates => Set<TollRate>();
    public DbSet<CommunityPlace> CommunityPlaces => Set<CommunityPlace>();
    public DbSet<PlaceVote> PlaceVotes => Set<PlaceVote>();
    public DbSet<PlaceSalt> PlaceSalts => Set<PlaceSalt>();
    public DbSet<PlaceDispute> PlaceDisputes => Set<PlaceDispute>();
    public DbSet<UserKey> UserKeys => Set<UserKey>();
    public DbSet<AppAttestKey> AppAttestKeys => Set<AppAttestKey>();
    public DbSet<PlaceSuggestion> PlaceSuggestions => Set<PlaceSuggestion>();
    public DbSet<Review> Reviews => Set<Review>();
    public DbSet<ReviewHelpful> ReviewHelpfuls => Set<ReviewHelpful>();
    public DbSet<ReviewFlag> ReviewFlags => Set<ReviewFlag>();
    public DbSet<Photo> Photos => Set<Photo>();
    public DbSet<PhotoFlag> PhotoFlags => Set<PhotoFlag>();
    public DbSet<WaterArea> WaterAreas => Set<WaterArea>();
    public DbSet<RestrictedArea> RestrictedAreas => Set<RestrictedArea>();
    public DbSet<PlaceEntrance> PlaceEntrances => Set<PlaceEntrance>();
    public DbSet<InboxItem> InboxItems => Set<InboxItem>();
    public DbSet<ReportContact> ReportContacts => Set<ReportContact>();
    public DbSet<CrashGroup> CrashGroups => Set<CrashGroup>();
    public DbSet<CrashReport> CrashReports => Set<CrashReport>();
    public DbSet<Announcement> Announcements => Set<Announcement>();
    public DbSet<StreetAddress> StreetAddresses => Set<StreetAddress>();
    public DbSet<SearchMiss> SearchMisses => Set<SearchMiss>();
    public DbSet<AdminArea> AdminAreas => Set<AdminArea>();
    public DbSet<Issue> Issues => Set<Issue>();
    public DbSet<IssueVote> IssueVotes => Set<IssueVote>();
    public DbSet<IssueSalt> IssueSalts => Set<IssueSalt>();
    public DbSet<SegmentTraversalCount> SegmentTraversalCounts => Set<SegmentTraversalCount>();
    public DbSet<AgentToken> AgentTokens => Set<AgentToken>();
    public DbSet<AuditEntry> AuditLog => Set<AuditEntry>();
    public DbSet<AiUsageWeek> AiUsageWeeks => Set<AiUsageWeek>();
    public DbSet<WatchedBrand> WatchedBrands => Set<WatchedBrand>();
    public DbSet<ContentRejection> ContentRejections => Set<ContentRejection>();
    public DbSet<ContentAppeal> ContentAppeals => Set<ContentAppeal>();
    public DbSet<OsmPlaceFlag> OsmPlaceFlags => Set<OsmPlaceFlag>();
    public DbSet<AgentRun> AgentRuns => Set<AgentRun>();
    public DbSet<ReplyDraft> ReplyDrafts => Set<ReplyDraft>();
    public DbSet<AppBuild> AppBuilds => Set<AppBuild>();
    public DbSet<Events.Drop> Drops => Set<Events.Drop>();
    public DbSet<AppVersions.AppRelease> AppReleases => Set<AppVersions.AppRelease>();
    public DbSet<AppVersions.AppVersionConfig> AppVersionConfigs => Set<AppVersions.AppVersionConfig>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        b.HasPostgresExtension("postgis");
        b.HasPostgresExtension("pg_trgm");

        b.Entity<User>(e =>
        {
            e.HasIndex(x => x.DeviceId).IsUnique().HasFilter("device_id IS NOT NULL");
            e.Property(x => x.DeviceId).HasMaxLength(200);
            e.Property(x => x.DisplayName).HasMaxLength(40);
            e.Property(x => x.Mood).HasMaxLength(30);
            e.Property(x => x.Locale).HasMaxLength(20);
            e.Property(x => x.Platform).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.Vehicle).HasConversion<string>().HasMaxLength(12);
            e.Property(x => x.Tier).HasConversion<string>().HasMaxLength(8);
            e.Ignore(x => x.Level);
        });

        b.Entity<SavedPlace>(e =>
        {
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.Icon).HasConversion<string>().HasMaxLength(12);
            e.Ignore(x => x.EffectiveIcon);
            e.Property(x => x.Location).HasColumnType("geography (point, 4326)");
            e.HasIndex(x => new { x.UserId, x.Kind });
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<RecentDestination>(e =>
        {
            e.ToTable("recents");
            e.Property(x => x.Location).HasColumnType("geography (point, 4326)");
            e.HasIndex(x => new { x.UserId, x.LastUsedAt });
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<Place>(e =>
        {
            e.Property(x => x.Id).HasMaxLength(24);
            e.Property(x => x.Category).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.Country).HasMaxLength(2);
            e.Property(x => x.OsmType).HasMaxLength(10);
            e.Property(x => x.Location).HasColumnType("geography (point, 4326)");
            e.Property(x => x.Tags).HasColumnType("jsonb");
            e.HasIndex(x => x.Location).HasMethod("gist");
            e.HasIndex(x => x.Category);
            e.HasIndex(x => x.Name).HasMethod("gin").HasOperators("gin_trgm_ops");
        });

        b.Entity<Report>(e =>
        {
            e.Property(x => x.Type).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.Status).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.Subtype).HasMaxLength(30);
            e.Property(x => x.Comment).HasMaxLength(500);
            e.Property(x => x.Location).HasColumnType("geography (point, 4326)");
            e.Property(x => x.EndLocation).HasColumnType("geography (point, 4326)");
            e.Property(x => x.Version).IsRowVersion();
            e.HasIndex(x => x.Location).HasMethod("gist");
            e.HasIndex(x => new { x.Status, x.ExpiresAt });
            e.HasOne(x => x.Reporter).WithMany().HasForeignKey(x => x.ReporterId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<ReportVote>(e =>
        {
            e.HasKey(x => new { x.ReportId, x.UserId });
            e.HasOne<Report>().WithMany().HasForeignKey(x => x.ReportId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<RoadSegment>(e =>
        {
            e.Property(x => x.Geom).HasColumnType("geography (linestring, 4326)");
            e.Property(x => x.Highway).HasMaxLength(20);
            e.HasIndex(x => x.Geom).HasMethod("gist");
            e.HasIndex(x => x.FromNode);
            e.HasIndex(x => x.ToNode);
            e.HasIndex(x => new { x.OsmWayId, x.Seq });
        });

        b.Entity<SegmentSpeed>(e =>
        {
            e.HasKey(x => x.SegmentId);
            e.HasIndex(x => x.UpdatedAt);
        });

        b.Entity<Jam>(e =>
        {
            e.Property(x => x.Geom).HasColumnType("geography (linestring, 4326)");
            e.HasIndex(x => x.Geom).HasMethod("gist");
            e.HasIndex(x => x.AnchorSegmentId);
        });

        b.Entity<Feedback>(e =>
        {
            e.ToTable("feedback");
            e.Property(x => x.Category).HasConversion<string>().HasMaxLength(12);
            e.Property(x => x.Screen).HasConversion<string>().HasMaxLength(16);
            e.Property(x => x.Status).HasConversion<string>().HasMaxLength(12);
            e.Property(x => x.Message).HasMaxLength(2000);
            e.Property(x => x.ScreenshotContentType).HasMaxLength(20);
            e.Property(x => x.ExternalUrl).HasMaxLength(300);
            e.Property(x => x.Device).HasColumnType("jsonb").HasConversion(DeviceJson.Converter, DeviceJson.Comparer);
            e.Property(x => x.RouteId).HasMaxLength(64);
            e.Property(x => x.PlaceId).HasMaxLength(40);
            e.Property(x => x.Severity).HasConversion<string>().HasMaxLength(4);
            e.Property(x => x.CrashSignature).HasMaxLength(64);
            e.Property(x => x.TriageNote).HasMaxLength(2000);
            e.HasIndex(x => x.CrashSignature);
            e.HasIndex(x => new { x.Status, x.ClosedAt });
            e.HasIndex(x => new { x.UserId, x.CreatedAt });
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<CommunityPlace>(e =>
        {
            e.Property(x => x.Id).HasMaxLength(40);
            e.Property(x => x.Name).HasMaxLength(100);
            e.Property(x => x.Category).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.Status).HasConversion<string>().HasMaxLength(12);
            e.Property(x => x.Country).HasMaxLength(2);
            e.Property(x => x.Description).HasMaxLength(1000);
            e.Property(x => x.Location).HasColumnType("geography (point, 4326)");
            e.HasIndex(x => x.Location).HasMethod("gist");
            e.HasIndex(x => x.Name).HasMethod("gin").HasOperators("gin_trgm_ops");
            e.HasIndex(x => new { x.OwnerId, x.CreatedAt });
            e.HasOne(x => x.Owner).WithMany().HasForeignKey(x => x.OwnerId).OnDelete(DeleteBehavior.SetNull);
            e.Property(x => x.ScreeningState).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.ScreeningConfidence).HasConversion<string>().HasMaxLength(8);
            e.Property(x => x.ScreeningReasons).HasMaxLength(160);
            e.Property(x => x.OwnerWarnings).HasMaxLength(40);
            e.Property(x => x.Warnings).HasMaxLength(40);
            e.Property(x => x.SaidDifferentFrom).HasMaxLength(40);
            e.Property(x => x.AppealNote).HasMaxLength(200);
            e.HasIndex(x => x.ScreeningState).HasFilter("screening_state = 'Checking'");
        });

        b.Entity<AiUsageWeek>(e =>
        {
            e.HasKey(x => x.WeekStart);
            e.Property(x => x.CostUsd).HasPrecision(12, 6);
        });

        b.Entity<WatchedBrand>(e =>
        {
            e.ToTable("watched_brands");
            e.Property(x => x.Name).HasMaxLength(80);
            e.Property(x => x.Aliases).HasMaxLength(400);
            e.Property(x => x.Group).HasConversion<string>().HasMaxLength(24);
            e.Property(x => x.PlaceMode).HasConversion<string>().HasMaxLength(8);
            e.Property(x => x.TextMode).HasConversion<string>().HasMaxLength(12);
            e.Property(x => x.UpdatedBy).HasMaxLength(120);
            e.HasIndex(x => x.Name).IsUnique();
        });

        b.Entity<ContentRejection>(e =>
        {
            e.ToTable("content_rejections");
            e.HasIndex(x => new { x.UserId, x.At });
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<ContentAppeal>(e =>
        {
            e.ToTable("content_appeals");
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(8);
            e.Property(x => x.Status).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.PlaceId).HasMaxLength(40);
            e.Property(x => x.Text).HasMaxLength(2000);
            e.Property(x => x.Reasons).HasMaxLength(160);
            e.Property(x => x.Note).HasMaxLength(200);
            e.Property(x => x.EvidenceKeys).HasMaxLength(300);
            e.HasIndex(x => new { x.UserId, x.RefusalId }).IsUnique();
            e.HasIndex(x => x.Status);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<OsmPlaceFlag>(e =>
        {
            e.ToTable("osm_place_flags");
            e.HasKey(x => new { x.PlaceId, x.UserId });
            e.Property(x => x.PlaceId).HasMaxLength(40);
            e.Property(x => x.Reason).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.SuggestedWarnings).HasMaxLength(40);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<PlaceVote>(e =>
        {
            e.Property(x => x.PlaceId).HasMaxLength(40);
            e.Property(x => x.Answer).HasConversion<string>().HasMaxLength(8);
            e.HasIndex(x => new { x.PlaceId, x.VoterId }).IsUnique().HasFilter("voter_id IS NOT NULL");
            e.HasIndex(x => x.VoterId);
            e.HasOne<CommunityPlace>().WithMany().HasForeignKey(x => x.PlaceId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.VoterId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<PlaceSalt>(e =>
        {
            e.HasKey(x => x.PlaceId);
            e.Property(x => x.PlaceId).HasMaxLength(40);
            e.HasIndex(x => x.ResolvedAt);
        });

        b.Entity<PlaceDispute>(e =>
        {
            e.Property(x => x.PlaceId).HasMaxLength(40);
            e.HasIndex(x => new { x.ContributorId, x.CreatedAt });
            e.HasOne<User>().WithMany().HasForeignKey(x => x.ContributorId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<UserKey>(e =>
        {
            e.HasIndex(x => new { x.UserId, x.RevokedAt });
            e.HasIndex(x => x.PublicKey).IsUnique();
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<AppAttestKey>(e =>
        {
            e.HasKey(x => x.KeyId);
            e.Property(x => x.KeyId).HasMaxLength(100);
            e.HasIndex(x => x.UserId);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<PlaceSuggestion>(e =>
        {
            e.Property(x => x.PlaceId).HasMaxLength(40);
            e.Property(x => x.Status).HasConversion<string>().HasMaxLength(10);
            e.OwnsOne(x => x.Changes, o => o.ToJson());
            e.HasIndex(x => new { x.PlaceId, x.Status });
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<Review>(e =>
        {
            e.Property(x => x.PlaceId).HasMaxLength(40);
            e.Property(x => x.Text).HasMaxLength(2000);
            e.Property(x => x.Status).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.ModerationState).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.ModerationReasons).HasMaxLength(160);
            e.Property(x => x.AppealNote).HasMaxLength(200);
            e.Property(x => x.AppealEvidence).HasMaxLength(300);
            e.HasIndex(x => new { x.PlaceId, x.UserId }).IsUnique();
            e.HasIndex(x => new { x.PlaceId, x.Status, x.Id });
            e.HasIndex(x => new { x.UserId, x.CreatedAt });
            e.HasOne(x => x.User).WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<ReviewHelpful>(e =>
        {
            e.HasKey(x => new { x.ReviewId, x.UserId });
            e.HasOne<Review>().WithMany().HasForeignKey(x => x.ReviewId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<ReviewFlag>(e =>
        {
            e.HasKey(x => new { x.ReviewId, x.UserId });
            e.Property(x => x.Reason).HasConversion<string>().HasMaxLength(24);
            e.HasOne<Review>().WithMany().HasForeignKey(x => x.ReviewId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<Photo>(e =>
        {
            e.Property(x => x.PlaceId).HasMaxLength(40);
            e.Property(x => x.Status).HasConversion<string>().HasMaxLength(12);
            e.Property(x => x.Caption).HasMaxLength(200);
            e.Property(x => x.Key).HasMaxLength(80);
            e.Property(x => x.ThumbKey).HasMaxLength(80);
            e.Property(x => x.UploadKey).HasMaxLength(80);
            e.Property(x => x.ModerationState).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.ModerationReasons).HasMaxLength(160);
            e.Property(x => x.AppealNote).HasMaxLength(200);
            e.Property(x => x.AppealEvidence).HasMaxLength(300);
            e.HasIndex(x => new { x.PlaceId, x.Status, x.Id });
            e.HasIndex(x => x.ReviewId);
            e.HasOne(x => x.User).WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.SetNull);
            e.HasOne<Review>().WithMany().HasForeignKey(x => x.ReviewId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<PlaceFlag>(e =>
        {
            e.ToTable("place_flags");
            e.HasKey(x => new { x.PlaceId, x.UserId });
            e.Property(x => x.PlaceId).HasMaxLength(40);
            e.Property(x => x.Reason).HasConversion<string>().HasMaxLength(20);
            e.HasOne<CommunityPlace>().WithMany().HasForeignKey(x => x.PlaceId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<PhotoFlag>(e =>
        {
            e.HasKey(x => new { x.PhotoId, x.UserId });
            e.Property(x => x.Reason).HasConversion<string>().HasMaxLength(24);
            e.HasOne<Photo>().WithMany().HasForeignKey(x => x.PhotoId).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<ReportContact>(e =>
        {
            e.HasKey(x => new { x.SubjectType, x.SubjectId });
            e.Property(x => x.SubjectType).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.KeyId).HasMaxLength(10);
            e.HasIndex(x => x.CreatedAt);
        });

        b.Entity<CrashGroup>(e =>
        {
            e.HasKey(x => x.Signature);
            e.Property(x => x.Signature).HasMaxLength(64);
            e.Property(x => x.Exception).HasMaxLength(300);
            e.Property(x => x.Status).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.Platform).HasMaxLength(10);
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(8);
            e.Property(x => x.Severity).HasConversion<string>().HasMaxLength(4);
            e.Property(x => x.Message).HasMaxLength(500);
            e.Property(x => x.TopFrame).HasMaxLength(300);
            e.Property(x => x.FirstVersion).HasMaxLength(30);
            e.Property(x => x.LatestVersion).HasMaxLength(30);
            e.Property(x => x.FixedInVersion).HasMaxLength(30);
            e.Property(x => x.ExternalUrl).HasMaxLength(300);
            e.Property(x => x.TriageNote).HasMaxLength(2000);
            e.Property(x => x.Analysis).HasMaxLength(20_000);
            e.Property(x => x.AnalysisBy).HasMaxLength(100);
            e.HasIndex(x => new { x.Status, x.LastSeen });
        });

        // ---- Back office (docs/back-office.md) ----
        b.Entity<AgentToken>(e =>
        {
            e.Property(x => x.Name).HasMaxLength(60);
            e.Property(x => x.Prefix).HasMaxLength(16);
            e.Property(x => x.TokenHash).HasMaxLength(64);
            e.Property(x => x.CreatedBy).HasMaxLength(100);
            e.HasIndex(x => x.TokenHash).IsUnique();
        });

        b.Entity<AuditEntry>(e =>
        {
            e.ToTable("audit_log");
            e.Property(x => x.Actor).HasMaxLength(100);
            e.Property(x => x.ActorKind).HasMaxLength(8);
            e.Property(x => x.Action).HasMaxLength(60);
            e.Property(x => x.TargetType).HasMaxLength(20);
            e.Property(x => x.TargetId).HasMaxLength(80);
            e.Property(x => x.Detail).HasMaxLength(500);
            e.HasIndex(x => x.At);
            e.HasIndex(x => new { x.TargetType, x.TargetId });
        });

        b.Entity<AgentRun>(e =>
        {
            e.Property(x => x.Title).HasMaxLength(200);
            e.Property(x => x.TargetType).HasMaxLength(10);
            e.Property(x => x.TargetId).HasMaxLength(80);
            e.Property(x => x.Status).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.Agent).HasMaxLength(100);
            e.Property(x => x.Branch).HasMaxLength(120);
            e.Property(x => x.PrUrl).HasMaxLength(300);
            e.Property(x => x.Summary).HasMaxLength(20_000);
            e.Property(x => x.Steps).HasColumnType("jsonb").HasConversion(RunStepsJson.Converter, RunStepsJson.Comparer);
            e.HasIndex(x => new { x.TargetType, x.TargetId });
            e.HasIndex(x => x.UpdatedAt);
        });

        b.Entity<ReplyDraft>(e =>
        {
            e.Property(x => x.Message).HasMaxLength(1000);
            e.Property(x => x.NewStatus).HasConversion<string>().HasMaxLength(12);
            e.Property(x => x.Status).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.DraftedBy).HasMaxLength(100);
            e.Property(x => x.DecidedBy).HasMaxLength(100);
            e.HasIndex(x => new { x.Status, x.CreatedAt });
            e.HasIndex(x => x.FeedbackId);
            e.HasOne<Feedback>().WithMany().HasForeignKey(x => x.FeedbackId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<AppBuild>(e =>
        {
            e.Property(x => x.Platform).HasMaxLength(10);
            e.Property(x => x.Version).HasMaxLength(30);
            e.Property(x => x.Commit).HasMaxLength(40);
            e.Property(x => x.SymbolsUrl).HasMaxLength(300);
            e.HasIndex(x => new { x.Platform, x.Build }).IsUnique();
        });

        b.Entity<CrashReport>(e =>
        {
            e.Property(x => x.Signature).HasMaxLength(64);
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(8);
            e.Property(x => x.Exception).HasMaxLength(300);
            e.Property(x => x.Message).HasMaxLength(500);
            e.Property(x => x.Screen).HasMaxLength(32);
            e.Property(x => x.Device).HasColumnType("jsonb").HasConversion(DeviceJson.Converter, DeviceJson.Comparer);
            e.HasIndex(x => new { x.UserId, x.CreatedAt });
            e.HasIndex(x => new { x.Signature, x.CreatedAt });
            e.HasIndex(x => x.CreatedAt);
            e.HasOne<CrashGroup>().WithMany().HasForeignKey(x => x.Signature).OnDelete(DeleteBehavior.Cascade);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.SetNull);
        });

        b.Entity<InboxItem>(e =>
        {
            e.ToTable("inbox_items");
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(20);
            e.Property(x => x.Title).HasMaxLength(200);
            e.Property(x => x.Body).HasMaxLength(1000);
            e.Property(x => x.Subject).HasMaxLength(200);
            e.Property(x => x.RefType).HasMaxLength(20);
            e.Property(x => x.RefId).HasMaxLength(64);
            e.Property(x => x.AggregateKey).HasMaxLength(80);
            e.Property(x => x.PlaceId).HasMaxLength(40);
            e.Property(x => x.Reasons).HasMaxLength(160);
            e.HasIndex(x => new { x.UserId, x.Id });
            e.HasIndex(x => new { x.UserId, x.AggregateKey }).IsUnique().HasFilter("aggregate_key IS NOT NULL");
            e.HasIndex(x => x.CreatedAt);
            e.HasOne<User>().WithMany().HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<Announcement>(e =>
        {
            e.Property(x => x.Title).HasMaxLength(200);
            e.Property(x => x.TitleMs).HasMaxLength(200);
            e.Property(x => x.Body).HasMaxLength(2000);
            e.Property(x => x.BodyMs).HasMaxLength(2000);
            e.Property(x => x.Url).HasMaxLength(300);
            e.HasIndex(x => x.CreatedAt);
        });

        b.Entity<StreetAddress>(e =>
        {
            e.ToTable("street_addresses");
            e.Property(x => x.Id).HasMaxLength(24);
            e.Property(x => x.HouseNumber).HasMaxLength(40);
            e.Property(x => x.Street).HasMaxLength(200);
            e.Property(x => x.Postcode).HasMaxLength(12);
            e.Property(x => x.City).HasMaxLength(100);
            e.Property(x => x.Country).HasMaxLength(2);
            e.Property(x => x.Location).HasColumnType("geography (point, 4326)");
            e.HasIndex(x => x.Location).HasMethod("gist");
        });

        b.Entity<Issue>(e =>
        {
            e.ToTable("issues");
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(32);
            e.Property(x => x.State).HasConversion<string>().HasMaxLength(12);
            e.Property(x => x.Source).HasConversion<string>().HasMaxLength(12);
            e.Property(x => x.Direction).HasConversion<string>().HasMaxLength(10);
            e.Property(x => x.Vehicle).HasConversion<string>().HasMaxLength(12);
            e.Property(x => x.Subtype).HasMaxLength(20);
            e.Property(x => x.PlaceId).HasMaxLength(40);
            e.Property(x => x.Highway).HasMaxLength(20);
            e.Property(x => x.RoadName).HasMaxLength(200);
            e.Property(x => x.Location).HasColumnType("geography (point, 4326)");
            e.Property(x => x.Payload).HasColumnType("jsonb");
            e.Property(x => x.History).HasColumnType("jsonb");
            e.Property(x => x.Version).IsRowVersion();
            e.HasIndex(x => x.Location).HasMethod("gist");
            e.HasIndex(x => new { x.State, x.Kind });
            e.HasIndex(x => new { x.WayId, x.Seq });
            e.HasIndex(x => x.PlaceId);
            e.HasIndex(x => x.CreatedBy);
        });

        b.Entity<IssueVote>(e =>
        {
            e.ToTable("issue_votes");
            e.Property(x => x.Answer).HasConversion<string>().HasMaxLength(10);
            e.HasIndex(x => new { x.IssueId, x.VoterId }).IsUnique().HasFilter("voter_id IS NOT NULL");
            e.HasIndex(x => new { x.VoterId, x.Day });
        });

        b.Entity<IssueSalt>(e =>
        {
            e.ToTable("issue_salts");
            e.HasKey(x => x.IssueId);
        });

        b.Entity<SegmentTraversalCount>(e =>
        {
            e.ToTable("segment_traversal_counts");
            e.HasKey(x => new { x.WayId, x.Seq, x.Direction, x.Hour });
            e.Property(x => x.Direction).HasConversion<string>().HasMaxLength(10);
            e.HasIndex(x => x.Hour);
        });

        b.Entity<AdminArea>(e =>
        {
            e.ToTable("admin_areas");
            e.Property(x => x.Id).ValueGeneratedNever();
            e.Property(x => x.Name).HasMaxLength(200);
            e.Property(x => x.Geom).HasColumnType("geography (multipolygon, 4326)");
            e.HasIndex(x => x.Geom).HasMethod("gist");
        });

        b.Entity<SearchMiss>(e =>
        {
            e.ToTable("search_misses");
            e.HasKey(x => new { x.Week, x.Cell, x.Query });
            e.Property(x => x.Query).HasMaxLength(100);
            e.Property(x => x.Cell).HasMaxLength(16);
            e.Property(x => x.Week).HasMaxLength(8);
        });

        b.Entity<WaterArea>(e =>
        {
            e.Property(x => x.Geom).HasColumnType("geography (polygon, 4326)");
            e.HasIndex(x => x.Geom).HasMethod("gist");
        });

        b.Entity<PlaceEntrance>(e =>
        {
            e.HasKey(x => x.PlaceId);
            e.Property(x => x.PlaceId).HasMaxLength(40);
            e.Property(x => x.Location).HasColumnType("geography (point, 4326)");
            e.Property(x => x.Source).HasMaxLength(16);
            e.Property(x => x.Kind).HasMaxLength(16);
        });

        b.Entity<RestrictedArea>(e =>
        {
            e.Property(x => x.Geom).HasColumnType("geography (polygon, 4326)");
            e.HasIndex(x => x.Geom).HasMethod("gist");
        });

        // Event short links (docs/events.md §5.6): an encrypted pack the server can't read, kept until the event is over.
        b.Entity<Events.Drop>(e =>
        {
            e.ToTable("drops");
            e.Property(x => x.Id).HasMaxLength(10);
            e.Property(x => x.WriteTokenHash).HasMaxLength(32);
            e.Property(x => x.OwnerHash).HasMaxLength(32);
            e.HasIndex(x => x.OwnerHash);
            e.HasIndex(x => x.ExpiresAt);
        });


        // Store versions (docs/app-updates.md): public facts only.
        b.Entity<AppVersions.AppRelease>(e =>
        {
            e.ToTable("app_releases");
            e.HasKey(x => new { x.Platform, x.Version });
            e.Property(x => x.Platform).HasMaxLength(16);
            e.Property(x => x.Version).HasMaxLength(30);
        });
        b.Entity<AppVersions.AppVersionConfig>(e =>
        {
            e.ToTable("app_version_config");
            e.HasKey(x => x.Platform);
            e.Property(x => x.Platform).HasMaxLength(16);
            e.Property(x => x.MinVersion).HasMaxLength(30);
            e.Property(x => x.StoreUrl).HasMaxLength(300);
            e.Property(x => x.MaxBehind).HasDefaultValue(3);
        });

        b.Entity<TollRate>(e =>
        {
            e.Property(x => x.System).HasConversion<string>().HasMaxLength(12);
            e.Property(x => x.Class0Myr).HasPrecision(8, 2);
            e.Property(x => x.Class1Myr).HasPrecision(8, 2);
            e.HasIndex(x => x.MatchedPlaceIds).HasMethod("gin");
        });
    }
}

public static class GimanoDb
{
    public const string ConnectionStringName = "Postgres";
    /// <summary>Environment variable with the full connection string for design-time tools (<c>dotnet ef</c>).</summary>
    public const string DesignTimeEnvVar = "GIMANO_PG";

    public static NpgsqlDataSource BuildDataSource(string connectionString)
    {
        var dsb = new NpgsqlDataSourceBuilder(connectionString);
        dsb.UseNetTopologySuite(geographyAsDefault: true);
        dsb.EnableDynamicJson();
        return dsb.Build();
    }

    public static void Configure(DbContextOptionsBuilder o, NpgsqlDataSource ds) =>
        o.UseNpgsql(ds, npg =>
            {
                npg.UseNetTopologySuite(geographyAsDefault: true);
                npg.MigrationsAssembly(typeof(GimanoDbContext).Assembly.FullName);
            })
            .UseSnakeCaseNamingConvention();
}

/// <summary>Used by <c>dotnet ef</c> at design time.</summary>
public sealed class DesignTimeFactory : IDesignTimeDbContextFactory<GimanoDbContext>
{
    public GimanoDbContext CreateDbContext(string[] args)
    {
        var cs = Environment.GetEnvironmentVariable(GimanoDb.DesignTimeEnvVar)
                 ?? Environment.GetEnvironmentVariable("ConnectionStrings__Postgres")
                 ?? throw new InvalidOperationException(
                     $"Set {GimanoDb.DesignTimeEnvVar} to a PostgreSQL connection string (e.g. Host=localhost;Port=5433;Database=gimano;Username=gimano;Password=…) for dotnet ef.");
        var o = new DbContextOptionsBuilder<GimanoDbContext>();
        GimanoDb.Configure(o, GimanoDb.BuildDataSource(cs));
        return new GimanoDbContext(o.Options);
    }
}

/// <summary>Agent run steps ↔ jsonb. Steps are replaced, never mutated in place, so reference equality tracks changes.</summary>
internal static class RunStepsJson
{
    private static readonly System.Text.Json.JsonSerializerOptions O = new(System.Text.Json.JsonSerializerDefaults.Web);
    public static readonly Microsoft.EntityFrameworkCore.Storage.ValueConversion.ValueConverter<List<AgentRunStep>, string> Converter = new(
        v => System.Text.Json.JsonSerializer.Serialize(v, O),
        v => System.Text.Json.JsonSerializer.Deserialize<List<AgentRunStep>>(v, O) ?? new List<AgentRunStep>());
    public static readonly Microsoft.EntityFrameworkCore.ChangeTracking.ValueComparer<List<AgentRunStep>> Comparer = new(
        (a, b) => a != null && b != null && a.SequenceEqual(b), v => v.Count, v => v.ToList());
}

/// <summary>DeviceInfo ↔ jsonb (camelCase, like the API).</summary>
internal static class DeviceJson
{
    private static readonly System.Text.Json.JsonSerializerOptions O = new(System.Text.Json.JsonSerializerDefaults.Web);
    public static readonly Microsoft.EntityFrameworkCore.Storage.ValueConversion.ValueConverter<Contracts.DeviceInfo?, string?> Converter = new(
        v => v == null ? null : System.Text.Json.JsonSerializer.Serialize(v, O),
        v => v == null ? null : System.Text.Json.JsonSerializer.Deserialize<Contracts.DeviceInfo>(v, O));
    public static readonly Microsoft.EntityFrameworkCore.ChangeTracking.ValueComparer<Contracts.DeviceInfo?> Comparer = new(
        (a, b) => Equals(a, b), v => v == null ? 0 : v.GetHashCode(), v => v);
}
