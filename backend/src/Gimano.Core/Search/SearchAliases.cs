namespace Gimano.Core.Search;

/// <summary>
/// Index-time name variants for areas (OSM official/alt/short/old/en/ms names). Brand and rename aliases live in
/// data/search/aliases.csv and are applied to the query (<see cref="AliasTable"/>).
/// </summary>
public static class SearchAliases
{
    /// <summary>OSM name variants indexed for areas ("Wilayah Persekutuan Putrajaya", "Kuala Lumpur" for name:en …).</summary>
    public static readonly string[] AreaNameTags = ["official_name", "alt_name", "short_name", "old_name", "name:en", "name:ms", "name:zh", "name:ta"];

    public static string? AreaVariants(string name, IReadOnlyDictionary<string, string>? tags)
    {
        if (tags is null) return null;
        var hits = AreaNameTags.Select(t => tags.GetValueOrDefault(t)).OfType<string>()
            .SelectMany(v => v.Split(';', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
            .Where(v => !string.Equals(v, name, StringComparison.OrdinalIgnoreCase))
            .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        return hits.Count == 0 ? null : string.Join(' ', hits);
    }
}
