using Gimano.Api.Auth;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Api.Endpoints;

public sealed record DataExport(IReadOnlyList<SavedPlaceDto> SavedPlaces, IReadOnlyList<RecentDto> Recents);

/// <summary>
/// Privacy rule (AGENTS.md): personal data lives on the device. These endpoints let the apps take the legacy
/// server copy home once (export → import locally → DELETE /me/data) and let users delete their account.
/// </summary>
public static class PrivacyEndpoints
{
    public static RouteGroupBuilder MapPrivacy(this RouteGroupBuilder api)
    {
        var me = api.MapGroup("/me").WithTags("Privacy").RequireAuthorization();
        me.MapGet("/data/export", Export).WithSummary("Legacy server copy of saved places and recents (for the one-time move to the device).");
        me.MapDelete("/data", DeleteData).WithSummary("Permanently delete the legacy server copy of saved places and recents.");
        me.MapDelete("", DeleteAccount).WithSummary("Delete the account. Reports and feedback are kept anonymised; everything else is deleted.");
        return api;
    }

    private static async Task<Ok<DataExport>> Export(HttpContext http, GimanoDbContext db, CancellationToken ct)
    {
        var uid = http.User.RequiredUserId();
        var places = await db.SavedPlaces.AsNoTracking().Where(p => p.UserId == uid).ToListAsync(ct);
        var recents = await db.Recents.AsNoTracking().Where(r => r.UserId == uid).OrderByDescending(r => r.LastUsedAt).ToListAsync(ct);
        return TypedResults.Ok(new DataExport(
            AuthAndMeEndpoints.Ordered(places).Select(p => p.ToDto()).ToList(),
            recents.Select(r => r.ToDto()).ToList()));
    }

    private static async Task<NoContent> DeleteData(HttpContext http, GimanoDbContext db, CancellationToken ct)
    {
        var uid = http.User.RequiredUserId();
        await db.SavedPlaces.Where(p => p.UserId == uid).ExecuteDeleteAsync(ct);
        await db.Recents.Where(r => r.UserId == uid).ExecuteDeleteAsync(ct);
        return TypedResults.NoContent();
    }

    /// <summary>
    /// Deletes the user row and everything keyed by it: saved places, recents (cascade), report votes,
    /// feedback screenshots, event short links; reports and feedback text are detached (anonymised). Device tokens are stateless JWTs:
    /// once the user row is gone they no longer resolve to an account. Driver dots were never stored.
    /// </summary>
    private static async Task<NoContent> DeleteAccount(HttpContext http, GimanoDbContext db, Gimano.Core.Events.DropService drops,
        Gimano.Core.Community.IMediaStore media, CancellationToken ct)
    {
        var uid = http.User.RequiredUserId();
        // Appeal text, notes and private evidence photos go with the account (the rows cascade; the files are ours to delete).
        var evidence = await db.ContentAppeals.Where(a => a.UserId == uid && a.EvidenceKeys != null).Select(a => a.EvidenceKeys).ToListAsync(ct);
        evidence.AddRange(await db.Reviews.Where(r => r.UserId == uid && r.AppealEvidence != null).Select(r => r.AppealEvidence).ToListAsync(ct));
        evidence.AddRange(await db.Photos.Where(p => p.UserId == uid && p.AppealEvidence != null).Select(p => p.AppealEvidence).ToListAsync(ct));
        foreach (var keys in evidence) await Gimano.Core.Community.AppealEvidence.DeleteAsync(media, keys, ct);
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        // Event short links (encrypted packs) the user uploaded, live or ended: found by the keyed owner hash.
        await drops.DeleteAllForUserAsync(uid, ct);
        // Volunteered contact details on this user's reports go immediately.
        var fbIds = db.Feedback.Where(f => f.UserId == uid).Select(f => f.Id);
        var crashIds = db.CrashReports.Where(c => c.UserId == uid).Select(c => c.Id);
        await db.ReportContacts.Where(c => (c.SubjectType == ContactSubject.Feedback && fbIds.Contains(c.SubjectId))
                                           || (c.SubjectType == ContactSubject.Crash && crashIds.Contains(c.SubjectId))).ExecuteDeleteAsync(ct);
        await db.ReportVotes.Where(v => v.UserId == uid).ExecuteDeleteAsync(ct);
        // Complaints are public contributions: kept, anonymised. Open votes are deleted (closed ones are already unlinked).
        await db.IssueVotes.Where(v => v.VoterId == uid).ExecuteDeleteAsync(ct);
        await db.Issues.Where(i => i.CreatedBy == uid).ExecuteUpdateAsync(s => s.SetProperty(i => i.CreatedBy, (Guid?)null), ct);
        await db.Reports.Where(r => r.ReporterId == uid).ExecuteUpdateAsync(s => s.SetProperty(r => r.ReporterId, (Guid?)null), ct);
        await db.Feedback.Where(f => f.UserId == uid).ExecuteUpdateAsync(s => s
            .SetProperty(f => f.UserId, (Guid?)null)
            .SetProperty(f => f.Screenshot, (byte[]?)null)
            .SetProperty(f => f.ScreenshotContentType, (string?)null), ct);
        await db.SavedPlaces.Where(p => p.UserId == uid).ExecuteDeleteAsync(ct);
        await db.Recents.Where(r => r.UserId == uid).ExecuteDeleteAsync(ct);
        // Notes and evidence of older-style appeals live on the (anonymised, kept) review/photo/place rows: cleared. content_appeals and
        // osm_place_flags rows cascade with the user.
        await db.Reviews.Where(r => r.UserId == uid && (r.AppealNote != null || r.AppealEvidence != null))
            .ExecuteUpdateAsync(s => s.SetProperty(r => r.AppealNote, (string?)null).SetProperty(r => r.AppealEvidence, (string?)null), ct);
        await db.Photos.Where(p => p.UserId == uid && (p.AppealNote != null || p.AppealEvidence != null))
            .ExecuteUpdateAsync(s => s.SetProperty(p => p.AppealNote, (string?)null).SetProperty(p => p.AppealEvidence, (string?)null), ct);
        await db.CommunityPlaces.Where(p => p.OwnerId == uid && p.AppealNote != null)
            .ExecuteUpdateAsync(s => s.SetProperty(p => p.AppealNote, (string?)null), ct);
        await db.Users.Where(u => u.Id == uid).ExecuteDeleteAsync(ct);
        await tx.CommitAsync(ct);
        return TypedResults.NoContent();
    }
}

/// <summary><c>Features:LegacySavedPlaces=false</c> → the deprecated /me/places* and /me/recents answer 410 Gone.</summary>
public sealed class LegacySavedPlacesFilter(IConfiguration config) : IEndpointFilter
{
    public async ValueTask<object?> InvokeAsync(EndpointFilterInvocationContext context, EndpointFilterDelegate next)
    {
        if (config.GetValue("Features:LegacySavedPlaces", true)) return await next(context);
        return TypedResults.Problem(statusCode: StatusCodes.Status410Gone, title: "Moved to your device",
            detail: "Saved places and recents are stored on your device now. Use GET /api/v1/me/data/export to fetch any old server copy.");
    }
}
