using Gimano.Core.Data;
using Gimano.Core.Events;
using Microsoft.EntityFrameworkCore;
using Npgsql;
using R = Gimano.Core.Events.DropService.Result;

namespace Gimano.Tests;

/// <summary>
/// Event short links against a real PostGIS (a throwaway database per run): GIMANO_PG_TEST = a connection string to a server
/// where we may CREATE DATABASE (see backend/tests/postgres-it.ps1). Skipped otherwise.
/// </summary>
public sealed class PostgresIntegrationDropTests : IAsyncLifetime
{
    private NpgsqlDataSource? _ds;
    private string? _dbName;
    private string? _admin;

    private sealed class Clock : TimeProvider
    {
        public DateTimeOffset Now = new(2026, 10, 24, 8, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
    }

    private static readonly DropOwnerKey Owners = new(Enumerable.Range(1, 32).Select(i => (byte)i).ToArray());

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
    public async Task Lifecycle_quota_purge_and_delete_me_on_postgres()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        var clock = new Clock();
        await using var db = NewDb();
        var svc = new DropService(new EfDropStore(db), Owners, clock);
        var (me, other) = (Guid.NewGuid(), Guid.NewGuid());
        var blob = Enumerable.Repeat((byte)5, 1000).ToArray();

        var (r, c) = await svc.CreateAsync(me, blob, clock.Now.AddDays(10).ToString("O"));
        Assert.Equal(R.Ok, r);
        Assert.Equal(blob, (await svc.GetAsync(c!.DropId)).Item2);
        Assert.Equal(R.Ok, (await svc.PutAsync(c.DropId, c.WriteToken, [.. blob, 1, 2], clock.Now.AddDays(20).ToString("O"))).Item1);
        Assert.Equal(blob.Length + 2, (await svc.GetAsync(c.DropId)).Item2!.Length);
        Assert.Equal(R.Unauthorized, await svc.DeleteAsync(c.DropId, "nope"));

        // Collision on the primary key is reported, not thrown.
        var store = new EfDropStore(db);
        Assert.False(await store.TryInsertAsync(new Drop { Id = c.DropId, Blob = blob, WriteTokenHash = new byte[32], OwnerHash = new byte[32] }, default));
        Assert.Equal(blob.Length + 2, (await svc.GetAsync(c.DropId)).Item2!.Length);

        // Quota.
        for (var i = 1; i < DropService.MaxLivePerUser; i++) Assert.Equal(R.Ok, (await svc.CreateAsync(me, blob, clock.Now.AddDays(3).ToString("O"))).Item1);
        Assert.Equal(R.TooMany, (await svc.CreateAsync(me, blob, clock.Now.AddDays(3).ToString("O"))).Item1);
        var (_, theirs) = await svc.CreateAsync(other, blob, clock.Now.AddDays(3).ToString("O"));

        // Delete → 410 with the blob cleared; purge → 404.
        Assert.Equal(R.Ok, await svc.DeleteAsync(c.DropId, c.WriteToken));
        Assert.Equal(R.Gone, (await svc.GetAsync(c.DropId)).Item1);
        Assert.Empty((await db.Drops.AsNoTracking().SingleAsync(d => d.Id == c.DropId)).Blob);
        clock.Now = clock.Now.AddDays(4);                                       // the 3-day ones expired
        Assert.Equal(R.Gone, (await svc.GetAsync(theirs!.DropId)).Item1);
        Assert.Equal(DropService.MaxLivePerUser + 1, await store.PurgeAsync(clock.Now, default));
        Assert.Equal(R.NotFound, (await svc.GetAsync(c.DropId)).Item1);

        // DELETE /me removes only the user's rows.
        var (_, mine) = await svc.CreateAsync(me, blob, clock.Now.AddDays(3).ToString("O"));
        var (_, kept) = await svc.CreateAsync(other, blob, clock.Now.AddDays(3).ToString("O"));
        Assert.Equal(1, await svc.DeleteAllForUserAsync(me));
        Assert.Equal(R.NotFound, (await svc.GetAsync(mine!.DropId)).Item1);
        Assert.Equal(R.Ok, (await svc.GetAsync(kept!.DropId)).Item1);
    }
}
