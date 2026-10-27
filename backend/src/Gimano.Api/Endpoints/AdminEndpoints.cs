using System.Security.Cryptography;
using System.Text;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Messaging;
using Gimano.Core.Support;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Api.Endpoints;

public sealed record AdminFeedbackItem(Guid Id, FeedbackCategory Category, string Message, int? Rating, FeedbackScreen? Screen, FeedbackStatus Status,
    DeviceInfo? Device, double? Lat, double? Lng, string? RouteId, string? PlaceId, bool HasScreenshot, bool HasContact, DateTimeOffset CreatedAt, string? ExternalUrl,
    bool SuspectedSpam = false);
public sealed record AdminCrashGroup(string Signature, string Exception, int Count, DateTimeOffset FirstSeen, DateTimeOffset LastSeen, CrashGroupStatus Status);
public sealed record AdminCrashReport(Guid Id, CrashKind Kind, string Exception, string? Message, string? Stack, string? Screen, long? UptimeS,
    DeviceInfo? Device, DateTimeOffset? OccurredAt, bool HasContact);
public sealed record AdminStatusRequest(string Status);
/// <summary>An OSM note to file by hand (v1 never posts to OSM). note = suggested text; links point at the OSM object.</summary>
public sealed record AdminOsmNote(Guid IssueId, IssueKind Kind, string? Subtype, IssueState State, double Lat, double Lng, string Note,
    string? OsmUrl, string? NoteUrl, int StillVotes, int ClearedVotes, DateTimeOffset CreatedAt, DateTimeOffset? ConfirmedAt,
    DateTimeOffset? ExportedAt, IReadOnlyDictionary<string, string> Payload);
/// <summary>DEV ONLY seed: the same body as POST /issues, plus the state to create it in (default confirmed).</summary>
public sealed record SeedIssueRequest(CreateIssueRequest Issue, IssueState? State);

/// <summary>Dev-only endpoints answer 404 unless Features:DevSeed is true (set in deploy/docker-compose.yml only).</summary>
public sealed class DevSeedFilter(IConfiguration config) : IEndpointFilter
{
    public async ValueTask<object?> InvokeAsync(EndpointFilterInvocationContext context, EndpointFilterDelegate next) =>
        config.GetValue("Features:DevSeed", false) ? await next(context) : TypedResults.NotFound();
}

public sealed record AdminSearchMiss(string Query, string Cell, string Week, int Count);

/// <summary>
/// Minimal maintainer view, protected by an admin key (X-Admin-Key = Admin:Key; disabled when not configured).
/// Contact details are decrypted ONLY on an explicit per-item reveal, which is audit-logged without the values.
/// </summary>
public static class AdminEndpoints
{
    public static RouteGroupBuilder MapAdmin(this RouteGroupBuilder api)
    {
        var g = api.MapGroup("/admin").WithTags("Admin").AllowAnonymous().AddEndpointFilter<AdminKeyFilter>().ExcludeFromDescription();
        g.MapGet("/feedback", ListFeedback);
        g.MapPatch("/feedback/{id:guid}", SetFeedbackStatus);
        g.MapGet("/feedback/{id:guid}/screenshot", Screenshot);
        g.MapGet("/crash-groups", ListCrashGroups);
        g.MapGet("/crash-groups/{signature}/reports", CrashReports);
        g.MapPatch("/crash-groups/{signature}", SetCrashStatus);
        g.MapPost("/contacts/{subject}/{id:guid}/reveal", RevealContact);
        g.MapGet("/search-misses", SearchMissReport);
        g.MapGet("/osm-queue", OsmQueue);
        g.MapGet("/place-suggestions", async (GimanoDbContext db, CancellationToken ct) =>
            await db.PlaceSuggestions.AsNoTracking().Where(s => s.Status == SuggestionStatus.Pending).OrderBy(s => s.CreatedAt)
                .Take(100).Select(s => new { s.Id, s.PlaceId, s.Changes, s.Status, s.CreatedAt, s.StreetOriginalName, s.StreetWayIds }).ToListAsync(ct));
        g.MapPost("/place-suggestions/{id:guid}/accept", async (Guid id, Services.PlaceCorrectionService service, CancellationToken ct) =>
            await service.AcceptAsync(id, ct) ? Results.NoContent() : Results.NotFound());
        // Moderation queue (docs/back-office.md "Moderation"; act within 24 h): flagged reviews, photos and community places.
        var mod = g.MapGroup("/moderation");
        mod.MapGet("", (string? kind, string? state, Services.Moderation m, CancellationToken ct) => ModerationQueue(kind, state, m, ct));
        mod.MapPost("/{kind}/{id}/hide", (string kind, string id, Services.Moderation m, CancellationToken ct) => ModerationAct(kind, id, (k, i) => m.HideAsync(k, i, ct)));
        mod.MapPost("/{kind}/{id}/restore", (string kind, string id, Services.Moderation m, CancellationToken ct) => ModerationAct(kind, id, (k, i) => m.RestoreAsync(k, i, ct)));
        mod.MapGet("/{kind}/{id}/evidence/{n:int}", async (string kind, string id, int n, Services.Moderation m, Gimano.Core.Community.IMediaStore media, HttpContext http, CancellationToken ct) =>
        {
            if (!TryKind(kind, out var k)) return Validation.Problem("kind", "kind must be review, photo, place or appeal.");
            if (await m.EvidenceAsync(k, id, n, media, ct) is not { } bytes) return Results.NotFound();
            http.Response.Headers.CacheControl = "no-store";
            return Results.File(bytes, "image/webp");
        });
        mod.MapPost("/{kind}/{id}/ban-author", (string kind, string id, Services.Moderation m, CancellationToken ct) => ModerationAuthor(kind, id, (k, i) => m.BanAuthorAsync(k, i, ct)));
        mod.MapPost("/{kind}/{id}/unban-author", (string kind, string id, Services.Moderation m, CancellationToken ct) => ModerationAuthor(kind, id, (k, i) => m.UnbanAuthorAsync(k, i, ct)));
        // DEV ONLY: seed issues for app testing (404 unless Features:DevSeed=true; never set in production).
        var dev = g.MapGroup("/dev").AddEndpointFilter<DevSeedFilter>();
        dev.MapPost("/issues", SeedIssue);
        dev.MapDelete("/issues/{id:guid}", DeleteSeededIssue);
        g.MapPost("/osm-queue/{id:guid}/exported", MarkExported);
        g.MapPost("/search/aliases/reload", (Services.AliasStore store) => TypedResults.Ok(new { rows = store.Reload() }));

        // Curated restricted areas (docs/api.md "Restricted areas"): sites OSM doesn't tag. public=false (shelters, safe
        // houses) is checked on the server only and never sent to phones. No names are stored.
        g.MapGet("/restricted-areas", ListCurated);
        g.MapPost("/restricted-areas", AddCurated);
        g.MapDelete("/restricted-areas/{id:long}", DeleteCurated);
        return api;
    }

    public sealed record CuratedAreaRequest(IReadOnlyList<double[]> Ring, bool Public);
    public sealed record CuratedArea(long Id, bool Public, IReadOnlyList<double[]> Ring);

    private static async Task<Ok<List<CuratedArea>>> ListCurated(GimanoDbContext db, CancellationToken ct) =>
        TypedResults.Ok((await db.RestrictedAreas.AsNoTracking().Where(a => a.Curated).OrderBy(a => a.Id).ToListAsync(ct))
            .Select(a => new CuratedArea(a.Id, a.Public, a.Geom.ExteriorRing.Coordinates.Select(c => new[] { c.X, c.Y }).ToList())).ToList());

    /// <summary>ring = [[lng, lat], …] (closed or not; at least 3 distinct points).</summary>
    private static async Task<IResult> AddCurated(CuratedAreaRequest req, GimanoDbContext db, CancellationToken ct)
    {
        if (req.Ring is not { Count: >= 3 } || req.Ring.Any(p => p is not { Length: 2 } || !Validation.ValidLatLng(p[1], p[0])))
            return Validation.Problem("ring", "ring must be at least 3 [lng, lat] points.");
        var pts = req.Ring.Select(p => new NetTopologySuite.Geometries.Coordinate(p[0], p[1])).ToList();
        if (!pts[0].Equals2D(pts[^1])) pts.Add(pts[0]);
        var poly = Gimano.Core.Geo.GeoMath.Factory.CreatePolygon(pts.ToArray());
        if (!poly.IsValid) return Validation.Problem("ring", "ring must not cross itself.");
        if (!poly.Shell.IsCCW) poly = (NetTopologySuite.Geometries.Polygon)poly.Reverse();
        var area = new RestrictedArea { Curated = true, Public = req.Public, Geom = poly };
        db.RestrictedAreas.Add(area);
        await db.SaveChangesAsync(ct);
        return TypedResults.Created($"/api/v1/admin/restricted-areas/{area.Id}", new { id = area.Id });
    }

    private static async Task<IResult> DeleteCurated(long id, GimanoDbContext db, CancellationToken ct) =>
        await db.RestrictedAreas.Where(a => a.Id == id && a.Curated).ExecuteDeleteAsync(ct) > 0 ? TypedResults.NoContent() : TypedResults.NotFound();

    private static bool TryKind(string? kind, out Services.ModerationKind k) => GimanoJson.TryParseWire(kind ?? "", out k);

    private static async Task<IResult> ModerationQueue(string? kind, string? state, Services.Moderation m, CancellationToken ct)
    {
        Services.ModerationKind? k = null;
        if (!string.IsNullOrEmpty(kind)) { if (!TryKind(kind, out var kk)) return Validation.Problem("kind", "kind must be review, photo, place or appeal."); k = kk; }
        if (state is not (null or "" or "flagged" or "hidden")) return Validation.Problem("state", "state must be flagged or hidden.");
        return TypedResults.Ok(await m.QueueAsync(k, state == "hidden", ct));
    }

    private static async Task<IResult> ModerationAct(string kind, string id, Func<Services.ModerationKind, string, Task> act)
    {
        if (!TryKind(kind, out var k)) return Validation.Problem("kind", "kind must be review, photo, place or appeal.");
        await act(k, id);
        return TypedResults.NoContent();
    }

    private static async Task<IResult> ModerationAuthor(string kind, string id, Func<Services.ModerationKind, string, Task<bool>> act)
    {
        if (!TryKind(kind, out var k)) return Validation.Problem("kind", "kind must be review, photo, place or appeal.");
        return await act(k, id) ? TypedResults.NoContent() : TypedResults.NotFound();
    }

    /// <summary>
    /// OSM notes queue (export only): odd routes, new roads, "actually two-way", and issues confirmed for 7+ days that
    /// the map should fix (no road, one-way, turn, place details). Coordinates at 5 dp; nothing about the reporter.
    /// </summary>
    private static async Task<Ok<List<AdminOsmNote>>> OsmQueue(bool? includeExported, GimanoDbContext db, TimeProvider clock, CancellationToken ct)
    {
        var settled = clock.GetUtcNow().AddDays(-7);
        var q = db.Issues.AsNoTracking().Where(i =>
            ((i.Kind == IssueKind.OddRoute || i.Kind == IssueKind.NewRoad || i.Kind == IssueKind.OnewayWrongOpenDir)
                && (i.State == IssueState.Reported || i.State == IssueState.Suspected || i.State == IssueState.Confirmed))
            || (i.State == IssueState.Confirmed && i.ConfirmedAt < settled && i.Kind != IssueKind.RoadClosedTemp && i.Kind != IssueKind.PlaceClosedTemp));
        if (includeExported != true) q = q.Where(i => i.ExportedAt == null);
        var rows = await q.OrderBy(i => i.CreatedAt).Take(500).ToListAsync(ct);
        return TypedResults.Ok(rows.Select(i =>
        {
            var lat = Math.Round(i.Location.Y, 5); var lng = Math.Round(i.Location.X, 5);
            var osm = i.WayId is { } w ? $"https://www.openstreetmap.org/way/{w}"
                : i.PlaceId is { } pid && pid.Length > 1 && pid[0] is 'n' or 'w' or 'r' && long.TryParse(pid[1..], out var oid)
                    ? $"https://www.openstreetmap.org/{(pid[0] == 'n' ? "node" : pid[0] == 'w' ? "way" : "relation")}/{oid}" : null;
            var note = Gimano.Core.Issues.IssueText.Summary(i, "en") + (i.Kind switch
            {
                IssueKind.RoadNotExist => " — drivers report there is no usable road here (gate/private/track).",
                IssueKind.OnewayWrongClosedDir => " — drivers report this is one-way (the map says two-way).",
                IssueKind.OnewayWrongOpenDir => " — vehicles use both directions (the map says one-way).",
                IssueKind.TurnNotAllowed => " — drivers report this turn is not allowed.",
                IssueKind.NewRoad => " — a road that is not on the map (trace attached).",
                IssueKind.OddRoute => " — the suggested route seemed wrong here.",
                _ => ".",
            }) + $" {i.StillVotes} confirmation(s), {i.ClearedVotes} against. (Manotu/Gimano community report; please survey before editing.)";
            return new AdminOsmNote(i.Id, i.Kind, i.Subtype, i.State, lat, lng, note, osm,
                string.Create(System.Globalization.CultureInfo.InvariantCulture, $"https://www.openstreetmap.org/note/new#map=19/{lat}/{lng}"),
                i.StillVotes, i.ClearedVotes, i.CreatedAt, i.ConfirmedAt, i.ExportedAt, i.Payload);
        }).ToList());
    }

    private static async Task<Created<IssueDto>> SeedIssue(SeedIssueRequest req, HttpContext http, Services.IssueService issues, CancellationToken ct)
    {
        var dto = await issues.SeedAsync(req.Issue, req.State ?? IssueState.Confirmed, http.Lang(), ct);
        return TypedResults.Created($"/api/v1/issues/{dto.Id}", dto);
    }

    private static async Task<Results<NoContent, NotFound>> DeleteSeededIssue(Guid id, Services.IssueService issues, CancellationToken ct) =>
        await issues.DeleteAsync(id, ct) ? TypedResults.NoContent() : TypedResults.NotFound();

    private static async Task<Results<NoContent, NotFound>> MarkExported(Guid id, GimanoDbContext db, TimeProvider clock, CancellationToken ct) =>
        await db.Issues.Where(i => i.Id == id).ExecuteUpdateAsync(s => s.SetProperty(i => i.ExportedAt, clock.GetUtcNow()), ct) > 0
            ? TypedResults.NoContent() : TypedResults.NotFound();

    /// <summary>Anonymous zero-result counts: query, ~11 km cell, ISO week, count (nothing else exists to show).</summary>
    private static async Task<Ok<List<AdminSearchMiss>>> SearchMissReport(string? week, int? minCount, int? take, GimanoDbContext db, TimeProvider clock, CancellationToken ct)
    {
        var w = string.IsNullOrEmpty(week) ? Core.Support.SearchMisses.Week(clock.GetUtcNow()) : week;
        var min = Math.Max(1, minCount ?? 1);
        var rows = await db.SearchMisses.AsNoTracking().Where(m => m.Week == w && m.Count >= min)
            .OrderByDescending(m => m.Count).ThenBy(m => m.Query).Take(Math.Clamp(take ?? 200, 1, 1000))
            .Select(m => new AdminSearchMiss(m.Query, m.Cell, m.Week, m.Count)).ToListAsync(ct);
        return TypedResults.Ok(rows);
    }

    private static async Task<Ok<List<AdminFeedbackItem>>> ListFeedback(string? status, int? take, GimanoDbContext db, CancellationToken ct)
    {
        var q = db.Feedback.AsNoTracking();
        if (GimanoJson.TryParseWire<FeedbackStatus>(status, out var st)) q = q.Where(f => f.Status == st);
        var rows = await q.OrderByDescending(f => f.CreatedAt).Take(Math.Clamp(take ?? 50, 1, 200))
            .Select(f => new AdminFeedbackItem(f.Id, f.Category, f.Message, f.Rating, f.Screen, f.Status, f.Device, f.Lat, f.Lng, f.RouteId, f.PlaceId,
                f.Screenshot != null, db.ReportContacts.Any(c => c.SubjectType == ContactSubject.Feedback && c.SubjectId == f.Id), f.CreatedAt, f.ExternalUrl, f.SuspectedSpam))
            .ToListAsync(ct);
        return TypedResults.Ok(rows);
    }

    private static async Task<Results<NoContent, NotFound, ValidationProblem>> SetFeedbackStatus(Guid id, AdminStatusRequest req, GimanoDbContext db,
        IEventPublisher bus, TimeProvider clock, CancellationToken ct)
    {
        if (!GimanoJson.TryParseWire<FeedbackStatus>(req.Status, out var status)) return Validation.Problem("status", "received|triaged|planned|done|wont_fix");
        var f = await db.Feedback.FirstOrDefaultAsync(x => x.Id == id, ct);
        if (f is null) return TypedResults.NotFound();
        f.Status = status;
        f.ClosedAt = status is FeedbackStatus.Done or FeedbackStatus.WontFix ? f.ClosedAt ?? clock.GetUtcNow() : null;
        await db.SaveChangesAsync(ct);
        await bus.PublishAsync(RoutingKeys.FeedbackStatusChanged, new FeedbackStatusEvent(id, status), ct);
        return TypedResults.NoContent();
    }

    private static async Task<IResult> Screenshot(Guid id, GimanoDbContext db, CancellationToken ct)
    {
        var f = await db.Feedback.AsNoTracking().Where(x => x.Id == id).Select(x => new { x.Screenshot, x.ScreenshotContentType }).FirstOrDefaultAsync(ct);
        return f?.Screenshot is null ? Results.NotFound() : Results.File(f.Screenshot, f.ScreenshotContentType ?? "application/octet-stream");
    }

    private static async Task<Ok<List<AdminCrashGroup>>> ListCrashGroups(string? status, GimanoDbContext db, CancellationToken ct)
    {
        var q = db.CrashGroups.AsNoTracking();
        if (GimanoJson.TryParseWire<CrashGroupStatus>(status, out var st)) q = q.Where(g => g.Status == st);
        return TypedResults.Ok(await q.OrderByDescending(g => g.LastSeen).Take(200)
            .Select(g => new AdminCrashGroup(g.Signature, g.Exception, g.Count, g.FirstSeen, g.LastSeen, g.Status)).ToListAsync(ct));
    }

    private static async Task<Ok<List<AdminCrashReport>>> CrashReports(string signature, GimanoDbContext db, CancellationToken ct) =>
        TypedResults.Ok(await db.CrashReports.AsNoTracking().Where(c => c.Signature == signature).OrderByDescending(c => c.CreatedAt).Take(50)
            .Select(c => new AdminCrashReport(c.Id, c.Kind, c.Exception, c.Message, c.Stack, c.Screen, c.UptimeS, c.Device, c.OccurredAt,
                db.ReportContacts.Any(x => x.SubjectType == ContactSubject.Crash && x.SubjectId == c.Id)))
            .ToListAsync(ct));

    private static async Task<Results<NoContent, NotFound, ValidationProblem>> SetCrashStatus(string signature, AdminStatusRequest req, GimanoDbContext db,
        TimeProvider clock, CancellationToken ct)
    {
        if (!GimanoJson.TryParseWire<CrashGroupStatus>(req.Status, out var status)) return Validation.Problem("status", "open|triaged|fixing|regressed|done|wont_fix");
        var g = await db.CrashGroups.FirstOrDefaultAsync(x => x.Signature == signature, ct);
        if (g is null) return TypedResults.NotFound();
        g.Status = status;
        // Only done/wont_fix are closed (start the 30-day contact clock); open/triaged/fixing/regressed are not.
        g.ClosedAt = CrashGroup.IsClosed(status) ? g.ClosedAt ?? clock.GetUtcNow() : null;
        await db.SaveChangesAsync(ct);
        return TypedResults.NoContent();
    }

    /// <summary>Explicit per-item reveal. The audit log records who/what/when, never the contact values.</summary>
    private static async Task<Results<Ok<ContactDetails>, NotFound, ValidationProblem>> RevealContact(string subject, Guid id, HttpContext http,
        GimanoDbContext db, ContactCrypto crypto, ILogger<AdminKeyFilter> log, CancellationToken ct)
    {
        if (!GimanoJson.TryParseWire<ContactSubject>(subject, out var type)) return Validation.Problem("subject", "feedback|crash");
        var c = await db.ReportContacts.AsNoTracking().FirstOrDefaultAsync(x => x.SubjectType == type && x.SubjectId == id, ct);
        if (c is null) return TypedResults.NotFound();
        log.LogWarning("AUDIT contact revealed: {Subject} {Id} by admin key {KeyFingerprint} from {Ip}",
            type, id, AdminKeyFilter.Fingerprint(http), http.Connection.RemoteIpAddress);
        return TypedResults.Ok(crypto.Decrypt(c));
    }
}

public sealed class AdminKeyFilter(IConfiguration config) : IEndpointFilter
{
    public async ValueTask<object?> InvokeAsync(EndpointFilterInvocationContext context, EndpointFilterDelegate next)
    {
        var expected = config["Admin:Key"];
        if (string.IsNullOrEmpty(expected) || expected.Length < 24) return Results.NotFound(); // disabled
        var given = context.HttpContext.Request.Headers["X-Admin-Key"].ToString();
        var a = SHA256.HashData(Encoding.UTF8.GetBytes(given));
        var b = SHA256.HashData(Encoding.UTF8.GetBytes(expected));
        if (!CryptographicOperations.FixedTimeEquals(a, b)) return Results.Unauthorized();
        return await next(context);
    }

    /// <summary>Short, non-reversible fingerprint of the admin key used (for the audit log).</summary>
    public static string Fingerprint(HttpContext http) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(http.Request.Headers["X-Admin-Key"].ToString())))[..8];
}
