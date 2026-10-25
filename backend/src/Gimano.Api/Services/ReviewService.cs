using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Messaging;
using Gimano.Core.Places;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Api.Services;

/// <summary>Reviews: one per user per place, helpful toggle, flags (3 distinct → hidden), rate limits, cursor pages.</summary>
public sealed class ReviewService(GimanoDbContext db, IEventPublisher bus, TimeProvider clock, AuthorHandles handles, RestrictedAreaService restricted)
{
    public const int PageSize = 20;

    public async Task<ReviewsPage> ListAsync(string placeId, ReviewSort sort, string? cursor, CancellationToken ct)
    {
        var q = db.Reviews.AsNoTracking().Include(r => r.User).Where(r => r.PlaceId == placeId && r.Status == ReviewStatus.Published);
        var c = CommunityRules.DecodeCursor(cursor);
        List<Review> rows;
        if (sort == ReviewSort.Helpful)
        {
            if (c is [var h, var id] && int.TryParse(h, out var helpful) && Guid.TryParse(id, out var after))
                q = q.Where(r => r.HelpfulCount < helpful || (r.HelpfulCount == helpful && r.Id.CompareTo(after) < 0));
            rows = await q.OrderByDescending(r => r.HelpfulCount).ThenByDescending(r => r.Id).Take(PageSize + 1).ToListAsync(ct);
        }
        else
        {
            // Ids are UUIDv7, so id order is creation order.
            if (c is [var id] && Guid.TryParse(id, out var after)) q = q.Where(r => r.Id.CompareTo(after) < 0);
            rows = await q.OrderByDescending(r => r.Id).Take(PageSize + 1).ToListAsync(ct);
        }
        var more = rows.Count > PageSize;
        if (more) rows.RemoveAt(rows.Count - 1);
        var dtos = await ToDtosAsync(rows, ct);
        string? next = more
            ? sort == ReviewSort.Helpful ? CommunityRules.EncodeCursor(rows[^1].HelpfulCount, rows[^1].Id) : CommunityRules.EncodeCursor(rows[^1].Id)
            : null;
        return new ReviewsPage(dtos, next);
    }

    public async Task<ReviewDto> CreateAsync(Guid userId, string placeId, CreateReviewRequest req, CancellationToken ct)
    {
        var user = Moderation.EnsureMayContribute(await db.Users.FirstOrDefaultAsync(u => u.Id == userId, ct) ?? throw new UnauthorizedAccessException("This account was deleted."));
        await CheckPlaceAsync(placeId, userId, ct);
        var text = CheckText(req.Rating, req.Text);
        if (await restricted.LevelForPlaceAsync(placeId, ct) == RestrictedLevel.Blocked) restricted.Refuse();
        if (await db.Reviews.AnyAsync(r => r.PlaceId == placeId && r.UserId == userId, ct))
            throw new ConflictException("You already reviewed this place; edit your review instead.");
        var now = clock.GetUtcNow();
        if (await db.Reviews.CountAsync(r => r.UserId == userId && r.CreatedAt > now.AddDays(-1), ct) >= CommunityRules.ReviewsPerDay)
            throw new RateLimitedException($"At most {CommunityRules.ReviewsPerDay} reviews per day.");

        var review = new Review { PlaceId = placeId, UserId = userId, User = user, Rating = req.Rating, Text = text, CreatedAt = now };
        if (RestrictedAreaRules.HasSensitiveTerm(text)) { review.Status = ReviewStatus.Hidden; review.HeldForReview = true; }
        db.Reviews.Add(review);
        user.Points += CommunityRules.Points.Review;
        await db.SaveChangesAsync(ct);
        await AttachPhotosAsync(review, userId, req.PhotoIds, ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(placeId), ct);
        return (await ToDtosAsync([review], ct))[0];
    }

    public async Task<ReviewDto> PatchAsync(Guid userId, Guid id, PatchReviewRequest req, CancellationToken ct)
    {
        var review = await OwnAsync(userId, id, ct);
        var text = CheckText(req.Rating ?? review.Rating, req.Text ?? review.Text);
        if (req.Rating is { } r) review.Rating = r;
        if (req.Text is not null) review.Text = text;
        if (req.Text is not null && RestrictedAreaRules.HasSensitiveTerm(text)) { review.Status = ReviewStatus.Hidden; review.HeldForReview = true; }
        review.EditedAt = clock.GetUtcNow();
        await db.SaveChangesAsync(ct);
        if (req.PhotoIds is not null) await AttachPhotosAsync(review, userId, req.PhotoIds, ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(review.PlaceId), ct);
        return (await ToDtosAsync([review], ct))[0];
    }

    public async Task DeleteAsync(Guid userId, Guid id, CancellationToken ct)
    {
        var review = await OwnAsync(userId, id, ct);
        db.Reviews.Remove(review);
        await db.SaveChangesAsync(ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(review.PlaceId), ct);
    }

    /// <summary>Toggle: first call marks helpful (+1 point to the author), second call removes it.</summary>
    public async Task ToggleHelpfulAsync(Guid userId, Guid id, CancellationToken ct)
    {
        var review = await db.Reviews.Include(r => r.User).FirstOrDefaultAsync(r => r.Id == id, ct) ?? throw new NotFoundException("Review not found.");
        if (review.UserId == userId) throw new ForbiddenException("You can't mark your own review as helpful.");
        var existing = await db.ReviewHelpfuls.FindAsync([id, userId], ct);
        if (existing is null)
        {
            db.ReviewHelpfuls.Add(new ReviewHelpful { ReviewId = id, UserId = userId });
            review.HelpfulCount++;
            if (review.User is not null) review.User.Points += CommunityRules.Points.HelpfulReceived;
            await db.SaveChangesAsync(ct);
            await bus.PublishAsync(RoutingKeys.ReviewHelpful, new ReviewHelpfulEvent(id), ct);
            return;
        }
        else
        {
            db.ReviewHelpfuls.Remove(existing);
            review.HelpfulCount = Math.Max(0, review.HelpfulCount - 1);
            if (review.User is not null) review.User.Points = Math.Max(0, review.User.Points - CommunityRules.Points.HelpfulReceived);
        }
        await db.SaveChangesAsync(ct);
    }

    /// <summary>3 flags from distinct users hide the review pending moderation.</summary>
    public async Task FlagAsync(Guid userId, Guid id, FlagReason reason, CancellationToken ct)
    {
        var review = await db.Reviews.FirstOrDefaultAsync(r => r.Id == id, ct) ?? throw new NotFoundException("Review not found.");
        if (await db.ReviewFlags.FindAsync([id, userId], ct) is not null) return;
        db.ReviewFlags.Add(new ReviewFlag { ReviewId = id, UserId = userId, Reason = reason, CreatedAt = clock.GetUtcNow() });
        review.FlagCount++;
        if (review.FlagCount >= RestrictedAreaRules.FlagsToHide(reason, CommunityRules.FlagsToHide)) review.Status = ReviewStatus.Hidden;
        await db.SaveChangesAsync(ct);
        if (review.Status == ReviewStatus.Hidden) await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(review.PlaceId), ct);
    }

    internal static string? CheckText(int rating, string? text)
    {
        if (rating is < 1 or > 5) throw new ValidationException("rating", "rating must be 1–5.");
        if (text is null) return null;
        if (text.Length > CommunityRules.MaxReviewLength) throw new ValidationException("text", $"text max {CommunityRules.MaxReviewLength} chars.");
        if (TextFilter.Default.Check(text, rejectLinks: false) == TextVerdict.Profanity) throw new ValidationException("text", "Please keep reviews friendly.");
        var stripped = TextFilter.StripLinks(text);
        return stripped.Length == 0 ? null : stripped;
    }

    /// <summary>The place must exist and be visible; no reviews on a place you added in its first 24 h.</summary>
    private async Task CheckPlaceAsync(string placeId, Guid userId, CancellationToken ct)
    {
        if (CommunityPlace.IsCommunityId(placeId))
        {
            var p = await db.CommunityPlaces.AsNoTracking().FirstOrDefaultAsync(x => x.Id == placeId, ct) ?? throw new NotFoundException("Place not found.");
            if (!CommunityRules.IsVisibleTo(p.Status, p.OwnerId, userId, p.ScreeningState) || p.Status is PlaceStatus.Hidden or PlaceStatus.Rejected) throw new NotFoundException("Place not found.");
            if (p.OwnerId == userId && clock.GetUtcNow() - p.CreatedAt < CommunityRules.SelfReviewBlock)
                throw new ForbiddenException("You can review a place you added only after 24 hours.");
        }
        else if (!await db.Places.AnyAsync(x => x.Id == placeId, ct)) throw new NotFoundException("Place not found.");
    }

    private async Task AttachPhotosAsync(Review review, Guid userId, IReadOnlyList<Guid>? photoIds, CancellationToken ct)
    {
        if (photoIds is not { Count: > 0 }) return;
        var ids = photoIds.Distinct().Take(10).ToList();
        await db.Photos.Where(p => ids.Contains(p.Id) && p.UserId == userId && p.PlaceId == review.PlaceId)
            .ExecuteUpdateAsync(s => s.SetProperty(p => p.ReviewId, review.Id), ct);
    }

    private async Task<Review> OwnAsync(Guid userId, Guid id, CancellationToken ct)
    {
        var r = await db.Reviews.Include(x => x.User).FirstOrDefaultAsync(x => x.Id == id, ct) ?? throw new NotFoundException("Review not found.");
        if (r.UserId != userId) throw new ForbiddenException("Only the author can change this review.");
        return r;
    }

    private async Task<List<ReviewDto>> ToDtosAsync(IReadOnlyList<Review> rows, CancellationToken ct)
    {
        var ids = rows.Select(r => r.Id).ToList();
        var photos = await db.Photos.AsNoTracking().Include(p => p.User)
            .Where(p => p.ReviewId != null && ids.Contains(p.ReviewId.Value) && p.Status != PhotoStatus.Rejected)
            .OrderBy(p => p.Id).ToListAsync(ct);
        var userIds = rows.Where(r => r.UserId != null).Select(r => r.UserId!.Value).Distinct().ToList();
        var counts = await db.Reviews.AsNoTracking().Where(r => r.UserId != null && userIds.Contains(r.UserId.Value))
            .GroupBy(r => r.UserId!.Value).Select(g => new { g.Key, Count = g.Count() }).ToDictionaryAsync(x => x.Key, x => x.Count, ct);
        return rows.Select(r => new ReviewDto(
            r.Id, r.PlaceId, r.Rating, r.Text,
            photos.Where(p => p.ReviewId == r.Id).Select(p => PhotoService.ToDto(p, handles)).ToList(),
            r.User is null
                ? new ReviewAuthor("Pemandu Manotu", 1, 0)
                : new ReviewAuthor(r.User.DisplayName, r.User.Level, counts.GetValueOrDefault(r.User.Id), handles.For(r.User.Id)),
            r.HelpfulCount, r.CreatedAt, r.EditedAt, r.Status, r.HeldForReview)).ToList();
    }
}
