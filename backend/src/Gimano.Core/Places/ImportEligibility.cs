using System.Text.RegularExpressions;

namespace Gimano.Core.Places;

/// <summary>Public destination coverage is independent of the presentation category. No personal dwelling records.</summary>
public static partial class ImportEligibility
{
    public const string Version = "public-destinations-v1";
    private static readonly string[] Names = ["name", "name:ms", "name:en", "name:zh", "name:ta", "brand"];
    public static string? Name(IReadOnlyDictionary<string, string> tags) =>
        Names.Select(k => tags.GetValueOrDefault(k)).FirstOrDefault(v => !string.IsNullOrWhiteSpace(v));

    [GeneratedRegex(@"(?:\b(?:home|house|residence)\s+(?:of|of\s+mr)\b|\b(?:home|house)\s*$|^rumah\s+(?:mak|pak|encik|puan|cik|tuan|saya|aku)\b)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex PersonalName();

    public static bool IsBusiness(IReadOnlyDictionary<string, string> t) =>
        new[] { "shop", "office", "craft", "amenity", "tourism" }.Any(k => t.TryGetValue(k, out var v) && v is not ("no" or "private"));

    public static string? Exclusion(IReadOnlyDictionary<string, string> t)
    {
        if (t.GetValueOrDefault("addr:country") is { } c && c.ToUpperInvariant() is not ("MY" or "SG" or "BN")) return "outside_region";
        if (RestrictedAreaRules.IsRestricted(t) || t.GetValueOrDefault("military") is { } m && m != "no"
            || t.GetValueOrDefault("amenity") == "shelter" && t.GetValueOrDefault("shelter_type") == "domestic_violence"
            || t.GetValueOrDefault("office") is "intelligence" or "security") return "sensitive_site";
        if (t.GetValueOrDefault("name") is { } name && RestrictedAreaRules.HasSensitiveTerm(name)) return "sensitive_identity";
        if (t.ContainsKey("addr:unit") || t.ContainsKey("addr:door") || t.GetValueOrDefault("place") == "house") return "private_unit";
        var business = IsBusiness(t);
        if (!business && t.GetValueOrDefault("building") is "house" or "detached" or "semidetached_house" or "terrace" or "bungalow" or "residential") return "private_dwelling";
        if (!business && Name(t) is { } n && PersonalName().IsMatch(n)) return "personal_home";
        if (t.GetValueOrDefault("disused") == "yes" || t.GetValueOrDefault("abandoned") == "yes" || t.GetValueOrDefault("demolished") == "yes") return "inactive";
        return null;
    }

    public static bool IncludeNamed(IReadOnlyDictionary<string, string> tags) =>
        Exclusion(tags) is null && Name(tags) is not null && !tags.ContainsKey("highway") && !tags.ContainsKey("waterway")
        && tags.GetValueOrDefault("boundary") != "administrative";

    // Individual house/unit addresses must not bypass the POI gate. Only explicit public business addresses remain.
    public static bool IncludeAddress(IReadOnlyDictionary<string, string> tags) =>
        Exclusion(tags) is null && IsBusiness(tags) && Name(tags) is not null;
}
