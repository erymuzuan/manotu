using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Gimano.Core.Contracts;
using Gimano.Core.Geo;

namespace Gimano.Core.Tolls;

/// <summary>An OSM toll plaza node (a <c>toll_booth</c> place).</summary>
public sealed record TollPlaza(string Id, string Name, double Lat, double Lng);

/// <summary>A tariff row (see data/tolls/my-toll-rates.csv) already matched to OSM plaza ids.</summary>
public sealed record TollTariff(
    string Name, string? Highway, TollSystem System, string? EntryPlaza,
    decimal? Class0Myr, decimal? Class1Myr, string? SourceUrl, IReadOnlyCollection<string> PlaceIds);

public sealed record TollResult(IReadOnlyList<TollOnRoute> Tolls, decimal? EstimateMyr, bool FareComplete);

/// <summary>Finds the toll plazas a route passes and prices them from the curated tariff table.</summary>
public static partial class TollCalculator
{
    public const double MatchM = 25;
    /// <summary>OSM maps one physical plaza as several booth nodes (lanes, directions); nodes this close along the route are one plaza.</summary>
    public const double SamePlazaAlongM = 250;
    public const double SameNamedPlazaAlongM = 1000;

    public static TollResult Compute(IReadOnlyList<GeoPoint> route, IReadOnlyList<TollPlaza> plazas, IReadOnlyList<TollTariff> tariffs, Vehicle vehicle)
    {
        if (route.Count < 2 || plazas.Count == 0 || vehicle is Vehicle.Bicycle or Vehicle.Walk)
            return new TollResult([], null, true);

        // 1. Plaza nodes on the route, in travel order.
        var bbox = BBox.Of(route).Expand(MatchM);
        var hits = plazas
            .Where(p => bbox.Contains(p.Lat, p.Lng))
            .Select(p => (Plaza: p, Proj: GeoMath.ProjectOnLine(route, new GeoPoint(p.Lat, p.Lng))))
            .Where(x => x.Proj.DistanceM <= MatchM)
            .OrderBy(x => x.Proj.AlongM)
            .ToList();
        if (hits.Count == 0) return new TollResult([], null, true);

        // 2. Collapse booth nodes of the same physical plaza.
        var groups = new List<List<(TollPlaza Plaza, LineProjection Proj)>>();
        foreach (var h in hits)
        {
            var last = groups.LastOrDefault();
            var samePlaza = last is not null &&
                (h.Proj.AlongM - last[0].Proj.AlongM <= SamePlazaAlongM
                 // Booth lines of one named plaza (e.g. "Pantai (A)" / "(B)") can sit a few hundred metres apart.
                 || (h.Proj.AlongM - last[0].Proj.AlongM <= SameNamedPlazaAlongM
                     && SameName(NormalizeName(h.Plaza.Name), NormalizeName(last[0].Plaza.Name))));
            if (samePlaza) last!.Add(h);
            else groups.Add([h]);
        }

        var byPlace = new Dictionary<string, List<TollTariff>>();
        foreach (var t in tariffs)
            foreach (var id in t.PlaceIds)
                (byPlace.TryGetValue(id, out var l) ? l : byPlace[id] = []).Add(t);

        // Representative node: the closest to the route that has tariff data, else the closest.
        var passed = groups.Select(g =>
        {
            var withData = g.Where(x => byPlace.ContainsKey(x.Plaza.Id)).OrderBy(x => x.Proj.DistanceM).ToList();
            var rep = (withData.Count > 0 ? withData : g.OrderBy(x => x.Proj.DistanceM).ToList())[0].Plaza;
            var tariffsHere = g.SelectMany(x => byPlace.GetValueOrDefault(x.Plaza.Id) ?? []).Distinct().ToList();
            // Where the driver first reaches the plaza (its first booth node along the route), for the "toll ahead" alert.
            return (Plaza: rep, Tariffs: tariffsHere, AlongM: g.Min(x => x.Proj.AlongM));
        }).ToList();

        // 3. Price: open plazas directly; closed-system exits by the entry plaza passed earlier on this route.
        var result = new List<TollOnRoute>(passed.Count);
        var closedEntryIdx = new HashSet<int>();
        var fares = new decimal?[passed.Count];
        var systems = new TollSystem[passed.Count];
        var sources = new string?[passed.Count];
        for (var i = 0; i < passed.Count; i++)
        {
            var (plaza, tariffsHere, _) = passed[i];
            var open = tariffsHere.FirstOrDefault(t => t.System == TollSystem.Open);
            if (open is not null)
            {
                systems[i] = TollSystem.Open;
                fares[i] = FareFor(open, vehicle);
                sources[i] = open.SourceUrl;
                continue;
            }
            var exits = tariffsHere.Where(t => t.System == TollSystem.ClosedExit).ToList();
            if (exits.Count > 0)
            {
                systems[i] = TollSystem.ClosedExit;
                for (var j = i - 1; j >= 0; j--)
                {
                    var entryName = NormalizeName(passed[j].Plaza.Name);
                    var pair = exits.FirstOrDefault(t => t.EntryPlaza is { } e && SameName(NormalizeName(e), entryName));
                    if (pair is null) continue;
                    fares[i] = FareFor(pair, vehicle);
                    sources[i] = pair.SourceUrl;
                    closedEntryIdx.Add(j);
                    break;
                }
                continue;
            }
            var entry = tariffsHere.FirstOrDefault(t => t.System == TollSystem.ClosedEntry);
            systems[i] = entry is not null ? TollSystem.ClosedEntry : TollSystem.Open;
            if (entry is not null) { fares[i] = FareFor(entry, vehicle); sources[i] = entry.SourceUrl; }
        }
        foreach (var j in closedEntryIdx)
        {
            // Entering a closed system costs nothing at the entry plaza; the pair fare is charged at the exit.
            systems[j] = TollSystem.ClosedEntry;
            fares[j] ??= 0m;
            sources[j] ??= sources.Skip(j + 1).FirstOrDefault(s => s is not null);
        }

        for (var i = 0; i < passed.Count; i++)
        {
            var (plaza, tariffsHere, alongM) = passed[i];
            result.Add(new TollOnRoute(plaza.Id, DisplayName(plaza.Name), tariffsHere.Select(t => t.Highway).FirstOrDefault(h => h is not null),
                plaza.Lat, plaza.Lng, fares[i], systems[i], sources[i], Math.Round(alongM)));
        }

        var known = result.Where(t => t.FareMyr is not null).Select(t => t.FareMyr!.Value).ToList();
        var complete = result.All(t => t.FareMyr is not null);
        return new TollResult(result, known.Count > 0 ? known.Sum() : null, complete);
    }

    public static decimal? FareFor(TollTariff t, Vehicle v) => v == Vehicle.Motorcycle ? t.Class0Myr : t.Class1Myr;

    /// <summary>"Plaza Tol Pantai (A)" → "Plaza Tol Pantai": lane/direction suffixes are dropped for display.</summary>
    public static string DisplayName(string name) => LaneSuffix().Replace(name.Trim(), "").Trim();

    /// <summary>
    /// Matching key: lower-case ASCII, without "plaza/tol/toll/PLUS", parenthesised lane/direction suffixes and lane codes.
    /// "Plaza Tol Damansara (B)" and "Plaza Toll PLUS Damansara" both become "damansara".
    /// </summary>
    public static string NormalizeName(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return "";
        var s = name.Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder(s.Length);
        foreach (var c in s)
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) sb.Append(Community.TextFilter.FoldLatin(char.ToLowerInvariant(c)));
        s = sb.ToString();
        s = Parenthesised().Replace(s, " ");
        s = NonAlnum().Replace(s, " ");
        var words = s.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Where(w => w is not ("plaza" or "tol" or "toll" or "plus" or "lebuhraya" or "highway" or "expressway" or "entry" or "exit"))
            .ToList();
        // Trailing lane codes: "a", "b1", "c".
        while (words.Count > 1 && LaneCode().IsMatch(words[^1])) words.RemoveAt(words.Count - 1);
        s = string.Join(' ', words);
        return s.Replace("sungai", "sg").Replace("bukit", "bkt");
    }

    public static bool SameName(string a, string b) => a.Length > 0 && b.Length > 0 && (a == b);

    [GeneratedRegex(@"\s*(\([^)]*\)|\b[A-Z]\d?)$")]
    private static partial Regex LaneSuffix();

    [GeneratedRegex(@"\([^)]*\)")]
    private static partial Regex Parenthesised();

    [GeneratedRegex(@"[^a-z0-9]+")]
    private static partial Regex NonAlnum();

    [GeneratedRegex(@"^[a-z]\d?$")]
    private static partial Regex LaneCode();
}
