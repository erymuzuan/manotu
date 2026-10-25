using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Gimano.Core.Contracts;

namespace Gimano.Core.Places;

/// <summary>
/// No community content in or next to military, strategic and other sensitive sites, and no security details anywhere
/// (docs/api.md "Restricted areas", docs/safety.md part 4). The apps get the same terms and distances from
/// GET /restricted-areas, so the phone check and the server check agree.
/// </summary>
public static class RestrictedAreaRules
{
    /// <summary>Inside a shape or within this distance: no public contributions (422 restricted_area).</summary>
    public const double BlockM = 100;
    /// <summary>Within this distance: places are held for a moderator, photos refused.</summary>
    public const double ReviewM = 300;
    /// <summary>One "sensitive_location" report hides the item (other reasons need CommunityRules.FlagsToHide).</summary>
    public const int SensitiveFlagsToHide = 1;

    public static int FlagsToHide(FlagReason reason, int otherwise) => reason == FlagReason.SensitiveLocation ? SensitiveFlagsToHide : otherwise;

    /// <summary>Kept as specific as possible: a match only holds the item for review, it never rejects it.</summary>
    public static readonly IReadOnlyList<string> Terms =
    [
        // military and security sites (BM / EN)
        "kem tentera", "pangkalan", "markas", "tudm", "tldm", "angkatan tentera", "rejimen", "batalion", "berek",
        "lapang sasar", "depoh senjata", "senjata", "peluru", "radar", "military", "army camp", "air base", "airbase",
        "naval base", "barracks", "armoury", "armory", "ammunition", "firing range",
        // at-risk places
        "rumah perlindungan", "rumah selamat", "safe house", "women's shelter", "womens shelter",
        // security details
        "cctv", "pengawal", "pondok pengawal", "pondok jaga", "pintu belakang", "rondaan", "waktu rondaan", "pagar rosak",
        "tiada pengawal", "tak ada pengawal", "guard post", "guardhouse", "security guard", "back entrance", "patrol",
        "security camera", "unguarded",
    ];

    private static readonly Regex Matcher = new(
        @"(?<![\p{L}\p{N}])(" + string.Join("|", Terms.Select(t => Regex.Escape(Fold(t)).Replace(@"\ ", @"\s+"))) + @")(?![\p{L}\p{N}])",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// <summary>True when the text contains a term as a whole word or phrase (case- and accent-insensitive).</summary>
    public static bool HasSensitiveTerm(params string?[] texts) =>
        texts.Any(t => !string.IsNullOrWhiteSpace(t) && Matcher.IsMatch(Fold(t!)));

    /// <summary>Lower case, accents removed, curly apostrophes straightened.</summary>
    public static string Fold(string s)
    {
        var d = s.Replace('’', '\'').ToLowerInvariant().Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder(d.Length);
        foreach (var c in d)
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) sb.Append(c);
        return sb.ToString().Normalize(NormalizationForm.FormC);
    }

    /// <summary>
    /// OSM closed ways and multipolygons imported as restricted areas: military land and sites (not historic bunkers,
    /// trenches or offshore danger areas), power plants, transmission substations (≥ 132 kV), water works and prisons.
    /// </summary>
    public static bool IsRestricted(IReadOnlyDictionary<string, string> tags)
    {
        if (tags.GetValueOrDefault("landuse") == "military") return true;
        if (tags.GetValueOrDefault("military") is { } m && m is not ("bunker" or "trench" or "danger_area" or "no")) return true;
        if (tags.GetValueOrDefault("power") == "plant") return true;
        if (tags.GetValueOrDefault("power") == "substation" && MaxVoltage(tags.GetValueOrDefault("voltage")) >= 132_000) return true;
        if (tags.GetValueOrDefault("man_made") == "water_works") return true;
        return tags.GetValueOrDefault("amenity") == "prison";
    }

    /// <summary>"275000;132000" → 275000; unparsable → 0.</summary>
    internal static int MaxVoltage(string? v)
    {
        if (string.IsNullOrWhiteSpace(v)) return 0;
        var max = 0;
        foreach (var part in v.Split(';', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
            if (int.TryParse(part, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) && n > max) max = n;
        return max;
    }
}
