using System.Text.Json.Nodes;
using Gimano.Core.Contracts;
using Gimano.Core.Domain;

namespace Gimano.Core.Search;

/// <summary>Which document kinds a text query may return.</summary>
public enum SearchScope
{
    /// <summary>Places, areas and (de-boosted) streets; never house addresses or postcodes.</summary>
    Places,
    Streets,
    Addresses,
    Postcodes,
}

/// <param name="Q">Original text.</param>
/// <param name="Lat">Ranking origin (the user, or <c>near=</c>).</param>
/// <param name="Viewer">The caller (if signed in): their own pending community places are included.</param>
/// <param name="Variants">Alias rewrites of <paramref name="Q"/> (tesco → lotus's), searched as alternatives.</param>
/// <param name="Categories">Category filter (any of).</param>
/// <param name="RadiusM">Hard distance limit from the origin.</param>
/// <param name="SortNearest">Sort by distance instead of relevance (category intent, sort=nearest).</param>
public sealed record SearchQuery(string Q, double? Lat, double? Lng, int Limit = 10, PlaceCategory? Category = null, string? Country = null, Guid? Viewer = null,
    IReadOnlyList<string>? Variants = null, IReadOnlyList<PlaceCategory>? Categories = null, double? RadiusM = null, bool SortNearest = false,
    SearchScope Scope = SearchScope.Places, string? HouseNumber = null, SearchViewport? Viewport = null);

/// <summary>Per-place review/photo aggregates carried on search documents.</summary>
public sealed record PlaceAggregates(double? Rating, int ReviewCount, string? ThumbKey);

/// <summary>Builds OpenSearch request bodies for the <c>places</c> index (docs/api.md "Finding places").</summary>
public static class SearchQueryBuilder
{
    /// <summary>Base name; the effective alias is <c>OpenSearch:IndexPrefix</c> + this (e.g. "gimano-places").</summary>
    public const string IndexName = "places";
    public const int MaxLimit = 50;
    public const double ExactNameBoost = 40;
    public const double BrandBoost = 20;
    public const double WordsPrefixBoost = 15;
    public const double NamePrefixBoost = 10;
    public const double AliasBoost = 10;
    public const double AreaBoost = 6;
    public const double DuplicateRadiusM = 50;

    private static JsonObject Gauss(double lat, double lng, string offset, string scale, double decay, double weight) => new()
    {
        ["gauss"] = new JsonObject
        {
            ["location"] = new JsonObject
            {
                ["origin"] = new JsonObject { ["lat"] = lat, ["lon"] = lng },
                ["offset"] = offset, ["scale"] = scale, ["decay"] = decay,
            }
        },
        ["weight"] = weight,
    };

    private static JsonObject Term(string field, string value, double? boost = null) => boost is { } b
        ? new JsonObject { ["term"] = new JsonObject { [field] = new JsonObject { ["value"] = value, ["boost"] = b } } }
        : new JsonObject { ["term"] = new JsonObject { [field] = value } };

    private static JsonObject Terms(string field, IEnumerable<string> values) =>
        new() { ["terms"] = new JsonObject { [field] = new JsonArray(values.Select(v => (JsonNode)JsonValue.Create(v)!).ToArray()) } };

    /// <summary>Per-word typo budget: 0 edits up to 3 letters, 1 for 4–6, 2 from 7 ("ali" never becomes "abu").</summary>
    public const string WordFuzziness = "AUTO:4,7";

    /// <summary>Spacing-free keys are long, so a fixed single edit ("famlymart" → "familymart"), never two.</summary>
    private static JsonObject Fuzzy(string field, string value, double boost) =>
        new() { ["fuzzy"] = new JsonObject { [field] = new JsonObject { ["value"] = value, ["fuzziness"] = 1, ["prefix_length"] = 1, ["boost"] = boost } } };

    /// <summary>The text query: every variant (original first) contributes match alternatives and ranking boosts.</summary>
    public static JsonObject Build(SearchQuery q)
    {
        var limit = Math.Clamp(q.Limit, 1, MaxLimit);
        var texts = new List<(string Text, double Weight)> { (q.Q.Trim(), 1.0) };
        foreach (var v in q.Variants ?? []) if (!string.IsNullOrWhiteSpace(v)) texts.Add((v, 0.9));

        var anyText = new JsonArray();
        var should = new JsonArray();
        foreach (var (text, w) in texts)
        {
            var compact = TextNormalizer.Compact(text);
            var norm = TextNormalizer.Normalize(text);
            if (compact.Length == 0) continue;
            // Prefix matching for as-you-type, OR a fuzzy full-word match so typos in the last/only word still hit
            // (bool_prefix never applies fuzziness to its final prefix term).
            anyText.Add(new JsonObject
            {
                ["multi_match"] = new JsonObject
                {
                    ["query"] = norm,
                    ["type"] = "bool_prefix",
                    ["fields"] = new JsonArray("name", "name._2gram", "name._3gram", "brand^0.8", "aliases^0.9", "address^0.3", "searchText^0.5"),
                    ["operator"] = "and",
                    ["fuzziness"] = norm.Length >= 4 ? WordFuzziness : "0",
                }
            });
            if (norm.Length >= 5)
                anyText.Add(new JsonObject
                {
                    ["multi_match"] = new JsonObject
                    {
                        ["query"] = norm, ["fields"] = new JsonArray("name^0.8", "brand^0.6"), ["operator"] = "and", ["fuzziness"] = WordFuzziness, ["prefix_length"] = 1,
                    }
                });
            // Spacing-insensitive keys: "family mart" = "FamilyMart", "7 eleven" = "7-Eleven"; fuzzy for "famly mart".
            anyText.Add(Term("nameKeys", compact));
            anyText.Add(Term("brandKey", compact));
            if (compact.Length >= 3) anyText.Add(new JsonObject { ["prefix"] = new JsonObject { ["nameKey"] = compact } });
            if (compact.Length >= 4)
            {
                anyText.Add(Fuzzy("nameKeys", compact, 1));
                anyText.Add(Fuzzy("brandKey", compact, 1));
            }

            // Ranking: the whole name equal to / starting with the query, a brand hit, an alias hit, and areas beat long names
            // that merely contain the term somewhere ("Jabatan … Kuala Lumpur & Putrajaya" must not beat Putrajaya itself).
            should.Add(Term("nameKey", compact, ExactNameBoost * w));
            should.Add(Term("nameKeys", compact, WordsPrefixBoost * w));
            should.Add(Term("brandKey", compact, BrandBoost * w));
            if (compact.Length >= 3) should.Add(new JsonObject { ["prefix"] = new JsonObject { ["nameKey"] = new JsonObject { ["value"] = compact, ["boost"] = NamePrefixBoost * w } } });
            if (compact.Length >= 4) should.Add(Fuzzy("brandKey", compact, BrandBoost * 0.5 * w));
            should.Add(new JsonObject { ["match_phrase_prefix"] = new JsonObject { ["name"] = new JsonObject { ["query"] = norm, ["boost"] = 3 * w } } });
            should.Add(new JsonObject { ["match"] = new JsonObject { ["aliases"] = new JsonObject { ["query"] = norm, ["boost"] = AliasBoost * w } } });
        }
        should.Add(Term("status", "published", 2));
        should.Add(Term("communityUpdated", "true", 2));
        should.Add(Term("category", "area", AreaBoost));
        if (q.Country is null) should.Add(Term("country", "MY", 0.5));

        var filter = Filters(q);
        var mustNot = new JsonArray();
        if (q.Scope == SearchScope.Places) mustNot.Add(Terms("category", ["address", "postcode"]));

        JsonNode query = new JsonObject
        {
            ["bool"] = new JsonObject
            {
                ["must"] = new JsonArray(new JsonObject { ["bool"] = new JsonObject { ["should"] = anyText, ["minimum_should_match"] = 1 } }),
                ["should"] = should, ["filter"] = filter, ["must_not"] = mustNot,
            }
        };
        // Streets are found by the street-address path; in a place search they only fill in after places.
        if (q.Scope == SearchScope.Places)
            query = new JsonObject
            {
                ["boosting"] = new JsonObject { ["positive"] = query, ["negative"] = Term("category", "street"), ["negative_boost"] = 0.2 }
            };

        var functions = new JsonArray
        {
            new JsonObject { ["field_value_factor"] = new JsonObject { ["field"] = "popularity", ["modifier"] = "log2p", ["factor"] = 1, ["missing"] = 1 } }
        };
        if (q.Lat is { } lat && q.Lng is { } lng)
        {
            // Two distance terms: a broad one (the metro area matters) and a local one (among equal names, nearest first).
            // Both are additive with popularity, so a strong name match far away still beats a weak one nearby.
            functions.Add(Gauss(lat, lng, "500m", "20km", 0.5, 2.5));
            functions.Add(Gauss(lat, lng, "0km", "3km", 0.5, 1.5));
        }

        var body = new JsonObject
        {
            // Over-fetch so near-duplicates (same name within 50 m) can be collapsed and chains regrouped, and still fill the page.
            ["size"] = Math.Min(MaxLimit, limit * 2 + 5),
            ["_source"] = SourceFields(),
            ["track_total_hits"] = false,
            ["query"] = new JsonObject
            {
                ["function_score"] = new JsonObject
                {
                    ["query"] = query, ["functions"] = functions, ["score_mode"] = "sum", ["boost_mode"] = "multiply",
                }
            },
        };
        if (q.SortNearest && q.Lat is { } sl && q.Lng is { } sg) body["sort"] = NearestSort(sl, sg);
        return q.Viewport?.Constrain(body) ?? body;
    }

    /// <summary>"Nearest X": category filter, optional radius, distance order (step 5).</summary>
    public static JsonObject BuildCategory(SearchQuery q)
    {
        var filter = Filters(q);
        return new JsonObject
        {
            ["size"] = Math.Clamp(q.Limit, 1, MaxLimit) * 2 + 5,
            ["_source"] = SourceFields(),
            ["track_total_hits"] = false,
            ["query"] = new JsonObject { ["bool"] = new JsonObject { ["filter"] = filter } },
            ["sort"] = q.Lat is { } lat && q.Lng is { } lng
                ? NearestSort(lat, lng)
                : new JsonArray(new JsonObject { ["popularity"] = new JsonObject { ["order"] = "desc" } }),
        };
    }

    /// <summary>Streets by street key (step 6), or house addresses on that street when a house number is given; nearest first.</summary>
    public static JsonObject BuildStreet(SearchQuery q, string streetKey)
    {
        var filter = new JsonArray
        {
            Term("category", q.Scope == SearchScope.Addresses ? "address" : "street"),
        };
        if (q.Scope == SearchScope.Addresses && q.HouseNumber is { } hn) filter.Add(Term("houseNumber", hn.ToLowerInvariant()));
        if (q.Country is { } c) filter.Add(Term("country", c));
        var must = new JsonArray
        {
            new JsonObject
            {
                ["bool"] = new JsonObject
                {
                    ["should"] = new JsonArray(
                        Term("streetKey", streetKey, 10),
                        new JsonObject { ["prefix"] = new JsonObject { ["streetKey"] = new JsonObject { ["value"] = streetKey, ["boost"] = 3 } } },
                        new JsonObject { ["match"] = new JsonObject { ["streetText"] = new JsonObject { ["query"] = streetKey, ["operator"] = "and", ["fuzziness"] = WordFuzziness, ["prefix_length"] = 1 } } }),
                    ["minimum_should_match"] = 1,
                }
            },
        };
        var body = new JsonObject
        {
            ["size"] = Math.Clamp(q.Limit, 1, MaxLimit),
            ["_source"] = SourceFields(),
            ["track_total_hits"] = false,
            ["query"] = new JsonObject { ["bool"] = new JsonObject { ["must"] = must, ["filter"] = filter } },
        };
        var sort = new JsonArray(new JsonObject { ["_score"] = new JsonObject { ["order"] = "desc" } });
        if (q.Lat is { } lat && q.Lng is { } lng) sort.Add(NearestSort(lat, lng)[0]!.DeepClone());
        body["sort"] = sort;
        return q.Viewport?.Constrain(body) ?? body;
    }

    public static JsonObject BuildPostcode(string postcode) => new()
    {
        ["size"] = 3,
        ["_source"] = SourceFields(),
        ["query"] = new JsonObject { ["bool"] = new JsonObject { ["filter"] = new JsonArray(Term("category", "postcode"), Term("postcode", postcode)) } },
    };

    /// <summary>How many places of these categories are within <paramref name="radiusM"/> (category suggestions).</summary>
    public static JsonObject BuildCategoryCount(IEnumerable<PlaceCategory> cats, double lat, double lng, double radiusM, Guid? viewer) => new()
    {
        ["query"] = new JsonObject
        {
            ["bool"] = new JsonObject
            {
                ["filter"] = new JsonArray(
                    Terms("category", cats.Select(GimanoJson.ToWire)), Visibility(viewer),
                    new JsonObject { ["geo_distance"] = new JsonObject { ["distance"] = $"{radiusM:0}m", ["location"] = new JsonObject { ["lat"] = lat, ["lon"] = lng } } }),
            }
        },
    };

    /// <summary>How many outlets of a chain (same brand key or name key) are within <paramref name="radiusM"/> of the origin.</summary>
    public static JsonObject BuildChainCount(string chainKey, double lat, double lng, double radiusM, Guid? viewer) => new()
    {
        ["query"] = new JsonObject
        {
            ["bool"] = new JsonObject
            {
                ["filter"] = new JsonArray(
                    new JsonObject { ["bool"] = new JsonObject { ["should"] = new JsonArray(Term("nameKey", chainKey), Term("brandKey", chainKey)), ["minimum_should_match"] = 1 } },
                    Visibility(viewer),
                    new JsonObject { ["geo_distance"] = new JsonObject { ["distance"] = $"{radiusM:0}m", ["location"] = new JsonObject { ["lat"] = lat, ["lon"] = lng } } }),
            }
        },
    };

    public static JsonObject BuildChainSearch(SearchQuery q, IEnumerable<string> keys)
    {
        var body = Build(q with { SortNearest = true });
        body["query"] = new JsonObject { ["bool"] = new JsonObject
        {
            ["must"] = new JsonArray(body["query"]!.DeepClone()),
            ["filter"] = new JsonArray(new JsonObject { ["bool"] = new JsonObject
            {
                ["should"] = new JsonArray(Terms("nameKey", keys), Terms("brandKey", keys)),
                ["minimum_should_match"] = 1
            } })
        } };
        return body;
    }

    private static JsonArray NearestSort(double lat, double lng) => new(new JsonObject
    {
        ["_geo_distance"] = new JsonObject { ["location"] = new JsonObject { ["lat"] = lat, ["lon"] = lng }, ["order"] = "asc", ["unit"] = "m" },
    });

    private static JsonArray SourceFields() =>
        new("id", "name", "category", "address", "location", "brand", "country", "source", "status", "rating", "reviewCount", "thumbKey", "nameKey", "postcode", "openingHours");

    private static JsonArray Filters(SearchQuery q)
    {
        var filter = new JsonArray { Visibility(q.Viewer) };
        var cats = (q.Categories ?? []).Concat(q.Category is { } c ? [c] : []).Distinct().ToList();
        if (cats.Count > 0) filter.Add(Terms("category", cats.Select(GimanoJson.ToWire)));
        if (q.Country is { } country) filter.Add(Term("country", country.ToUpperInvariant()));
        if (q.RadiusM is { } r && q.Lat is { } lat && q.Lng is { } lng)
            filter.Add(new JsonObject { ["geo_distance"] = new JsonObject { ["distance"] = $"{r:0}m", ["location"] = new JsonObject { ["lat"] = lat, ["lon"] = lng } } });
        return filter;
    }

    public static JsonObject Visibility(Guid? viewer)
    {
        var should = new JsonArray
        {
            new JsonObject { ["term"] = new JsonObject { ["source"] = "osm" } },
            new JsonObject { ["term"] = new JsonObject { ["status"] = "published" } },
            // Pending places the AI check passed (shown as "not verified yet").
            new JsonObject { ["term"] = new JsonObject { ["listed"] = true } },
        };
        if (viewer is { } v)
            should.Add(new JsonObject
            {
                ["bool"] = new JsonObject
                {
                    ["filter"] = new JsonArray(
                        new JsonObject { ["term"] = new JsonObject { ["status"] = "pending" } },
                        new JsonObject { ["term"] = new JsonObject { ["ownerId"] = v.ToString("D") } }),
                }
            });
        return new JsonObject { ["bool"] = new JsonObject { ["should"] = should, ["minimum_should_match"] = 1, ["must_not"] = new JsonArray(new JsonObject { ["term"] = new JsonObject { ["closed"] = true } }) } };
    }

    /// <summary>Index definition: search_as_you_type on name, geo_point location.</summary>
    /// <param name="replicas">0 on single-node clusters (otherwise the index stays yellow); OpenSearch:Replicas.</param>
    public static JsonObject IndexDefinition(int replicas = 0) => new()
    {
        ["settings"] = new JsonObject
        {
            ["number_of_shards"] = 1,
            ["number_of_replicas"] = replicas,
            ["analysis"] = new JsonObject
            {
                ["normalizer"] = new JsonObject
                {
                    ["lowercase_ascii"] = new JsonObject
                    {
                        ["type"] = "custom",
                        ["filter"] = new JsonArray("lowercase", "asciifolding"),
                    }
                },
                // Apostrophes vanish, as in TextNormalizer ("Lotus's" → "lotuss", "McDonald's" → "mcdonalds").
                ["char_filter"] = new JsonObject
                {
                    ["no_apostrophe"] = new JsonObject
                    {
                        ["type"] = "mapping",
                        ["mappings"] = new JsonArray("'=>", "’=>", "‘=>", "`=>"),
                    }
                },
                ["analyzer"] = new JsonObject
                {
                    ["folded"] = new JsonObject
                    {
                        ["type"] = "custom",
                        ["char_filter"] = new JsonArray("no_apostrophe"),
                        ["tokenizer"] = "standard",
                        ["filter"] = new JsonArray("lowercase", "asciifolding"),
                    }
                }
            }
        },
        ["mappings"] = new JsonObject
        {
            ["properties"] = new JsonObject
            {
                ["id"] = new JsonObject { ["type"] = "keyword" },
                ["name"] = new JsonObject
                {
                    ["type"] = "search_as_you_type",
                    ["analyzer"] = "folded",
                    ["fields"] = new JsonObject
                    {
                        ["raw"] = new JsonObject { ["type"] = "keyword", ["normalizer"] = "lowercase_ascii" }
                    }
                },
                ["nameKey"] = new JsonObject { ["type"] = "keyword" },
                ["nameKeys"] = new JsonObject { ["type"] = "keyword" },
                ["brandKey"] = new JsonObject { ["type"] = "keyword" },
                ["streetKey"] = new JsonObject { ["type"] = "keyword" },
                ["streetText"] = new JsonObject { ["type"] = "text", ["analyzer"] = "whitespace" },
                ["houseNumber"] = new JsonObject { ["type"] = "keyword" },
                ["postcode"] = new JsonObject { ["type"] = "keyword" },
                ["brand"] = new JsonObject { ["type"] = "text", ["analyzer"] = "folded" },
                ["aliases"] = new JsonObject { ["type"] = "text", ["analyzer"] = "folded" },
                ["address"] = new JsonObject { ["type"] = "text", ["analyzer"] = "folded" },
                ["searchText"] = new JsonObject { ["type"] = "text", ["analyzer"] = "folded" },
                ["communityUpdated"] = new JsonObject { ["type"] = "boolean" },
                ["closed"] = new JsonObject { ["type"] = "boolean" },
                ["category"] = new JsonObject { ["type"] = "keyword" },
                ["country"] = new JsonObject { ["type"] = "keyword" },
                ["location"] = new JsonObject { ["type"] = "geo_point" },
                ["popularity"] = new JsonObject { ["type"] = "float" },
                ["source"] = new JsonObject { ["type"] = "keyword" },
                ["status"] = new JsonObject { ["type"] = "keyword" },
                ["listed"] = new JsonObject { ["type"] = "boolean" },
                ["ownerId"] = new JsonObject { ["type"] = "keyword" },
                ["rating"] = new JsonObject { ["type"] = "float" },
                ["reviewCount"] = new JsonObject { ["type"] = "integer" },
                ["thumbKey"] = new JsonObject { ["type"] = "keyword", ["index"] = false },
                ["openingHours"] = new JsonObject { ["type"] = "keyword", ["index"] = false },
            }
        }
    };

    public static JsonObject ToDocument(Place p, PlaceAggregates? agg = null) => WithKeys(new JsonObject
    {
        ["id"] = p.Id,
        ["name"] = p.Name,
        ["closed"] = p.Tags.GetValueOrDefault("manotu:closed") == "yes",
        ["communityUpdated"] = p.Tags.GetValueOrDefault("manotu:community_updated") == "yes",
        ["brand"] = p.Brand,
        ["aliases"] = SearchAliases.AreaVariants(p.Name, p.Tags),
        ["searchText"] = string.Join(" ", p.Name, p.Brand, p.Address, p.Tags.GetValueOrDefault("manotu:locality"), p.Tags.GetValueOrDefault("addr:state"), p.Tags.GetValueOrDefault("manotu:admin_names"), p.Tags.GetValueOrDefault("old_name")),
        ["address"] = p.Address,
        ["category"] = GimanoJson.ToWire(p.Category),
        ["country"] = p.Country,
        ["location"] = new JsonObject { ["lat"] = p.Location.Y, ["lon"] = p.Location.X },
        ["popularity"] = p.Popularity + Boost(agg),
        ["source"] = "osm",
        ["rating"] = agg?.Rating,
        ["reviewCount"] = agg?.ReviewCount ?? 0,
        ["thumbKey"] = agg?.ThumbKey,
        ["openingHours"] = p.OpeningHours,
    }, p.Name, p.Brand);

    public static JsonObject ToDocument(CommunityPlace p, PlaceAggregates? agg = null) => WithKeys(new JsonObject
    {
        ["id"] = p.Id,
        ["name"] = p.Name,
        ["brand"] = null,
        ["searchText"] = string.Join(" ", p.Name, p.Address),
        ["address"] = p.Address,
        ["category"] = GimanoJson.ToWire(p.Category),
        ["country"] = p.Country,
        ["location"] = new JsonObject { ["lat"] = p.Location.Y, ["lon"] = p.Location.X },
        ["popularity"] = 1 + Boost(agg),
        ["source"] = "community",
        ["status"] = GimanoJson.ToWire(p.Status),
        ["listed"] = p.Status == PlaceStatus.Pending && p.Listed,
        ["ownerId"] = p.OwnerId?.ToString("D"),
        ["rating"] = agg?.Rating,
        ["reviewCount"] = agg?.ReviewCount ?? 0,
        ["thumbKey"] = agg?.ThumbKey,
        ["openingHours"] = p.OpeningHours,
    }, p.Name, null);

    /// <summary>A named street (one document per street name per ~20–40 km cell), on the road, labelled with its area.</summary>
    public static JsonObject StreetDocument(string id, string name, double lat, double lng, string areaLabel, string country) => WithKeys(new JsonObject
    {
        ["id"] = id,
        ["name"] = name,
        ["address"] = areaLabel,
        ["category"] = "street",
        ["country"] = country,
        ["location"] = new JsonObject { ["lat"] = lat, ["lon"] = lng },
        ["popularity"] = 1,
        ["source"] = "osm",
        ["streetKey"] = QueryParser.StreetKey(name),
        ["streetText"] = QueryParser.StreetKey(name),
    }, name, null);

    /// <summary>A house address from OSM addr:* ("18, Jalan SS 2/24").</summary>
    public static JsonObject AddressDocument(AddressPoint a, string areaLabel) => new()
    {
        ["id"] = "ad-" + a.Id,
        ["name"] = $"{a.HouseNumber}, {a.Street}",
        ["address"] = string.Join(", ", new[] { a.Postcode is null ? null : $"{a.Postcode} {a.City}".Trim(), a.Postcode is null ? (a.City ?? areaLabel) : null }
            .Where(x => !string.IsNullOrWhiteSpace(x))),
        ["category"] = "address",
        ["country"] = a.Country,
        ["location"] = new JsonObject { ["lat"] = a.Lat, ["lon"] = a.Lng },
        ["popularity"] = 0,
        ["source"] = "osm",
        ["houseNumber"] = a.HouseNumber.ToLowerInvariant(),
        ["streetKey"] = QueryParser.StreetKey(a.Street),
        ["streetText"] = QueryParser.StreetKey(a.Street),
        ["postcode"] = a.Postcode,
        ["nameKey"] = TextNormalizer.Compact($"{a.HouseNumber} {a.Street}"),
    };

    /// <summary>A postcode area at the centroid of the addresses/places that carry it.</summary>
    public static JsonObject PostcodeDocument(string postcode, double lat, double lng, string label, string country) => new()
    {
        ["id"] = "pc-" + postcode,
        ["name"] = postcode,
        ["address"] = label,
        ["category"] = "postcode",
        ["country"] = country,
        ["location"] = new JsonObject { ["lat"] = lat, ["lon"] = lng },
        ["popularity"] = 2,
        ["source"] = "osm",
        ["postcode"] = postcode,
        ["nameKey"] = postcode,
    };

    private static JsonObject WithKeys(JsonObject doc, string name, string? brand)
    {
        doc["nameKey"] = TextNormalizer.Compact(name);
        doc["nameKeys"] = new JsonArray(TextNormalizer.NameKeys(name).Select(k => (JsonNode)JsonValue.Create(k)!).ToArray());
        doc["brandKey"] = string.IsNullOrWhiteSpace(brand) ? null : TextNormalizer.Compact(brand);
        return doc;
    }

    /// <summary>Well-reviewed places rank a little higher.</summary>
    private static double Boost(PlaceAggregates? a) => a is { ReviewCount: >= 3, Rating: { } r } ? Math.Round((r - 3) * 0.5 + Math.Log10(a.ReviewCount), 2) : 0;
}

public static class SearchResults
{
    /// <summary>Collapses near-duplicates (same normalised name within 50 m — e.g. an OSM node and its building), keeping the better-ranked one.</summary>
    public static List<T> Dedupe<T>(IEnumerable<T> ranked, Func<T, string> name, Func<T, (double Lat, double Lng)> at, int take)
    {
        var kept = new List<T>();
        foreach (var r in ranked)
        {
            var n = TextNormalizer.Compact(name(r)); var p = at(r);
            if (kept.Any(k => TextNormalizer.Compact(name(k)) == n && Geo.GeoMath.HaversineM(p.Lat, p.Lng, at(k).Lat, at(k).Lng) <= SearchQueryBuilder.DuplicateRadiusM)) continue;
            kept.Add(r);
            if (kept.Count == take) break;
        }
        return kept;
    }

    /// <summary>Chain identity: the brand when tagged ("FamilyMart" for "Family Mart Damansara"), else the spacing-free name.</summary>
    public static string ChainKey(string name, string? brand) =>
        !string.IsNullOrWhiteSpace(brand) ? TextNormalizer.Compact(brand)
        : GenericNames.Contains(TextNormalizer.Compact(name)) ? "" : TextNormalizer.Compact(name);

    /// <summary>Fallback names of unnamed features ("Toilet", "ATM"): the same name, but not a chain.</summary>
    private static readonly HashSet<string> GenericNames =
        ["toilet", "atm", "parking", "petrolstation", "evcharger", "tollplaza", "restarea", "surau", "masjid", "tandas", "tandasawam"];

    /// <summary>
    /// Chains are always nearest-first: members of the same chain (same brand / spacing-insensitive name) keep the slots the ranking gave
    /// the chain, but are re-assigned to those slots in distance order. "7 eleven" 13.7 km away can't sit above the 7-Eleven 623 m away.
    /// </summary>
    public static List<T> ChainsNearestFirst<T>(IReadOnlyList<T> ranked, Func<T, string> chainKey, Func<T, double?> distance)
    {
        var result = ranked.ToList();
        foreach (var g in Enumerable.Range(0, ranked.Count).GroupBy(i => chainKey(ranked[i])).Where(g => g.Key.Length > 0 && g.Count() > 1))
        {
            var slots = g.OrderBy(i => i).ToList();
            var members = slots.Select(i => ranked[i]).OrderBy(m => distance(m) ?? double.MaxValue).ToList();
            for (var k = 0; k < slots.Count; k++) result[slots[k]] = members[k];
        }
        return result;
    }
}
