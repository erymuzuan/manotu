using Gimano.Api.Services;
using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Messaging;
using Microsoft.AspNetCore.Http;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using SkiaSharp;
using Xunit;

namespace Gimano.Tests;

/// <summary>
/// Public content safety (docs/content-safety.md) end to end against a real PostGIS (GIMANO_PG_TEST, see backend/tests/postgres-it.ps1)
/// with a scripted content screener: no model is called. Skipped without a database.
/// </summary>
public sealed class PostgresIntegrationContentSafetyTests : IAsyncLifetime
{
    private NpgsqlDataSource? _ds;
    private string? _dbName, _admin;
    private string? _mediaDir;
    private static readonly DateTimeOffset T0 = new(2026, 10, 27, 2, 0, 0, TimeSpan.Zero);
    private const double Lat = 3.1196, Lng = 101.6214;
    private readonly Bus _bus = new();
    private readonly Clock _clock = new(T0);
    private readonly AuthorHandles _handles = new(new byte[32]);
    private Guid _alice, _bob;

    private sealed class Bus : IEventPublisher
    {
        public readonly List<(string Key, object Payload)> Sent = [];
        public Task<bool> PublishAsync<T>(string routingKey, T payload, CancellationToken ct = default) { Sent.Add((routingKey, payload!)); return Task.FromResult(true); }
    }

    private sealed class Clock(DateTimeOffset now) : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = now;
        public override DateTimeOffset GetUtcNow() => Now;
    }

    public async ValueTask InitializeAsync()
    {
        _admin = Environment.GetEnvironmentVariable("GIMANO_PG_TEST");
        if (string.IsNullOrEmpty(_admin)) return;
        _dbName = "gimano_it_" + Guid.NewGuid().ToString("N")[..12];
        await using (var c = new NpgsqlConnection(_admin))
        {
            await c.OpenAsync();
            await using var cmd = new NpgsqlCommand($"CREATE DATABASE {_dbName}", c);
            await cmd.ExecuteNonQueryAsync();
        }
        _ds = GimanoDb.BuildDataSource(new NpgsqlConnectionStringBuilder(_admin) { Database = _dbName }.ConnectionString);
        _mediaDir = Path.Combine(Path.GetTempPath(), _dbName);
        await using var db = NewDb();
        await db.Database.MigrateAsync();
        db.Places.Add(new Place { Id = "n77", Name = "99 Speedmart Bangi", Category = PlaceCategory.Convenience, Location = new GeoPoint(Lat, Lng).ToPoint(), OsmType = "node" });
        var users = new[] { new User { DisplayName = "Alice", JoinedAt = T0.AddDays(-60) }, new User { DisplayName = "Bob", JoinedAt = T0.AddDays(-60) } };
        db.Users.AddRange(users);
        await db.SaveChangesAsync();
        (_alice, _bob) = (users[0].Id, users[1].Id);
    }

    public async ValueTask DisposeAsync()
    {
        if (_mediaDir is not null && Directory.Exists(_mediaDir)) Directory.Delete(_mediaDir, true);
        if (_ds is null) return;
        await _ds.DisposeAsync();
        NpgsqlConnection.ClearAllPools();
        await using var c = new NpgsqlConnection(_admin);
        await c.OpenAsync();
        await using var cmd = new NpgsqlCommand($"DROP DATABASE IF EXISTS {_dbName} WITH (FORCE)", c);
        await cmd.ExecuteNonQueryAsync();
    }

    private GimanoDbContext NewDb()
    {
        var o = new DbContextOptionsBuilder<GimanoDbContext>();
        GimanoDb.Configure(o, _ds!);
        return new GimanoDbContext(o.Options);
    }

    private static TestGates.ContentScreener Answer(string decision, string confidence = "high", string? safe = null, params string[] reasons) =>
        new(_ => new ContentResult(PlaceScreening.Normalize(decision, confidence, reasons), safe, false));

    private ContentGate Gate(GimanoDbContext db, IContentScreener? screener) => TestGates.Content(db, _clock, screener, _bus);

    private ReviewService Reviews(GimanoDbContext db, IContentScreener? screener) => new(db, _bus, _clock, _handles, new RestrictedAreaService(db, new()), Gate(db, screener), new LocalMediaStore(_mediaDir!));

    private PhotoService Photos(GimanoDbContext db, IContentScreener? screener) =>
        new(db, new LocalMediaStore(_mediaDir!), _bus, _clock, _handles, new RestrictedAreaService(db, new()), Gate(db, screener));

    private Moderation Moderators(GimanoDbContext db) => new(db, _bus, _handles, _clock);

    private IEnumerable<ContentScreenedEvent> Screened => _bus.Sent.Where(s => s.Key == RoutingKeys.ContentScreened).Select(s => (ContentScreenedEvent)s.Payload);

    private static CreateReviewRequest Review(string text, int rating = 5) => new(rating, text, null);

    // ---- reviews ------------------------------------------------------------------------------------

    [Fact]
    public async Task A_clean_review_is_published_and_the_author_sees_passed()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var screener = Answer("publish", "high", null, "ok");
        var r = await Reviews(db, screener).CreateAsync(_alice, "n77", Review("Parking mudah, kedai bersih."), ct);
        Assert.Equal(ReviewStatus.Published, r.Status);
        Assert.Equal(new ContentModerationDto(ContentState.Passed, [], false), r.Moderation);
        // The model saw the text and the public place name, nothing about the author.
        var seen = Assert.Single(screener.Inputs);
        Assert.Equal((ContentKind.Review, "Parking mudah, kedai bersih.", "99 Speedmart Bangi"), (seen.Kind, seen.Text, seen.PlaceName));
        Assert.Empty(Screened);
    }

    [Fact]
    public async Task A_held_review_is_hidden_for_a_maintainer_and_the_author_hears_it()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var r = await Reviews(db, Answer("hold", "medium", null, "unclear")).CreateAsync(_alice, "n77", Review("Hmm, tengok sendiri."), ct);
        Assert.Equal((ReviewStatus.Hidden, true), (r.Status, r.HeldForReview));
        Assert.Equal(new ContentModerationDto(ContentState.Held, ["unclear"], false), r.Moderation);
        Assert.Contains(Screened, e => e.SubjectKind == "review" && e.SubjectId == r.Id.ToString() && e.State == ContentState.Held);

        // Others see nothing; the author sees their own review in the list.
        Assert.Empty((await Reviews(db, null).ListAsync("n77", ReviewSort.Recent, null, ct, _bob)).Reviews);
        var own = Assert.Single((await Reviews(db, null).ListAsync("n77", ReviewSort.Recent, null, ct, _alice)).Reviews);
        Assert.Equal(ContentState.Held, own.Moderation!.State);

        var queue = await Moderators(db).QueueAsync(ModerationKind.Review, hidden: true, ct);
        var item = Assert.Single(queue);
        Assert.True(item.Held);
        Assert.Equal(["unclear"], item.Reasons);
        Assert.Equal("Alice", item.AuthorName);     // public pseudonym only

        await Moderators(db).RestoreAsync(ModerationKind.Review, r.Id.ToString(), ct);
        var live = Assert.Single((await Reviews(db, null).ListAsync("n77", ReviewSort.Recent, null, ct, _bob)).Reviews);
        Assert.Equal(r.Id, live.Id);
        Assert.Null(live.Moderation);
        Assert.Contains(Screened, e => e.SubjectId == r.Id.ToString() && e.State == ContentState.Passed && e.Late);
    }

    [Fact]
    public async Task A_rejected_review_returns_422_data_and_nothing_is_stored()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var ex = await Assert.ThrowsAsync<ContentRejectedException>(() => Reviews(db, Answer("reject", "high", "Parking mudah.", "alcohol_promo", "external_contact"))
            .CreateAsync(_alice, "n77", Review("Parking mudah. Arak murah wasap 0123456789"), ct));
        Assert.Equal(["alcohol_promo", "external_contact"], ex.Reasons);
        Assert.Equal("Parking mudah.", ex.SafeText);
        Assert.False(await db.Reviews.AnyAsync(ct));
        Assert.Equal(1, await db.ContentRejections.CountAsync(ct));
        // Posting the safe part afterwards works.
        var ok = await Reviews(db, Answer("publish", "high", null, "ok")).CreateAsync(_alice, "n77", Review(ex.SafeText!), ct);
        Assert.Equal(ReviewStatus.Published, ok.Status);
    }

    [Fact]
    public async Task No_answer_in_time_stores_it_hidden_as_checking_and_the_worker_finishes_it()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var r = await Reviews(db, new TestGates.ContentScreener(_ => ContentResult.Failed)).CreateAsync(_alice, "n77", Review("Boleh tahan."), ct);
        Assert.Equal((ReviewStatus.Hidden, ContentState.Checking), (r.Status, r.Moderation!.State));

        var row = await db.Reviews.SingleAsync(x => x.Id == r.Id, ct);
        var gate = Gate(db, Answer("publish", "high", null, "ok"));
        var outcome = await gate.CheckTextAsync(new ContentInput(ContentKind.Review, row.Text, "99 Speedmart Bangi"), null, ct);
        await gate.ApplyReviewAsync(row, outcome, late: true, ct);
        Assert.Equal((ReviewStatus.Published, ContentState.Passed), (row.Status, row.ModerationState));
        Assert.Contains(Screened, e => e.SubjectId == r.Id.ToString() && e.State == ContentState.Passed && e.Late);
    }

    [Fact]
    public async Task Check_off_publishes_with_the_plain_filters_and_says_skipped()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var r = await Reviews(db, null).CreateAsync(_alice, "n77", Review("Okay."), ct);
        Assert.Equal((ReviewStatus.Published, ContentState.Skipped), (r.Status, r.Moderation!.State));
    }

    [Fact]
    public async Task A_watchlist_brand_set_to_reject_is_refused_without_calling_the_model_and_other_matches_go_as_context()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        await BrandWatchlistService.EnsureSeededAsync(db, ct);
        var screener = Answer("publish", "high", null, "ok");
        var ex = await Assert.ThrowsAsync<ContentRejectedException>(() => Reviews(db, screener).CreateAsync(_alice, "n77", Review("daftar M e g a 8 8 8 bonus"), ct));
        Assert.Equal(["brand_promo"], ex.Reasons);
        Assert.Empty(screener.Inputs);

        await Reviews(db, screener).CreateAsync(_bob, "n77", Review("Ada jual Heineken kat belakang"), ct);
        var brand = Assert.Single(Assert.Single(screener.Inputs).Brands!);
        Assert.Equal(("Heineken", BrandGroup.Alcohol), (brand.Name, brand.Group));
    }

    [Fact]
    public async Task Three_rejections_in_a_day_pause_posting_for_a_day()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var reject = Answer("reject", "high", null, "scam");
        for (var i = 0; i < 3; i++)
            await Assert.ThrowsAsync<ContentRejectedException>(() => Reviews(db, reject).CreateAsync(_alice, "n77", Review("scam " + i), ct));
        var paused = await Assert.ThrowsAsync<PostingPausedException>(() => Reviews(db, Answer("publish")).CreateAsync(_alice, "n77", Review("fine"), ct));
        Assert.Equal(T0.AddHours(24), paused.Until);
        // Photos and the place pause share it (SuspendedUntil); another account is unaffected.
        Assert.Equal(T0.AddHours(24), (await db.Users.AsNoTracking().SingleAsync(u => u.Id == _alice, ct)).SuspendedUntil);
        await Reviews(db, Answer("publish")).CreateAsync(_bob, "n77", Review("fine"), ct);
        _clock.Now = T0.AddHours(25);
        await db.Users.Where(u => u.Id == _alice).ExecuteUpdateAsync(s => s.SetProperty(u => u.SuspendedUntil, (DateTimeOffset?)null), ct);   // the vetting job clears it
        Assert.Equal(ReviewStatus.Published, (await Reviews(db, Answer("publish")).CreateAsync(_alice, "n77", Review("fine"), ct)).Status);
    }

    [Fact]
    public async Task Rejected_place_counts_toward_the_same_pause()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        for (var i = 0; i < 2; i++)
            db.CommunityPlaces.Add(new CommunityPlace { Name = "Spam " + i, Location = new GeoPoint(Lat + i * 0.01, Lng).ToPoint(), OwnerId = _alice, Status = PlaceStatus.Rejected,
                ScreeningState = ScreeningState.Rejected, ScreenedAt = T0.AddHours(-1) });
        await db.SaveChangesAsync(ct);
        await Gate(db, null).RecordRejectionAsync(_alice, ct);
        Assert.NotNull((await db.Users.AsNoTracking().SingleAsync(u => u.Id == _alice, ct)).SuspendedUntil);
    }

    [Fact]
    public async Task Editing_a_review_is_screened_and_a_rejected_edit_changes_nothing()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var r = await Reviews(db, Answer("publish", "high", null, "ok")).CreateAsync(_alice, "n77", Review("Bagus."), ct);
        await Assert.ThrowsAsync<ContentRejectedException>(() => Reviews(db, Answer("reject", "high", null, "gambling_promo"))
            .PatchAsync(_alice, r.Id, new PatchReviewRequest(1, "Judi online di sini", null), ct));
        var unchanged = await db.Reviews.AsNoTracking().SingleAsync(x => x.Id == r.Id, ct);
        Assert.Equal(("Bagus.", 5, ReviewStatus.Published), (unchanged.Text, unchanged.Rating, unchanged.Status));

        var held = await Reviews(db, Answer("hold", "medium", null, "unclear")).PatchAsync(_alice, r.Id, new PatchReviewRequest(null, "Hmm.", null), ct);
        Assert.Equal((ReviewStatus.Hidden, ContentState.Held), (held.Status, held.Moderation!.State));
        // A rating-only edit does not call the model.
        var screener = Answer("publish");
        await Reviews(db, screener).PatchAsync(_alice, r.Id, new PatchReviewRequest(3, null, null), ct);
        Assert.Empty(screener.Inputs);
    }

    [Fact]
    public async Task A_review_rejected_late_can_be_appealed_once_and_a_maintainer_decides()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var r = await Reviews(db, new TestGates.ContentScreener(_ => ContentResult.Failed)).CreateAsync(_alice, "n77", Review("Kedai ini..."), ct);
        var row = await db.Reviews.SingleAsync(x => x.Id == r.Id, ct);
        await Gate(db, null).ApplyReviewAsync(row, new ContentOutcome(ContentOutcomeKind.Rejected, ["harassment"]), late: true, ct);
        Assert.Contains(Screened, e => e.SubjectId == r.Id.ToString() && e.State == ContentState.Rejected);
        var mine = Assert.Single((await Reviews(db, null).ListAsync("n77", ReviewSort.Recent, null, ct, _alice)).Reviews);
        Assert.Equal(new ContentModerationDto(ContentState.Rejected, ["harassment"], true), mine.Moderation);
        // Not in the maintainers' queue until appealed.
        Assert.Empty(await Moderators(db).QueueAsync(ModerationKind.Review, hidden: true, ct));

        await Assert.ThrowsAsync<ForbiddenException>(() => Reviews(db, null).AppealAsync(_bob, r.Id, null, ct));
        Assert.Equal("note_required", (await Assert.ThrowsAsync<ApiCodeException>(() => Reviews(db, null).AppealAsync(_alice, r.Id, new string('x', 201), ct))).Code);
        Assert.Equal("note_required", (await Assert.ThrowsAsync<ApiCodeException>(() => Reviews(db, null).AppealAsync(_alice, r.Id, "   ", ct))).Code);
        await Reviews(db, null).AppealAsync(_alice, r.Id, "Itu bukan hinaan, itu pendapat", ct);
        await Assert.ThrowsAsync<ConflictException>(() => Reviews(db, null).AppealAsync(_alice, r.Id, null, ct));
        var item = Assert.Single(await Moderators(db).QueueAsync(ModerationKind.Review, hidden: true, ct));
        Assert.Equal("Itu bukan hinaan, itu pendapat", item.AppealNote);

        await Moderators(db).RestoreAsync(ModerationKind.Review, r.Id.ToString(), ct);
        Assert.Equal(ReviewStatus.Published, (await db.Reviews.AsNoTracking().SingleAsync(x => x.Id == r.Id, ct)).Status);
    }

    // ---- photos ---------------------------------------------------------------------------------------

    private static IFormFile Jpeg()
    {
        using var bmp = new SKBitmap(640, 480);
        using (var canvas = new SKCanvas(bmp)) canvas.Clear(SKColors.Orange);
        using var data = SKImage.FromBitmap(bmp).Encode(SKEncodedImageFormat.Jpeg, 80);
        var ms = new MemoryStream(data.ToArray());
        return new FormFile(ms, 0, ms.Length, "file", "a.jpg") { Headers = new HeaderDictionary(), ContentType = "image/jpeg" };
    }

    [Fact]
    public async Task An_uploaded_photo_starts_as_checking_and_shows_no_url_until_published()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var dto = await Photos(db, Answer("publish")).UploadAsync(_alice, "n77", Jpeg(), "Depan kedai", ct);
        Assert.Equal((PhotoStatus.Processing, ContentState.Checking, null), (dto.Status, dto.Moderation!.State, dto.Url));

        // With the check off the photo has no moderation block at all.
        var off = await Photos(db, null).UploadAsync(_bob, "n77", Jpeg(), null, ct);
        Assert.Null(off.Moderation);
    }

    [Fact]
    public async Task Photo_outcomes_publish_hold_or_reject_and_a_rejected_photo_never_blocks_the_place()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var photos = Photos(db, Answer("publish"));
        async Task<Photo> Uploaded()
        {
            var dto = await photos.UploadAsync(_alice, "n77", Jpeg(), "Depan kedai", ct);
            var p = await db.Photos.Include(x => x.User).SingleAsync(x => x.Id == dto.Id, ct);
            p.Key = "k" + dto.Id.ToString("N")[..30]; p.ThumbKey = "t" + dto.Id.ToString("N")[..30];   // as if the worker had processed it
            return p;
        }
        var gate = Gate(db, null);

        var ok = await Uploaded();
        await gate.ApplyPhotoAsync(ok, new ContentOutcome(ContentOutcomeKind.Passed, ["ok"]), late: false, ct);
        Assert.Equal(PhotoStatus.Published, ok.Status);
        Assert.Equal(PhotoStatus.Published, (await photos.GetAsync(ok.Id, ct)).Status);

        var held = await Uploaded();
        await gate.ApplyPhotoAsync(held, new ContentOutcome(ContentOutcomeKind.Held, ["unclear"]), late: false, ct);
        Assert.Equal((PhotoStatus.Processing, ContentState.Held), (held.Status, held.ModerationState));
        await Assert.ThrowsAsync<NotFoundException>(() => photos.GetAsync(held.Id, ct, _bob));       // not visible to others
        var mine = await photos.GetAsync(held.Id, ct, _alice);
        Assert.Equal(new ContentModerationDto(ContentState.Held, ["unclear"], false), mine.Moderation);
        Assert.Null(mine.Url);
        Assert.Contains(Assert.Single(await Moderators(db).QueueAsync(ModerationKind.Photo, hidden: true, ct)).Reasons!, r => r == "unclear");

        var bad = await Uploaded();
        await gate.ApplyPhotoAsync(bad, new ContentOutcome(ContentOutcomeKind.Rejected, ["adult"]), late: false, ct);
        Assert.Equal((PhotoStatus.Rejected, ContentState.Rejected), (bad.Status, bad.ModerationState));
        Assert.Equal(new ContentModerationDto(ContentState.Rejected, ["adult"], true), (await photos.GetAsync(bad.Id, ct, _alice)).Moderation);
        Assert.Contains(Screened, e => e.SubjectKind == "photo" && e.SubjectId == bad.Id.ToString() && e.State == ContentState.Rejected);

        // Appeal once; a maintainer approves it and the photo goes live.
        await photos.AppealAsync(_alice, bad.Id, "Ini gambar kedai kuih", ct);
        await Assert.ThrowsAsync<ConflictException>(() => photos.AppealAsync(_alice, bad.Id, null, ct));
        await Moderators(db).RestoreAsync(ModerationKind.Photo, bad.Id.ToString(), ct);
        Assert.Equal(PhotoStatus.Published, (await photos.GetAsync(bad.Id, ct)).Status);

        // Reviews and the place are unaffected by a rejected photo, and the 3-rejections rule counts photos too.
        var review = await Reviews(db, Answer("publish", "high", null, "ok")).CreateAsync(_alice, "n77", Review("Okay."), ct);
        Assert.Equal(ReviewStatus.Published, review.Status);
        Assert.Equal(1, await db.ContentRejections.CountAsync(x => x.UserId == _alice, ct));
    }

    [Fact]
    public async Task The_image_check_gets_a_metadata_free_jpeg_and_the_caption_only()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var screener = Answer("publish");
        var dto = await Photos(db, screener).UploadAsync(_alice, "n77", Jpeg(), "Depan kedai", ct);
        var photo = await db.Photos.SingleAsync(x => x.Id == dto.Id, ct);
        var original = await new LocalMediaStore(_mediaDir!).GetAsync(photo.UploadKey!, ct);
        var processed = ImageProcessor.Process(original!);
        var outcome = await Worker.Photos.PhotoProcessor.CheckAsync(Gate(db, screener), db, photo, processed.Webp, ct);
        Assert.Equal(ContentOutcomeKind.Passed, outcome.Kind);
        Assert.Equal(1, screener.ImageCalls);
        var seen = Assert.Single(screener.Inputs);
        Assert.Equal((ContentKind.Photo, "Depan kedai", "99 Speedmart Bangi"), (seen.Kind, seen.Text, seen.PlaceName));
    }

    // ---- report notes ---------------------------------------------------------------------------------

    private ReportService Reports(GimanoDbContext db, IContentScreener? screener) =>
        new(db, _bus, new GeoLookup(db, new Gimano.Api.Live.DriverSnapshotStore(_clock), _clock), _clock,
            new Microsoft.Extensions.Caching.Memory.MemoryCache(new Microsoft.Extensions.Caching.Memory.MemoryCacheOptions()),
            new RestrictedAreaService(db, new()), Gate(db, screener));

    [Fact]
    public async Task A_rejected_report_note_is_dropped_and_the_report_still_goes_out()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var bad = new CreateReportRequest(ReportType.Hazard, "pothole", Lat, Lng, 0, "Lubang. Jual vape wasap 0123456789");
        var (report, merged) = await Reports(db, Answer("reject", "high", null, "tobacco_promo", "external_contact")).CreateAsync(_alice, bad, ct);
        Assert.False(merged);
        Assert.Equal((true, new[] { "tobacco_promo", "external_contact" }), (report.NoteDropped, report.NoteReasons!.ToArray()));
        Assert.Null((await db.Reports.AsNoTracking().SingleAsync(r => r.Id == report.Id, ct)).Comment);

        var good = new CreateReportRequest(ReportType.Hazard, "pothole", Lat + 0.05, Lng, 0, null, Note: "Lubang besar lorong kiri");
        var (ok, _) = await Reports(db, Answer("publish", "high", null, "ok")).CreateAsync(_bob, good, ct);
        Assert.Null(ok.NoteDropped);
        Assert.Equal("Lubang besar lorong kiri", (await db.Reports.AsNoTracking().SingleAsync(r => r.Id == ok.Id, ct)).Comment);
        Assert.Equal(1, await db.ContentRejections.CountAsync(ct));
    }

    // ---- place warnings and the watchlist -------------------------------------------------------------

    private CommunityService Places(GimanoDbContext db, IPlaceScreener screener) => new(db, _bus,
        new Gimano.Api.Identity.AttestationService(new Microsoft.Extensions.Configuration.ConfigurationBuilder().Build(), null!, db, _clock,
            NullLogger<Gimano.Api.Identity.AttestationService>.Instance), _clock, new RestrictedAreaService(db, new()),
        new PlaceGate(db, screener, _bus, _clock, Microsoft.Extensions.Options.Options.Create(new Gimano.Core.Identity.VettingOptions { LaunchMode = true }),
            new BrandWatchlistService(db, _clock)));

    private async Task AddRoadAsync(GimanoDbContext db)
    {
        var line = new[] { new GeoPoint(Lat, Lng - 0.05), new GeoPoint(Lat, Lng + 0.05) };
        db.RoadSegments.Add(new RoadSegment { OsmWayId = 1, Seq = 0, Name = "Jalan Test", Highway = "residential", Oneway = false, FreeFlowKmh = 30, LengthM = 9000,
            FromNode = 1, ToNode = 2, Geom = GeoMath.ToLineString(line) });
        await db.SaveChangesAsync();
    }

    [Fact]
    public async Task Place_warnings_come_from_owner_tags_ai_codes_and_the_watchlist_and_hold_brands_wait_for_a_person()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        await AddRoadAsync(db);
        await BrandWatchlistService.EnsureSeededAsync(db, ct);
        TestGates.Screener Place(string decision, params string[] reasons) => new(_ => new ScreeningResult(PlaceScreening.Normalize(decision, "high", reasons), false));
        CreatePlaceRequest Req(string name, double d, IReadOnlyList<string>? warnings = null) =>
            new(name, PlaceCategory.Restaurant, Lat + d, Lng, null, "Makan", null, null, null, null, null, warnings);

        // The AI check adds the warning on a place that otherwise passes; the owner's tags are merged in; unknown tags are ignored.
        var pub = await Places(db, Place("publish", "sensitive_alcohol")).CreateAsync(_alice, Req("Kedai Minuman Ali", 0.001, ["tobacco", "nonsense"]), ct);
        Assert.Equal(["alcohol", "tobacco"], pub.Warnings);
        Assert.Equal(PlaceStatus.Pending, pub.Status);
        var summary = Assert.Single(await Places(db, Place("publish")).ContributedAsync(_alice, ct));
        Assert.Equal(["alcohol", "tobacco"], summary.Warnings);

        // Watchlist, warn mode: a shop named after a gambling brand is listed with the gambling warning.
        var magnum = await Places(db, Place("publish")).CreateAsync(_bob, Req("Kedai Magnum 4D Bangi", 0.01), ct);
        Assert.Equal(["gambling"], magnum.Warnings);
        Assert.Equal(PlaceStatus.Pending, magnum.Status);

        // Watchlist, hold mode: never goes live on the model's say-so.
        var online = await Places(db, Place("publish")).CreateAsync(_bob, Req("Mega888 Reload Centre", 0.02), ct);
        Assert.Equal((PlaceStatus.Hidden, ScreeningState.Held), (online.Status, online.Screening!.State));

        // The owner can change the tags afterwards; the AI's stay.
        var patched = await Places(db, Place("publish")).PatchAsync(_alice, pub.Id, new PatchCommunityPlaceRequest(null, null, null, null, null, null, null, null, null, null, ["gambling"]), ct);
        Assert.Equal(["alcohol", "gambling"], patched.Warnings);
        Assert.Equal(PlaceStatus.Pending, patched.Status);
    }

    [Fact]
    public async Task Watchlist_edits_are_validated_and_audited()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var svc = new BrandWatchlistService(db, _clock);
        var b = await svc.SaveAsync(null, "Rothmans", "Rothman", BrandGroup.Tobacco, BrandPlaceMode.Warn, BrandTextMode.MentionOk, true, "maint@example.com", ct);
        await Assert.ThrowsAsync<ConflictException>(() => svc.SaveAsync(null, "rothmans", null, BrandGroup.Tobacco, BrandPlaceMode.Warn, BrandTextMode.MentionOk, true, "m", ct));
        await Assert.ThrowsAsync<ValidationException>(() => svc.SaveAsync(null, "!", null, BrandGroup.Tobacco, BrandPlaceMode.Warn, BrandTextMode.MentionOk, true, "m", ct));
        Assert.Single(await svc.TestAsync("kedai r o t h m a n s", ct));
        await svc.SaveAsync(b.Id, "Rothmans", "Rothman", BrandGroup.Tobacco, BrandPlaceMode.Warn, BrandTextMode.MentionOk, false, "maint@example.com", ct);
        Assert.Empty(await svc.TestAsync("kedai rothmans", ct));
        Assert.Equal(["brand.add", "brand.disable"], await db.AuditLog.AsNoTracking().Where(a => a.TargetType == "brand").OrderBy(a => a.Id).Select(a => a.Action).ToListAsync(ct));
    }

    [Fact]
    public async Task Rejected_content_nobody_appealed_is_purged_after_a_week()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var old = T0.AddDays(-8);
        db.Reviews.Add(new Review { PlaceId = "n77", UserId = _alice, Rating = 1, Text = "x", Status = ReviewStatus.Hidden, ModerationState = ContentState.Rejected, ModeratedAt = old });
        db.Reviews.Add(new Review { PlaceId = "n77", UserId = _bob, Rating = 1, Text = "y", Status = ReviewStatus.Hidden, ModerationState = ContentState.Rejected, ModeratedAt = old, AppealedAt = old });
        await db.SaveChangesAsync(ct);
        await Worker.Vetting.ContentScreeningRetry.PurgeRejectedAsync(db, new LocalMediaStore(_mediaDir!), T0, ct);
        Assert.Equal("y", Assert.Single(await db.Reviews.AsNoTracking().ToListAsync(ct)).Text);
    }

    // ---- appeals (POST /appeals) ----------------------------------------------------------------------

    private AppealService Appeals(GimanoDbContext db) => new(db, new LocalMediaStore(_mediaDir!), _clock);

    private static Gimano.Api.Endpoints.AppealInput Appeal(string kind, string refusal, string place, string? note = "Ini ulasan jujur", string? text = "Kedai ini bersih", int photos = 0,
        string? rating = "4", params string[] reasons) =>
        new(refusal, kind, place, text, reasons, note, rating, Enumerable.Range(0, photos).Select(_ => ImageProcessorTests.Jpeg()).ToList());

    [Fact]
    public async Task A_refused_review_appeal_needs_a_note_is_one_per_refusal_and_lands_in_the_queue_with_private_evidence()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var refusal = Guid.NewGuid().ToString();
        Assert.Equal("note_required", (await Assert.ThrowsAsync<ApiCodeException>(() => Appeals(db).CreateAsync(_alice, Appeal("review", refusal, "n77", note: " "), ct))).Code);
        Assert.Equal("note_required", (await Assert.ThrowsAsync<ApiCodeException>(() => Appeals(db).CreateAsync(_alice, Appeal("review", refusal, "n77", note: new string('x', 201)), ct))).Code);
        await Assert.ThrowsAsync<ValidationException>(() => Appeals(db).CreateAsync(_alice, Appeal("review", refusal, "n77", photos: 4), ct));

        var accepted = await Appeals(db).CreateAsync(_alice, Appeal("review", refusal, "n77", photos: 2, reasons: ["alcohol_promo", "made_up"]), ct);
        Assert.Equal("pending", accepted.Status);
        Assert.Equal("already_appealed", (await Assert.ThrowsAsync<ApiCodeException>(() => Appeals(db).CreateAsync(_alice, Appeal("review", refusal, "n77"), ct))).Code);
        // Another user may use the same client id.
        await Appeals(db).CreateAsync(_bob, Appeal("review", refusal, "n77"), ct);

        var row = await db.ContentAppeals.AsNoTracking().SingleAsync(a => a.Id == accepted.Id, ct);
        Assert.Equal("alcohol_promo", row.Reasons);
        Assert.Equal(2, AppealEvidence.Split(row.EvidenceKeys).Count);
        Assert.False(await db.Reviews.AnyAsync(ct));     // nothing is published, nothing stored as a review yet

        var item = Assert.Single(await Moderators(db).QueueAsync(ModerationKind.Appeal, hidden: true, ct), i => i.Id == accepted.Id.ToString());
        Assert.Equal(("review", "Alice", "Ini ulasan jujur", "Kedai ini bersih"), (item.AppealKind, item.AuthorName, item.AppealNote, item.Text));
        Assert.Equal(["alcohol_promo"], item.Reasons);
        Assert.Equal(2, item.EvidenceUrls!.Count);
        var bytes = await Moderators(db).EvidenceAsync(ModerationKind.Appeal, item.Id, 0, new LocalMediaStore(_mediaDir!), ct);
        Assert.NotNull(bytes);
        Assert.DoesNotContain("GimanoTestGPS", System.Text.Encoding.Latin1.GetString(bytes!));
    }

    [Fact]
    public async Task Approving_a_review_appeal_publishes_the_review_for_the_author_and_denying_tells_them_no_second_appeal()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var yes = await Appeals(db).CreateAsync(_alice, Appeal("review", Guid.NewGuid().ToString(), "n77", rating: "5"), ct);
        var pointsBefore = (await db.Users.AsNoTracking().SingleAsync(u => u.Id == _alice, ct)).Points;
        await Moderators(db).RestoreAsync(ModerationKind.Appeal, yes.Id.ToString(), ct);
        var review = await db.Reviews.AsNoTracking().SingleAsync(r => r.UserId == _alice, ct);
        Assert.Equal((ReviewStatus.Published, 5, "Kedai ini bersih", ContentState.Passed), (review.Status, review.Rating, review.Text, review.ModerationState));
        Assert.Equal(pointsBefore + CommunityRules.Points.Review, (await db.Users.AsNoTracking().SingleAsync(u => u.Id == _alice, ct)).Points);
        Assert.Contains(Screened, e => e.SubjectKind == "review" && e.SubjectId == review.Id.ToString() && e.State == ContentState.Passed && e.Late && e.AppealId is null);
        await Assert.ThrowsAsync<ConflictException>(() => Moderators(db).RestoreAsync(ModerationKind.Appeal, yes.Id.ToString(), ct));

        var no = await Appeals(db).CreateAsync(_bob, Appeal("review", Guid.NewGuid().ToString(), "n77"), ct);
        await Moderators(db).HideAsync(ModerationKind.Appeal, no.Id.ToString(), ct);
        Assert.False(await db.Reviews.AnyAsync(r => r.UserId == _bob, ct));
        Assert.Contains(Screened, e => e.SubjectKind == "review" && e.State == ContentState.Rejected && e.AppealId == no.Id);
        Assert.Empty((await Moderators(db).QueueAsync(ModerationKind.Appeal, hidden: true, ct)));
    }

    [Fact]
    public async Task A_photo_appeal_must_point_at_the_users_own_rejected_photo_and_approval_awards_the_two_points()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var photos = Photos(db, Answer("publish"));
        var dto = await photos.UploadAsync(_alice, "n77", Jpeg(), "Depan kedai", ct);
        var p = await db.Photos.Include(x => x.User).SingleAsync(x => x.Id == dto.Id, ct);
        p.Key = "k" + dto.Id.ToString("N")[..30]; p.ThumbKey = "t" + dto.Id.ToString("N")[..30];
        await Gate(db, null).ApplyPhotoAsync(p, new ContentOutcome(ContentOutcomeKind.Rejected, ["adult"]), late: true, ct);

        await Assert.ThrowsAsync<ForbiddenException>(() => Appeals(db).CreateAsync(_bob, Appeal("photo", dto.Id.ToString(), "n77"), ct));
        var a = await Appeals(db).CreateAsync(_alice, Appeal("photo", dto.Id.ToString(), "n77", photos: 1), ct);
        // The older per-photo appeal is closed by it.
        await Assert.ThrowsAsync<ConflictException>(() => photos.AppealAsync(_alice, dto.Id, "satu lagi", ct));
        Assert.Equal("already_appealed", (await Assert.ThrowsAsync<ApiCodeException>(() => Appeals(db).CreateAsync(_alice, Appeal("photo", dto.Id.ToString(), "n77"), ct))).Code);

        var before = (await db.Users.AsNoTracking().SingleAsync(u => u.Id == _alice, ct)).Points;
        await Moderators(db).RestoreAsync(ModerationKind.Appeal, a.Id.ToString(), ct);
        Assert.Equal(PhotoStatus.Published, (await photos.GetAsync(dto.Id, ct)).Status);
        Assert.Equal(before + CommunityRules.Points.Photo, (await db.Users.AsNoTracking().SingleAsync(u => u.Id == _alice, ct)).Points);
        Assert.Contains(Screened, e => e.SubjectKind == "photo" && e.SubjectId == dto.Id.ToString() && e.State == ContentState.Passed && e.Late);
    }

    [Fact]
    public async Task A_photo_a_maintainer_approves_from_the_queue_earns_two_points_once()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var photos = Photos(db, Answer("publish"));
        var dto = await photos.UploadAsync(_alice, "n77", Jpeg(), null, ct);
        var p = await db.Photos.Include(x => x.User).SingleAsync(x => x.Id == dto.Id, ct);
        p.Key = "k" + dto.Id.ToString("N")[..30]; p.ThumbKey = "t" + dto.Id.ToString("N")[..30];
        await Gate(db, null).ApplyPhotoAsync(p, new ContentOutcome(ContentOutcomeKind.Held, ["unclear"]), late: false, ct);
        var before = (await db.Users.AsNoTracking().SingleAsync(u => u.Id == _alice, ct)).Points;

        await Moderators(db).RestoreAsync(ModerationKind.Photo, dto.Id.ToString(), ct);
        Assert.Equal(before + CommunityRules.Points.Photo, (await db.Users.AsNoTracking().SingleAsync(u => u.Id == _alice, ct)).Points);
        // Hidden by reports later and restored again: already earned, not again.
        await Moderators(db).HideAsync(ModerationKind.Photo, dto.Id.ToString(), ct);
        await Moderators(db).RestoreAsync(ModerationKind.Photo, dto.Id.ToString(), ct);
        Assert.Equal(before + CommunityRules.Points.Photo, (await db.Users.AsNoTracking().SingleAsync(u => u.Id == _alice, ct)).Points);
    }

    [Fact]
    public async Task Appeal_text_note_and_evidence_are_deleted_30_days_after_the_decision_and_with_the_account()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var media = new LocalMediaStore(_mediaDir!);
        var a = await Appeals(db).CreateAsync(_alice, Appeal("review", Guid.NewGuid().ToString(), "n77", photos: 1), ct);
        var keys = (await db.ContentAppeals.AsNoTracking().SingleAsync(x => x.Id == a.Id, ct)).EvidenceKeys;
        Assert.Equal(0, await AppealRetention.RunAsync(db, media, T0.AddDays(90), ct));          // pending appeals are kept
        await Moderators(db).HideAsync(ModerationKind.Appeal, a.Id.ToString(), ct);
        Assert.Equal(0, await AppealRetention.RunAsync(db, media, T0.AddDays(29), ct));
        Assert.NotNull(await media.GetAsync(keys!, ct));

        Assert.Equal(1, await AppealRetention.RunAsync(db, media, T0.AddDays(31), ct));
        var row = await db.ContentAppeals.AsNoTracking().SingleAsync(x => x.Id == a.Id, ct);
        Assert.Equal((null, "", null), (row.Text, row.Note, row.EvidenceKeys));
        Assert.Null(await media.GetAsync(keys!, ct));
        // The row stays, so the same refusal can't be appealed twice.
        await Assert.ThrowsAsync<ApiCodeException>(() => Appeals(db).CreateAsync(_alice, Appeal("review", row.RefusalId.ToString(), "n77"), ct));

        // Older-style appeals keep their note on the review: same 30 days.
        var r = await Reviews(db, new TestGates.ContentScreener(_ => ContentResult.Failed)).CreateAsync(_bob, "n77", Review("Hmm"), ct);
        var rr = await db.Reviews.SingleAsync(x => x.Id == r.Id, ct);
        await Gate(db, null).ApplyReviewAsync(rr, new ContentOutcome(ContentOutcomeKind.Rejected, ["unclear"]), late: true, ct);
        await Reviews(db, null).AppealAsync(_bob, r.Id, "Tolong semak", ct, [ImageProcessorTests.Jpeg()]);
        Assert.NotNull((await db.Reviews.AsNoTracking().SingleAsync(x => x.Id == r.Id, ct)).AppealEvidence);
        await Moderators(db).HideAsync(ModerationKind.Review, r.Id.ToString(), ct);
        await AppealRetention.RunAsync(db, media, T0.AddDays(31), ct);
        var cleared = await db.Reviews.AsNoTracking().SingleAsync(x => x.Id == r.Id, ct);
        Assert.Equal((null, null), (cleared.AppealNote, cleared.AppealEvidence));
    }

    [Fact]
    public async Task A_map_place_can_be_flagged_with_suggested_warnings_and_the_report_waits_in_the_queue()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        await Places(db, null!).FlagAsync(_alice, "n77", FlagReason.Other, ct, ["gambling", "Alcohol", "nonsense"]);
        await Places(db, null!).FlagAsync(_alice, "n77", FlagReason.Spam, ct);          // the same user twice: ignored
        await Places(db, null!).FlagAsync(_bob, "n77", FlagReason.Other, ct, ["alcohol"]);
        await Assert.ThrowsAsync<NotFoundException>(() => Places(db, null!).FlagAsync(_alice, "n999", FlagReason.Other, ct));
        Assert.Equal(2, await db.OsmPlaceFlags.CountAsync(ct));

        var item = Assert.Single(await Moderators(db).QueueAsync(ModerationKind.Place, hidden: false, ct));
        Assert.Equal(("n77", "osm", 2, "99 Speedmart Bangi"), (item.Id, item.Status, item.FlagCount, item.Text));
        Assert.Equal(["alcohol", "gambling"], item.SuggestedWarnings);
        Assert.Null(item.AuthorRef);

        await Assert.ThrowsAsync<ConflictException>(() => Moderators(db).HideAsync(ModerationKind.Place, "n77", ct));
        await Moderators(db).RestoreAsync(ModerationKind.Place, "n77", ct);              // dismiss
        Assert.Empty(await Moderators(db).QueueAsync(ModerationKind.Place, hidden: false, ct));
    }
}
