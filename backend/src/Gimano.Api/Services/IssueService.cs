using System.Globalization;
using System.Text.Json.Nodes;
using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Identity;
using Gimano.Core.Issues;
using Gimano.Core.Messaging;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Api.Services;

/// <summary>Road and place complaints (docs/complaints.md, docs/api.md "Issues").</summary>
public sealed class IssueService(GimanoDbContext db, IEventPublisher bus, IssueDirectory directory, TimeProvider clock, ILogger<IssueService> logger,
    AuthorHandles? handles = null, RestrictedAreaService? restricted = null)
{
    /// <summary>
    /// Dual carriageways are separate one-way ways; on the E12 (AKLEH) they are ~37 m apart, so a westbound driver whose fix
    /// sits mid-structure had no heading-compatible road within 30 m. 50 m, nearest compatible first.
    /// </summary>
    public const double SnapRadiusM = 50;
    public const int ProximityWithinM = 1_000;

    private sealed record Snapped(long WayId, int Seq, string? Name, string? Highway, bool Oneway, IssueDirection Direction, GeoPoint At);

    public async Task<IssueDto> CreateAsync(Guid userId, CreateIssueRequest req, string lang, CancellationToken ct)
    {
        var kind = req.Kind ?? throw new ValidationException("kind", "kind is required.");
        if (!Gimano.Api.Endpoints.Validation.ValidLatLng(req.Lat, req.Lng)) throw new ValidationException("lat", "lat/lng must be valid.");
        if (!CommunityRules.InServiceArea(req.Lat, req.Lng)) throw new ValidationException("lat", "Location must be in Malaysia, Singapore or Brunei.");
        if (restricted is not null) await restricted.EnsureAllowedAsync(new GeoPoint(req.Lat, req.Lng), ct);
        var user = Moderation.EnsureMayContribute(await db.Users.FirstOrDefaultAsync(u => u.Id == userId, ct) ?? throw new UnauthorizedAccessException("Unknown user."));
        var now = clock.GetUtcNow();
        if (user.SuspendedUntil > now) throw new ForbiddenException($"Contributions are paused until {user.SuspendedUntil:yyyy-MM-dd HH:mm} UTC.");
        var since = now.AddDays(-1);
        if (await db.Issues.CountAsync(i => i.CreatedBy == userId && i.CreatedAt > since, ct) >= IssueRules.ReportsPerDay)
            throw new RateLimitedException($"At most {IssueRules.ReportsPerDay} reports per day.");

        var payload = ValidatePayload(kind, req.Payload, now);
        var at = new GeoPoint(req.Lat, req.Lng);
        Snapped? snap = null;
        string? placeId = null;
        if (IssueRules.IsPlace(kind))
        {
            placeId = req.PlaceId ?? throw new ValidationException("placeId", "placeId is required for place issues.");
            at = await PlaceAsync(placeId, ct) ?? throw new NotFoundException($"Place {placeId} not found.");
        }
        else if (IssueRules.IsRoad(kind))
        {
            snap = await SnapAsync(at, req.Heading, ct)
                   ?? throw new ValidationException("lat", "No road within 50 m of this point.");
            at = snap.At;
        }
        var direction = kind switch
        {
            // The direction the reporter can't drive (or does drive, against the map) = their heading.
            IssueKind.OnewayWrongClosedDir or IssueKind.OnewayWrongOpenDir => snap?.Direction ?? IssueDirection.Both,
            _ => IssueDirection.Both,
        };

        // Dedupe: the same open issue on the same segment / place (or within 50 m for anything else) gets a supporting vote.
        if (!IssueRules.IsFeedbackOnly(kind) && await FindDuplicateAsync(kind, snap, placeId, at, direction, ct) is { } existing)
        {
            existing = await VoteInternalAsync(existing, user, IssueAnswer.Still, now, isReport: false, ct);
            await PublishAsync(existing, existing.State, ct);
            return ToDto(existing, userId, IssueAnswer.Still, lang, await PlaceNameAsync(existing.PlaceId, ct)) with { Merged = true };
        }

        var issue = new Issue
        {
            Kind = kind,
            Subtype = kind is IssueKind.RoadClosedTemp or IssueKind.RoadNotExist ? Subtype(kind, req.Subtype) : null,
            State = IssueRules.InitialState(kind),
            Source = req.Source ?? IssueSource.Report,
            WayId = snap?.WayId, Seq = snap?.Seq, Direction = direction, Highway = snap?.Highway, RoadName = snap?.Name,
            MajorRoad = IssueRules.IsMajor(snap?.Highway),
            PlaceId = placeId,
            Location = new GeoPoint(IssueRules.Round5m(at.Lat), IssueRules.Round5m(at.Lng)).ToPoint(),
            Vehicle = kind == IssueKind.RoadNotExist ? req.Vehicle ?? Vehicle.Car : req.Vehicle,
            CreatedBy = userId, CreatedAt = now, LastEvidenceAt = now, Payload = payload,
            ExpiresAt = IssueRules.InitialExpiry(kind, req.Subtype, req.DurationHint, payload.GetValueOrDefault("until"), now),
        };
        issue.History.Add(string.Create(CultureInfo.InvariantCulture, $"{now:yyyy-MM-ddTHH:mm}Z created ({GimanoJson.ToWire(issue.State)})"));
        db.Issues.Add(issue);
        await db.SaveChangesAsync(ct);
        if (!IssueRules.IsFeedbackOnly(kind)) issue = await VoteInternalAsync(issue, user, IssueAnswer.Still, now, isReport: true, ct);
        else await PublishAsync(issue, issue.State, ct);
        // Coordinates in logs at 2 dp at most (privacy rule).
        logger.LogInformation("Issue {Kind} created near {Lat:F2},{Lng:F2} ({State})", kind, at.Lat, at.Lng, issue.State);
        return ToDto(issue, userId, IssueRules.IsFeedbackOnly(kind) ? null : IssueAnswer.Still, lang, await PlaceNameAsync(placeId, ct));
    }

    /// <summary>
    /// DEV ONLY (Features:DevSeed + X-Admin-Key): creates an issue directly in a given state, snapped like a report, with no
    /// reporter, so the apps can test complaint flows (a confirmed closure on a route, a suspected place issue).
    /// </summary>
    public async Task<IssueDto> SeedAsync(CreateIssueRequest req, IssueState state, string lang, CancellationToken ct)
    {
        var kind = req.Kind ?? throw new ValidationException("kind", "kind is required.");
        var now = clock.GetUtcNow();
        var payload = ValidatePayload(kind, req.Payload, now);
        var at = new GeoPoint(req.Lat, req.Lng);
        Snapped? snap = null;
        if (IssueRules.IsPlace(kind))
            at = await PlaceAsync(req.PlaceId ?? throw new ValidationException("placeId", "placeId is required."), ct)
                 ?? throw new NotFoundException($"Place {req.PlaceId} not found.");
        else if (IssueRules.IsRoad(kind))
            at = (snap = await SnapAsync(at, req.Heading, ct) ?? throw new ValidationException("lat", "No road within 50 m of this point.")).At;
        var issue = new Issue
        {
            Kind = kind, Subtype = req.Subtype, State = state, Source = req.Source ?? IssueSource.Report,
            WayId = snap?.WayId, Seq = snap?.Seq, Direction = kind is IssueKind.OnewayWrongClosedDir or IssueKind.OnewayWrongOpenDir ? snap?.Direction ?? IssueDirection.Both : IssueDirection.Both,
            Highway = snap?.Highway, RoadName = snap?.Name, MajorRoad = IssueRules.IsMajor(snap?.Highway), PlaceId = req.PlaceId,
            Location = new GeoPoint(IssueRules.Round5m(at.Lat), IssueRules.Round5m(at.Lng)).ToPoint(), Vehicle = req.Vehicle,
            CreatedAt = now, LastEvidenceAt = now, Payload = payload, ConfirmedAt = state == IssueState.Confirmed ? now : null,
            ExpiresAt = IssueRules.InitialExpiry(kind, req.Subtype, req.DurationHint, payload.GetValueOrDefault("until"), now),
            WeightedStill = state == IssueState.Confirmed ? IssueRules.Required(new Issue { Kind = kind, MajorRoad = IssueRules.IsMajor(snap?.Highway), Location = at.ToPoint() }) : 1,
            StillVotes = state == IssueState.Confirmed ? 2 : 1,
        };
        issue.History.Add(string.Create(CultureInfo.InvariantCulture, $"{now:yyyy-MM-ddTHH:mm}Z seeded ({GimanoJson.ToWire(state)}, dev)"));
        issue.Confidence = IssueRules.Confidence(issue);
        db.Issues.Add(issue);
        await db.SaveChangesAsync(ct);
        await PublishAsync(issue, issue.State, ct);
        return ToDto(issue, null, null, lang, await PlaceNameAsync(issue.PlaceId, ct));
    }

    /// <summary>DEV ONLY: removes a (seeded) issue and its votes.</summary>
    public async Task<bool> DeleteAsync(Guid id, CancellationToken ct)
    {
        await db.IssueVotes.Where(v => v.IssueId == id).ExecuteDeleteAsync(ct);
        await db.IssueSalts.Where(s => s.IssueId == id).ExecuteDeleteAsync(ct);
        var n = await db.Issues.Where(i => i.Id == id).ExecuteDeleteAsync(ct);
        directory.Invalidate();
        return n > 0;
    }

    public async Task<IssueVoteResult> VoteAsync(Guid userId, Guid id, IssueVoteRequest req, CancellationToken ct)
    {
        var answer = req.Answer ?? throw new ValidationException("answer", "answer must be still, cleared or unsure.");
        var issue = await db.Issues.FirstOrDefaultAsync(i => i.Id == id, ct) ?? throw new NotFoundException($"Issue {id} not found.");
        if (IssueRules.IsFeedbackOnly(issue.Kind)) throw new ConflictException("This report is feedback for maintainers and takes no votes.");
        if (!IssueRules.IsOpen(issue.State)) throw new ConflictException("This issue is closed.");
        if (answer != IssueAnswer.Unsure)
        {
            var prox = req.Proximity ?? throw new ValidationException("proximity", "proximity {cell, withinM} is required.");
            if (!Geohash.IsValid(prox.Cell) || prox.Cell.Length != 6) throw new ValidationException("proximity.cell", "cell must be a 6-character geohash.");
            if (!Geohash.WithNeighbours(Geohash.Encode(issue.Location.Y, issue.Location.X, 6)).Contains(prox.Cell)
                || prox.WithinM <= 0 || prox.WithinM > ProximityWithinM)
                throw new ForbiddenException($"You need to be within {ProximityWithinM} m to answer.");
        }
        var user = Moderation.EnsureMayContribute(await db.Users.FirstOrDefaultAsync(u => u.Id == userId, ct) ?? throw new UnauthorizedAccessException("Unknown user."));
        var now = clock.GetUtcNow();
        if (user.SuspendedUntil > now) throw new ForbiddenException("Contributions are paused.");
        var today = DateOnly.FromDateTime(now.UtcDateTime);
        if (await db.IssueVotes.CountAsync(v => v.VoterId == userId && v.Day == today, ct) >= IssueRules.VotesPerDay)
            throw new RateLimitedException($"At most {IssueRules.VotesPerDay} answers per day.");
        issue = await VoteInternalAsync(issue, user, answer, now, isReport: false, ct);
        return new IssueVoteResult(issue.State, Math.Round(issue.WeightedStill, 2), Math.Round(issue.WeightedCleared, 2), IssueRules.Required(issue));
    }

    /// <summary>Enough for a burst of drivers answering the same closure at once (each conflict round has one winner).</summary>
    public const int VoteAttempts = 10;

    /// <summary>
    /// Applies the vote, retrying when another writer got there first: a concurrent vote or the worker changed the issue
    /// (xmin), or the same pseudonym's double-tap inserted the vote row first (unique index). Each retry reloads the issue and
    /// the user and re-applies on fresh numbers, so no vote weight is lost. Returns the (possibly reloaded) issue.
    /// </summary>
    private async Task<Issue> VoteInternalAsync(Issue issue, User user, IssueAnswer answer, DateTimeOffset now, bool isReport, CancellationToken ct)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await ApplyVoteOnceAsync(issue, user, answer, now, isReport, ct);
                return issue;
            }
            catch (DbUpdateException ex) when (attempt < VoteAttempts && IsWriteRace(ex))
            {
                var (issueId, userId) = (issue.Id, user.Id);
                db.ChangeTracker.Clear();
                // Each round only one of the contenders wins; a short jittered pause spreads the rest out.
                await Task.Delay(Random.Shared.Next(5, 25) * attempt, ct);
                issue = await db.Issues.FirstAsync(i => i.Id == issueId, ct);
                user = await db.Users.FirstAsync(u => u.Id == userId, ct);
                if (!IssueRules.IsOpen(issue.State)) throw new ConflictException("This issue was closed just now.");
            }
        }
    }

    internal static bool IsWriteRace(DbUpdateException ex) =>
        ex is DbUpdateConcurrencyException || ex.InnerException is Npgsql.PostgresException { SqlState: Npgsql.PostgresErrorCodes.UniqueViolation };

    /// <summary>One vote per pseudonym; answering again replaces the earlier answer. Then the state machine runs.</summary>
    private async Task ApplyVoteOnceAsync(Issue issue, User user, IssueAnswer answer, DateTimeOffset now, bool isReport, CancellationToken ct)
    {
        var hasKey = await db.UserKeys.AnyAsync(k => k.UserId == user.Id && k.RevokedAt == null, ct);
        var tier = Reputation.CapForLegacy(user.Tier, hasKey);
        var weight = Reputation.VoteWeight(tier, user.JoinedAt, now, answer == IssueAnswer.Unsure ? VoteAnswer.Unsure : VoteAnswer.Yes, hasKey);
        var emas = tier == Tier.Emas;
        var vote = await db.IssueVotes.FirstOrDefaultAsync(v => v.IssueId == issue.Id && v.VoterId == user.Id, ct);
        // Same answer again (a repeat, or a retry after the vote itself was saved but the evaluation raced): nothing to apply,
        // but the state machine still runs so the evaluation isn't lost.
        if (vote is not null && vote.Answer == answer)
        {
            var was = issue.State;
            await IssueLedger.EvaluateAsync(db, issue, now, ct);
            await db.SaveChangesAsync(ct);
            if (issue.State != was) await PublishAsync(issue, was, ct);
            return;
        }
        if (vote is not null)
        {
            Unapply(issue, vote);
            // A withdrawn Emas "still" no longer supports the issue unless another Emas "still" does.
            if (vote is { Answer: IssueAnswer.Still, Emas: true })
            {
                var voteId = vote.Id;
                issue.EmasSupport = await db.IssueVotes.AnyAsync(v => v.IssueId == issue.Id && v.Id != voteId && v.Answer == IssueAnswer.Still
                                                                      && v.Emas && v.Weight > 0, ct);
            }
            vote.Answer = answer; vote.Weight = weight; vote.Emas = emas; vote.CreatedAt = now;
        }
        else
        {
            vote = new IssueVote
            {
                IssueId = issue.Id, VoterId = user.Id, Answer = answer, Weight = weight, IsReport = isReport, Emas = emas,
                CreatedAt = now, Day = DateOnly.FromDateTime(now.UtcDateTime),
            };
            db.IssueVotes.Add(vote);
        }
        IssueRules.ApplyVote(issue, answer, weight, emas, now);
        await IssueLedger.SaltAsync(db, issue.Id, ct);
        user.LastActiveDay = DateOnly.FromDateTime(now.UtcDateTime);
        await db.SaveChangesAsync(ct);

        var before = issue.State;
        await IssueLedger.EvaluateAsync(db, issue, now, ct);
        await db.SaveChangesAsync(ct);
        await PublishAsync(issue, before, ct);
    }

    private static void Unapply(Issue i, IssueVote v)
    {
        if (v.Answer == IssueAnswer.Still) { i.WeightedStill = Math.Max(0, i.WeightedStill - v.Weight); i.StillVotes = Math.Max(0, i.StillVotes - 1); }
        if (v.Answer == IssueAnswer.Cleared) { i.WeightedCleared = Math.Max(0, i.WeightedCleared - v.Weight); i.ClearedVotes = Math.Max(0, i.ClearedVotes - 1); }
    }

    private async Task PublishAsync(Issue issue, IssueState before, CancellationToken ct)
    {
        directory.Invalidate();
        await bus.PublishAsync(RoutingKeys.IssueChanged, new IssueChangedEvent(issue.Id, issue.State, issue.State != before), ct);
    }

    public async Task<IssueDto?> GetAsync(Guid id, Guid? viewer, string lang, CancellationToken ct)
    {
        var i = await db.Issues.AsNoTracking().FirstOrDefaultAsync(x => x.Id == id, ct);
        if (i is null) return null;
        var mine = viewer is { } v ? await db.IssueVotes.Where(x => x.IssueId == id && x.VoterId == v).Select(x => (IssueAnswer?)x.Answer).FirstOrDefaultAsync(ct) : null;
        var reporter = i.CreatedBy is { } c ? await db.Users.Where(u => u.Id == c).Select(u => u.DisplayName).FirstOrDefaultAsync(ct) : null;
        return ToDto(i, viewer, mine, lang, await PlaceNameAsync(i.PlaceId, ct), reporter, reporter is null ? null : handles?.For(i.CreatedBy));
    }

    /// <summary>Open issues in a bbox (public; for the map and "Masih ditutup?" prompts). Feedback-only kinds are not listed.</summary>
    public async Task<IReadOnlyList<IssueDto>> NearbyAsync(BBox bbox, IReadOnlyCollection<IssueKind>? kinds, Guid? viewer, string lang, CancellationToken ct)
    {
        var poly = bbox.ToPolygon();
        var now = clock.GetUtcNow();
        // Past expiresAt but not yet swept by the worker (every 15 min): not shown, so nobody is asked "Masih ditutup?" about it.
        var q = db.Issues.AsNoTracking().Where(i => (i.State == IssueState.Suspected || i.State == IssueState.Confirmed)
            && (i.ExpiresAt == null || i.ExpiresAt > now) && i.Location.Intersects(poly));
        if (kinds is { Count: > 0 }) q = q.Where(i => kinds.Contains(i.Kind));
        var rows = await q.OrderByDescending(i => i.LastEvidenceAt).Take(200).ToListAsync(ct);
        var ids = rows.Select(r => r.Id).ToList();
        var mine = viewer is { } v
            ? await db.IssueVotes.Where(x => ids.Contains(x.IssueId) && x.VoterId == v).ToDictionaryAsync(x => x.IssueId, x => x.Answer, ct)
            : [];
        var placeIds = rows.Select(r => r.PlaceId).OfType<string>().Distinct().ToList();
        var names = await PlaceNamesAsync(placeIds, ct);
        return rows.Select(i => ToDto(i, viewer, mine.TryGetValue(i.Id, out var a) ? a : null, lang, i.PlaceId is { } p ? names.GetValueOrDefault(p) : null)).ToList();
    }

    public static IssueDto ToDto(Issue i, Guid? viewer, IssueAnswer? myVote, string lang, string? placeName = null, string? reporterName = null,
        string? reporterHandle = null) => new(
        i.Id, i.Kind, i.Subtype, i.State, i.Source, i.Location.Y, i.Location.X, i.Direction,
        i.WayId is { } w ? new IssueSegment(w, i.Seq ?? 0, i.RoadName, i.Highway, i.Direction) : null,
        i.PlaceId, i.Vehicle, IssueText.Summary(i, lang, placeName),
        Math.Round(i.WeightedStill, 2), Math.Round(i.WeightedCleared, 2), IssueRules.Required(i), i.StillVotes, i.ClearedVotes, i.Confidence,
        i.CreatedAt, i.LastEvidenceAt, i.ExpiresAt, i.ConfirmedAt,
        reporterName is null ? null : new AddedBy(reporterName, reporterHandle), viewer is { } v && v == i.CreatedBy, myVote, PublicPayload(i));

    /// <summary>new_road traces and odd_route details are maintainer-only; everything else in the payload is public.</summary>
    private static IReadOnlyDictionary<string, string> PublicPayload(Issue i) =>
        i.Kind is IssueKind.NewRoad or IssueKind.OddRoute ? new Dictionary<string, string>() : i.Payload;

    private async Task<Issue?> FindDuplicateAsync(IssueKind kind, Snapped? snap, string? placeId, GeoPoint at, IssueDirection direction, CancellationToken ct)
    {
        var open = db.Issues.Where(i => i.Kind == kind && (i.State == IssueState.Suspected || i.State == IssueState.Confirmed));
        if (placeId is not null) return await open.FirstOrDefaultAsync(i => i.PlaceId == placeId, ct);
        // One-way corrections are about one direction of one way: "northbound can't drive" is not a vote for "southbound can't
        // drive" on the same two-way segment, and direction is relative to a way's digitisation, so no 50 m merge across ways.
        if (kind is IssueKind.OnewayWrongClosedDir or IssueKind.OnewayWrongOpenDir)
            return snap is null ? null
                : await open.FirstOrDefaultAsync(i => i.WayId == snap.WayId && i.Seq == snap.Seq && i.Direction == direction, ct);
        if (snap is not null)
        {
            var same = await open.FirstOrDefaultAsync(i => i.WayId == snap.WayId && i.Seq == snap.Seq, ct);
            if (same is not null) return same;
        }
        var pt = at.ToPoint();
        return await open.Where(i => i.Location.IsWithinDistance(pt, IssueRules.DedupeRadiusM)).OrderBy(i => i.Location.Distance(pt)).FirstOrDefaultAsync(ct);
    }

    /// <summary>Nearest road segment within 30 m whose direction fits the heading (one-way aware), and the travel direction.</summary>
    private async Task<Snapped?> SnapAsync(GeoPoint p, double? heading, CancellationToken ct)
    {
        var pt = p.ToPoint();
        var candidates = await db.RoadSegments.AsNoTracking().Where(s => s.Geom.IsWithinDistance(pt, SnapRadiusM))
            .OrderBy(s => s.Geom.Distance(pt)).Take(16).ToListAsync(ct);
        Snapped? best = null;
        var bestDist = double.MaxValue;
        foreach (var s in candidates)
        {
            var line = GeoMath.FromLineString(s.Geom);
            var proj = GeoMath.ProjectOnLine(line, p);
            if (proj.DistanceM > SnapRadiusM || proj.DistanceM >= bestDist) continue;
            var dir = IssueDirection.Both;
            if (heading is >= 0 and <= 360)
            {
                var fwd = GeoMath.HeadingDelta(heading.Value, proj.SegmentBearing) <= 60;
                var back = GeoMath.HeadingDelta(heading.Value, (proj.SegmentBearing + 180) % 360) <= 60;
                if (!fwd && !(back && !s.Oneway)) continue;
                dir = fwd ? IssueDirection.Forward : IssueDirection.Backward;
            }
            best = new Snapped(s.OsmWayId, s.Seq, s.Name ?? s.Ref, s.Highway, s.Oneway, dir, IssueGeometry.PointAt(line, proj.AlongM));
            bestDist = proj.DistanceM;
        }
        return best;
    }

    private async Task<GeoPoint?> PlaceAsync(string placeId, CancellationToken ct)
    {
        if (CommunityPlace.IsCommunityId(placeId))
        {
            var c = await db.CommunityPlaces.AsNoTracking().Where(p => p.Id == placeId && p.Status == PlaceStatus.Published).Select(p => p.Location).FirstOrDefaultAsync(ct);
            return c is null ? null : new GeoPoint(c.Y, c.X);
        }
        var l = await db.Places.AsNoTracking().Where(p => p.Id == placeId).Select(p => p.Location).FirstOrDefaultAsync(ct);
        return l is null ? null : new GeoPoint(l.Y, l.X);
    }

    private async Task<string?> PlaceNameAsync(string? placeId, CancellationToken ct) =>
        placeId is null ? null : (await PlaceNamesAsync([placeId], ct)).GetValueOrDefault(placeId);

    private async Task<Dictionary<string, string>> PlaceNamesAsync(IReadOnlyCollection<string> ids, CancellationToken ct)
    {
        if (ids.Count == 0) return [];
        var osm = await db.Places.AsNoTracking().Where(p => ids.Contains(p.Id)).Select(p => new { p.Id, p.Name }).ToListAsync(ct);
        var community = await db.CommunityPlaces.AsNoTracking().Where(p => ids.Contains(p.Id)).Select(p => new { p.Id, p.Name }).ToListAsync(ct);
        return osm.Concat(community).ToDictionary(p => p.Id, p => p.Name);
    }

    private static string? Subtype(IssueKind kind, string? subtype)
    {
        var allowed = kind == IssueKind.RoadClosedTemp ? ["accident", "flood", "event", "roadworks"] : new[] { "gate", "private", "track" };
        if (subtype is null) return null;
        return allowed.Contains(subtype) ? subtype : throw new ValidationException("subtype", $"subtype must be one of {string.Join(", ", allowed)}.");
    }

    /// <summary>Validates and normalises the kind-specific payload (rounding odd_route ends to ~1 km, trimming new_road traces).</summary>
    internal static Dictionary<string, string> ValidatePayload(IssueKind kind, JsonObject? p, DateTimeOffset now)
    {
        var d = new Dictionary<string, string>();
        string? Str(string key, int max)
        {
            var v = (p?[key] is JsonValue sv ? (sv.TryGetValue<string>(out var t) ? t : sv.ToJsonString()) : null)?.Trim();
            if (v is null || v.Length == 0) return null;
            if (v.Length > max) throw new ValidationException($"payload.{key}", $"{key} is too long (max {max}).");
            if (TextFilter.Default.Check(v, rejectLinks: key != "website") != TextVerdict.Ok) throw new ValidationException($"payload.{key}", "Please keep it friendly.");
            return v;
        }
        // JSON numbers or numeric strings ("3.1196"): iOS sends strings.
        double? Num(string key) => p?[key] is JsonValue jv
            ? jv.TryGetValue<double>(out var x) ? x
              : jv.TryGetValue<string>(out var str) && double.TryParse(str, NumberStyles.Float, CultureInfo.InvariantCulture, out var y) ? y
              : throw new ValidationException($"payload.{key}", $"{key} must be a number.")
            : null;
        string F(double x) => x.ToString("0.#####", CultureInfo.InvariantCulture);

        switch (kind)
        {
            case IssueKind.PlaceClosedTemp:
                var until = Str("until", 10) ?? throw new ValidationException("payload.until", "until (yyyy-MM-dd) is required.");
                if (IssueRules.ParseUntil(until, now) is null) throw new ValidationException("payload.until", "until must be a future date within 60 days.");
                d["until"] = until;
                break;
            case IssueKind.PlaceHoursWrong:
                d["openingHours"] = Str("openingHours", 255) ?? throw new ValidationException("payload.openingHours", "openingHours is required.");
                break;
            case IssueKind.PlaceEntranceWrong:
                var nl = Num("navLat") ?? double.NaN;
                var ng = Num("navLng") ?? double.NaN;
                if (double.IsNaN(nl) || double.IsNaN(ng) || !Gimano.Api.Endpoints.Validation.ValidLatLng(nl, ng))
                    throw new ValidationException("payload.navLat", "navLat and navLng are required.");
                d["navLat"] = F(IssueRules.Round5m(nl)); d["navLng"] = F(IssueRules.Round5m(ng));
                if (Str("kind", 12) is { } ek) d["entrance"] = ek is "entrance" or "parking" ? ek : "entrance";
                break;
            case IssueKind.PlaceInfoWrong:
                foreach (var (key, max) in new[] { ("name", 120), ("category", 30), ("phone", 40), ("website", 200), ("comment", 300) })
                    if (Str(key, max) is { } v) d[key] = v;
                if (d.Count == 0) throw new ValidationException("payload", "Say what is wrong (name, category, phone, website or comment).");
                break;
            case IssueKind.PlaceDuplicate:
                d["duplicateOf"] = Str("duplicateOf", 40) ?? throw new ValidationException("payload.duplicateOf", "duplicateOf (place id) is required.");
                break;
            case IssueKind.TurnNotAllowed:
                if (Num("toLat") is { } tl && Num("toLng") is { } tg)
                {
                    if (!Gimano.Api.Endpoints.Validation.ValidLatLng(tl, tg)) throw new ValidationException("payload.toLat", "toLat/toLng must be valid.");
                    d["toLat"] = F(IssueRules.Round5m(tl)); d["toLng"] = F(IssueRules.Round5m(tg));
                }
                break;
            case IssueKind.OddRoute:
                // Rounded to ~1 km: an odd-route note never carries a precise origin or destination.
                if (Num("fromLat") is { } fl && Num("fromLng") is { } fg) { d["fromLat"] = F(IssueRules.Round1km(fl)); d["fromLng"] = F(IssueRules.Round1km(fg)); }
                if (Num("toLat") is { } tl2 && Num("toLng") is { } tg2) { d["toLat"] = F(IssueRules.Round1km(tl2)); d["toLng"] = F(IssueRules.Round1km(tg2)); }
                if (Str("chosen", 300) is { } ch) d["chosen"] = ch;
                if (Str("taken", 300) is { } tk) d["taken"] = tk;
                if (Str("comment", 300) is { } cm) d["comment"] = cm;
                break;
            case IssueKind.NewRoad:
                if (p?["trace"] is not JsonArray arr || arr.Count < 2) throw new ValidationException("payload.trace", "trace [[lat,lng],…] (only the new road) is required.");
                static double D(JsonNode? n) => n is JsonValue v && (v.TryGetValue<double>(out var x) || (v.TryGetValue<string>(out var t)
                    && double.TryParse(t, NumberStyles.Float, CultureInfo.InvariantCulture, out x))) ? x : throw new ValidationException("payload.trace", "trace items are [lat,lng].");
                var pts = arr.Select(e => e is JsonArray a && a.Count == 2 ? (D(a[0]), D(a[1])) : throw new ValidationException("payload.trace", "trace items are [lat,lng].")).Take(2000).ToList();
                var trimmed = IssueRules.TrimTrace(pts);
                if (trimmed.Count < 2) throw new ValidationException("payload.trace", "The trace must be longer than 400 m (200 m is trimmed at each end).");
                d["trace"] = string.Join(';', trimmed.Select(t => $"{F(t.Lat)},{F(t.Lng)}"));
                if (Str("name", 120) is { } rn) d["name"] = rn;
                break;
        }
        return d;
    }
}

/// <summary>
/// Open issues in memory for routing and search (refreshed every 60 s, or right after a change on this instance):
/// confirmed closures/no-road as exclusion boxes, warn-only road issues, place badges, closed places, navigation points.
/// </summary>
public sealed class IssueDirectory(IServiceScopeFactory scopes, TimeProvider clock, ILogger<IssueDirectory> logger)
{
    public sealed record RoadIssue(Issue Issue, IReadOnlyList<GeoPoint> Line, GeoPoint Mid, IReadOnlyList<(double Lng, double Lat)> Ring);

    public sealed record Snapshot(
        IReadOnlyList<RoadIssue> Exclusions, IReadOnlyList<RoadIssue> Warnings,
        IReadOnlyDictionary<string, Issue> PlaceBadges, IReadOnlySet<string> ClosedPlaces,
        IReadOnlyDictionary<string, Issue> NavPoints, IReadOnlyDictionary<string, string> Hours, DateTimeOffset At,
        IReadOnlySet<string>? ClosedNow = null)
    {
        /// <summary>Places that are shut right now: an open place_closed_temp (until its date) or a confirmed place_closed_perm.</summary>
        public bool IsClosedNow(string placeId) => ClosedNow?.Contains(placeId) == true;
    }

    private Snapshot? _snap;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public void Invalidate() => _snap = null;

    public async Task<Snapshot> GetAsync(CancellationToken ct)
    {
        if (_snap is { } s && clock.GetUtcNow() - s.At < TimeSpan.FromSeconds(60)) return s;
        await _gate.WaitAsync(ct);
        try
        {
            if (_snap is { } s2 && clock.GetUtcNow() - s2.At < TimeSpan.FromSeconds(60)) return s2;
            _snap = await LoadAsync(ct);
            return _snap;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning("Issue directory load failed: {Message}", ex.Message);
            return _snap ?? new Snapshot([], [], new Dictionary<string, Issue>(), new HashSet<string>(), new Dictionary<string, Issue>(), new Dictionary<string, string>(), clock.GetUtcNow());
        }
        finally { _gate.Release(); }
    }

    private async Task<Snapshot> LoadAsync(CancellationToken ct)
    {
        await using var scope = scopes.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<GimanoDbContext>();
        var now = clock.GetUtcNow();
        var open = await db.Issues.AsNoTracking().Where(i => (i.State == IssueState.Suspected || i.State == IssueState.Confirmed)
            && (i.ExpiresAt == null || i.ExpiresAt > now || (i.Kind == IssueKind.PlaceClosedPerm && i.State == IssueState.Confirmed))).ToListAsync(ct);

        var ways = open.Where(i => IssueRules.IsRoad(i.Kind) && i.WayId is not null).Select(i => i.WayId!.Value).Distinct().ToList();
        var segs = ways.Count == 0 ? [] : await db.RoadSegments.AsNoTracking().Where(s => ways.Contains(s.OsmWayId))
            .Select(s => new { s.OsmWayId, s.Seq, s.Geom }).ToListAsync(ct);
        var lines = segs.ToDictionary(s => (s.OsmWayId, s.Seq), s => (IReadOnlyList<GeoPoint>)GeoMath.FromLineString(s.Geom));
        return Compose(open, lines, now);
    }

    /// <summary>
    /// Builds the snapshot from open issues. Issues past <c>expiresAt</c> are left out even while still open in the database:
    /// the worker only sweeps every 15 minutes, and an expired closure must not keep being routed around (nor an expired
    /// place_closed_temp keep a place "closed now").
    /// </summary>
    internal static Snapshot Compose(IReadOnlyList<Issue> openIssues, IReadOnlyDictionary<(long, int), IReadOnlyList<GeoPoint>> lines, DateTimeOffset now)
    {
        var open = openIssues.Where(i => i.State is IssueState.Suspected or IssueState.Confirmed && (i.ExpiresAt is not { } e || e > now || (i.Kind == IssueKind.PlaceClosedPerm && i.State == IssueState.Confirmed))).ToList();
        var road = open.Where(i => IssueRules.IsRoad(i.Kind) && i.WayId is not null).ToList();

        RoadIssue Road(Issue i)
        {
            var line = lines.GetValueOrDefault((i.WayId!.Value, i.Seq ?? 0)) ?? [new GeoPoint(i.Location.Y, i.Location.X)];
            var mid = IssueGeometry.PointAt(line, GeoMath.LengthM(line) / 2);
            return new RoadIssue(i, line, mid, IssueGeometry.ExclusionRing(line));
        }

        var exclusions = road.Where(i => i.State == IssueState.Confirmed && IssueRules.ExcludesRouting(i.Kind)).Select(Road).ToList();
        var warnings = road.Where(i => !(i.State == IssueState.Confirmed && IssueRules.ExcludesRouting(i.Kind))
                                       && i.Kind != IssueKind.OnewayWrongOpenDir).Select(Road).ToList();
        var place = open.Where(i => i.PlaceId is not null).ToList();
        var badges = place.Where(i => i.Kind is IssueKind.PlaceClosedPerm or IssueKind.PlaceClosedTemp or IssueKind.PlaceHoursWrong)
            .GroupBy(i => i.PlaceId!)
            .ToDictionary(g => g.Key, g => g.OrderByDescending(i => i.State == IssueState.Confirmed).ThenBy(i => i.Kind).First());
        var closed = place.Where(i => i.Kind == IssueKind.PlaceClosedPerm && i.State == IssueState.Confirmed).Select(i => i.PlaceId!).ToHashSet();
        var nav = place.Where(i => i.Kind == IssueKind.PlaceEntranceWrong && i.State == IssueState.Confirmed)
            .GroupBy(i => i.PlaceId!).ToDictionary(g => g.Key, g => g.OrderByDescending(i => i.ConfirmedAt).First());
        var hours = place.Where(i => i.Kind == IssueKind.PlaceHoursWrong && i.State == IssueState.Confirmed && i.Payload.ContainsKey("openingHours"))
            .GroupBy(i => i.PlaceId!).ToDictionary(g => g.Key, g => g.OrderByDescending(i => i.ConfirmedAt).First().Payload["openingHours"]);
        var closedNow = place.Where(i => i.Kind == IssueKind.PlaceClosedTemp || (i.Kind == IssueKind.PlaceClosedPerm && i.State == IssueState.Confirmed))
            .Select(i => i.PlaceId!).ToHashSet();
        return new Snapshot(exclusions, warnings, badges, closed, nav, hours, now, closedNow);
    }

    public static PlaceBadge? Badge(Snapshot s, string placeId, string lang)
    {
        if (!s.PlaceBadges.TryGetValue(placeId, out var i)) return null;
        var until = i.Kind == IssueKind.PlaceClosedTemp ? i.Payload.GetValueOrDefault("until") : null;
        var label = (i.Kind, i.State, L10n.IsMs(lang)) switch
        {
            (IssueKind.PlaceClosedPerm, IssueState.Suspected, true) => "Dilaporkan tutup · sahkan?",
            (IssueKind.PlaceClosedPerm, IssueState.Suspected, false) => "Reported closed · confirm?",
            (IssueKind.PlaceClosedPerm, _, true) => "Tutup kekal",
            (IssueKind.PlaceClosedPerm, _, false) => "Permanently closed",
            (IssueKind.PlaceClosedTemp, _, true) => $"Tutup sementara sehingga {until}",
            (IssueKind.PlaceClosedTemp, _, false) => $"Temporarily closed until {until}",
            (IssueKind.PlaceHoursWrong, IssueState.Suspected, true) => "Waktu mungkin berubah",
            (IssueKind.PlaceHoursWrong, IssueState.Suspected, false) => "Hours may have changed",
            (IssueKind.PlaceHoursWrong, _, true) => "Waktu buka dikemas kini",
            _ => "Opening hours updated",
        };
        return new PlaceBadge(i.Id, i.Kind, i.State, label, until);
    }
}
