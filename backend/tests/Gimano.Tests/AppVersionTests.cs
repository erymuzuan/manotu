using System.Net;
using System.Net.Http;
using Gimano.Core.AppVersions;
using Gimano.Core.Data;
using Gimano.Worker.AppUpdates;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;

namespace Gimano.Tests;

public class AppVersionTests
{
    [Theory]
    [InlineData("0.4.10", "0.4.9", 1)]
    [InlineData("0.4.9", "0.4.10", -1)]
    [InlineData("1.0.0", "0.99.99", 1)]
    [InlineData("0.4", "0.4.0", 0)]
    [InlineData("v0.4.2", "0.4.2", 0)]
    [InlineData("0.4.2-beta+7", "0.4.2", 0)]
    [InlineData("garbage", "0.0.1", -1)]
    public void Semver_compares_numerically(string a, string b, int sign) => Assert.Equal(sign, Math.Sign(SemVer.Compare(a, b)));

    [Theory]
    [InlineData("")]
    [InlineData("a.b.c")]
    [InlineData("1.2.3.4")]
    [InlineData("1.-2.3")]
    public void Semver_rejects_junk(string s) => Assert.False(SemVer.TryParse(s, out _));

    [Fact]
    public void Latest_is_the_highest_not_the_last_inserted() =>
        Assert.Equal("0.4.10", AppVersionPolicy.Latest(["0.4.9", "0.4.10", "0.4.2", "junk"]));

    [Fact]
    public void ForceBelow_is_null_until_enough_releases_exist() =>
        Assert.Null(AppVersionPolicy.ForceBelow(["0.4.0", "0.4.1", "0.4.2"], null, 3));

    [Fact]
    public void ForceBelow_is_the_release_max_behind_older_than_latest() =>
        Assert.Equal("0.4.8", AppVersionPolicy.ForceBelow(["0.4.8", "0.4.9", "0.4.10", "0.4.11"], null, 3));

    [Fact]
    public void ForceBelow_takes_the_higher_of_min_and_behind()
    {
        string[] v = ["0.4.0", "0.4.1", "0.4.2", "0.4.3", "0.4.4"];
        Assert.Equal("0.4.3", AppVersionPolicy.ForceBelow(v, "0.4.3", 3));   // min beats behind (0.4.1)
        Assert.Equal("0.4.1", AppVersionPolicy.ForceBelow(v, "0.4.0", 3));   // behind beats min
        Assert.Equal("0.4.2", AppVersionPolicy.ForceBelow(["0.4.0"], "0.4.2", 3));   // min alone
    }

    [Fact]
    public void Build_omits_unknown_platforms_and_fills_default_store_url()
    {
        var t = new DateTimeOffset(2026, 10, 27, 0, 0, 0, TimeSpan.Zero);
        var r = AppVersionPolicy.Build(
            [new AppRelease { Platform = "ios", Version = "0.4.2", FirstSeenAt = t, ReleasedAt = t.AddHours(-5) }, new AppRelease { Platform = "ios", Version = "0.4.1", FirstSeenAt = t }],
            [new AppVersionConfig { Platform = "ios", MinVersion = "0.4.1" }]);
        Assert.Single(r.Platforms);
        var ios = r.Platforms["ios"];
        Assert.Equal("0.4.2", ios.Latest);
        Assert.Equal("0.4.1", ios.ForceBelow);
        Assert.Equal("https://apps.apple.com/app/id6826478029", ios.StoreUrl);
        Assert.Equal(t.AddHours(-5), ios.ReleasedAt);
        Assert.DoesNotContain("android-play", r.Platforms.Keys);
    }

    [Fact]
    public void Json_shape_is_camelCase()
    {
        var r = AppVersionPolicy.Build([new AppRelease { Platform = "android-play", Version = "0.4.2", FirstSeenAt = DateTimeOffset.UnixEpoch }], []);
        var json = System.Text.Json.JsonSerializer.Serialize(r, Gimano.Core.Contracts.GimanoJson.Options);
        Assert.Contains("\"platforms\":{\"android-play\":{\"latest\":\"0.4.2\",\"forceBelow\":null,\"storeUrl\":\"https://play.google.com/store/apps/details?id=my.manotu.app\"", json);
    }

    [Fact]
    public void AppStore_lookup_parse()
    {
        var ok = AppStorePoller.Parse("""{"resultCount":1,"results":[{"version":"0.4.2","currentVersionReleaseDate":"2026-10-26T03:04:05Z"}]}""");
        Assert.Equal("0.4.2", ok!.Value.Version);
        Assert.Equal(new DateTimeOffset(2026, 10, 26, 3, 4, 5, TimeSpan.Zero), ok.Value.ReleasedAt);
        Assert.Null(AppStorePoller.Parse("""{"resultCount":0,"results":[]}"""));
        Assert.Null(AppStorePoller.Parse("<html>"));
        Assert.Null(AppStorePoller.Parse("""{"results":[{"version":"x"}]}"""));
    }

    private sealed class Handler(Func<HttpResponseMessage> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) => Task.FromResult(respond());
    }

    private sealed class Factory(HttpMessageHandler h) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(h, disposeHandler: false);
    }

    [Fact]
    public async Task Poller_never_throws_on_failures_and_respects_the_flag()
    {
        var scopes = new ServiceCollection().BuildServiceProvider().GetRequiredService<IServiceScopeFactory>();   // no DbContext: any success path would throw
        var cfg = new ConfigurationBuilder().Build();
        foreach (var respond in new Func<HttpResponseMessage>[]
                 { () => new(HttpStatusCode.InternalServerError), () => new(HttpStatusCode.OK) { Content = new StringContent("nope") }, () => throw new HttpRequestException("down") })
            await new AppStorePoller(scopes, new Factory(new Handler(respond)), cfg, NullLogger<AppStorePoller>.Instance).PollOnceAsync(default);

        var off = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["AppUpdates:PollAppStore"] = "false" }).Build();
        var poller = new AppStorePoller(scopes, new Factory(new Handler(() => throw new InvalidOperationException("must not call"))), off, NullLogger<AppStorePoller>.Instance);
        await poller.StartAsync(default);
        await poller.StopAsync(default);
    }
}

/// <summary>Record/config round trip on a real PostGIS (GIMANO_PG_TEST); skipped otherwise.</summary>
public sealed class PostgresIntegrationAppVersionTests : IAsyncLifetime
{
    private NpgsqlDataSource? _ds;
    private string? _dbName, _admin;

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
    public async Task Record_is_idempotent_and_config_drives_forceBelow()
    {
        if (_ds is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        await using var db = NewDb();
        var s = new AppVersionService(db, TimeProvider.System);
        Assert.Empty((await s.GetAsync()).Platforms);
        Assert.True(await s.RecordReleaseAsync("android-play", "0.4.9"));
        Assert.False(await s.RecordReleaseAsync("android-play", "0.4.9"));
        foreach (var v in new[] { "0.4.10", "0.4.11", "0.4.12" }) await s.RecordReleaseAsync("android-play", v);
        var p = (await s.GetAsync()).Platforms["android-play"];
        Assert.Equal("0.4.12", p.Latest);
        Assert.Equal("0.4.9", p.ForceBelow);
        await s.SetConfigAsync("android-play", "0.4.11", null);
        Assert.Equal("0.4.11", (await s.GetAsync()).Platforms["android-play"].ForceBelow);
        await s.SetConfigAsync("android-play", "", null);
        Assert.Equal("0.4.9", (await s.GetAsync()).Platforms["android-play"].ForceBelow);
        await Assert.ThrowsAsync<Gimano.Core.Contracts.ValidationException>(() => s.RecordReleaseAsync("windows", "1.0.0"));
    }
}
