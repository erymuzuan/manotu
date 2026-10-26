using Gimano.Api.Auth;
using Gimano.Api.Services;
using Gimano.Core.Contracts;
using Gimano.Core.Geo;
using Gimano.Core.Search;
using Microsoft.AspNetCore.Http.HttpResults;

namespace Gimano.Api.Endpoints;

public static class PlaceEndpoints
{
    public static RouteGroupBuilder MapPlaces(this RouteGroupBuilder api)
    {
        var search = api.MapGroup("/search").WithTags("Search").AllowAnonymous();
        search.MapGet("", Search).WithSummary("Finding places: text, brand+area, category words, streets/addresses, postcodes, coordinates, Plus Codes.");
        search.MapGet("/nearby", Nearby).WithSummary("Places of a category around a point (PostGIS).");

        api.MapGet("/places/{id}", GetPlace).WithTags("Search").AllowAnonymous();
        api.MapGet("/geocode/reverse", Reverse).WithTags("Search").AllowAnonymous();
        api.MapGet("/restricted-areas", RestrictedAreas).WithTags("Community places").AllowAnonymous()
            .WithSummary("Restricted areas (whole set, no names), distances and sensitive terms for the on-phone check. ETag; 304 when unchanged.");

        return api;
    }

    /// <summary>The whole set (never a bounding box), so the request says nothing about where the user is.</summary>
    private static async Task<IResult> RestrictedAreas(HttpContext http, RestrictedAreaSnapshot snapshot, CancellationToken ct)
    {
        var (body, version) = await snapshot.GetAsync(ct);
        var etag = $"\"{version}\"";
        http.Response.Headers.ETag = etag;
        http.Response.Headers.CacheControl = "public, max-age=86400";
        if (http.Request.Headers.IfNoneMatch.Any(v => v == etag)) return Results.StatusCode(StatusCodes.Status304NotModified);
        return Results.Bytes(body, "application/json");
    }

    private static async Task<Results<Ok<SearchResponse>, ValidationProblem>> Search(
        string? q, double? lat, double? lng, int? limit, string? category, string? country, string? near, string? sort, bool? exact, string? viewport,
        HttpContext http, SearchService search, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(q)) return Validation.Problem("q", "q is required.");
        if (q.Length > 100) return Validation.Problem("q", "q is too long (max 100).");
        if ((lat is null) != (lng is null) || (lat is { } a && lng is { } b && !Validation.ValidLatLng(a, b)))
            return Validation.Problem("lat", "lat and lng must both be valid when given.");
        PlaceCategory? cat = null;
        if (!string.IsNullOrEmpty(category))
        {
            if (!GimanoJson.TryParseWire<PlaceCategory>(category, out var c)) return Validation.Problem("category", $"Unknown category '{category}'.");
            cat = c;
        }
        if (country is not null && country.ToUpperInvariant() is not ("MY" or "SG" or "BN"))
            return Validation.Problem("country", "country must be MY, SG or BN.");

        double? nearLat = null, nearLng = null;
        if (!string.IsNullOrEmpty(near))
        {
            var parts = near.Split(',', StringSplitOptions.TrimEntries);
            if (parts.Length != 2 || !double.TryParse(parts[0], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var nl)
                || !double.TryParse(parts[1], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var ng)
                || !Validation.ValidLatLng(nl, ng))
                return Validation.Problem("near", "near must be \"lat,lng\".");
            (nearLat, nearLng) = (nl, ng);
        }
        if (sort is not (null or "" or "relevance" or "nearest")) return Validation.Problem("sort", "sort must be relevance or nearest.");

        SearchViewport? footprint = null;
        if (viewport is not null && !SearchViewport.TryParse(viewport, out footprint))
            return Validation.Problem("viewport", "viewport must be a valid polygon of 3–8 lon,lat pairs separated by semicolons.");
        http.Response.Headers.CacheControl = "no-store";
        var response = await search.SearchAsync(new SearchRequest(q, lat, lng, nearLat, nearLng, limit ?? 10, cat, country?.ToUpperInvariant(),
            http.User.UserId(), sort == "nearest", http.Lang(), exact ?? false, footprint), ct);
        return TypedResults.Ok(response);
    }

    private static async Task<Results<Ok<SearchResponse>, ValidationProblem>> Nearby(
        double lat, double lng, string? category, double? radius, int? limit, HttpContext http, PlaceService places, CancellationToken ct)
    {
        if (Validation.LatLng(lat, lng) is { } p) return p;
        PlaceCategory? cat = null;
        if (!string.IsNullOrEmpty(category))
        {
            if (!GimanoJson.TryParseWire<PlaceCategory>(category, out var c)) return Validation.Problem("category", $"Unknown category '{category}'.");
            cat = c;
        }
        var r = Math.Clamp(radius ?? 5000, 50, 50_000);
        var results = await places.NearbyAsync(new GeoPoint(lat, lng), cat, r, Math.Clamp(limit ?? 20, 1, 100), http.User.UserId(), ct, http.Lang());
        return TypedResults.Ok(new SearchResponse(results));
    }

    private static async Task<Results<Ok<PlaceDto>, NotFound>> GetPlace(string id, double? lat, double? lng, HttpContext http, PlaceService places, CancellationToken ct)
    {
        var p = await places.GetAsync(id, lat, lng, http.User.UserId(), ct, http.Lang());
        return p is null ? TypedResults.NotFound() : TypedResults.Ok(p);
    }

    /// <summary>"Pilih pada peta": name/address, street-level label and places within 50 m. Anonymous, not cached; coordinates never logged.</summary>
    private static async Task<Results<Ok<ReverseGeocodeResponse>, ValidationProblem>> Reverse(double lat, double lng, HttpContext http, SearchService search, CancellationToken ct)
    {
        if (Validation.LatLng(lat, lng) is { } p) return p;
        http.Response.Headers.CacheControl = "no-store";
        return TypedResults.Ok(await search.ReverseAsync(new GeoPoint(lat, lng), http.Lang(), http.User.UserId(), ct));
    }
}
