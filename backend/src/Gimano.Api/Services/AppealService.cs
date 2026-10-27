using Gimano.Api.Endpoints;
using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Api.Services;

/// <summary>
/// <c>POST /api/v1/appeals</c> (docs/content-safety.md "Appeals"): "ask for a review" with a compulsory note and up to three private
/// evidence photos, for a review that was refused (nothing of it is stored on our side), or a photo or place the content check did not accept.
/// The appeal waits in the maintainers' queue; approving or denying it is in <see cref="Moderation"/>.
/// </summary>
public sealed class AppealService(GimanoDbContext db, IMediaStore media, TimeProvider clock)
{
    public const int PerDay = 10;

    public async Task<AppealAccepted> CreateAsync(Guid userId, AppealInput input, CancellationToken ct)
    {
        var user = Moderation.EnsureMayContribute(await db.Users.FirstOrDefaultAsync(u => u.Id == userId, ct) ?? throw new UnauthorizedAccessException("This account was deleted."));
        if (!Guid.TryParse(input.RefusalId, out var refusalId) || refusalId == Guid.Empty) throw new ValidationException("refusalId", "refusalId must be a UUID.");
        if (!GimanoJson.TryParseWire<AppealKind>(input.Kind, out var kind)) throw new ValidationException("kind", "kind must be review, photo or place.");
        var placeId = input.PlaceId?.Trim() ?? "";
        if (kind != AppealKind.Photo && (placeId.Length == 0 || placeId.Length > 40)) throw new ValidationException("placeId", "placeId is required.");
        var note = Moderation.CheckAppealNote(input.Note);
        var reasons = input.Reasons.Select(r => r.Trim().ToLowerInvariant()).Where(PlaceScreening.ReasonCodes.Contains).Distinct().Take(4).ToList();

        if (await db.ContentAppeals.AnyAsync(a => a.UserId == userId && a.RefusalId == refusalId, ct)) throw AlreadyAppealed();
        var now = clock.GetUtcNow();
        if (await db.ContentAppeals.CountAsync(a => a.UserId == userId && a.CreatedAt > now.AddDays(-1), ct) >= PerDay)
            throw new RateLimitedException($"At most {PerDay} appeals per day.");

        // What each kind needs, and what it points at.
        string? text = null;
        int? rating = null;
        switch (kind)
        {
            case AppealKind.Review:
                if (!int.TryParse(input.Rating, out var r)) throw new ValidationException("rating", "rating (1-5) is required for a review.");
                text = ReviewService.CheckText(r, TrimToNull(input.Text));
                rating = r;
                if (!await PlaceExistsAsync(placeId, ct)) throw new NotFoundException("Place not found.");
                break;
            case AppealKind.Photo:
            {
                var p = await db.Photos.FirstOrDefaultAsync(x => x.Id == refusalId, ct) ?? throw new NotFoundException("Photo not found.");
                if (p.UserId != userId) throw new ForbiddenException("Only the uploader can ask for a review of this photo.");
                if (p.ModerationState != ContentState.Rejected || p.Key is null) throw new ConflictException("Only a photo that was not accepted can be sent for review.");
                if (p.AppealedAt is not null) throw AlreadyAppealed();
                placeId = p.PlaceId;
                p.AppealedAt = now;      // keeps the photo's files while a person looks, and closes the older per-photo appeal
                break;
            }
            default:
            {
                var c = await db.CommunityPlaces.FirstOrDefaultAsync(x => x.Id == placeId, ct) ?? throw new NotFoundException("Place not found.");
                if (c.OwnerId != userId) throw new ForbiddenException("Only the owner can ask for a review of this place.");
                if (c.Status != PlaceStatus.Rejected) throw new ConflictException("Only a place that was not accepted can be sent for review.");
                if (c.AppealedAt is not null) throw AlreadyAppealed();
                text = TrimToNull(input.Text);
                if (text is { Length: > AppealEvidence.MaxTextLength }) throw new ValidationException("text", $"text max {AppealEvidence.MaxTextLength} chars.");
                c.AppealedAt = now;
                break;
            }
        }

        var webps = AppealEvidence.Prepare(input.Photos);
        var appeal = new ContentAppeal
        {
            RefusalId = refusalId, UserId = userId, Kind = kind, PlaceId = placeId, Rating = rating, Text = text,
            Reasons = reasons.Count == 0 ? null : ContentScreening.Join(reasons), Note = note, CreatedAt = now,
        };
        appeal.EvidenceKeys = await AppealEvidence.StoreAsync(media, appeal.Id, webps, ct);
        db.ContentAppeals.Add(appeal);
        try { await db.SaveChangesAsync(ct); }
        catch (DbUpdateException ex) when (ex.InnerException is Npgsql.PostgresException { SqlState: Npgsql.PostgresErrorCodes.UniqueViolation })
        {
            await AppealEvidence.DeleteAsync(media, appeal.EvidenceKeys, ct);
            throw AlreadyAppealed();
        }
        catch
        {
            await AppealEvidence.DeleteAsync(media, appeal.EvidenceKeys, ct);
            throw;
        }
        return new AppealAccepted(appeal.Id, "pending");
    }

    private static ApiCodeException AlreadyAppealed() => new(409, "already_appealed", "This was already sent for review.");

    private static string? TrimToNull(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

    private async Task<bool> PlaceExistsAsync(string placeId, CancellationToken ct) =>
        CommunityPlace.IsCommunityId(placeId)
            ? await db.CommunityPlaces.AnyAsync(p => p.Id == placeId, ct)
            : await db.Places.AnyAsync(p => p.Id == placeId, ct);
}
