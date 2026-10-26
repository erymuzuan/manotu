namespace Gimano.Core.Community;

/// <summary>
/// "Warnings" on a place (docs/content-safety.md "Place warnings"): alcohol, gambling, tobacco. The place stays listed and routable;
/// the apps show a banner. Sources: the owner's tags, the AI check's sensitive_* codes, the brand watchlist, OSM tags.
/// </summary>
public static class PlaceWarnings
{
    public const string Alcohol = "alcohol", Gambling = "gambling", Tobacco = "tobacco";
    private static readonly string[] Order = [Alcohol, Gambling, Tobacco];
    public const int MaxFromOwner = 3;

    /// <summary>Known warnings only, in a fixed order, no duplicates. Null when there are none (so the field is omitted).</summary>
    public static IReadOnlyList<string>? Normalize(IEnumerable<string?>? warnings)
    {
        if (warnings is null) return null;
        var set = warnings.Where(w => w is not null).Select(w => w!.Trim().ToLowerInvariant()).ToHashSet();
        var list = Order.Where(set.Contains).ToList();
        return list.Count == 0 ? null : list;
    }

    public static IReadOnlyList<string> Split(string? csv) => string.IsNullOrEmpty(csv) ? [] : csv.Split(',');
    public static string? Join(IEnumerable<string?>? warnings) => Normalize(warnings) is { } n ? string.Join(',', n) : null;

    /// <summary>"sensitive_alcohol" → "alcohol", for the codes the AI check returns on a passing place.</summary>
    public static IEnumerable<string> FromReasonCodes(IEnumerable<string> reasons) =>
        reasons.Where(PlaceScreening.WarningCodes.Contains).Select(r => r["sensitive_".Length..]);

    /// <summary>
    /// OSM tags: shop=alcohol; amenity=bar|pub|biergarten|casino; leisure=adult_gaming_centre; shop=bookmaker|lottery;
    /// shop=tobacco|e-cigarette.
    /// </summary>
    public static IReadOnlyList<string>? FromOsmTags(IReadOnlyDictionary<string, string>? tags)
    {
        if (tags is null || tags.Count == 0) return null;
        var found = new List<string>();
        var shop = tags.GetValueOrDefault("shop");
        var amenity = tags.GetValueOrDefault("amenity");
        if (shop == "alcohol" || amenity is "bar" or "pub" or "biergarten") found.Add(Alcohol);
        if (amenity == "casino" || tags.GetValueOrDefault("leisure") == "adult_gaming_centre" || shop is "bookmaker" or "lottery") found.Add(Gambling);
        if (shop is "tobacco" or "e-cigarette") found.Add(Tobacco);
        return Normalize(found);
    }

    public static IReadOnlyList<string>? Merge(params IEnumerable<string?>?[] sources) => Normalize(sources.Where(s => s is not null).SelectMany(s => s!));
}
