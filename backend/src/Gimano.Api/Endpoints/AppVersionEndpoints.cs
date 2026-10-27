using Gimano.Core.AppVersions;

namespace Gimano.Api.Endpoints;

/// <summary>
/// GET /app/versions: the latest store version per platform and the floor below which an app must update (docs/app-updates.md).
/// Public and anonymous; it takes no input and collects nothing, so every client gets the same cacheable answer.
/// </summary>
public static class AppVersionEndpoints
{
    public static RouteGroupBuilder MapAppVersions(this RouteGroupBuilder api)
    {
        api.MapGroup("/app").WithTags("App updates").MapGet("/versions", Get).AllowAnonymous();
        return api;
    }

    private static async Task<AppVersionsResponse> Get(HttpContext http, AppVersionService versions, CancellationToken ct)
    {
        http.Response.Headers.CacheControl = "public, max-age=300";
        return await versions.GetAsync(ct);
    }
}
