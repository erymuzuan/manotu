using Gimano.Core.Alerts;
using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Messaging;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;

namespace Gimano.Api.Services;


public sealed class ReportService(GimanoDbContext db, IEventPublisher bus, GeoLookup geo, TimeProvider clock, IMemoryCache cache, RestrictedAreaService restricted,
    ContentGate gate)
{
    public async Task<(ReportCreatedDto Report, bool Merged)> CreateAsync(Guid userId, CreateReportRequest req, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var loc = new GeoPoint(req.Lat, req.Lng);
        await restricted.EnsureAllowedAsync(loc, ct);
        var user = Moderation.EnsureMayContribute(await db.Users.FirstOrDefaultAsync(u => u.Id == userId, ct) ?? throw new UnauthorizedAccessException("This account was deleted."));

        // Duplicate suppression: same type within 150 m along the same heading.
        var pt = loc.ToPoint();
        var nearby = await db.Reports.Include(r => r.Reporter)
            .Where(r => r.Status == ReportStatus.Active && r.ExpiresAt > now && r.Type == req.Type
                        && r.Location.IsWithinDistance(pt, AlertRules.DuplicateRadiusM))
            .OrderBy(r => r.Location.Distance(pt))
            .ToListAsync(ct);
        var dup = nearby.FirstOrDefault(r => AlertRules.IsDuplicate(req.Type, loc, req.Heading, r.Type, GeoPoint.From(r.Location), r.Heading));
        if (dup is not null)
        {
            // A duplicate report is a "still there" vote: once per pseudonym (the reporter's own report already counts), so
            // reporting the same hazard again and again doesn't add confirmations or points.
            var vote = await db.ReportVotes.FindAsync([dup.Id, userId], ct);
            var effect = AlertRules.OnVote(dup.ReporterId == userId ? true : vote?.StillThere, stillThere: true);
            if (vote is not null) { vote.StillThere = true; vote.CreatedAt = now; }
            else if (dup.ReporterId != userId)
                db.ReportVotes.Add(new ReportVote { ReportId = dup.Id, UserId = userId, StillThere = true, Weight = AlertRules.VoteWeight(user.Reputation), CreatedAt = now });
            dup.Confirmations += effect.ConfirmationsDelta;
            if (effect.ExtendExpiry) dup.ExpiresAt = AlertRules.ExtendOnStillThere(dup.Type, dup.CreatedAt, dup.ExpiresAt, now);
            if (effect.AwardPoints)
            {
                if (dup.Reporter is not null) dup.Reporter.Points += AlertRules.Points.Confirmed;
                user.Points += AlertRules.Points.Vote;
            }
            await db.SaveChangesAsync(ct);
            var merged = dup.ToDto();
            await bus.PublishAsync(RoutingKeys.ReportUpdated, merged, ct);
            return (ReportCreatedDto.From(merged), true);
        }

        // A free-text note is checked (docs/content-safety.md "Report notes"): a rejected note is dropped and the report still goes out.
        // No answer, or the check off: the note is kept (it is not shown to other drivers).
        var comment = string.IsNullOrWhiteSpace(req.Comment ?? req.Note) ? null : (req.Comment ?? req.Note)!.Trim();
        bool? noteDropped = null;
        IReadOnlyList<string>? noteReasons = null;
        if (comment is not null)
        {
            var outcome = await gate.CheckTextAsync(new ContentInput(ContentKind.ReportNote, comment), PlaceScreening.SyncBudget, ct);
            if (outcome.Kind is ContentOutcomeKind.Rejected or ContentOutcomeKind.Held)
            {
                if (outcome.Kind == ContentOutcomeKind.Rejected) await gate.RecordRejectionAsync(userId, ct);
                (comment, noteDropped, noteReasons) = (null, true, outcome.Reasons);
            }
        }

        var report = new Report
        {
            Type = req.Type,
            Subtype = string.IsNullOrWhiteSpace(req.Subtype) ? null : req.Subtype,
            Location = pt,
            EndLocation = req.EndLat is { } elat && req.EndLng is { } elng ? new GeoPoint(elat, elng).ToPoint() : null,
            Heading = req.Heading is { } h ? ((h % 360) + 360) % 360 : null,
            Comment = comment,
            Street = await geo.StreetNameAsync(loc, ct),
            ReporterId = userId,
            Reporter = user,
            CreatedAt = now,
            ExpiresAt = AlertRules.InitialExpiry(req.Type, now),
        };
        user.Points += AlertRules.Points.NewReport;
        db.Reports.Add(report);
        await db.SaveChangesAsync(ct);

        var dto = report.ToDto();
        await bus.PublishAsync(RoutingKeys.ReportCreated, dto, ct);
        return (ReportCreatedDto.From(dto, noteDropped, noteReasons), false);
    }

    /// <summary>"Undo" right after a quick report (docs/driving.md §6.4): within <see cref="UndoWindow"/>, the reporter's own
    /// report is withdrawn (expired now, points taken back), or, when their report was merged into an existing one, their
    /// vote on it is removed. Later: 409.</summary>
    public static readonly TimeSpan UndoWindow = TimeSpan.FromMinutes(2);

    public async Task RetractAsync(Guid reportId, Guid userId, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var report = await db.Reports.Include(r => r.Reporter).FirstOrDefaultAsync(r => r.Id == reportId, ct)
                     ?? throw new NotFoundException($"Report {reportId} not found.");
        var user = await db.Users.FirstOrDefaultAsync(u => u.Id == userId, ct) ?? throw new UnauthorizedAccessException("This account was deleted.");
        if (report.ReporterId == userId)
        {
            if (now - report.CreatedAt > UndoWindow) throw new ConflictException("This report can no longer be undone.");
            if (report.Status == ReportStatus.Expired) return;
            report.Status = ReportStatus.Expired;
            report.ExpiresAt = now;
            user.Points = Math.Max(0, user.Points - AlertRules.Points.NewReport);
            await db.SaveChangesAsync(ct);
            await bus.PublishAsync(RoutingKeys.ReportExpired, new ReportExpiredEvent(reportId), ct);
            return;
        }
        var vote = await db.ReportVotes.FindAsync([reportId, userId], ct) ?? throw new ForbiddenException("Only your own report or confirmation can be undone.");
        if (now - vote.CreatedAt > UndoWindow) throw new ConflictException("This report can no longer be undone.");
        db.ReportVotes.Remove(vote);
        if (vote.StillThere)
        {
            report.Confirmations = Math.Max(0, report.Confirmations - 1);
            // The reporter was credited for this confirmation; take it back with the vote.
            if (report.Reporter is not null) report.Reporter.Points = Math.Max(0, report.Reporter.Points - AlertRules.Points.Confirmed);
        }
        user.Points = Math.Max(0, user.Points - AlertRules.Points.Vote);
        await db.SaveChangesAsync(ct);
        await bus.PublishAsync(RoutingKeys.ReportUpdated, report.ToDto(), ct);
    }

    public async Task<ReportDto> VoteAsync(Guid reportId, Guid userId, bool stillThere, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var report = await db.Reports.Include(r => r.Reporter).FirstOrDefaultAsync(r => r.Id == reportId, ct)
                     ?? throw new NotFoundException($"Report {reportId} not found.");
        if (report.Status != ReportStatus.Active || report.ExpiresAt <= now)
            throw new ConflictException("Report has already expired.");

        var voter = Moderation.EnsureMayContribute(await db.Users.FirstOrDefaultAsync(u => u.Id == userId, ct) ?? throw new UnauthorizedAccessException("This account was deleted."));
        var existing = await db.ReportVotes.FindAsync([reportId, userId], ct);
        var effect = AlertRules.OnVote(existing?.StillThere, stillThere);
        if (existing is not null)
        {
            // Changing your mind is allowed, but a repeated identical vote does nothing.
            if (existing.StillThere == stillThere) return report.ToDto();
            existing.StillThere = stillThere;
            existing.CreatedAt = now;
        }
        else
        {
            db.ReportVotes.Add(new ReportVote
            {
                ReportId = reportId, UserId = userId, StillThere = stillThere,
                Weight = AlertRules.VoteWeight(voter.Reputation), CreatedAt = now,
            });
        }
        if (effect.AwardPoints) voter.Points += AlertRules.Points.Vote;
        report.Confirmations = Math.Max(0, report.Confirmations + effect.ConfirmationsDelta);

        var expired = false;
        if (stillThere)
        {
            if (effect.ExtendExpiry) report.ExpiresAt = AlertRules.ExtendOnStillThere(report.Type, report.CreatedAt, report.ExpiresAt, now);
            if (effect.AwardPoints && report.Reporter is not null && report.ReporterId != userId) report.Reporter.Points += AlertRules.Points.Confirmed;
        }
        else
        {
            await db.SaveChangesAsync(ct);
            var weights = await db.ReportVotes.Where(v => v.ReportId == reportId && !v.StillThere && v.UserId != report.ReporterId)
                .Select(v => v.Weight).ToListAsync(ct);
            if (AlertRules.ShouldExpireOnNotThere(weights))
            {
                report.Status = ReportStatus.Expired;
                report.ExpiresAt = now;
                expired = true;
            }
        }
        await db.SaveChangesAsync(ct);

        var dto = report.ToDto();
        await bus.PublishAsync(RoutingKeys.ReportVoted, new ReportVotedEvent(reportId, stillThere, userId), ct);
        if (expired) await bus.PublishAsync(RoutingKeys.ReportExpired, new ReportExpiredEvent(reportId), ct);
        else await bus.PublishAsync(RoutingKeys.ReportUpdated, dto, ct);
        return dto;
    }

    public async Task ThankAsync(Guid reportId, Guid userId, CancellationToken ct)
    {
        var report = await db.Reports.Include(r => r.Reporter).FirstOrDefaultAsync(r => r.Id == reportId, ct)
                     ?? throw new NotFoundException($"Report {reportId} not found.");
        // One thanks per pseudonym per report: repeating it is a no-op (no count, points or inbox bump).
        if (!FirstThanks(cache, reportId, userId, report.ExpiresAt, clock.GetUtcNow())) return;
        report.Thanks++;
        if (report.Reporter is not null && report.ReporterId != userId) report.Reporter.Points += AlertRules.Points.Thanked;
        await db.SaveChangesAsync(ct);
        await bus.PublishAsync(RoutingKeys.ReportUpdated, report.ToDto(), ct);
        if (report.ReporterId != userId) await bus.PublishAsync(RoutingKeys.ReportThanked, new ReportThankedEvent(reportId), ct);
    }

    private static readonly Lock ThanksLock = new();

    /// <summary>
    /// True the first time this pseudonym thanks this report. Remembered in memory until the report expires (reports live
    /// hours, at most 3× their base TTL), so no per-user thanks rows are stored.
    /// </summary>
    internal static bool FirstThanks(IMemoryCache cache, Guid reportId, Guid userId, DateTimeOffset reportExpiresAt, DateTimeOffset now)
    {
        var key = $"thanks:{reportId:N}:{userId:N}";
        lock (ThanksLock)
        {
            if (cache.TryGetValue(key, out _)) return false;
            cache.Set(key, true, reportExpiresAt > now ? reportExpiresAt : now.AddHours(1));
            return true;
        }
    }

    public async Task<IReadOnlyList<ReportDto>> ActiveInBBoxAsync(BBox bbox, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var poly = bbox.ToPolygon();
        var list = await db.Reports.AsNoTracking().Include(r => r.Reporter)
            .Where(r => r.Status == ReportStatus.Active && r.ExpiresAt > now && r.Location.Intersects(poly))
            .OrderByDescending(r => r.CreatedAt)
            .Take(1000)
            .ToListAsync(ct);
        return list.Select(r => r.ToDto()).ToList();
    }
}
