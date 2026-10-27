using Gimano.Core.Geo;

namespace Gimano.Core.Search;

/// <summary>An imported area (OSM place=* or admin boundary): kind is the OSM place value or "admin".</summary>
public sealed record AreaRef(string Id, string Name, string Kind, double Lat, double Lng, double Popularity, string Country = "MY", IReadOnlyList<string>? Aliases = null);

/// <summary>
/// In-memory area lookups: "which suburb/city is this point in" (labels, reverse geocoding) and "is this phrase an area"
/// (brand + area queries such as "kfc ss2"). ~15k areas, bucketed on a 0.1° grid.
/// </summary>
public sealed class AreaLocator
{
    private static readonly HashSet<string> Local = ["suburb", "neighbourhood", "quarter", "village"];
    private static readonly HashSet<string> Town = ["city", "town"];
    private readonly Dictionary<(int, int), List<AreaRef>> _grid = new();
    private readonly Dictionary<string, List<AreaRef>> _byName = new();
    private readonly Dictionary<string, List<AreaRef>> _sectionShorthands = new();

    public int Count { get; }

    public AreaLocator(IEnumerable<AreaRef> areas)
    {
        var all = areas.ToList();
        foreach (var a in all)
        {
            Count++;
            var key = Cell(a.Lat, a.Lng);
            if (!_grid.TryGetValue(key, out var list)) _grid[key] = list = [];
            list.Add(a);
            foreach (var n in (a.Aliases ?? []).Prepend(a.Name).Select(TextNormalizer.Compact).Where(n => n.Length > 0).Distinct())
            {
                if (!_byName.TryGetValue(n, out var named)) _byName[n] = named = [];
                named.Add(a);
            }
        }
        foreach (var a in all)
        {
            var name = TextNormalizer.Compact(a.Name);
            var prefix = new[] { "seksyen", "section" }.FirstOrDefault(p => name.StartsWith(p, StringComparison.Ordinal));
            if (prefix is null) continue;
            var code = name[prefix.Length..];
            if (code.Length == 0 || !code.Any(char.IsDigit) || !code.All(char.IsLetterOrDigit)) continue;
            AddShorthand("ss" + code, a);
            // Derive city initials from imported geography, not a hand-maintained POI/city alias.
            if (Nearest(a.Lat, a.Lng, Town, 20_000) is { } town)
            {
                var words = TextNormalizer.Tokens(town.Name);
                if (words.Length >= 2) AddShorthand(string.Concat(words.Select(w => w[0])) + code, a);
            }
        }
    }

    private void AddShorthand(string key, AreaRef area)
    {
        if (!_sectionShorthands.TryGetValue(key, out var list)) _sectionShorthands[key] = list = [];
        list.Add(area);
    }

    private static (int, int) Cell(double lat, double lng) => ((int)Math.Floor(lat * 10), (int)Math.Floor(lng * 10));

    private IEnumerable<AreaRef> Around(double lat, double lng, double radiusM)
    {
        var r = (int)Math.Ceiling(radiusM / 11_000) ;
        var (cy, cx) = Cell(lat, lng);
        for (var y = cy - r; y <= cy + r; y++)
            for (var x = cx - r; x <= cx + r; x++)
                if (_grid.TryGetValue((y, x), out var list))
                    foreach (var a in list) yield return a;
    }

    private AreaRef? Nearest(double lat, double lng, HashSet<string> kinds, double radiusM) =>
        Around(lat, lng, radiusM).Where(a => kinds.Contains(a.Kind))
            .Select(a => (a, d: GeoMath.HaversineM(lat, lng, a.Lat, a.Lng))).Where(x => x.d <= radiusM)
            .OrderBy(x => x.d).Select(x => x.a).FirstOrDefault();

    /// <summary>Nearest suburb/neighbourhood/village (≤ 2.5 km) and city/town (≤ 20 km).</summary>
    public (AreaRef? Local, AreaRef? Town) Locate(double lat, double lng) =>
        (Nearest(lat, lng, Local, 2500), Nearest(lat, lng, Town, 20_000));

    /// <summary>"SS2, Petaling Jaya" (or one of them, or "").</summary>
    public string Label(double lat, double lng)
    {
        var (local, town) = Locate(lat, lng);
        return string.Join(", ", new[] { local?.Name, town?.Name }.Where(x => !string.IsNullOrEmpty(x)).Distinct());
    }

    /// <summary>The area a phrase names (exact, spacing-insensitive), preferring the one nearest to the origin, else the most popular.</summary>
    /// <summary>Resolve a named locality, optionally qualified by a parent area. Fuzzy candidates must have a unique spelling.</summary>
    public AreaRef? Resolve(string phrase, double? lat, double? lng, bool fuzzy = true)
    {
        if (Find(phrase, lat, lng) is { } exact) return exact;
        var words = phrase.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        for (var split = words.Length - 1; split >= 1; split--)
        {
            var parent = Find(string.Join(' ', words[split..]), lat, lng);
            if (parent is null) continue;
            var local = Find(string.Join(' ', words[..split]), parent.Lat, parent.Lng)
                ?? (fuzzy ? FuzzyFind(string.Join(' ', words[..split]), parent.Lat, parent.Lng) : null);
            if (local is not null && local.Id != parent.Id && local.Country == parent.Country
                && GeoMath.HaversineM(local.Lat, local.Lng, parent.Lat, parent.Lng) < 250_000) return local;
        }
        return fuzzy ? FuzzyFind(phrase, lat, lng) : null;
    }

    private AreaRef? FuzzyFind(string phrase, double? lat, double? lng)
    {
        var key = TextNormalizer.Compact(phrase);
        // A locality code is an identifier: SS17A must never lose its A or become SS18A.
        if (key.Length < 5 || key.Any(char.IsDigit)) return null;
        var budget = key.Length >= 10 ? 2 : 1;
        var matches = _byName.Keys.Where(k => !k.Any(char.IsDigit) && Math.Abs(k.Length - key.Length) <= budget)
            .Select(k => (Key: k, Distance: EditDistance(key, k))).Where(x => x.Distance <= budget).ToList();
        if (matches.Count == 0) return null;
        var best = matches.Min(x => x.Distance);
        var winners = matches.Where(x => x.Distance == best).Select(x => x.Key).Distinct().ToList();
        return winners.Count == 1 ? Find(winners[0], lat, lng) : null;
    }

    private static int EditDistance(string a, string b)
    {
        var row = Enumerable.Range(0, b.Length + 1).ToArray();
        for (var i = 1; i <= a.Length; i++)
        {
            var previous = row[0]; row[0] = i;
            for (var j = 1; j <= b.Length; j++)
            {
                var old = row[j];
                row[j] = Math.Min(Math.Min(row[j] + 1, row[j - 1] + 1), previous + (a[i - 1] == b[j - 1] ? 0 : 1));
                previous = old;
            }
        }
        return row[^1];
    }

    public AreaRef? Find(string phrase, double? lat, double? lng)
    {
        var key = TextNormalizer.Compact(phrase);
        if (!_byName.TryGetValue(key, out var list))
        {
            // Exact imported names always win (SS17 stays SS17). Inferred section shorthand needs nearby context.
            if (lat is not { } nearbyLat || lng is not { } nearbyLng || !_sectionShorthands.TryGetValue(key, out var sections)) return null;
            list = sections.Where(a => GeoMath.HaversineM(nearbyLat, nearbyLng, a.Lat, a.Lng) <= 5_000).ToList();
            if (list.Count == 0) return null;
        }
        return lat is { } la && lng is { } lo
            ? list.OrderBy(a => GeoMath.HaversineM(la, lo, a.Lat, a.Lng) / 1000 - a.Popularity * 5).First()
            : list.OrderByDescending(a => a.Popularity).First();
    }
}
