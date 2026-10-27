using System.Globalization;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Microsoft.EntityFrameworkCore;
using Npgsql;

namespace Gimano.Core.AppVersions;

/// <summary>A store release we know about (docs/app-updates.md). Public facts only: no user data.</summary>
public sealed class AppRelease
{
    /// <summary>ios | android-play</summary>
    public required string Platform { get; set; }
    /// <summary>Marketing version, e.g. 0.4.2.</summary>
    public required string Version { get; set; }
    public DateTimeOffset FirstSeenAt { get; set; }
    /// <summary>When the store says it went live (iOS currentVersionReleaseDate); null when unknown.</summary>
    public DateTimeOffset? ReleasedAt { get; set; }
}

/// <summary>Per-platform update policy, set by a maintainer.</summary>
public sealed class AppVersionConfig
{
    public required string Platform { get; set; }
    /// <summary>Hard floor: apps older than this are forced to update. Null = none.</summary>
    public string? MinVersion { get; set; }
    /// <summary>Apps this many releases behind latest (by distinct recorded versions) are forced. Default 3.</summary>
    public int MaxBehind { get; set; } = 3;
    public string? StoreUrl { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}

/// <summary>Marketing semver (major.minor.patch, numeric compare so 0.4.10 &gt; 0.4.9). Pure.</summary>
public readonly record struct SemVer(int Major, int Minor, int Patch) : IComparable<SemVer>
{
    /// <summary>Accepts 1 to 3 numeric parts, with an optional leading v and a -prerelease/+build suffix that is ignored.</summary>
    public static bool TryParse(string? s, out SemVer v)
    {
        v = default;
        if (string.IsNullOrWhiteSpace(s)) return false;
        s = s.Trim();
        if (s[0] is 'v' or 'V') s = s[1..];
        var cut = s.IndexOfAny(['-', '+']);
        if (cut >= 0) s = s[..cut];
        var parts = s.Split('.');
        if (parts.Length is < 1 or > 3) return false;
        var n = new int[3];
        for (var i = 0; i < parts.Length; i++)
            if (!int.TryParse(parts[i], NumberStyles.None, CultureInfo.InvariantCulture, out n[i])) return false;
        v = new SemVer(n[0], n[1], n[2]);
        return true;
    }

    public int CompareTo(SemVer o) => (Major, Minor, Patch).CompareTo((o.Major, o.Minor, o.Patch));
    public override string ToString() => $"{Major}.{Minor}.{Patch}";

    /// <summary>Compares two version strings; unparseable ones sort lowest.</summary>
    public static int Compare(string? a, string? b) =>
        (TryParse(a, out var x), TryParse(b, out var y)) switch
        {
            (true, true) => x.CompareTo(y),
            (true, false) => 1,
            (false, true) => -1,
            _ => 0,
        };
}

public sealed record PlatformVersion(string Latest, string? ForceBelow, string? StoreUrl, DateTimeOffset? ReleasedAt);
public sealed record AppVersionsResponse(IReadOnlyDictionary<string, PlatformVersion> Platforms);

/// <summary>Pure policy: latest and forceBelow from the recorded versions and the config.</summary>
public static class AppVersionPolicy
{
    public static readonly string[] Platforms = ["ios", "android-play"];
    public const int DefaultMaxBehind = 3;

    public static readonly IReadOnlyDictionary<string, string> DefaultStoreUrls = new Dictionary<string, string>
    {
        ["ios"] = "https://apps.apple.com/app/id6826478029",
        ["android-play"] = "https://play.google.com/store/apps/details?id=my.manotu.app",
    };

    public static bool IsPlatform(string? p) => p is not null && Platforms.Contains(p);

    /// <summary>Distinct, parseable versions, oldest first.</summary>
    public static List<SemVer> Ordered(IEnumerable<string> versions) =>
        versions.Select(v => SemVer.TryParse(v, out var s) ? (SemVer?)s : null).Where(s => s is not null).Select(s => s!.Value).Distinct().Order().ToList();

    public static string? Latest(IEnumerable<string> versions) => Ordered(versions) is { Count: > 0 } o ? o[^1].ToString() : null;

    /// <summary>
    /// The higher of <paramref name="minVersion"/> and the version <paramref name="maxBehind"/> releases older than the latest
    /// (null when fewer than maxBehind older releases exist). Apps strictly below it are forced to update.
    /// </summary>
    public static string? ForceBelow(IEnumerable<string> versions, string? minVersion, int maxBehind)
    {
        var o = Ordered(versions);
        SemVer? behind = maxBehind > 0 && o.Count > maxBehind ? o[^(maxBehind + 1)] : null;
        SemVer? min = SemVer.TryParse(minVersion, out var m) ? m : null;
        var best = (behind, min) switch
        {
            (null, null) => (SemVer?)null,
            (null, _) => min,
            (_, null) => behind,
            _ => behind.Value.CompareTo(min.Value) >= 0 ? behind : min,
        };
        return best?.ToString();
    }

    public static AppVersionsResponse Build(IEnumerable<AppRelease> releases, IEnumerable<AppVersionConfig> configs)
    {
        var cfg = configs.ToDictionary(c => c.Platform);
        var result = new SortedDictionary<string, PlatformVersion>(StringComparer.Ordinal);
        foreach (var g in releases.GroupBy(r => r.Platform).Where(g => IsPlatform(g.Key)))
        {
            var rows = g.ToList();
            var latest = Latest(rows.Select(r => r.Version));
            if (latest is null) continue;
            cfg.TryGetValue(g.Key, out var c);
            var row = rows.Where(r => SemVer.TryParse(r.Version, out var s) && s.ToString() == latest).OrderBy(r => r.FirstSeenAt).First();
            result[g.Key] = new PlatformVersion(latest, ForceBelow(rows.Select(r => r.Version), c?.MinVersion, c?.MaxBehind ?? DefaultMaxBehind),
                string.IsNullOrWhiteSpace(c?.StoreUrl) ? DefaultStoreUrls[g.Key] : c!.StoreUrl, row.ReleasedAt ?? row.FirstSeenAt);
        }
        return new AppVersionsResponse(result);
    }
}

public sealed record AppVersionConfigView(string Platform, string? MinVersion, int MaxBehind, string? StoreUrl, DateTimeOffset? UpdatedAt);

/// <summary>Reads and records store releases and the update policy. Used by the API, the worker and the back office.</summary>
public sealed class AppVersionService(GimanoDbContext db, TimeProvider clock)
{
    public async Task<AppVersionsResponse> GetAsync(CancellationToken ct = default) =>
        AppVersionPolicy.Build(await db.AppReleases.AsNoTracking().ToListAsync(ct), await db.AppVersionConfigs.AsNoTracking().ToListAsync(ct));

    public async Task<IReadOnlyList<AppVersionConfigView>> ConfigsAsync(CancellationToken ct = default)
    {
        var rows = await db.AppVersionConfigs.AsNoTracking().ToListAsync(ct);
        return AppVersionPolicy.Platforms.Select(p => rows.FirstOrDefault(r => r.Platform == p) is { } r
            ? new AppVersionConfigView(p, r.MinVersion, r.MaxBehind, r.StoreUrl, r.UpdatedAt)
            : new AppVersionConfigView(p, null, AppVersionPolicy.DefaultMaxBehind, null, null)).ToList();
    }

    /// <summary>Records a release; true when it was new. Idempotent. Fills releasedAt on an existing row if it was unknown.</summary>
    public async Task<bool> RecordReleaseAsync(string platform, string version, DateTimeOffset? releasedAt = null, CancellationToken ct = default)
    {
        Check(platform);
        if (!SemVer.TryParse(version, out var v)) throw new ValidationException("version", "version must look like 0.4.2.");
        var canonical = v.ToString();
        var existing = await db.AppReleases.FirstOrDefaultAsync(r => r.Platform == platform && r.Version == canonical, ct);
        if (existing is not null)
        {
            if (existing.ReleasedAt is null && releasedAt is not null) { existing.ReleasedAt = releasedAt; await db.SaveChangesAsync(ct); }
            return false;
        }
        db.AppReleases.Add(new AppRelease { Platform = platform, Version = canonical, FirstSeenAt = clock.GetUtcNow(), ReleasedAt = releasedAt });
        try { await db.SaveChangesAsync(ct); return true; }
        catch (DbUpdateException ex) when (ex.InnerException is PostgresException { SqlState: PostgresErrorCodes.UniqueViolation })
        {
            db.ChangeTracker.Clear();   // a concurrent poll recorded it first
            return false;
        }
    }

    /// <summary>Updates the policy; null leaves a field unchanged. minVersion "" clears the floor.</summary>
    public async Task<AppVersionConfigView> SetConfigAsync(string platform, string? minVersion, int? maxBehind, string? storeUrl = null, CancellationToken ct = default)
    {
        Check(platform);
        if (minVersion is { Length: > 0 } && !SemVer.TryParse(minVersion, out _)) throw new ValidationException("minVersion", "minVersion must look like 0.4.0.");
        if (maxBehind is < 1 or > 50) throw new ValidationException("maxBehind", "maxBehind must be between 1 and 50.");
        if (storeUrl is { Length: > 0 } && (!Uri.TryCreate(storeUrl, UriKind.Absolute, out var u) || u.Scheme != Uri.UriSchemeHttps || storeUrl.Length > 300))
            throw new ValidationException("storeUrl", "storeUrl must be an https URL.");
        var c = await db.AppVersionConfigs.FirstOrDefaultAsync(x => x.Platform == platform, ct);
        if (c is null) db.AppVersionConfigs.Add(c = new AppVersionConfig { Platform = platform });
        if (minVersion is not null) c.MinVersion = minVersion.Length == 0 ? null : SemVer.TryParse(minVersion, out var m) ? m.ToString() : null;
        if (maxBehind is { } mb) c.MaxBehind = mb;
        if (storeUrl is not null) c.StoreUrl = storeUrl.Length == 0 ? null : storeUrl;
        c.UpdatedAt = clock.GetUtcNow();
        await db.SaveChangesAsync(ct);
        return new(c.Platform, c.MinVersion, c.MaxBehind, c.StoreUrl, c.UpdatedAt);
    }

    private static void Check(string platform)
    {
        if (!AppVersionPolicy.IsPlatform(platform)) throw new ValidationException("platform", "platform must be ios or android-play.");
    }
}
