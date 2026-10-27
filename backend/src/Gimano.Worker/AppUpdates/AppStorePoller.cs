using System.Globalization;
using System.Text.Json;
using Gimano.Core.AppVersions;
using Gimano.Core.Data;

namespace Gimano.Worker.AppUpdates;

/// <summary>
/// Hourly: asks Apple's public lookup which Manotu version is live on the App Store and records a new one
/// (docs/app-updates.md). Sends nothing about users; failures are logged without bodies and never throw.
/// </summary>
public sealed class AppStorePoller(IServiceScopeFactory scopes, IHttpClientFactory http, IConfiguration config, ILogger<AppStorePoller> logger) : BackgroundService
{
    public const string ClientName = "appstore";
    public const string LookupUrl = "https://itunes.apple.com/lookup?bundleId=my.manotu.app&country=my";

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!config.GetValue("AppUpdates:PollAppStore", true)) { logger.LogInformation("App Store polling is off (AppUpdates:PollAppStore=false)"); return; }
        using var timer = new PeriodicTimer(TimeSpan.FromHours(1));
        do { await PollOnceAsync(stoppingToken); } while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    internal async Task PollOnceAsync(CancellationToken ct)
    {
        try
        {
            using var client = http.CreateClient(ClientName);
            client.Timeout = TimeSpan.FromSeconds(10);
            using var res = await client.GetAsync(LookupUrl, ct);
            if (!res.IsSuccessStatusCode) { logger.LogWarning("App Store lookup answered {Status}", (int)res.StatusCode); return; }
            if (Parse(await res.Content.ReadAsStringAsync(ct)) is not { } found) { logger.LogWarning("App Store lookup had no usable version"); return; }
            await using var scope = scopes.CreateAsyncScope();
            var service = new AppVersionService(scope.ServiceProvider.GetRequiredService<GimanoDbContext>(), TimeProvider.System);
            if (await service.RecordReleaseAsync("ios", found.Version, found.ReleasedAt, ct))
                logger.LogInformation("App Store: new iOS version {Version} is live", found.Version);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            logger.LogWarning("App Store lookup failed: {Type}", ex.GetType().Name);   // no message or body: they could echo the request
        }
    }

    /// <summary>Reads results[0].version and currentVersionReleaseDate; null if absent or not a version.</summary>
    internal static (string Version, DateTimeOffset? ReleasedAt)? Parse(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("results", out var results) || results.ValueKind != JsonValueKind.Array || results.GetArrayLength() == 0) return null;
            var first = results[0];
            if (!first.TryGetProperty("version", out var v) || v.GetString() is not { } version || !SemVer.TryParse(version, out _)) return null;
            DateTimeOffset? at = first.TryGetProperty("currentVersionReleaseDate", out var d)
                && DateTimeOffset.TryParse(d.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed) ? parsed : null;
            return (version, at);
        }
        catch (JsonException) { return null; }
    }
}
