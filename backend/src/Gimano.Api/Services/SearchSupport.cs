using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Search;
using Gimano.Core.Support;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Api.Services;

/// <summary>The current alias table: Search:AliasesPath if present (re-read when the file changes), else the embedded copy.</summary>
public sealed class AliasStore : BackgroundService
{
    private readonly IConfiguration config;
    private readonly ILogger<AliasStore> logger;
    private AliasTable _table;
    private DateTime _stamp;

    public AliasStore(IConfiguration config, ILogger<AliasStore> logger)
    {
        this.config = config;
        this.logger = logger;
        _table = LoadInitial(config, logger, out _stamp);
    }

    public AliasTable Current => _table;

    private string? Path => config["Search:AliasesPath"] is { Length: > 0 } p && File.Exists(p) ? p : null;

    private static AliasTable LoadInitial(IConfiguration config, ILogger logger, out DateTime stamp)
    {
        stamp = default;
        var path = config["Search:AliasesPath"];
        if (path is { Length: > 0 } && File.Exists(path))
        {
            try { stamp = File.GetLastWriteTimeUtc(path); return AliasTable.Load(path); }
            catch (Exception ex) { logger.LogWarning("Alias file unreadable ({Message}); using the embedded copy", ex.Message); }
        }
        return AliasTable.Embedded();
    }

    /// <summary>Reloads now; returns the number of rows.</summary>
    public int Reload()
    {
        var path = Path;
        _table = path is null ? AliasTable.Embedded() : AliasTable.Load(path);
        _stamp = path is null ? default : File.GetLastWriteTimeUtc(path);
        logger.LogInformation("Search aliases loaded: {Count} rows ({Source})", _table.Entries.Count, path ?? "embedded");
        return _table.Entries.Count;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(1));
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            try
            {
                if (Path is { } p && File.GetLastWriteTimeUtc(p) != _stamp) Reload();
            }
            catch (Exception ex) { logger.LogWarning("Alias reload failed: {Message}", ex.Message); }
        }
    }
}

/// <summary>Areas (cities, towns, suburbs…) in memory for brand+area queries and reverse-geocode labels; refreshed hourly.</summary>
public sealed class AreaDirectory(IServiceScopeFactory scopes, TimeProvider clock, ILogger<AreaDirectory> logger)
{
    private AreaLocator? _locator;
    private DateTimeOffset _loadedAt;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public async Task<AreaLocator> GetAsync(CancellationToken ct)
    {
        if (_locator is { } l && clock.GetUtcNow() - _loadedAt < TimeSpan.FromHours(1)) return l;
        await _gate.WaitAsync(ct);
        try
        {
            if (_locator is { } l2 && clock.GetUtcNow() - _loadedAt < TimeSpan.FromHours(1)) return l2;
            await using var scope = scopes.CreateAsyncScope();
            var db = scope.ServiceProvider.GetRequiredService<GimanoDbContext>();
            var rows = await db.Places.AsNoTracking().Where(p => p.Category == Core.Contracts.PlaceCategory.Area)
                .Select(p => new { p.Id, p.Name, p.Tags, p.Location, p.Popularity, p.Country }).ToListAsync(ct);
            _locator = new AreaLocator(rows.Select(r => new AreaRef(r.Id, r.Name, r.Tags.GetValueOrDefault("place") ?? "admin", r.Location.Y, r.Location.X, r.Popularity, r.Country, SearchAliases.AreaNameTags.Where(r.Tags.ContainsKey).Select(t => r.Tags[t]).ToArray())));
            _loadedAt = clock.GetUtcNow();
            logger.LogInformation("Area directory: {Count} areas", _locator.Count);
            return _locator;
        }
        finally { _gate.Release(); }
    }

    /// <summary>For tests.</summary>
    public void Set(AreaLocator locator) { _locator = locator; _loadedAt = clock.GetUtcNow(); }
}

/// <summary>Counts anonymous zero-result searches (see <see cref="SearchMisses"/>). Failures never affect the search.</summary>
public sealed class SearchMissRecorder(GimanoDbContext db, TimeProvider clock, ILogger<SearchMissRecorder> logger)
{
    public async Task RecordAsync(string rawQuery, double? lat, double? lng, CancellationToken ct)
    {
        if (SearchMisses.Scrub(rawQuery) is not { } q) return;
        try
        {
            await db.Database.ExecuteSqlInterpolatedAsync($"""
                INSERT INTO search_misses (week, cell, query, count) VALUES ({SearchMisses.Week(clock.GetUtcNow())}, {SearchMisses.Cell(lat, lng)}, {q}, 1)
                ON CONFLICT (week, cell, query) DO UPDATE SET count = search_misses.count + 1
                """, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException) { logger.LogWarning("Search miss not counted: {Message}", ex.Message); }
    }
}
