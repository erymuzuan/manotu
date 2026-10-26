using Gimano.Api.Services;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Issues;
using Gimano.Core.Messaging;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;

namespace Gimano.Tests;

/// <summary>
/// Issues against a real PostGIS (a throwaway database per run): GIMANO_PG_TEST = a connection string to a server where we
/// may CREATE DATABASE (see backend/tests/postgres-it.ps1). Skipped otherwise.
/// </summary>
public sealed class PostgresIntegrationIssueTests : IAsyncLifetime
{
    private NpgsqlDataSource? _ds;
    private string? _dbName;
    private string? _admin;

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
        var cs = new NpgsqlConnectionStringBuilder(_admin) { Database = _dbName }.ConnectionString;
        _ds = GimanoDb.BuildDataSource(cs);
        await using var db = NewDb();
        await db.Database.MigrateAsync();
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

    private (IssueService Svc, GimanoDbContext Db, Bus Bus) Service(Clock clock)
    {
        var db = NewDb();
        var services = new ServiceCollection().AddScoped(_ => NewDb()).BuildServiceProvider();
        var directory = new IssueDirectory(services.GetRequiredService<IServiceScopeFactory>(), clock, NullLogger<IssueDirectory>.Instance);
        var bus = new Bus();
        return (new IssueService(db, bus, directory, clock, NullLogger<IssueService>.Instance), db, bus);
    }

    private static readonly DateTimeOffset T0 = new(2026, 10, 23, 2, 0, 0, TimeSpan.Zero);
    private const double Lat = 3.1196, Lng = 101.6214;

    private async Task<List<User>> SeedAsync(int users, string highway = "residential", Tier tier = Tier.Baharu, bool emasFirst = false)
    {
        await using var db = NewDb();
        var line = new[] { new GeoPoint(Lat - 0.001, Lng), new GeoPoint(Lat + 0.001, Lng) };
        db.RoadSegments.Add(new RoadSegment { OsmWayId = 4242, Seq = 0, Name = "Jalan SS 2/24", Highway = highway, Oneway = false, FreeFlowKmh = 30,
            LengthM = 222, FromNode = 1, ToNode = 2, Geom = GeoMath.ToLineString(line) });
        db.Places.Add(new Place { Id = "n77", Name = "Kedai Runcit Ali", Category = PlaceCategory.Convenience, Location = new GeoPoint(Lat, Lng + 0.0005).ToPoint(), OsmType = "node" });
        var list = Enumerable.Range(0, users).Select(k => new User
        {
            DisplayName = $"Pemandu {k}", JoinedAt = T0.AddDays(-30), Tier = emasFirst && k == 0 ? Tier.Emas : tier,
        }).ToList();
        db.Users.AddRange(list);
        await db.SaveChangesAsync();
        foreach (var u in list.Where(u => u.Tier == Tier.Emas)) db.UserKeys.Add(new UserKey { UserId = u.Id, PublicKey = new byte[32] });
        await db.SaveChangesAsync();
        return list;
    }

    private static ProximityClaim Near => new(Geohash.Encode(Lat, Lng, 6), 200);

    private static CreateIssueRequest Closed(string subtype = "accident") =>
        new(IssueKind.RoadClosedTemp, subtype, Lat + 0.00005, Lng + 0.00003, 0, null, null, null, IssueSource.Report, null);

    [Fact]
    public async Task Report_snaps_merges_confirms_and_votes_unlink_on_refute()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var users = await SeedAsync(4);
        var clock = new Clock(T0);
        var (svc, db, bus) = Service(clock);

        var a = await svc.CreateAsync(users[0].Id, Closed(), "ms", default);
        Assert.Equal(IssueState.Suspected, a.State);
        Assert.Equal(4242, a.Segment!.WayId);
        Assert.Equal("Jalan SS 2/24", a.Segment.Name);
        Assert.Equal(T0.AddHours(2), a.ExpiresAt);
        Assert.Contains("ditutup (kemalangan)", a.Summary);

        // A second driver reporting the same closure 20 m away is merged into it: two weighted votes → confirmed.
        clock.Now = T0.AddMinutes(10);
        var b = await svc.CreateAsync(users[1].Id, Closed() with { Lat = Lat - 0.0001 }, "ms", default);
        Assert.True(b.Merged);
        Assert.Equal(a.Id, b.Id);
        Assert.Equal(IssueState.Confirmed, b.State);
        Assert.Contains(bus.Sent, s => s.Key == RoutingKeys.IssueChanged && ((IssueChangedEvent)s.Payload).StateChanged && ((IssueChangedEvent)s.Payload).State == IssueState.Confirmed);
        await using (var check = NewDb())
            Assert.Equal(1, (await check.Users.FirstAsync(u => u.Id == users[0].Id)).PlacesAccepted);   // reporter accuracy

        // Two "dah dibuka" answers refute it; every vote is unlinked and the voters' accuracy is updated.
        await svc.VoteAsync(users[2].Id, a.Id, new IssueVoteRequest(IssueAnswer.Cleared, Near), default);
        await svc.VoteAsync(users[3].Id, a.Id, new IssueVoteRequest(IssueAnswer.Cleared, Near), default);
        await using var after = NewDb();
        var issue = await after.Issues.FirstAsync(i => i.Id == a.Id);
        Assert.Equal(IssueState.Refuted, issue.State);
        var votes = await after.IssueVotes.Where(v => v.IssueId == a.Id).ToListAsync();
        Assert.Equal(4, votes.Count);
        Assert.All(votes, v => { Assert.Null(v.VoterId); Assert.NotNull(v.VoterHash); Assert.Null(v.CreatedAt); });
        Assert.NotNull((await after.IssueSalts.FirstAsync(s => s.IssueId == a.Id)).ResolvedAt);
        var voter = await after.Users.FirstAsync(u => u.Id == users[2].Id);
        Assert.Equal((1, 1), (voter.VerifierVotes, voter.VerifierAgreed));
        await Assert.ThrowsAsync<ConflictException>(() => svc.VoteAsync(users[1].Id, a.Id, new IssueVoteRequest(IssueAnswer.Still, Near), default));
    }

    [Fact]
    public async Task One_way_reports_for_opposite_directions_are_not_merged()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var users = await SeedAsync(3);
        var (svc, _, _) = Service(new Clock(T0));
        CreateIssueRequest OneWay(double heading) =>
            new(IssueKind.OnewayWrongClosedDir, null, Lat, Lng + 0.00003, heading, null, null, null, IssueSource.Report, null);

        var north = await svc.CreateAsync(users[0].Id, OneWay(0), "en", default);
        var south = await svc.CreateAsync(users[1].Id, OneWay(180), "en", default);
        Assert.False(south.Merged);   // before: merged into the northbound issue as a "still" vote for the wrong direction
        Assert.NotEqual(north.Id, south.Id);
        Assert.Equal((IssueDirection.Forward, IssueDirection.Backward), (north.Direction, south.Direction));

        var north2 = await svc.CreateAsync(users[2].Id, OneWay(5), "en", default);
        Assert.True(north2.Merged);
        Assert.Equal(north.Id, north2.Id);
    }

    [Fact]
    public async Task A_withdrawn_emas_still_no_longer_counts_as_emas_support()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var users = await SeedAsync(2, emasFirst: true);   // users[0] is Emas
        var clock = new Clock(T0);
        var (svc, db, _) = Service(clock);
        var a = await svc.CreateAsync(users[1].Id,
            new CreateIssueRequest(IssueKind.OnewayWrongOpenDir, null, Lat, Lng + 0.00003, 0, null, null, null, IssueSource.Report, null), "en", default);
        await svc.VoteAsync(users[0].Id, a.Id, new IssueVoteRequest(IssueAnswer.Still, Near), default);
        await svc.VoteAsync(users[0].Id, a.Id, new IssueVoteRequest(IssueAnswer.Unsure, null), default);   // the Emas changes their mind

        // Traffic now uses the forbidden direction; "actually two-way" needs one Emas *and* that evidence.
        db.SegmentTraversalCounts.Add(new SegmentTraversalCount { WayId = 4242, Seq = 0, Direction = IssueDirection.Forward, Hour = T0.AddHours(1), Count = 6 });
        await db.SaveChangesAsync();
        clock.Now = T0.AddHours(3);
        await using var fresh = NewDb();
        var issue = await fresh.Issues.FirstAsync(i => i.Id == a.Id);
        Assert.False(issue.EmasSupport);
        Assert.Null(await IssueLedger.EvaluateAsync(fresh, issue, clock.Now, default));   // before: confirmed on the withdrawn Emas vote
    }

    [Fact]
    public async Task Concurrent_votes_on_one_issue_all_count()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var users = await SeedAsync(9, highway: "trunk");   // major road: 3 weighted + passive needed, so it stays open throughout
        var clock = new Clock(T0);
        var (svc0, _, _) = Service(clock);
        var a = await svc0.CreateAsync(users[0].Id, Closed("flood"), "en", default);

        // Eight drivers answer at the same moment, each through its own request scope (DbContext).
        await Task.WhenAll(users.Skip(1).Select(async u =>
        {
            var (svc, _, _) = Service(clock);
            await svc.VoteAsync(u.Id, a.Id, new IssueVoteRequest(IssueAnswer.Still, Near), default);
        }));

        await using var check = NewDb();
        var issue = await check.Issues.FirstAsync(i => i.Id == a.Id);
        // Before the xmin token, concurrent saves overwrote each other's WeightedStill/StillVotes.
        Assert.Equal(9, issue.StillVotes);
        Assert.Equal(9, issue.WeightedStill);
        Assert.Equal(9, await check.IssueVotes.CountAsync(v => v.IssueId == a.Id));
    }

    // ---- Store readiness: unlinking, retention, moderation (this class owns the throwaway PostGIS database) ----

    [Fact]
    public async Task Expired_road_reports_lose_their_reporter_and_votes_after_the_grace_period()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var users = await SeedAsync(2);
        await using var db = NewDb();
        Report R(DateTimeOffset expires) => new() { Type = ReportType.Hazard, Location = new GeoPoint(Lat, Lng).ToPoint(), ReporterId = users[0].Id,
            CreatedAt = expires.AddHours(-1), ExpiresAt = expires, Status = expires < T0 ? ReportStatus.Expired : ReportStatus.Active };
        var old = R(T0.AddHours(-2));
        var recent = R(T0.AddMinutes(-20));   // expired, but within the 1 h grace (thanks/reputation events may be in flight)
        var active = R(T0.AddHours(1));
        db.Reports.AddRange(old, recent, active);
        db.ReportVotes.AddRange(new ReportVote { ReportId = old.Id, UserId = users[1].Id, StillThere = true },
            new ReportVote { ReportId = active.Id, UserId = users[1].Id, StillThere = true });
        await db.SaveChangesAsync();

        var (reports, votes) = await Gimano.Core.Alerts.ReportUnlinking.RunAsync(db, T0, default);

        Assert.Equal((1, 1), (reports, votes));
        await using var check = NewDb();
        Assert.Null((await check.Reports.FirstAsync(r => r.Id == old.Id)).ReporterId);
        Assert.NotNull((await check.Reports.FirstAsync(r => r.Id == recent.Id)).ReporterId);
        Assert.NotNull((await check.Reports.FirstAsync(r => r.Id == active.Id)).ReporterId);
        Assert.False(await check.ReportVotes.AnyAsync(v => v.ReportId == old.Id));
        Assert.True(await check.ReportVotes.AnyAsync(v => v.ReportId == active.Id));
    }

    [Fact]
    public async Task Feedback_is_deleted_after_24_months_and_contact_reports_are_unlinked()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var users = await SeedAsync(1);
        var crypto = new Gimano.Core.Support.ContactCrypto(Convert.ToBase64String(new byte[32]));
        await using var db = NewDb();
        var ancient = new Feedback { UserId = users[0].Id, Message = "old", CreatedAt = T0.AddDays(-731), Screenshot = [1, 2, 3] };
        var kept = new Feedback { UserId = users[0].Id, Message = "recent", CreatedAt = T0.AddDays(-30) };
        var withContact = new Feedback { UserId = users[0].Id, Message = "reply please", CreatedAt = T0.AddDays(-1) };   // stored before the rule
        db.Feedback.AddRange(ancient, kept, withContact);
        db.ReportContacts.Add(crypto.Encrypt(ContactSubject.Feedback, ancient.Id, new ContactDetails("a@example.com", null, true), T0.AddDays(-731)));
        db.ReportContacts.Add(crypto.Encrypt(ContactSubject.Feedback, withContact.Id, new ContactDetails("b@example.com", null, true), T0.AddDays(-1)));
        await db.SaveChangesAsync();

        Assert.Equal(1, await Gimano.Core.Support.ReportRetention.FeedbackAsync(db, T0, default));
        Assert.Equal(1, await Gimano.Core.Support.ReportRetention.UnlinkContactReportsAsync(db, default));

        await using var check = NewDb();
        Assert.False(await check.Feedback.AnyAsync(f => f.Id == ancient.Id));
        Assert.False(await check.ReportContacts.AnyAsync(c => c.SubjectId == ancient.Id));
        Assert.Equal(users[0].Id, (await check.Feedback.FirstAsync(f => f.Id == kept.Id)).UserId);
        Assert.Null((await check.Feedback.FirstAsync(f => f.Id == withContact.Id)).UserId);   // the contact can't be joined to the pseudonym
        Assert.True(await check.ReportContacts.AnyAsync(c => c.SubjectId == withContact.Id));
    }

    [Fact]
    public async Task Moderation_flags_hide_places_restore_and_ban_an_author()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var users = await SeedAsync(5);
        var author = users[0];
        var placeId = "c" + new string('b', 32);
        Review review;
        Photo photo;
        await using (var seed = NewDb())
        {
            seed.CommunityPlaces.Add(new CommunityPlace { Id = placeId, Name = "Kedai Spam", OwnerId = author.Id, Status = PlaceStatus.Published,
                ResolvedAt = T0, Location = new GeoPoint(Lat, Lng).ToPoint(), CreatedAt = T0, UpdatedAt = T0 });
            seed.Reviews.Add(review = new Review { PlaceId = "n77", UserId = author.Id, Rating = 1, Text = "x" });
            seed.Photos.Add(photo = new Photo { PlaceId = "n77", UserId = author.Id, Key = "k", ThumbKey = "t", Status = PhotoStatus.Published });
            await seed.SaveChangesAsync();
        }
        var handles = new Gimano.Core.Community.AuthorHandles(new byte[32].Select((_, i) => (byte)i).ToArray());
        Gimano.Api.Services.CommunityService Community(GimanoDbContext db) => new(db, new Bus(),
            new Gimano.Api.Identity.AttestationService(new Microsoft.Extensions.Configuration.ConfigurationBuilder().Build(), null!, db, new Clock(T0),
                NullLogger<Gimano.Api.Identity.AttestationService>.Instance), new Clock(T0),
                new Gimano.Api.Services.RestrictedAreaService(db, new()), TestGates.Off(db, new Clock(T0)));

        // Three different users report the place → hidden; a repeat report by the same user doesn't count.
        foreach (var u in users.Skip(1).Take(3).Append(users[1]))
        {
            await using var db = NewDb();
            await Community(db).FlagAsync(u.Id, placeId, FlagReason.Spam, default);
        }
        await using (var db = NewDb())
        {
            var p = await db.CommunityPlaces.FirstAsync(x => x.Id == placeId);
            Assert.Equal((PlaceStatus.Hidden, 3), (p.Status, p.FlagCount));
            var queue = await new Moderation(db, new Bus(), handles, new Clock(T0)).QueueAsync(ModerationKind.Place, hidden: true, default);
            Assert.Equal(handles.For(author.Id), Assert.Single(queue).AuthorRef);
            await new Moderation(db, new Bus(), handles, new Clock(T0)).RestoreAsync(ModerationKind.Place, placeId, default);
        }
        await using (var db = NewDb())
        {
            var p = await db.CommunityPlaces.FirstAsync(x => x.Id == placeId);
            Assert.Equal((PlaceStatus.Published, 0), (p.Status, p.FlagCount));
            Assert.False(await db.PlaceFlags.AnyAsync(f => f.PlaceId == placeId));

            // Ban the author through their review: everything they published is hidden, and new contributions are refused.
            Assert.True(await new Moderation(db, new Bus(), handles, new Clock(T0)).BanAuthorAsync(ModerationKind.Review, review.Id.ToString(), default));
        }
        await using (var db = NewDb())
        {
            Assert.Equal(ReviewStatus.Hidden, (await db.Reviews.FirstAsync(r => r.Id == review.Id)).Status);
            Assert.Equal(PhotoStatus.Rejected, (await db.Photos.FirstAsync(p => p.Id == photo.Id)).Status);
            Assert.Equal(PlaceStatus.Hidden, (await db.CommunityPlaces.FirstAsync(p => p.Id == placeId)).Status);
            Assert.NotNull((await db.Users.FirstAsync(u => u.Id == author.Id)).BannedAt);
            await Assert.ThrowsAsync<ForbiddenException>(() => Community(db).CreateAsync(author.Id,
                new CreatePlaceRequest("Kedai Baru", PlaceCategory.Convenience, Lat + 0.01, Lng, null, null, null, null, null, null), default));
        }
    }

    // (Place verification lives here too: it needs the same throwaway PostGIS database.)
    [Fact]
    public async Task Legacy_verify_body_is_accepted_only_from_keyless_accounts()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var users = await SeedAsync(3, emasFirst: true);   // users[0] Emas (keyed), users[1..2] key-less
        await using (var seed = NewDb())
        {
            seed.CommunityPlaces.Add(new CommunityPlace { Id = "c" + new string('a', 32), Name = "Warung Mak Som", OwnerId = users[2].Id,
                Location = new GeoPoint(Lat, Lng).ToPoint(), CreatedAt = T0, UpdatedAt = T0 });
            await seed.SaveChangesAsync();
        }
        var legacy = new VerifyPlaceRequest(null, null, null, null, null, Exists: true, CorrectLocation: true);
        Gimano.Api.Services.CommunityService Svc(GimanoDbContext db) => new(db, new Bus(),
            new Gimano.Api.Identity.AttestationService(new Microsoft.Extensions.Configuration.ConfigurationBuilder().Build(), null!, db, new Clock(T0),
                NullLogger<Gimano.Api.Identity.AttestationService>.Instance), new Clock(T0),
                new Gimano.Api.Services.RestrictedAreaService(db, new()), TestGates.Off(db, new Clock(T0)));

        await using (var db = NewDb())
            await Assert.ThrowsAsync<ValidationException>(() => Svc(db).VerifyAsync(users[0].Id, "c" + new string('a', 32), legacy, null, default));
        await using (var db = NewDb())
        {
            var r = await Svc(db).VerifyAsync(users[1].Id, "c" + new string('a', 32), legacy, null, default);   // a real 0.1.0 app
            Assert.Equal(1, r.ConfirmationsWeighted);
        }
    }

    // (Crash grouping lives here because this class owns the throwaway PostGIS database.)
    [Fact]
    public async Task Crash_groups_count_concurrent_reports_exactly_and_reopen_when_closed()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        static CrashReport Report(string sig) => new() { Signature = sig, Exception = "NullPointerException", Kind = CrashKind.Crash, CreatedAt = T0 };

        // Ten phones hit the same new crash at once: one creates the group, the rest bump it (no lost counts, no 500).
        await Task.WhenAll(Enumerable.Range(0, 10).Select(async _ =>
        {
            await using var db = NewDb();
            await Gimano.Api.Endpoints.CrashEndpoints.RecordAsync(db, Report("sig-race"), "NullPointerException", T0, _ => { }, default);
        }));
        await using (var check = NewDb())
        {
            Assert.Equal(10, (await check.CrashGroups.FirstAsync(g => g.Signature == "sig-race")).Count);
            Assert.Equal(10, await check.CrashReports.CountAsync(r => r.Signature == "sig-race"));
        }

        // A group marked done that crashes again reopens.
        await using (var db = NewDb())
        {
            db.CrashGroups.Add(new CrashGroup { Signature = "sig-done", Exception = "X", Count = 4, FirstSeen = T0, LastSeen = T0, Status = CrashGroupStatus.Done, ClosedAt = T0 });
            await db.SaveChangesAsync();
            await Gimano.Api.Endpoints.CrashEndpoints.RecordAsync(db, Report("sig-done"), "X", T0.AddDays(1), _ => { }, default);
        }
        await using var after = NewDb();
        var g = await after.CrashGroups.FirstAsync(x => x.Signature == "sig-done");
        Assert.Equal((5, CrashGroupStatus.Open, (DateTimeOffset?)null, T0.AddDays(1)), (g.Count, g.Status, g.ClosedAt, g.LastSeen));
    }

    [Fact]
    public async Task Votes_need_proximity_and_new_accounts_weigh_nothing()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var users = await SeedAsync(3);
        var (svc, db, _) = Service(new Clock(T0));
        var a = await svc.CreateAsync(users[0].Id, Closed(), "en", default);
        await Assert.ThrowsAsync<ForbiddenException>(() => svc.VoteAsync(users[1].Id, a.Id, new IssueVoteRequest(IssueAnswer.Still, new ProximityClaim("w0zzzz", 100)), default));
        await Assert.ThrowsAsync<ValidationException>(() => svc.VoteAsync(users[1].Id, a.Id, new IssueVoteRequest(IssueAnswer.Still, null), default));
        await db.Users.Where(u => u.Id == users[2].Id).ExecuteUpdateAsync(s => s.SetProperty(u => u.JoinedAt, T0.AddDays(-1)));
        var r = await svc.VoteAsync(users[2].Id, a.Id, new IssueVoteRequest(IssueAnswer.Still, Near), default);
        Assert.Equal(IssueState.Suspected, r.State);   // < 7 days old: weight 0
        Assert.Equal(1, r.ConfirmationsWeighted);
    }

    [Fact]
    public async Task Major_roads_wait_for_passive_evidence_and_traffic_refutes()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var users = await SeedAsync(3, highway: "trunk");
        var clock = new Clock(T0);
        var (svc, db, _) = Service(clock);
        var a = await svc.CreateAsync(users[0].Id, Closed("flood"), "en", default);
        await svc.VoteAsync(users[1].Id, a.Id, new IssueVoteRequest(IssueAnswer.Still, Near), default);
        var r = await svc.VoteAsync(users[2].Id, a.Id, new IssueVoteRequest(IssueAnswer.Still, Near), default);
        Assert.Equal(IssueState.Suspected, r.State);   // major road: 3 weighted but no passive evidence
        Assert.Equal(3, r.Required);

        // Five vehicles drive through in the hour after the report → refuted by traffic (the 15-minute job).
        db.SegmentTraversalCounts.Add(new SegmentTraversalCount { WayId = 4242, Seq = 0, Direction = IssueDirection.Forward, Hour = T0.AddHours(1), Count = 5 });
        await db.SaveChangesAsync();
        clock.Now = T0.AddHours(2.5);
        var issue = await db.Issues.FirstAsync(i => i.Id == a.Id);
        Assert.Equal(IssueState.Refuted, await IssueLedger.EvaluateAsync(db, issue, clock.Now, default));
        Assert.Contains("traffic 5", issue.History[^1]);
    }

    [Fact]
    public async Task Emas_confirms_a_place_closure_which_hides_it_and_two_still_open_reopen_it()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var users = await SeedAsync(3, emasFirst: true);
        var clock = new Clock(T0);
        var (svc, db, _) = Service(clock);
        var a = await svc.CreateAsync(users[0].Id, new CreateIssueRequest(IssueKind.PlaceClosedPerm, null, Lat, Lng, null, "n77", null, null, IssueSource.PlaceEdit, null), "ms", default);
        Assert.Equal(IssueState.Confirmed, a.State);
        Assert.Equal("Kedai Runcit Ali: tutup kekal", a.Summary);

        // While confirmed, the place is hidden from search/nearby.
        var services = new ServiceCollection().AddScoped(_ => NewDb()).BuildServiceProvider();
        var directory = new IssueDirectory(services.GetRequiredService<IServiceScopeFactory>(), clock, NullLogger<IssueDirectory>.Instance);
        var snap = await directory.GetAsync(default);
        Assert.Contains("n77", snap.ClosedPlaces);
        Assert.Equal("Tutup kekal", IssueDirectory.Badge(snap, "n77", "ms")!.Label);

        Assert.True(snap.IsClosedNow("n77"));   // openNow=false while closed

        // Two "masih buka" answers reopen it (spec: reopened by 2 votes).
        var r1 = await svc.VoteAsync(users[1].Id, a.Id, new IssueVoteRequest(IssueAnswer.Cleared, Near), default);
        Assert.Equal(IssueState.Confirmed, r1.State);
        var r2 = await svc.VoteAsync(users[2].Id, a.Id, new IssueVoteRequest(IssueAnswer.Cleared, Near), default);
        Assert.Equal(IssueState.Refuted, r2.State);
        directory.Invalidate();
        Assert.DoesNotContain("n77", (await directory.GetAsync(default)).ClosedPlaces);
        Assert.False((await directory.GetAsync(default)).IsClosedNow("n77"));

        // A temporary closure (even before it's confirmed) makes the place "not open now" until its date.
        await svc.CreateAsync(users[1].Id, new CreateIssueRequest(IssueKind.PlaceClosedTemp, null, Lat, Lng, null, "n77", null, null, IssueSource.PlaceEdit,
            System.Text.Json.Nodes.JsonNode.Parse("""{"until":"2026-11-15"}""")!.AsObject()), "ms", default);
        directory.Invalidate();
        var s2 = await directory.GetAsync(default);
        Assert.True(s2.IsClosedNow("n77"));
        Assert.Equal("Tutup sementara sehingga 2026-11-15", IssueDirectory.Badge(s2, "n77", "ms")!.Label);
    }

    [Fact]
    public async Task Expiry_and_map_resolution_by_the_maintenance_rules()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var users = await SeedAsync(2);
        var clock = new Clock(T0);
        var (svc, db, _) = Service(clock);
        var closed = await svc.CreateAsync(users[0].Id, Closed("accident"), "en", default);
        var noRoad = await svc.CreateAsync(users[1].Id, new CreateIssueRequest(IssueKind.RoadNotExist, "gate", Lat, Lng, null, null, Vehicle.Car, null, IssueSource.Deviation, null), "en", default);

        clock.Now = T0.AddHours(3);
        var i1 = await db.Issues.FirstAsync(i => i.Id == closed.Id);
        Assert.Equal(IssueState.Expired, await IssueLedger.EvaluateAsync(db, i1, clock.Now, default));

        var i2 = await db.Issues.FirstAsync(i => i.Id == noRoad.Id);
        Assert.False(await Gimano.Worker.Issues.IssueMaintenance.MapNowMatchesAsync(db, i2, default));
        await db.RoadSegments.Where(s => s.OsmWayId == 4242).ExecuteDeleteAsync();
        db.RoadSegments.Add(new RoadSegment { OsmWayId = 1, Seq = 0, Highway = "residential", FreeFlowKmh = 30, LengthM = 10, FromNode = 1, ToNode = 2,
            Geom = GeoMath.ToLineString([new GeoPoint(1, 101), new GeoPoint(1.0001, 101)]) });
        await db.SaveChangesAsync();
        Assert.True(await Gimano.Worker.Issues.IssueMaintenance.MapNowMatchesAsync(db, i2, default));   // the gate's way was removed from OSM
    }

    // Restricted areas (docs/api.md "Restricted areas"): the server check is authoritative.
    [Fact]
    public async Task Restricted_areas_refuse_inside_and_hold_near_or_sensitive_places()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var users = await SeedAsync(5);
        // A ~110 m square centred ~550 m north of the seeded road.
        var (cLat, cLng, h) = (Lat + 0.005, Lng, 0.0005);
        await using (var seed = NewDb())
        {
            seed.RestrictedAreas.Add(new RestrictedArea { OsmId = 1, Geom = GeoMath.Factory.CreatePolygon(new NetTopologySuite.Geometries.Coordinate[]
            {
                new(cLng - h, cLat - h), new(cLng + h, cLat - h), new(cLng + h, cLat + h), new(cLng - h, cLat + h), new(cLng - h, cLat - h),
            }) });
            await seed.SaveChangesAsync();
        }
        Gimano.Api.Services.CommunityService Community(GimanoDbContext db) => new(db, new Bus(),
            new Gimano.Api.Identity.AttestationService(new Microsoft.Extensions.Configuration.ConfigurationBuilder().Build(), null!, db, new Clock(T0),
                NullLogger<Gimano.Api.Identity.AttestationService>.Instance), new Clock(T0),
                new Gimano.Api.Services.RestrictedAreaService(db, new()), TestGates.Off(db, new Clock(T0)));
        CreatePlaceRequest At(string name, double lat, string? description = null) =>
            new(name, PlaceCategory.Convenience, lat, Lng, null, description, null, null, null, null);

        await using (var db = NewDb())
        {
            await Assert.ThrowsAsync<RestrictedAreaException>(() => Community(db).CreateAsync(users[0].Id, At("Gerai Dalam", cLat), default));
            // 50 m outside the edge: still within BlockM.
            await Assert.ThrowsAsync<RestrictedAreaException>(() => Community(db).CreateAsync(users[0].Id, At("Gerai Pagar", cLat - h - 0.00045), default));
        }
        PlaceDto near, sensitive, fine;
        await using (var db = NewDb()) near = await Community(db).CreateAsync(users[1].Id, At("Gerai Teh Pak Mat", cLat - h - 0.0018), default);   // ~200 m
        await using (var db = NewDb()) sensitive = await Community(db).CreateAsync(users[2].Id, At("Kedai Ah Seng", Lat, "Dekat pintu belakang, pengawal jarang ada."), default);
        await using (var db = NewDb()) fine = await Community(db).CreateAsync(users[3].Id, At("Kedai Runcit Mek Na", Lat - 0.0005), default);
        Assert.Equal((PlaceStatus.Hidden, true), (near.Status, near.HeldForReview));
        Assert.Equal((PlaceStatus.Hidden, true), (sensitive.Status, sensitive.HeldForReview));
        Assert.Equal((PlaceStatus.Pending, false), (fine.Status, fine.HeldForReview));

        await using (var db = NewDb())
        {
            var handles = new Gimano.Core.Community.AuthorHandles(new byte[32].Select((_, i) => (byte)i).ToArray());
            var moderation = new Moderation(db, new Bus(), handles, new Clock(T0));
            var queue = await moderation.QueueAsync(ModerationKind.Place, hidden: true, default);
            Assert.Equal(new[] { near.Id, sensitive.Id }.Order(), queue.Where(i => i.Held).Select(i => i.Id).Order());
            await moderation.RestoreAsync(ModerationKind.Place, near.Id, default);
        }
        await using (var db = NewDb())
        {
            var p = await db.CommunityPlaces.FirstAsync(x => x.Id == near.Id);
            Assert.Equal((PlaceStatus.Pending, false), (p.Status, p.HeldForReview));
            // The owner can't move it into the area afterwards.
            await Assert.ThrowsAsync<RestrictedAreaException>(() => Community(db).PatchAsync(users[1].Id, near.Id,
                new PatchCommunityPlaceRequest(null, null, cLat, Lng, null, null, null, null, null, null), default));
            // One "sensitive_location" report hides a place (other reasons need three).
            await Community(db).FlagAsync(users[4].Id, fine.Id, FlagReason.SensitiveLocation, default);
            Assert.Equal(PlaceStatus.Hidden, (await db.CommunityPlaces.FirstAsync(x => x.Id == fine.Id)).Status);
        }
    }

    // Quick-report Undo (docs/driving.md §6.4).
    [Fact]
    public async Task Undo_withdraws_your_own_quick_report_or_your_merged_confirmation_within_two_minutes()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var users = await SeedAsync(3);
        var clock = new MutableClock(T0);
        ReportService Svc(GimanoDbContext db) => new(db, new Bus(), new GeoLookup(db, new Gimano.Api.Live.DriverSnapshotStore(clock), clock), clock,
            new Microsoft.Extensions.Caching.Memory.MemoryCache(new Microsoft.Extensions.Caching.Memory.MemoryCacheOptions()),
            new RestrictedAreaService(db, new()), TestGates.Content(db, clock));
        var req = new CreateReportRequest(ReportType.Hazard, null, Lat, Lng, 0, null);

        Guid first;
        await using (var db = NewDb()) first = (await Svc(db).CreateAsync(users[0].Id, req, default)).Report.Id;
        bool merged;
        await using (var db = NewDb()) merged = (await Svc(db).CreateAsync(users[1].Id, req, default)).Merged;
        Assert.True(merged);   // same type, same place and heading: becomes a confirmation of the first

        await using (var db = NewDb()) await Svc(db).RetractAsync(first, users[1].Id, default);
        await using (var db = NewDb())
        {
            var r = await db.Reports.FirstAsync(x => x.Id == first);
            Assert.Equal((ReportStatus.Active, 0), (r.Status, r.Confirmations));
            Assert.False(await db.ReportVotes.AnyAsync(v => v.ReportId == first && v.UserId == users[1].Id));
            await Assert.ThrowsAsync<ForbiddenException>(() => Svc(db).RetractAsync(first, users[2].Id, default));
        }

        clock.Now = T0.AddMinutes(1);
        await using (var db = NewDb()) await Svc(db).RetractAsync(first, users[0].Id, default);
        await using (var db = NewDb())
        {
            Assert.Equal(ReportStatus.Expired, (await db.Reports.FirstAsync(x => x.Id == first)).Status);
            Assert.Equal(0, (await db.Users.FirstAsync(u => u.Id == users[0].Id)).Points);
        }

        // After the window it can't be undone.
        Guid late;
        await using (var db = NewDb()) late = (await Svc(db).CreateAsync(users[2].Id, req with { Lat = Lat + 0.01 }, default)).Report.Id;
        clock.Now = T0.AddMinutes(4);
        await using (var db = NewDb()) await Assert.ThrowsAsync<ConflictException>(() => Svc(db).RetractAsync(late, users[2].Id, default));
    }

    private sealed class MutableClock(DateTimeOffset now) : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = now;
        public override DateTimeOffset GetUtcNow() => Now;
    }
}
