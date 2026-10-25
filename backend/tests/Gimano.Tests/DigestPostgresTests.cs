using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Support;
using Microsoft.EntityFrameworkCore;
using Npgsql;
using Xunit;

namespace Gimano.Tests;

/// <summary>MaintainerDigest.CountAsync against a real PostGIS (GIMANO_PG_TEST, see backend/tests/postgres-it.ps1). Skipped otherwise.</summary>
public sealed class PostgresIntegrationDigestTests : IAsyncLifetime
{
    private NpgsqlDataSource? _ds;
    private string? _dbName;
    private string? _admin;
    private static readonly DateTimeOffset Now = new(2026, 10, 26, 0, 10, 0, TimeSpan.Zero);

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

    [Fact]
    public async Task Counts_match_the_queue_and_ages_come_from_the_oldest_item()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var ct = TestContext.Current.CancellationToken;
        var at = new GeoPoint(3.118, 101.619).ToPoint();
        await using (var db = NewDb())
        {
            var user = new User { DisplayName = "Pemandu 1", JoinedAt = Now.AddDays(-30) };
            db.Users.Add(user);
            db.Feedback.AddRange(
                new Feedback { Category = FeedbackCategory.Bug, Message = "a", CreatedAt = Now.AddHours(-2) },
                new Feedback { Category = FeedbackCategory.MapData, Message = "b", CreatedAt = Now.AddHours(-3) },
                new Feedback { Category = FeedbackCategory.Bug, Message = "c", CreatedAt = Now.AddDays(-3) },
                new Feedback { Category = FeedbackCategory.Idea, Message = "d", CreatedAt = Now.AddDays(-5), Status = FeedbackStatus.Done });
            db.CrashGroups.AddRange(
                new CrashGroup { Signature = new string('a', 64), Exception = "E", FirstSeen = Now.AddHours(-1), LastSeen = Now, Count = 1 },
                new CrashGroup { Signature = new string('b', 64), Exception = "E", FirstSeen = Now.AddDays(-9), LastSeen = Now, Count = 4, Status = CrashGroupStatus.Regressed },
                new CrashGroup { Signature = new string('c', 64), Exception = "E", FirstSeen = Now.AddDays(-9), LastSeen = Now, Count = 2, Status = CrashGroupStatus.Done });
            db.CommunityPlaces.AddRange(
                new CommunityPlace { Id = "c" + new string('1', 32), Name = "Held", Location = at, Status = PlaceStatus.Hidden, HeldForReview = true,
                    CreatedAt = Now.AddHours(-21), UpdatedAt = Now },
                new CommunityPlace { Id = "c" + new string('2', 32), Name = "Flagged", Location = at, Status = PlaceStatus.Published, FlagCount = 1,
                    CreatedAt = Now.AddDays(-4), UpdatedAt = Now },
                new CommunityPlace { Id = "c" + new string('3', 32), Name = "Fine", Location = at, Status = PlaceStatus.Published,
                    CreatedAt = Now.AddDays(-4), UpdatedAt = Now });
            await db.SaveChangesAsync(ct);
            db.PlaceFlags.Add(new PlaceFlag { PlaceId = "c" + new string('2', 32), UserId = user.Id, Reason = FlagReason.Spam, CreatedAt = Now.AddHours(-5) });
            await db.SaveChangesAsync(ct);
        }

        await using var read = NewDb();
        var c = await MaintainerDigest.CountAsync(read, Now, ct);
        Assert.Equal(2, c.FeedbackNew);
        Assert.Equal(1, c.FeedbackNewByCategory[FeedbackCategory.Bug]);
        Assert.Equal(1, c.FeedbackNewByCategory[FeedbackCategory.MapData]);
        Assert.Equal(3, c.FeedbackUntriaged);
        Assert.Equal(TimeSpan.FromDays(3), c.OldestUntriaged);
        Assert.Equal(1, c.CrashGroupsNew);
        Assert.Equal(1, c.CrashGroupsRegressed);
        Assert.Equal(2, c.CrashGroupsOpen);
        Assert.Equal(2, c.ModerationWaiting);
        Assert.Equal(1, c.PlacesHeld);
        Assert.Equal(TimeSpan.FromHours(21), c.OldestModeration);
        Assert.True(MaintainerDigest.ModerationAlertDue(c, Now, null));
    }
}
