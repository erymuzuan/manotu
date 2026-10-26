using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Messaging;
using Gimano.Core.Places;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Api.Services;

/// <summary>Reviews: one per user per place, helpful toggle, flags (3 distinct → hidden), rate limits, cursor pages.</summary>
public sealed class ReviewService(GimanoDbContext db, IEventPublisher bus, TimeProvider clock, AuthorHandles handles, RestrictedAreaService restricted,
    ContentGate gate)
{
    public const int PageSize = 20;

    public async Task<ReviewsPage> ListAsync(string placeId, ReviewSort sort, string? cursor, CancellationToken ct, Guid? viewer = null)
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
        // The author also sees their own review while it is checked, held or not accepted (first page only).
        if (viewer is { } me && cursor is null)
        {
            var own = await db.Reviews.AsNoTracking().Include(r => r.User).FirstOrDefaultAsync(r => r.PlaceId == placeId && r.UserId == me
                && r.Status == ReviewStatus.Hidden && r.ModerationState != ContentState.None && r.ModerationState != ContentState.Passed, ct);
            if (own is not null && rows.All(r => r.Id != own.Id)) rows.Insert(0, own);
        }
        var dtos = await ToDtosAsync(rows, ct, viewer);
        string? next = more
            ? sort == ReviewSort.Helpful ? CommunityRules.EncodeCursor(rows[^1].HelpfulCount, rows[^1].Id) : CommunityRules.EncodeCursor(rows[^1].Id)
            : null;
        return new ReviewsPage(dtos, next);
    }

    public async Task<ReviewDto> CreateAsync(Guid userId, string placeId, CreateReviewRequest req, CancellationToken ct)
    {
        var user = Moderation.EnsureMayContribute(await db.Users.FirstOrDefaultAsync(u => u.Id == userId, ct) ?? throw new UnauthorizedAccessException("This account was deleted."));
        Moderation.EnsureNotPaused(user, clock.GetUtcNow());
        await CheckPlaceAsync(placeId, userId, ct);
        var text = CheckText(req.Rating, req.Text);
        if (await restricted.LevelForPlaceAsync(placeId, ct) == RestrictedLevel.Blocked) restricted.Refuse();
        if (await db.Reviews.AnyAsync(r => r.PlaceId == placeId && r.UserId == userId, ct))
            throw new ConflictException("You already reviewed this place; edit your review instead.");
        var now = clock.GetUtcNow();
        if (await db.Reviews.CountAsync(r => r.UserId == userId && r.CreatedAt > now.AddDays(-1), ct) >= CommunityRules.ReviewsPerDay)
            throw new RateLimitedException($"At most {CommunityRules.ReviewsPerDay} reviews per day.");

        // The content check (docs/content-safety.md): about 2 s; past 4 s the review is stored hidden as "checking" and the worker finishes it.
        var outcome = await gate.CheckTextAsync(new ContentInput(ContentKind.Review, text, await PlaceNameAsync(placeId, ct)), PlaceScreening.SyncBudget, ct);
        if (outcome.Kind == ContentOutcomeKind.Rejected)
        {
            await gate.RecordRejectionAsync(userId, ct);
            throw new ContentRejectedException(outcome.Reasons, outcome.SafeText);
        }

        var review = new Review { PlaceId = placeId, UserId = userId, User = user, Rating = req.Rating, Text = text, CreatedAt = now };
        Apply(review, outcome, now);
        if (RestrictedAreaRules.HasSensitiveTerm(text)) HoldForSecurity(review, now);
        db.Reviews.Add(review);
        user.Points += CommunityRules.Points.Review;
        await db.SaveChangesAsync(ct);
        await AttachPhotosAsync(review, userId, req.PhotoIds, ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(placeId), ct);
        await gate.AnnounceAsync("review", review.Id.ToString(), placeId, review.ModerationState, late: false, ct);
        return (await ToDtosAsync([review], ct, userId))[0];
    }

    public async Task<ReviewDto> PatchAsync(Guid userId, Guid id, PatchReviewRequest req, CancellationToken ct)
    {
        var review = await OwnAsync(userId, id, ct);
        var now = clock.GetUtcNow();
        Moderation.EnsureNotPaused(review.User ?? throw new UnauthorizedAccessException("This account was deleted."), now);
        var text = CheckText(req.Rating ?? review.Rating, req.Text ?? review.Text);
        // An edited text is screened the same way as a new one; nothing changes when it is rejected.
        ContentOutcome? outcome = null;
        if (req.Text is not null && text != review.Text)
        {
            outcome = await gate.CheckTextAsync(new ContentInput(ContentKind.ReviewEdit, text, await PlaceNameAsync(review.PlaceId, ct)), PlaceScreening.SyncBudget, ct);
            if (outcome.Kind == ContentOutcomeKind.Rejected)
            {
                await gate.RecordRejectionAsync(userId, ct);
                throw new ContentRejectedException(outcome.Reasons, outcome.SafeText);
            }
        }
        if (req.Rating is { } r) review.Rating = r;
        if (req.Text is not null) review.Text = text;
        if (outcome is not null)
        {
            // Only a review that was live (or one that was not accepted and is being fixed) goes live again; flag and moderator hides stay.
            var wasLive = review.Status == ReviewStatus.Published || review.ModerationState == ContentState.Rejected;
            if (wasLive || outcome.Kind is ContentOutcomeKind.Held or ContentOutcomeKind.Checking) Apply(review, outcome, now);
            if (RestrictedAreaRules.HasSensitiveTerm(text)) HoldForSecurity(review, now);
        }
        review.EditedAt = now;
        await db.SaveChangesAsync(ct);
        if (req.PhotoIds is not null) await AttachPhotosAsync(review, userId, req.PhotoIds, ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(review.PlaceId), ct);
        if (outcome is not null) await gate.AnnounceAsync("review", review.Id.ToString(), review.PlaceId, review.ModerationState, late: false, ct);
        return (await ToDtosAsync([review], ct, userId))[0];
    }

    /// <summary>"Ask for a review" on a review the content check did not accept: once per review, held for a maintainer (note ≤ 200 characters).</summary>
    public async Task AppealAsync(Guid userId, Guid id, string? note, CancellationToken ct)
    {
        var review = await OwnAsync(userId, id, ct);
        if (review.ModerationState != ContentState.Rejected) throw new ConflictException("Only a review that was not accepted can be sent for review.");
        if (review.AppealedAt is not null) throw new ConflictException("This review was already sent for review.");
        var now = clock.GetUtcNow();
        review.AppealNote = Moderation.CheckAppealNote(note);
        review.AppealedAt = now;
        review.ModerationState = ContentState.Held;
        review.HeldForReview = true;
        review.Status = ReviewStatus.Hidden;
        review.ModeratedAt = now;
        await db.SaveChangesAsync(ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(review.PlaceId), ct);
        await gate.AnnounceAsync("review", review.Id.ToString(), review.PlaceId, ContentState.Held, late: false, ct);
    }

    /// <summary>The outcome as the review's status and moderation fields.</summary>
    internal static void Apply(Review r, ContentOutcome o, DateTimeOffset now)
    {
        r.ModerationState = o.State;
        r.ModerationReasons = o.Kind is ContentOutcomeKind.Held or ContentOutcomeKind.Rejected ? ContentScreening.Join(o.Reasons) : null;
        r.ModeratedAt = o.Kind == ContentOutcomeKind.Checking ? null : now;
        r.HeldForReview = o.Kind == ContentOutcomeKind.Held;
        r.Status = o.Kind is ContentOutcomeKind.Passed or ContentOutcomeKind.Skipped ? ReviewStatus.Published : ReviewStatus.Hidden;
    }

    private static void HoldForSecurity(Review r, DateTimeOffset now)
    {
        r.Status = ReviewStatus.Hidden; r.HeldForReview = true; r.ModerationState = ContentState.Held; r.ModerationReasons = "security"; r.ModeratedAt = now;
    }

    private async Task<string?> PlaceNameAsync(string placeId, CancellationToken ct) =>
        CommunityPlace.IsCommunityId(placeId)
            ? await db.CommunityPlaces.AsNoTracking().Where(p => p.Id == placeId).Select(p => p.Name).FirstOrDefaultAsync(ct)
            : await db.Places.AsNoTracking().Where(p => p.Id == placeId).Select(p => p.Name).FirstOrDefaultAsync(ct);

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

    /// <summary>The author's view of the content check; null for content that was never checked.</summary>
    internal static ContentModerationDto? ModerationFor(Review r) => r.ModerationState == ContentState.None ? null
        : new ContentModerationDto(r.ModerationState, ContentScreening.Split(r.ModerationReasons), r.ModerationState == ContentState.Rejected && r.AppealedAt is null);

    private async Task<List<ReviewDto>> ToDtosAsync(IReadOnlyList<Review> rows, CancellationToken ct, Guid? viewer = null)
    {
        var ids = rows.Select(r => r.Id).ToList();
        var photos = await db.Photos.AsNoTracking().Include(p => p.User)
            .Where(p => p.ReviewId != null && ids.Contains(p.ReviewId.Value) && p.Status != PhotoStatus.Rejected
                        && (p.ModerationState != ContentState.Held && p.ModerationState != ContentState.Checking || (viewer != null && p.UserId == viewer)))
            .OrderBy(p => p.Id).ToListAsync(ct);
        var userIds = rows.Where(r => r.UserId != null).Select(r => r.UserId!.Value).Distinct().ToList();
        var counts = await db.Reviews.AsNoTracking().Where(r => r.UserId != null && userIds.Contains(r.UserId.Value))
            .GroupBy(r => r.UserId!.Value).Select(g => new { g.Key, Count = g.Count() }).ToDictionaryAsync(x => x.Key, x => x.Count, ct);
        return rows.Select(r => new ReviewDto(
            r.Id, r.PlaceId, r.Rating, r.Text,
            photos.Where(p => p.ReviewId == r.Id).Select(p => PhotoService.ToDto(p, handles, viewer)).ToList(),
            r.User is null
                ? new ReviewAuthor("Pemandu Manotu", 1, 0)
                : new ReviewAuthor(r.User.DisplayName, r.User.Level, counts.GetValueOrDefault(r.User.Id), handles.For(r.User.Id)),
            r.HelpfulCount, r.CreatedAt, r.EditedAt, r.Status, r.HeldForReview,
            viewer is not null && r.UserId == viewer ? ModerationFor(r) : null)).ToList();
    }
}
