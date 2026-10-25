using System.Security.Cryptography;
using System.Text.Json;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Places;
using Microsoft.EntityFrameworkCore;
using NetTopologySuite.Simplify;

namespace Gimano.Api.Services;

/// <summary>422 with <c>code: "restricted_area"</c>; the handler words it in the request's language.</summary>
public sealed class RestrictedAreaException() : Exception("Restricted area.");

public enum RestrictedLevel { None, Near, Blocked }

/// <summary>
/// The server side of docs/api.md "Restricted areas": the authoritative distance check on every public write, and the
/// payload of GET /restricted-areas (public shapes only; curated server-only rows never leave the server).
/// </summary>
public sealed class RestrictedAreaService(GimanoDbContext db, RestrictedAreaMetrics metrics)
{
    public async Task<RestrictedLevel> LevelAsync(GeoPoint at, CancellationToken ct)
    {
        var pt = at.ToPoint();
        if (await db.RestrictedAreas.AnyAsync(a => a.Geom.IsWithinDistance(pt, RestrictedAreaRules.BlockM), ct)) return RestrictedLevel.Blocked;
        return await db.RestrictedAreas.AnyAsync(a => a.Geom.IsWithinDistance(pt, RestrictedAreaRules.ReviewM), ct)
            ? RestrictedLevel.Near : RestrictedLevel.None;
    }

    /// <summary>Throws (422) when the point is inside a restricted area or within BlockM of one; returns the level otherwise.</summary>
    public async Task<RestrictedLevel> EnsureAllowedAsync(GeoPoint at, CancellationToken ct)
    {
        var level = await LevelAsync(at, ct);
        if (level == RestrictedLevel.Blocked) Refuse();
        return level;
    }

    /// <summary>The level at a map or community place; None when the place is unknown (its own check reports that).</summary>
    public async Task<RestrictedLevel> LevelForPlaceAsync(string placeId, CancellationToken ct)
    {
        var at = CommunityPlace.IsCommunityId(placeId)
            ? await db.CommunityPlaces.Where(p => p.Id == placeId).Select(p => p.Location).FirstOrDefaultAsync(ct)
            : await db.Places.Where(p => p.Id == placeId).Select(p => p.Location).FirstOrDefaultAsync(ct);
        return at is null ? RestrictedLevel.None : await LevelAsync(new GeoPoint(at.Y, at.X), ct);
    }

    /// <summary>Counted, never logged with the user or the coordinates (privacy rule).</summary>
    public void Refuse()
    {
        Interlocked.Increment(ref metrics.Refused);
        throw new RestrictedAreaException();
    }
}

public sealed class RestrictedAreaMetrics
{
    public long Refused;
}

/// <summary>GET /restricted-areas body, rebuilt at most hourly. Version = SHA-256 of the body, also the ETag.</summary>
public sealed class RestrictedAreaSnapshot(IServiceScopeFactory scopes)
{
    public static readonly TimeSpan MaxAge = TimeSpan.FromHours(1);
    /// <summary>~10 m at Malaysian latitudes: small enough for 100 m buffers, keeps the download small.</summary>
    public const double SimplifyDegrees = 0.0001;

    private readonly SemaphoreSlim _gate = new(1, 1);
    private (byte[] Body, string Version, DateTimeOffset BuiltAt)? _current;

    public sealed record Payload(string Version, double BlockM, double ReviewM, IReadOnlyList<string> Terms, IReadOnlyList<double[][]> Areas);

    public async Task<(byte[] Body, string Version)> GetAsync(CancellationToken ct)
    {
        if (_current is { } c && DateTimeOffset.UtcNow - c.BuiltAt < MaxAge) return (c.Body, c.Version);
        await _gate.WaitAsync(ct);
        try
        {
            if (_current is { } again && DateTimeOffset.UtcNow - again.BuiltAt < MaxAge) return (again.Body, again.Version);
            await using var scope = scopes.CreateAsyncScope();
            var db = scope.ServiceProvider.GetRequiredService<GimanoDbContext>();
            var polys = await db.RestrictedAreas.AsNoTracking().Where(a => a.Public).OrderBy(a => a.Id).Select(a => a.Geom).ToListAsync(ct);
            var built = Build(polys);
            _current = (built.Body, built.Version, DateTimeOffset.UtcNow);
            return built;
        }
        finally { _gate.Release(); }
    }

    internal static (byte[] Body, string Version) Build(IEnumerable<NetTopologySuite.Geometries.Polygon> polys)
    {
        var areas = new List<double[][]>();
        foreach (var p in polys)
        {
            var simple = TopologyPreservingSimplifier.Simplify(p, SimplifyDegrees) as NetTopologySuite.Geometries.Polygon ?? p;
            var ring = simple.ExteriorRing.Coordinates;
            if (ring.Length < 4) ring = p.ExteriorRing.Coordinates;
            areas.Add(ring.Select(c => new[] { Math.Round(c.X, 6), Math.Round(c.Y, 6) }).ToArray());
        }
        // The version covers everything but itself.
        var unversioned = JsonSerializer.SerializeToUtf8Bytes(new Payload("", RestrictedAreaRules.BlockM, RestrictedAreaRules.ReviewM, RestrictedAreaRules.Terms, areas), GimanoJson.Options);
        var version = Convert.ToHexStringLower(SHA256.HashData(unversioned))[..16];
        var body = JsonSerializer.SerializeToUtf8Bytes(new Payload(version, RestrictedAreaRules.BlockM, RestrictedAreaRules.ReviewM, RestrictedAreaRules.Terms, areas), GimanoJson.Options);
        return (body, version);
    }
}
