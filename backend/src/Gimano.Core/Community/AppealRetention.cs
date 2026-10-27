using Gimano.Core.Data;
using Gimano.Core.Domain;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Core.Community;

/// <summary>
/// Appeal text, notes and private evidence photos are deleted 30 days after the decision (docs/content-safety.md "Appeals"). A decided appeal
/// from POST /appeals keeps its row (user, refusal id, kind, status, times) so the same refusal can't be appealed twice, until the account is deleted.
/// </summary>
public static class AppealRetention
{
    public static async Task<int> RunAsync(GimanoDbContext db, IMediaStore media, DateTimeOffset now, CancellationToken ct)
    {
        var cut = now - AppealEvidence.KeepAfterDecision;
        var done = 0;

        var appeals = await db.ContentAppeals.Where(a => a.Status != AppealStatus.Pending && a.DecidedAt < cut && a.ScrubbedAt == null).Take(100).ToListAsync(ct);
        foreach (var a in appeals)
        {
            await AppealEvidence.DeleteAsync(media, a.EvidenceKeys, ct);
            (a.Text, a.Note, a.EvidenceKeys, a.ScrubbedAt) = (null, "", null, now);
            done++;
        }

        // Older-style appeals (POST /reviews|photos/{id}/appeal) keep the note and photos on the review or photo; decided = no longer held.
        var reviews = await db.Reviews.Where(r => r.AppealedAt != null && (r.AppealNote != null || r.AppealEvidence != null)
            && (r.ModerationState == ContentState.Passed || r.ModerationState == ContentState.Rejected) && r.ModeratedAt < cut).Take(100).ToListAsync(ct);
        foreach (var r in reviews)
        {
            await AppealEvidence.DeleteAsync(media, r.AppealEvidence, ct);
            (r.AppealNote, r.AppealEvidence) = (null, null);
            done++;
        }
        var photos = await db.Photos.Where(p => p.AppealedAt != null && (p.AppealNote != null || p.AppealEvidence != null)
            && (p.ModerationState == ContentState.Passed || p.ModerationState == ContentState.Rejected) && p.ModeratedAt < cut).Take(100).ToListAsync(ct);
        foreach (var p in photos)
        {
            await AppealEvidence.DeleteAsync(media, p.AppealEvidence, ct);
            (p.AppealNote, p.AppealEvidence) = (null, null);
            done++;
        }
        await db.SaveChangesAsync(ct);

        done += await db.CommunityPlaces.Where(p => p.AppealedAt != null && p.AppealNote != null && !p.HeldForReview
            && p.ScreeningState != ScreeningState.Held && p.UpdatedAt < cut).ExecuteUpdateAsync(s => s.SetProperty(p => p.AppealNote, (string?)null), ct);
        return done;
    }
}
