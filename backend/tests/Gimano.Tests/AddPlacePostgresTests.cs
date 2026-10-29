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

    private async Task<CommunityPlace> SeedReplyPlaceAsync(Guid? owner)
    {
        await using var db = NewDb();
        var place = new CommunityPlace { Name = "Public test cafe", OwnerId = owner,
            Location = new GeoPoint(Lat, Lng).ToPoint(), Status = PlaceStatus.Hidden, HeldForReview = true,
            ScreeningState = ScreeningState.Held };
        db.CommunityPlaces.Add(place);
        await db.SaveChangesAsync();
        return place;
    }

    [Fact]
    public async Task Contributor_reply_is_private_to_author_audited_and_does_not_publish_or_fabricate_feedback()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var place = await SeedReplyPlaceAsync(_regular);
        await using var db = NewDb();
        var request = new PlaceContributorReplyRequest(Guid.NewGuid(), "Terima kasih. Sila cari nama sedia ada.", "duplicate");
        var result = await new PlaceContributorReplies(db, _clock).SendAsync(place.Id, request, "admin:testkey", default);
        Assert.Equal("sent", result.Status);
        Assert.False(result.Replay);
        var inbox = await db.InboxItems.SingleAsync();
        Assert.Equal(_regular, inbox.UserId);
        Assert.Equal(request.Message, inbox.Body);
        Assert.Equal((inbox.Title, inbox.Body), InboxRules.Render(inbox, "en"));
        Assert.Equal("place", inbox.RefType);
        Assert.Equal(place.Id, inbox.RefId);
        Assert.Empty(await db.Feedback.ToListAsync());
        Assert.Empty(await db.Announcements.ToListAsync());
        var audit = await db.AuditLog.SingleAsync();
        Assert.Equal("admin:testkey", audit.Actor);
        Assert.Equal("place.reply", audit.Action);
        Assert.Contains("duplicate", audit.Detail);
        Assert.DoesNotContain(request.Message!, audit.Detail!);
        Assert.DoesNotContain(_regular.ToString(), audit.Detail!);
        var current = await db.CommunityPlaces.SingleAsync(p => p.Id == place.Id);
        Assert.Equal(PlaceStatus.Hidden, current.Status);
        Assert.True(current.HeldForReview);
        Assert.False(current.Listed);
    }

    [Fact]
    public async Task Contributor_reply_retries_and_concurrent_delivery_create_one_item_and_one_audit()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var place = await SeedReplyPlaceAsync(_regular);
        var request = new PlaceContributorReplyRequest(Guid.NewGuid(), "Thank you for this public contribution.", "approved");
        async Task<PlaceContributorReplyResult> Send()
        {
            await using var db = NewDb();
            return await new PlaceContributorReplies(db, _clock).SendAsync(place.Id, request, "admin:testkey", default);
        }
        var results = await Task.WhenAll(Send(), Send());
        Assert.Single(results, r => !r.Replay);
        Assert.Equal(results[0].InboxId, results[1].InboxId);
        await using var check = NewDb();
        Assert.Equal(1, await check.InboxItems.CountAsync());
        Assert.Equal(1, await check.AuditLog.CountAsync());
        await Assert.ThrowsAsync<ConflictException>(() => new PlaceContributorReplies(check, _clock)
            .SendAsync(place.Id, request with { Message = "A different message" }, "admin:testkey", default));
    }

    [Fact]
    public async Task Contributor_reply_retry_after_inbox_retention_does_not_resend()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var place = await SeedReplyPlaceAsync(_regular);
        var request = new PlaceContributorReplyRequest(Guid.NewGuid(), "Thank you.", "approved");
        await using (var db = NewDb())
        {
            await new PlaceContributorReplies(db, _clock).SendAsync(place.Id, request, "admin:testkey", default);
            await db.InboxItems.ExecuteDeleteAsync();
        }
        await using var check = NewDb();
        var result = await new PlaceContributorReplies(check, _clock).SendAsync(place.Id, request, "admin:testkey", default);
        Assert.True(result.Replay);
        Assert.Empty(await check.InboxItems.ToListAsync());
        Assert.Equal(1, await check.AuditLog.CountAsync());
    }

    [Fact]
    public async Task Contributor_reply_with_deleted_author_is_audited_as_undeliverable()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var place = await SeedReplyPlaceAsync(null);
        await using var db = NewDb();
        var request = new PlaceContributorReplyRequest(Guid.NewGuid(), "Thank you.", "approved");
        var result = await new PlaceContributorReplies(db, _clock).SendAsync(place.Id, request, "admin:testkey", default);
        Assert.Equal("recipient_unavailable", result.Status);
        Assert.Null(result.InboxId);
        Assert.Empty(await db.InboxItems.ToListAsync());
        Assert.Single(await db.AuditLog.ToListAsync());
    }

    [Fact]
    public async Task Contributor_reply_invalid_input_and_missing_submission_write_nothing()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var place = await SeedReplyPlaceAsync(_regular);
        await using var db = NewDb();
        var service = new PlaceContributorReplies(db, _clock);
        var valid = new PlaceContributorReplyRequest(Guid.NewGuid(), "Thank you.", "approved");
        foreach (var invalid in new[] { valid with { RequestId = Guid.Empty }, valid with { Message = " " },
            valid with { Message = new string('x', 1001) }, valid with { Reason = "arbitrary private text" } })
            await Assert.ThrowsAsync<ValidationException>(() => service.SendAsync(place.Id, invalid, "admin:testkey", default));
        await Assert.ThrowsAsync<NotFoundException>(() => service.SendAsync(CommunityPlace.NewId(), valid, "admin:testkey", default));
        Assert.Empty(await db.InboxItems.ToListAsync());
        Assert.Empty(await db.AuditLog.ToListAsync());
    }

    [Fact]
    public async Task Explicit_restore_reaches_public_OpenSearch_without_exposing_unapproved_place()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var prefix = "gimano-approval" + Guid.NewGuid().ToString("N")[..10] + "-";
        var index = OpenSearchIntegrationTests.Create(prefix, out var client);
        if (index is null) { Assert.Skip("GIMANO_OS_URL not set"); return; }
        await using var db = NewDb();
        var selected = new CommunityPlace { Name = "Legacy Approval Cafe Alpha", OwnerId = _regular,
            Location = new GeoPoint(Lat, Lng).ToPoint(), Status = PlaceStatus.Pending };
        var untouched = new CommunityPlace { Name = "Legacy Approval Cafe Beta", OwnerId = _regular,
            Location = new GeoPoint(Lat, Lng + 0.001).ToPoint(), Status = PlaceStatus.Pending };
        db.CommunityPlaces.AddRange(selected, untouched);
        await db.SaveChangesAsync();
        try
        {
            await index.EnsureIndexAsync();
            await index.BulkIndexAsync(new[] { Core.Search.SearchQueryBuilder.ToDocument(selected), Core.Search.SearchQueryBuilder.ToDocument(untouched) });
            await index.RefreshAsync();
            var query = new Core.Search.SearchQuery("Legacy Approval Cafe", Lat, Lng);
            Assert.Empty(await index.SearchAsync(query));
            await new Moderation(db, _bus, new AuthorHandles(new byte[32]), _clock)
                .RestoreAsync(ModerationKind.Place, selected.Id, default, "admin:testkey");
            var changed = Assert.Single(_bus.Sent, e => e.Key == RoutingKeys.PlaceChanged);
            var doc = await Core.Search.PlaceDocuments.ForIdAsync(db, ((PlaceChangedEvent)changed.Payload).PlaceId, default);
            Assert.NotNull(doc);
            Assert.Equal(1, await index.BulkIndexAsync(new[] { doc }));
            await index.RefreshAsync();
            Assert.Equal(selected.Id, Assert.Single(await index.SearchAsync(query)).Id);
        }
        finally
        {
            var response = await client.Indices.GetAsync<OpenSearch.Net.StringResponse>(prefix + "*");
            if (response.Success && System.Text.Json.Nodes.JsonNode.Parse(response.Body) is System.Text.Json.Nodes.JsonObject rows)
                foreach (var (name, _) in rows) await client.Indices.DeleteAsync<OpenSearch.Net.StringResponse>(name);
        }
    }

    [Fact]
    public async Task Explicit_restore_lists_only_selected_legacy_pending_place_and_emits_index_and_inbox_events()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        await using var db = NewDb();
        var selected = new CommunityPlace { Name = "Verified public cafe", OwnerId = _regular,
            Location = new GeoPoint(Lat, Lng).ToPoint(), Status = PlaceStatus.Pending, ScreeningState = ScreeningState.None };
        var untouched = new CommunityPlace { Name = "Unverified public cafe", OwnerId = _regular,
            Location = new GeoPoint(Lat, Lng + 0.01).ToPoint(), Status = PlaceStatus.Pending, ScreeningState = ScreeningState.None };
        db.CommunityPlaces.AddRange(selected, untouched);
        await db.SaveChangesAsync();
        var moderation = new Moderation(db, _bus, new AuthorHandles(new byte[32]), _clock);
        await moderation.RestoreAsync(ModerationKind.Place, selected.Id, TestContext.Current.CancellationToken);
        await db.Entry(selected).ReloadAsync();
        await db.Entry(untouched).ReloadAsync();
        Assert.True(selected.Listed);
        Assert.Equal(ScreeningState.Passed, selected.ScreeningState);
        Assert.Equal(PlaceStatus.Pending, selected.Status);
        Assert.Equal(0, selected.WeightedYes);
        Assert.Contains(await db.AuditLog.ToListAsync(), a => a.Action == "place.restore" && a.TargetId == selected.Id);
        Assert.True(CommunityRules.IsSearchableBy(selected.Status, selected.OwnerId, null, selected.Listed));
        Assert.False(untouched.Listed);
        Assert.Equal(ScreeningState.None, untouched.ScreeningState);
        Assert.Contains(_bus.Sent, e => e.Key == RoutingKeys.PlaceChanged && ((PlaceChangedEvent)e.Payload).PlaceId == selected.Id);
        Assert.Single(Screened, e => e.PlaceId == selected.Id && e.State == ScreeningState.Passed && e.Late);
        await moderation.RestoreAsync(ModerationKind.Place, selected.Id, TestContext.Current.CancellationToken);
        Assert.Single(Screened, e => e.PlaceId == selected.Id && e.State == ScreeningState.Passed && e.Late);
    }

    [Fact]
    public async Task Street_rename_and_locality_enrichment_survive_index_rebuild()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var prefix = "gimano-st" + Guid.NewGuid().ToString("N")[..12] + "-";
        var index = OpenSearchIntegrationTests.Create(prefix, out var client);
        if (index is null) { Assert.Skip("GIMANO_OS_URL not set"); return; }
        await using var db = NewDb();
        try
        {
            var id = await db.Database.SqlQuery<string>($"""
                SELECT 'st-' || ST_GeoHash(ST_StartPoint(geom::geometry), 4) || '-' || left(md5(name), 10) AS "Value"
                FROM road_segments WHERE osm_way_id = 4242
                """).SingleAsync();
            var source = await Core.Search.StreetCorrections.CaptureAsync(db, id, default);
            Assert.NotNull(source);
            Assert.Equal([4242L], source.WayIds);
            var edit = new PlaceSuggestion { PlaceId = id, UserId = _regular, Status = SuggestionStatus.Applied, AppliedAt = T0,
                StreetOriginalName = source.Name, StreetWayIds = source.WayIds,
                Changes = new("Jalan Mawar Baru", null, null, null, null, null, null, null, null, null, null) };
            db.PlaceSuggestions.Add(edit);
            db.Places.Add(new Place { Id = "area-test", Name = "Petaling Jaya", Category = PlaceCategory.Area,
                Location = new GeoPoint(Lat, Lng).ToPoint(), OsmType = "node", Tags = new() { ["place"] = "city" } });
            await db.SaveChangesAsync();
            var importer = new Gimano.Importer.OsmImporter(db, _ds, index, NullLogger<Gimano.Importer.OsmImporter>.Instance);
            await importer.EnrichLocalitiesAsync(default);
            db.ChangeTracker.Clear();
            Assert.Equal("Petaling Jaya", (await db.Places.SingleAsync(p => p.Id == "n77")).Tags["manotu:locality"]);
            await importer.IndexSearchAsync(true, default);
            var query = new Core.Search.SearchQuery("Jalan Mawar Baru", Lat, Lng, Scope: Core.Search.SearchScope.Streets);
            var hits = await index.SearchAsync(Core.Search.SearchQueryBuilder.BuildStreet(query, Core.Search.QueryParser.StreetKey(query.Q)));
            Assert.Equal(id, Assert.Single(hits).Id);
            var old = await index.SearchAsync(Core.Search.SearchQueryBuilder.BuildStreet(query, Core.Search.QueryParser.StreetKey(source.Name)));
            Assert.Equal("Jalan Mawar Baru", Assert.Single(old).Name);
            await db.RoadSegments.ExecuteUpdateAsync(s => s.SetProperty(r => r.Name, "Changed upstream name"));
            await importer.IndexSearchAsync(true, default);
            Assert.Equal(id, Assert.Single(await index.SearchAsync(Core.Search.SearchQueryBuilder.BuildStreet(query, Core.Search.QueryParser.StreetKey(query.Q)))).Id);
        }
        finally
        {
            var response = await client.Indices.GetAsync<OpenSearch.Net.StringResponse>(prefix + "*");
            if (response.Success && System.Text.Json.Nodes.JsonNode.Parse(response.Body) is System.Text.Json.Nodes.JsonObject rows)
                foreach (var (name, _) in rows) await client.Indices.DeleteAsync<OpenSearch.Net.StringResponse>(name);
        }
    }

    [Fact]
    public async Task Accepted_correction_survives_source_refresh_and_viewport_uses_postgis()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        await using var db = NewDb();
        var place = await db.Places.SingleAsync(p => p.Id == "n77");
        var edit = new SuggestEditRequest("Kedai Baru SS2", null, null, null, null, null, null, null, null, true, null);
        db.PlaceSuggestions.Add(new PlaceSuggestion { PlaceId = place.Id, UserId = _regular, Changes = edit,
            Status = SuggestionStatus.Applied, CreatedAt = T0, AppliedAt = T0.AddMinutes(1) });
        await db.SaveChangesAsync();
        await Gimano.Core.Search.PlaceCorrections.ReplayAsync(db, default);
        var effective = await db.Places.SingleAsync(p => p.Id == "n77");
        Assert.Equal("Kedai Baru SS2", effective.Name);
        Assert.Equal("yes", effective.Tags["manotu:closed"]);
        effective.Name = "Stale imported name";
        effective.Tags = [];
        await db.SaveChangesAsync();
        await Gimano.Core.Search.PlaceCorrections.ReplayAsync(db, default);
        Assert.Equal("Kedai Baru SS2", (await db.Places.SingleAsync(p => p.Id == "n77")).Name);
        Assert.True(Gimano.Core.Search.SearchViewport.TryParse("101.60,3.10;101.65,3.10;101.65,3.15;101.60,3.15", out var viewport));
        Assert.Single(await db.Places.Where(p => viewport!.Polygon.Covers(p.Location)).ToListAsync());
        var doc = await Gimano.Core.Search.PlaceDocuments.ForIdAsync(db, "n77", default);
        Assert.True(doc!["closed"]!.GetValue<bool>());
    }

    [Fact]
    public async Task Passed_place_is_live_listed_and_needs_one_confirmation()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        await using var db = NewDb();
        var dto = await Svc(db, Answer("publish")).CreateAsync(_regular, Req("Gerai Nasi Kerabu Mek Na"), TestContext.Current.CancellationToken);
        Assert.Equal(PlaceStatus.Pending, dto.Status);
        Assert.Equal(ScreeningState.Passed, dto.Screening!.State);
        Assert.Equal((0d, 1d), (dto.ConfirmationsWeighted, dto.Required));
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
