using Gimano.Api.Services;
using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Messaging;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Npgsql;
using Xunit;

namespace Gimano.Tests;

/// <summary>
/// Add a place with the AI gate (design page "Add a place"), end to end against a real PostGIS (GIMANO_PG_TEST, see
/// backend/tests/postgres-it.ps1) with a scripted screener: no model is called. Skipped without a database.
/// </summary>
public sealed class PostgresIntegrationAddPlaceTests : IAsyncLifetime
{
    private NpgsqlDataSource? _ds;
    private string? _dbName;
    private string? _admin;
    private static readonly DateTimeOffset T0 = new(2026, 10, 26, 2, 0, 0, TimeSpan.Zero);
    private const double Lat = 3.1196, Lng = 101.6214;
    private readonly Bus _bus = new();
    private readonly Clock _clock = new(T0);
    private Guid _newUser, _regular, _emas;

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
        await using var db = NewDb();
        await db.Database.MigrateAsync();
        var line = new[] { new GeoPoint(Lat, Lng - 0.002), new GeoPoint(Lat, Lng + 0.002) };
        db.RoadSegments.Add(new RoadSegment { OsmWayId = 4242, Seq = 0, Name = "Jalan SS 2/24", Highway = "residential", Oneway = false, FreeFlowKmh = 30,
            LengthM = 444, FromNode = 1, ToNode = 2, Geom = GeoMath.ToLineString(line) });
        db.Places.Add(new Place { Id = "n77", Name = "99 Speedmart Bandar Baru Bangi Seksyen 9", Category = PlaceCategory.Convenience,
            Location = new GeoPoint(Lat, Lng + 0.0003).ToPoint(), OsmType = "node" });
        User U(string name, int daysOld, int accepted, Tier tier) => new() { DisplayName = name, JoinedAt = T0.AddDays(-daysOld), PlacesAccepted = accepted, Tier = tier };
        var users = new[] { U("Baru", 1, 0, Tier.Baharu), U("Biasa", 60, 5, Tier.Baharu), U("Emas", 200, 60, Tier.Emas) };
        db.Users.AddRange(users);
        await db.SaveChangesAsync();
        (_newUser, _regular, _emas) = (users[0].Id, users[1].Id, users[2].Id);
    }

    public async ValueTask DisposeAsync()
    {
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

    private static TestGates.Screener Answer(string decision, string confidence = "high", params string[] reasons) =>
        new(_ => new ScreeningResult(PlaceScreening.Normalize(decision, confidence, reasons), false));

    private CommunityService Svc(GimanoDbContext db, IPlaceScreener screener) => new(db, _bus,
        new Gimano.Api.Identity.AttestationService(new Microsoft.Extensions.Configuration.ConfigurationBuilder().Build(), null!, db, _clock,
            NullLogger<Gimano.Api.Identity.AttestationService>.Instance), _clock,
        new RestrictedAreaService(db, new()), TestGates.With(db, _clock, screener, _bus));

    private static CreatePlaceRequest Req(string name, double dLat = 0, string? notDuplicateOf = null) =>
        new(name, PlaceCategory.Restaurant, Lat + dLat, Lng, null, "Nasi lemak", null, null, null, null, notDuplicateOf);

    private IEnumerable<PlaceScreenedEvent> Screened => _bus.Sent.Where(s => s.Key == RoutingKeys.PlaceScreened).Select(s => (PlaceScreenedEvent)s.Payload);

    [Fact]
    public async Task Passed_place_is_live_listed_and_needs_one_confirmation()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        await using var db = NewDb();
        var dto = await Svc(db, Answer("publish")).CreateAsync(_regular, Req("Gerai Nasi Kerabu Mek Na"), TestContext.Current.CancellationToken);
        Assert.Equal(PlaceStatus.Pending, dto.Status);
        Assert.Equal(ScreeningState.Passed, dto.Screening!.State);
        var row = await db.CommunityPlaces.AsNoTracking().SingleAsync(p => p.Id == dto.Id, TestContext.Current.CancellationToken);
        Assert.True(row.Listed);
        Assert.Equal(1, row.RequiredConfirmations);
        Assert.True(CommunityRules.IsSearchableBy(row.Status, row.OwnerId, null, row.Listed));
        Assert.Contains(Screened, e => e.PlaceId == dto.Id && e.State == ScreeningState.Passed && !e.Late);
    }

    [Fact]
    public async Task New_contributor_with_a_medium_answer_is_held_for_a_person()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        await using var db = NewDb();
        var dto = await Svc(db, Answer("publish", "medium")).CreateAsync(_newUser, Req("Kedai Kuih Mak Teh"), TestContext.Current.CancellationToken);
        Assert.Equal(PlaceStatus.Hidden, dto.Status);
        Assert.True(dto.HeldForReview);
        Assert.Equal(ScreeningState.Held, dto.Screening!.State);
    }

    [Fact]
    public async Task Emas_is_published_at_once_and_a_reject_becomes_a_hold()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        await using var db = NewDb();
        var ok = await Svc(db, Answer("publish")).CreateAsync(_emas, Req("Bengkel Ah Seng"), TestContext.Current.CancellationToken);
        Assert.Equal(PlaceStatus.Published, ok.Status);
        var doubt = await Svc(db, Answer("reject", "high", "spam")).CreateAsync(_emas, Req("Kedai Promosi", 0.003), TestContext.Current.CancellationToken);
        Assert.Equal(ScreeningState.Held, doubt.Screening!.State);
    }

    [Fact]
    public async Task Rejected_place_can_be_edited_or_appealed_once_and_a_maintainer_can_accept_it()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var home = await Svc(db, Answer("reject", "high", "private_home")).CreateAsync(_regular, Req("Rumah Mak Teh"), ct);
        Assert.Equal(PlaceStatus.Rejected, home.Status);
        Assert.Equal(["private_home"], home.Screening!.Reasons);
        Assert.True(home.Screening.CanAppeal);
        Assert.Contains(Screened, e => e.PlaceId == home.Id && e.State == ScreeningState.Rejected);

        var appealed = await Svc(db, Answer("reject")).AppealAsync(_regular, home.Id, new AppealPlaceRequest("Dia jual kuih setiap pagi"), ct);
        Assert.Equal(PlaceStatus.Hidden, appealed.Status);
        Assert.True(appealed.Screening!.Appealed);
        await Assert.ThrowsAsync<ConflictException>(() => Svc(db, Answer("reject")).AppealAsync(_regular, home.Id, new AppealPlaceRequest(null), ct));

        var queue = await new Moderation(db, _bus, new AuthorHandles(new byte[32]), _clock).QueueAsync(ModerationKind.Place, hidden: true, ct);
        Assert.Contains(queue, i => i.Id == home.Id && i.Held && i.Text!.Contains("Dia jual kuih"));
        await new Moderation(db, _bus, new AuthorHandles(new byte[32]), _clock).RestoreAsync(ModerationKind.Place, home.Id, ct);
        var row = await db.CommunityPlaces.AsNoTracking().SingleAsync(p => p.Id == home.Id, ct);
        Assert.Equal((PlaceStatus.Pending, ScreeningState.Passed, true), (row.Status, row.ScreeningState, row.Listed));
        Assert.Contains(Screened, e => e.PlaceId == home.Id && e.State == ScreeningState.Passed && e.Late);

        // "Edit and try again": a rejected place that passes on the second look goes live.
        var ad = await Svc(db, Answer("reject", "high", "spam")).CreateAsync(_regular, Req("JUAL MURAH", 0.004), ct);
        var fixedUp = await Svc(db, Answer("publish")).PatchAsync(_regular, ad.Id,
            new PatchCommunityPlaceRequest("Kedai Runcit Pak Ali", null, null, null, null, "Kedai runcit", null, null, null, null), ct);
        Assert.Equal((PlaceStatus.Pending, ScreeningState.Passed), (fixedUp.Status, fixedUp.Screening!.State));
    }

    [Fact]
    public async Task Three_rejections_in_a_day_pause_adding()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var spam = Answer("reject", "high", "spam");
        await Svc(db, spam).CreateAsync(_regular, Req("Forex signal satu", 0.001), ct);
        await Svc(db, spam).CreateAsync(_regular, Req("Pil kurus murah", 0.002), ct);
        _clock.Now = T0.AddMinutes(61);   // past the 3-per-hour limit, so only the pause can stop the next one
        await Svc(db, spam).CreateAsync(_regular, Req("Join group sekarang", 0.003), ct);
        var paused = await Assert.ThrowsAsync<AddingPausedException>(() => Svc(db, spam).CreateAsync(_regular, Req("Lagi satu", 0.004), ct));
        Assert.Equal(T0.AddMinutes(61).AddHours(24), paused.Until);
    }

    [Fact]
    public async Task Duplicate_needs_the_users_answer_and_the_check_is_told()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var screener = Answer("publish");
        // Close enough for the 100 m trigram rule (a looser spelling like "99 Speed Mart Seksyen 9" is left to the AI check).
        const string name = "99 Speedmart Bandar Baru Bangi Sek 9";
        var dup = await Assert.ThrowsAsync<DuplicatePlaceException>(() => Svc(db, screener).CreateAsync(_regular, Req(name), ct));
        Assert.Equal("n77", dup.Existing.Id);
        var dto = await Svc(db, screener).CreateAsync(_regular, Req(name, notDuplicateOf: "n77"), ct);
        Assert.Equal(ScreeningState.Passed, dto.Screening!.State);
        Assert.Equal("99 Speedmart Bandar Baru Bangi Seksyen 9", screener.Inputs.Last().SaidDifferentFrom);
        Assert.Contains("99 Speedmart Bandar Baru Bangi Seksyen 9", screener.Inputs.Last().NearbyNames);
    }

    [Fact]
    public async Task No_answer_leaves_it_checking_and_hidden_from_others_until_the_retry()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var dto = await Svc(db, new TestGates.Screener(_ => ScreeningResult.Failed)).CreateAsync(_regular, Req("Warung Tepi Sawah"), ct);
        Assert.Equal(ScreeningState.Checking, dto.Screening!.State);
        Assert.False(CommunityRules.IsVisibleTo(dto.Status!.Value, _regular, _newUser, ScreeningState.Checking));

        var place = await db.CommunityPlaces.Include(p => p.Owner).SingleAsync(p => p.Id == dto.Id, ct);
        Assert.True(await TestGates.With(db, _clock, Answer("publish"), _bus).RunAsync(place, isEdit: false, wait: null, late: true, ct));
        Assert.Equal(ScreeningState.Passed, place.ScreeningState);
        Assert.Contains(Screened, e => e.PlaceId == dto.Id && e.State == ScreeningState.Passed && e.Late);
    }

    [Fact]
    public async Task Check_off_or_over_budget_falls_back_to_plain_vetting()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var dto = await Svc(db, new TestGates.Screener(_ => ScreeningResult.Off)).CreateAsync(_regular, Req("Surau Al-Ikhlas"), ct);
        Assert.Equal((PlaceStatus.Pending, ScreeningState.Skipped), (dto.Status, dto.Screening!.State));
        Assert.False((await db.CommunityPlaces.AsNoTracking().SingleAsync(p => p.Id == dto.Id, ct)).Listed);
    }

    [Fact]
    public async Task Haiku_screener_records_spend_and_stops_at_the_weekly_budget()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        await using var db = NewDb();
        var screener = new HaikuPlaceScreener(db, Options.Create(new ScreeningOptions { ApiKey = "not-a-real-key", WeeklyBudgetUsd = 50m }), _clock,
            NullLogger<HaikuPlaceScreener>.Instance);
        var week = PlaceScreening.WeekOf(T0);
        await screener.RecordAsync(week, 1_000_000, 0, ct);
        await screener.RecordAsync(week, 19_000_000, 20_000_000, ct);   // $1.90 + $10.00
        var row = await db.AiUsageWeeks.AsNoTracking().SingleAsync(w => w.WeekStart == week, ct);
        Assert.Equal((2, 20_000_000L, 20_000_000L, 12.00m), (row.Calls, row.InputTokens, row.OutputTokens, row.CostUsd));
        await screener.RecordAsync(week, 0, 16_000_000, ct);   // + $8.00 = $20.00, the cap (50 is clamped to 20)
        var result = await screener.ScreenAsync(new ScreeningInput("x", PlaceCategory.Other, null, null, null, null, [], null, false), ct);
        Assert.True(result.Unavailable);   // returned before any network call
    }
}
