using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Identity;
using Gimano.Api.Identity;
using Gimano.Core.Messaging;
using Gimano.Core.Places;
using Gimano.Core.Routing;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Api.Services;

public sealed class RateLimitedException(string message, TimeSpan? retryAfter = null) : Exception(message)
{
    /// <summary>When the limit frees up again (sent as Retry-After and <c>retryAfterSeconds</c>).</summary>
    public TimeSpan? RetryAfter { get; } = retryAfter;
}

/// <summary>409 with the existing place, so the app can ask "Is it this one?".</summary>
public sealed class DuplicatePlaceException(PlaceSummary existing) : Exception($"A similar place already exists nearby: {existing.Name}.")
{
    public PlaceSummary Existing { get; } = existing;
}

/// <summary>Community places: add (always public), owner edit/delete, verification votes, suggested edits.</summary>
public sealed class CommunityService(GimanoDbContext db, IEventPublisher bus, Gimano.Api.Identity.AttestationService attestation, TimeProvider clock,
    RestrictedAreaService restricted, PlaceGate gate)
{
    private static readonly TextFilter Filter = TextFilter.Default;

    public async Task<PlaceDto> CreateAsync(Guid userId, CreatePlaceRequest req, CancellationToken ct)
    {
        var user = await RequireUserAsync(userId, ct);
        var name = CheckName(req.Name);
        CheckOptional(req.Description, req.Phone, req.Website, req.OpeningHours, req.Address);
        var at = new GeoPoint(req.Lat, req.Lng);
        await CheckLocationAsync(at, ct);
        // Near a restricted area, or security details in the text: a maintainer decides before anyone sees it.
        var held = await restricted.EnsureAllowedAsync(at, ct) == RestrictedLevel.Near || RestrictedAreaRules.HasSensitiveTerm(name, req.Description);

        var now = clock.GetUtcNow();
        if (user.SuspendedUntil is { } until && until > now)
            throw new AddingPausedException(until, $"Adding places is paused until {until:yyyy-MM-dd HH:mm} UTC because several of your places were not accepted.");
        var perDay = Reputation.PublicPlacesPerDay(user.Tier);
        var dayStarts = await db.CommunityPlaces.Where(p => p.OwnerId == userId && p.CreatedAt > now.AddDays(-1)).Select(p => p.CreatedAt)
            .OrderBy(t => t).ToListAsync(ct);
        if (dayStarts.Count >= perDay)
            throw new RateLimitedException($"At most {perDay} new places per day.", dayStarts[^perDay].AddDays(1) - now);
        var hourStarts = dayStarts.Where(t => t > now.AddHours(-1)).ToList();
        if (hourStarts.Count >= CommunityRules.PublicPlacesPerHour)
            throw new RateLimitedException($"At most {CommunityRules.PublicPlacesPerHour} public places per hour.",
                hourStarts[^CommunityRules.PublicPlacesPerHour].AddHours(1) - now);

        // "No, mine is a different place" (design B1): the same duplicate no longer blocks; the AI check is told.
        string? saidDifferent = null;
        if (await FindDuplicateAsync(name, at, null, ct) is { } dup)
        {
            if (!gate.Enabled || dup.Id != req.NotDuplicateOf) throw new DuplicatePlaceException(dup);
            saidDifferent = dup.Id;
        }

        var place = new CommunityPlace
        {
            Name = name, Category = req.Category is null or PlaceCategory.Area ? PlaceCategory.Other : req.Category.Value, Location = at.ToPoint(),
            Address = req.Address?.Trim() ?? "", Description = req.Description?.Trim(), Phone = req.Phone?.Trim(),
            Website = req.Website?.Trim(), OpeningHours = req.OpeningHours?.Trim(),
            Amenities = (req.Amenities ?? []).Select(a => a.Trim()).Where(a => a.Length is > 0 and <= 40).Distinct().Take(30).ToList(),
            Country = CountryResolver.Resolve(at.Lat, at.Lng), OwnerId = userId, Owner = user, CreatedAt = now, UpdatedAt = now,
            RequiredConfirmations = Reputation.RequiredConfirmations(user.Tier, gate.LaunchMode),
            Rural = await IsRuralAsync(at, ct), SaidDifferentFrom = saidDifferent,
            OwnerWarnings = PlaceWarnings.Join(req.Warnings?.Take(PlaceWarnings.MaxFromOwner)),
        };
        place.Warnings = place.OwnerWarnings;
        if (held) { place.Status = PlaceStatus.Hidden; place.HeldForReview = true; }
        // The AI check decides (design page "Add a place"); without it, Emas contributors publish immediately as before.
        else if (gate.Enabled) place.ScreeningState = ScreeningState.Checking;
        else if (user.Tier == Tier.Emas)
        {
            place.Status = PlaceStatus.Published;
            place.AuditOpen = Reputation.PickForAudit(Random.Shared.NextDouble);
            if (!place.AuditOpen) { place.ResolvedAt = now; user.PlacesAccepted++; }
        }
        user.Points += CommunityRules.Points.PlaceAdded + (place.Status == PlaceStatus.Published ? CommunityRules.Points.PlacePublished : 0);
        user.LastActiveDay = DateOnly.FromDateTime(now.UtcDateTime);
        db.CommunityPlaces.Add(place);
        await db.SaveChangesAsync(ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(place.Id), ct);
        // About 2 s; past 4 s the app shows "We're still checking" and the worker finishes it (design A3, B6).
        if (place.ScreeningState == ScreeningState.Checking) await gate.RunAsync(place, isEdit: false, PlaceScreening.SyncBudget, late: false, ct);
        return Dto(place);
    }

    /// <summary>
    /// "Ask for a review" (design C1): a rejected place goes to a maintainer with the owner's note. Once per place; the note is
    /// filtered like other text and shown only to maintainers.
    /// </summary>
    public async Task<PlaceDto> AppealAsync(Guid userId, string id, AppealPlaceRequest req, CancellationToken ct)
    {
        var place = await OwnedAsync(userId, id, ct);
        if (place.Status != PlaceStatus.Rejected) throw new ConflictException("Only a place that was not accepted can be sent for review.");
        if (place.AppealedAt is not null) throw new ConflictException("This place was already sent for review.");
        var note = req.Note?.Trim();
        if (note is { Length: > PlaceScreening.MaxAppealLength })
            throw new ValidationException("note", $"note max {PlaceScreening.MaxAppealLength} chars.");
        if (Filter.Check(note, rejectLinks: true) != TextVerdict.Ok) throw new ValidationException("note", "Please keep the note friendly and without links.");
        var now = clock.GetUtcNow();
        place.AppealNote = string.IsNullOrEmpty(note) ? null : note;
        place.AppealedAt = now;
        place.Status = PlaceStatus.Hidden;
        place.HeldForReview = true;
        place.ScreeningState = ScreeningState.Held;
        place.UpdatedAt = now;
        await db.SaveChangesAsync(ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(place.Id), ct);
        return Dto(place);
    }

    /// <summary>A new place has never been checked or confirmed; anything else is an edit (PlaceScreening.ForEdit).</summary>
    internal static bool IsEdit(CommunityPlace p) => p.ResolvedAt is not null || p.ScreenedAt is not null;

    public async Task<PlaceDto> PatchAsync(Guid userId, string id, PatchCommunityPlaceRequest req, CancellationToken ct)
    {
        var place = await OwnedAsync(userId, id, ct);
        if (place.Status == PlaceStatus.Rejected && place.AppealedAt is not null)
            throw new ConflictException("This place is waiting for a maintainer's review.");
        var changed = (req.Name is not null && req.Name.Trim() != place.Name) || (req.Description is not null && req.Description.Trim() != place.Description)
            || (req.Category is { } nc && nc != place.Category) || req.Lat is not null || req.Lng is not null
            || (req.Phone is not null && req.Phone.Trim() != place.Phone) || (req.Website is not null && req.Website.Trim() != place.Website)
            || (req.OpeningHours is not null && req.OpeningHours.Trim() != place.OpeningHours);
        if (req.Name is not null) place.Name = CheckName(req.Name);
        CheckOptional(req.Description, req.Phone, req.Website, req.OpeningHours, req.Address);
        var held = RestrictedAreaRules.HasSensitiveTerm(req.Name, req.Description);
        if (req.Category is { } c && c != PlaceCategory.Area) place.Category = c;
        if (req.Lat is not null || req.Lng is not null)
        {
            var at = new GeoPoint(req.Lat ?? place.Location.Y, req.Lng ?? place.Location.X);
            await CheckLocationAsync(at, ct);
            held |= await restricted.EnsureAllowedAsync(at, ct) == RestrictedLevel.Near;
            if (await FindDuplicateAsync(place.Name, at, place.Id, ct) is { } dup) throw new DuplicatePlaceException(dup);
            place.Location = at.ToPoint();
            place.Country = CountryResolver.Resolve(at.Lat, at.Lng);
        }
        if (req.Address is not null) place.Address = req.Address.Trim();
        if (req.Description is not null) place.Description = req.Description.Trim();
        if (req.Phone is not null) place.Phone = req.Phone.Trim();
        if (req.Website is not null) place.Website = req.Website.Trim();
        if (req.OpeningHours is not null) place.OpeningHours = req.OpeningHours.Trim();
        if (req.Warnings is not null)
        {
            // The owner's tags change; what the AI check and the watchlist added stays until the place is checked again.
            var derived = PlaceWarnings.Split(place.Warnings).Except(PlaceWarnings.Split(place.OwnerWarnings));
            place.OwnerWarnings = PlaceWarnings.Join(req.Warnings.Take(PlaceWarnings.MaxFromOwner));
            place.Warnings = PlaceWarnings.Join(PlaceWarnings.Split(place.OwnerWarnings).Concat(derived));
        }
        if (req.Amenities is not null) place.Amenities = req.Amenities.Select(a => a.Trim()).Where(a => a.Length is > 0 and <= 40).Distinct().Take(30).ToList();
        if (held && place.Status is PlaceStatus.Pending or PlaceStatus.Published or PlaceStatus.Rejected) { place.Status = PlaceStatus.Hidden; place.HeldForReview = true; }
        place.UpdatedAt = clock.GetUtcNow();
        // An edit is checked again (design A4, B3 "Edit and try again"); a held place waits for its maintainer instead.
        var recheck = changed && gate.Enabled && !place.HeldForReview && place.Status is PlaceStatus.Pending or PlaceStatus.Published or PlaceStatus.Rejected;
        if (recheck) place.ScreeningState = ScreeningState.Checking;
        await db.SaveChangesAsync(ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(place.Id), ct);
        if (recheck) await gate.RunAsync(place, IsEdit(place), PlaceScreening.SyncBudget, late: false, ct);
        return Dto(place);
    }

    /// <summary>Owner delete: published places become "closed" (others may have reviewed them); others are removed.</summary>
    public async Task DeleteAsync(Guid userId, string id, CancellationToken ct)
    {
        var place = await OwnedAsync(userId, id, ct);
        if (place.Status == PlaceStatus.Published) place.Status = PlaceStatus.Closed;
        else db.CommunityPlaces.Remove(place);
        await db.SaveChangesAsync(ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(id), ct);
    }

    /// <summary>
    /// Local vetting vote (docs/identity-and-reputation.md §4): eligibility, proximity (computed on the phone, checked
    /// against the place's geohash-6 neighbourhood, never stored), attestation verdict, tier weights, resolution + unlinking.
    /// </summary>
    public async Task<VerifyResult> VerifyAsync(Guid userId, string id, VerifyPlaceRequest req, bool? attestationOk, CancellationToken ct)
    {
        var voter = await RequireUserAsync(userId, ct);
        var now = clock.GetUtcNow();
        var place = await db.CommunityPlaces.Include(p => p.Owner).FirstOrDefaultAsync(p => p.Id == id, ct)
                    ?? throw new NotFoundException("Only community places can be verified.");
        if (place.OwnerId == userId) throw new ForbiddenException("You can't verify a place you added.");
        var open = place.Status == PlaceStatus.Pending || (place.Status == PlaceStatus.Published && place.AuditOpen);
        if (!open) throw new ConflictException("This place is no longer waiting for verification.");

        var hasKey = await db.UserKeys.AnyAsync(k => k.UserId == userId && k.RevokedAt == null, ct);
        if (!LegacyBodyAllowed(req, hasKey))
            throw new ValidationException("answer", "answer (yes, no or unsure) and proximity {cell, withinM} are required.");
        var answer = req.Answer ?? (req.Exists is { } ex ? (ex && req.CorrectLocation != false ? VoteAnswer.Yes : VoteAnswer.No) : (VoteAnswer?)null)
                     ?? throw new ValidationException("answer", "answer must be yes, no or unsure.");
        if (req.Proximity is { } prox)
        {
            if (!Geohash.IsValid(prox.Cell) || prox.Cell.Length != 6) throw new ValidationException("proximity.cell", "cell must be a 6-character geohash.");
            var placeCell = Geohash.Encode(place.Location.Y, place.Location.X, 6);
            if (!Geohash.WithNeighbours(placeCell).Contains(prox.Cell))
                throw new ForbiddenException("You need to be near this place to verify it.");
            if (!Reputation.WithinProximity(prox.WithinM, place.Rural))
                throw new ForbiddenException($"You need to be within {(place.Rural ? Reputation.RuralWithinM : Reputation.TownWithinM)} m of this place to verify it.");
        }
        // Only a key-less (0.1.0) account gets here without proximity, via the legacy body (see LegacyBodyAllowed).
        else if (req.Answer is not null) throw new ValidationException("proximity", "proximity {cell, withinM} is required.");

        if (await db.PlaceVotes.AnyAsync(v => v.PlaceId == id && v.VoterId == userId, ct))
            throw new ConflictException("You already voted on this place.");
        var day = DateOnly.FromDateTime(now.UtcDateTime);
        if (voter.VotesDay != day) { voter.VotesDay = day; voter.VotesToday = 0; }
        if (voter.VotesToday >= Reputation.VotesPerDay) throw new RateLimitedException($"At most {Reputation.VotesPerDay} verification votes per day.");
        if (attestationOk == false && attestation.Mode == AttestationMode.Enforce)
            throw new ForbiddenException("Device check failed; votes from this device can't be counted.");

        var weight = Reputation.VoteWeight(Reputation.CapForLegacy(voter.Tier, hasKey), voter.JoinedAt, now, answer, hasKey, gate.LaunchMode);
        db.PlaceVotes.Add(new PlaceVote
        {
            PlaceId = id, VoterId = userId, Answer = answer, NameCorrect = req.NameCorrect, LocationCorrect = req.LocationCorrect ?? req.CorrectLocation,
            Weight = weight, AttestationOk = attestationOk, CreatedAt = now, Day = day,
        });
        await Ledger.SaltAsync(db, id, ct);
        voter.VotesToday++;
        voter.LastActiveDay = day;
        if (answer == VoteAnswer.Yes) { place.WeightedYes += weight; place.VerifiedCount++; }
        if (answer == VoteAnswer.No) { place.WeightedNo += weight; place.RejectedCount++; }
        await db.SaveChangesAsync(ct);

        var before = place.Status;
        if (place.AuditOpen)
        {
            if (Reputation.AuditFails(place.WeightedNo))
            {
                db.PlaceDisputes.Add(new PlaceDispute { PlaceId = id, ContributorId = place.OwnerId, CreatedAt = now });
                await Ledger.ResolveAsync(db, place, PlaceStatus.Hidden, now, ct);
            }
            else if (place.WeightedYes >= Reputation.RequiredConfirmations(Tier.Baharu))
            {
                await Ledger.ResolveAsync(db, place, PlaceStatus.Published, now, ct);
            }
        }
        else
        {
            switch (Reputation.Resolve(place.WeightedYes, place.WeightedNo, place.RequiredConfirmations))
            {
                case Reputation.Outcome.Published:
                    if (place.Owner is not null) place.Owner.Points += CommunityRules.Points.PlacePublished;
                    await Ledger.ResolveAsync(db, place, PlaceStatus.Published, now, ct);
                    break;
                case Reputation.Outcome.Hidden:
                    await Ledger.ResolveAsync(db, place, PlaceStatus.Hidden, now, ct);
                    break;
            }
        }
        await db.SaveChangesAsync(ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(id), ct);
        if (place.Status != before) await bus.PublishAsync(RoutingKeys.PlaceVerified, new PlaceVerifiedEvent(id, place.Status), ct);
        return new VerifyResult(place.Status, Math.Round(place.WeightedYes, 2), RequiredFor(place));
    }

    /// <summary>
    /// "Report this place": one flag per user. 3 hide a community place pending moderation (as for reviews and photos). A map (OSM) place can
    /// be reported too: the flag, with the reason and the warnings the user suggests (alcohol, gambling, tobacco), waits for a maintainer and
    /// changes nothing by itself; no location is stored.
    /// </summary>
    public async Task FlagAsync(Guid userId, string id, FlagReason reason, CancellationToken ct, IReadOnlyList<string>? suggestedWarnings = null)
    {
        if (!CommunityPlace.IsCommunityId(id))
        {
            await FlagOsmAsync(userId, id, reason, suggestedWarnings, ct);
            return;
        }
        var place = await db.CommunityPlaces.FirstOrDefaultAsync(p => p.Id == id, ct) ?? throw new NotFoundException("Place not found.");
        if (place.OwnerId == userId) return;
        if (await db.PlaceFlags.FindAsync([id, userId], ct) is not null) return;
        db.PlaceFlags.Add(new PlaceFlag { PlaceId = id, UserId = userId, Reason = reason, CreatedAt = clock.GetUtcNow() });
        place.FlagCount++;
        var hidden = place.FlagCount >= RestrictedAreaRules.FlagsToHide(reason, CommunityRules.FlagsToHide) && place.Status is PlaceStatus.Pending or PlaceStatus.Published;
        if (hidden) { place.Status = PlaceStatus.Hidden; place.UpdatedAt = clock.GetUtcNow(); }
        await db.SaveChangesAsync(ct);
        if (hidden) await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(id), ct);
    }

    private async Task FlagOsmAsync(Guid userId, string id, FlagReason reason, IReadOnlyList<string>? suggestedWarnings, CancellationToken ct)
    {
        if (id.Length > 40 || !await db.Places.AnyAsync(p => p.Id == id, ct)) throw new NotFoundException("Place not found.");
        if (await db.OsmPlaceFlags.FindAsync([id, userId], ct) is not null) return;
        db.OsmPlaceFlags.Add(new OsmPlaceFlag
        {
            PlaceId = id, UserId = userId, Reason = reason, SuggestedWarnings = PlaceWarnings.Join(suggestedWarnings), CreatedAt = clock.GetUtcNow(),
        });
        try { await db.SaveChangesAsync(ct); }
        catch (DbUpdateException) { /* the same user flagged it twice at once: already there */ }
    }

    /// <summary>
    /// The legacy 0.1.0 body {exists, correctLocation} has no `answer` and no proximity field, and installed 0.1.0 apps can't
    /// send them, so it is still accepted, without a proximity check, but only from accounts with no signing key (what 0.1.0
    /// apps run): their votes weigh at most 1 (Baharu cap, Reputation.CapForLegacy), are rate-limited per day, and
    /// Identity:RequireSignatures=true rejects them altogether. A keyed account is a current app: it must send `answer` and
    /// pass the proximity check, so the old shape can't be used to skip it. Drop the legacy shape once 0.1.0 is gone.
    /// </summary>
    internal static bool LegacyBodyAllowed(VerifyPlaceRequest req, bool hasKey) => req.Answer is not null || !hasKey;

    /// <summary>Pending (and audit-open) places in a geohash-6 cell and its 8 neighbours, excluding the caller's own and ones they voted on.</summary>
    /// <summary>Weighted confirmations a place needs: its creation-tier requirement, or baharu's while a random audit is open.</summary>
    internal static double RequiredFor(CommunityPlace p) => p.AuditOpen ? Reputation.RequiredConfirmations(Tier.Baharu) : p.RequiredConfirmations;

    public async Task<IReadOnlyList<PlaceSummary>> PendingNearbyAsync(Guid userId, string cell, CancellationToken ct)
    {
        if (!Geohash.IsValid(cell) || cell.Length != 6) throw new ValidationException("cell", "cell must be a 6-character geohash.");
        var cells = Geohash.WithNeighbours(cell).ToHashSet();
        var poly = Geohash.NeighbourhoodBounds(cell).ToPolygon();
        var rows = await db.CommunityPlaces.AsNoTracking()
            .Where(p => ((p.Status == PlaceStatus.Pending && p.ScreeningState != ScreeningState.Checking) || (p.Status == PlaceStatus.Published && p.AuditOpen))
                        && p.OwnerId != userId && p.Location.Intersects(poly)
                        && !db.PlaceVotes.Any(v => v.PlaceId == p.Id && v.VoterId == userId))
            .OrderByDescending(p => p.CreatedAt).Take(100).ToListAsync(ct);
        return rows.Where(p => cells.Contains(Geohash.Encode(p.Location.Y, p.Location.X, 6)))
            .Select(p => PlaceService.ToSummary(p, null, null) with
            {
                Status = PlaceStatus.Pending, ConfirmationsWeighted = Math.Round(p.WeightedYes, 2), Required = RequiredFor(p),
            }).ToList();
    }

    /// <summary>Rural = fewer than 20 mapped places within 2 km (5 km verification radius instead of 1 km).</summary>
    private async Task<bool> IsRuralAsync(GeoPoint at, CancellationToken ct)
    {
        var pt = at.ToPoint();
        return await db.Places.Where(p => p.Location.IsWithinDistance(pt, 2000)).Take(20).CountAsync(ct) < 20;
    }

    /// <summary>Any user, any place (OSM too). Owner suggestions on their own community place apply directly.</summary>
    public async Task<Guid> SuggestEditAsync(Guid userId, string id, SuggestEditRequest req, CancellationToken ct)
    {
        await RequireUserAsync(userId, ct);
        var isCommunity = CommunityPlace.IsCommunityId(id);
        var street = id.StartsWith("st-", StringComparison.Ordinal) ? await Core.Search.StreetCorrections.CaptureAsync(db, id, ct) : null;
        var exists = street is not null || (isCommunity ? await db.CommunityPlaces.AnyAsync(p => p.Id == id, ct) : await db.Places.AnyAsync(p => p.Id == id, ct));
        if (street is not null && (req.Name is null || req.Category is not null || req.Lat is not null || req.Lng is not null || req.Address is not null || req.Phone is not null || req.Website is not null || req.OpeningHours is not null || req.Description is not null || req.Closed is not null))
            throw new ValidationException("name", "A street suggestion supports a new name and comment only.");
        if (!exists) throw new NotFoundException($"Place {id} not found.");
        if (req.Name is not null) CheckName(req.Name);
        CheckOptional(req.Description, req.Phone, req.Website, req.OpeningHours, req.Address);
        if (Filter.Check(req.Comment, rejectLinks: false) != TextVerdict.Ok) throw new ValidationException("comment", "Please keep it friendly.");
        if ((req.Lat is null) != (req.Lng is null)) throw new ValidationException("lat", "Both coordinates are required.");
        if (req.Lat is { } la && req.Lng is { } lo && (!double.IsFinite(la) || !double.IsFinite(lo) || !CommunityRules.InServiceArea(la, lo))) throw new ValidationException("lat", "Location must be in Malaysia, Singapore or Brunei.");
        if (req.Lat is { } la2 && req.Lng is { } lo2) await restricted.EnsureAllowedAsync(new GeoPoint(la2, lo2), ct);

        var suggestion = new PlaceSuggestion { PlaceId = id, UserId = userId, Changes = req, CreatedAt = clock.GetUtcNow(), StreetWayIds = street?.WayIds ?? [], StreetOriginalName = street?.Name };
        db.PlaceSuggestions.Add(suggestion);
        if (req.Closed is null && isCommunity && await db.CommunityPlaces.AnyAsync(p => p.Id == id && p.OwnerId == userId, ct))
        {
            await db.SaveChangesAsync(ct);
            await PatchAsync(userId, id, new PatchCommunityPlaceRequest(req.Name, req.Category, req.Lat, req.Lng, req.Address, req.Description,
                req.Phone, req.Website, req.OpeningHours, null), ct);
            suggestion.Status = SuggestionStatus.Applied;
            suggestion.AppliedAt = clock.GetUtcNow();
        }
        await db.SaveChangesAsync(ct);
        return suggestion.Id;
    }

    public async Task<IReadOnlyList<PlaceSummary>> ContributedAsync(Guid userId, CancellationToken ct)
    {
        var rows = await db.CommunityPlaces.AsNoTracking().Where(p => p.OwnerId == userId).OrderByDescending(p => p.CreatedAt).Take(200).ToListAsync(ct);
        var agg = await Core.Search.PlaceDocuments.AggregatesAsync(db, rows.Select(r => r.Id).ToList(), ct);
        // Owners see their own status, including hidden/closed.
        return rows.Select(p => PlaceService.ToSummary(p, null, null, agg.GetValueOrDefault(p.Id)) with
        {
            Status = p.Status,
            HeldForReview = p.HeldForReview,
            Screening = ScreeningDto(p),
            ConfirmationsWeighted = p.Status == PlaceStatus.Pending || p.AuditOpen ? Math.Round(p.WeightedYes, 2) : null,
            Required = p.Status == PlaceStatus.Pending || p.AuditOpen ? RequiredFor(p) : null,
        }).ToList();
    }

    // ---- checks -------------------------------------------------------------------------------

    internal static string CheckName(string? name)
    {
        var n = name?.Trim() ?? "";
        if (n.Length is < 2 or > CommunityRules.MaxNameLength) throw new ValidationException("name", $"name must be 2–{CommunityRules.MaxNameLength} characters.");
        switch (Filter.Check(n))
        {
            case TextVerdict.Link: throw new ValidationException("name", "Names can't contain links.");
            case TextVerdict.Profanity: throw new ValidationException("name", "Please choose a different name.");
        }
        return n;
    }

    internal static void CheckOptional(string? description, string? phone, string? website, string? openingHours, string? address)
    {
        if (description is { Length: > CommunityRules.MaxDescriptionLength }) throw new ValidationException("description", $"description max {CommunityRules.MaxDescriptionLength} chars.");
        if (Filter.Check(description, rejectLinks: true) != TextVerdict.Ok) throw new ValidationException("description", "Please keep the description friendly and without links.");
        if (address is { Length: > 300 }) throw new ValidationException("address", "address max 300 chars.");
        if (Filter.Check(address, rejectLinks: true) != TextVerdict.Ok) throw new ValidationException("address", "Invalid address.");
        if (phone is not null && (phone.Length > 30 || phone.Any(ch => !(char.IsDigit(ch) || ch is ' ' or '+' or '-' or '(' or ')'))))
            throw new ValidationException("phone", "phone must contain digits, spaces, + - ( ) only.");
        if (website is not null && (website.Length > 200 || !Uri.TryCreate(website, UriKind.Absolute, out var u) || u.Scheme is not ("http" or "https")))
            throw new ValidationException("website", "website must be an http(s) URL.");
        if (openingHours is { Length: > 200 }) throw new ValidationException("openingHours", "openingHours max 200 chars.");
    }

    /// <summary>Inside MY/SG/BN (near a road from our extract) and not inside an inland water polygon.</summary>
    private async Task CheckLocationAsync(GeoPoint at, CancellationToken ct)
    {
        if (!CommunityRules.InServiceArea(at.Lat, at.Lng)) throw new ValidationException("lat", "Location must be in Malaysia, Singapore or Brunei.");
        var pt = at.ToPoint();
        if (!await db.RoadSegments.AnyAsync(s => s.Geom.IsWithinDistance(pt, 2000), ct))
            throw new ValidationException("lat", "This location is too far from any road (in the sea, or outside Malaysia, Singapore and Brunei).");
        if (await db.WaterAreas.AnyAsync(w => w.Geom.Intersects(pt), ct))
            throw new ValidationException("lat", "This location is in water. Move the pin onto land.");
    }

    private async Task<PlaceSummary?> FindDuplicateAsync(string name, GeoPoint at, string? exceptId, CancellationToken ct)
    {
        var pt = at.ToPoint();
        var osm = await db.Places.AsNoTracking().Where(p => p.Location.IsWithinDistance(pt, CommunityRules.DuplicateRadiusM)).Take(200).ToListAsync(ct);
        var community = await db.CommunityPlaces.AsNoTracking()
            .Where(p => p.Id != exceptId && p.Status != PlaceStatus.Hidden && p.Status != PlaceStatus.Closed && p.Location.IsWithinDistance(pt, CommunityRules.DuplicateRadiusM))
            .Take(200).ToListAsync(ct);
        var dup = CommunityRules.FindDuplicate(name, at,
            osm.Select(p => new CommunityRules.NearbyName(p.Id, p.Name, p.Location.Y, p.Location.X))
                .Concat(community.Select(p => new CommunityRules.NearbyName(p.Id, p.Name, p.Location.Y, p.Location.X))));
        if (dup is null) return null;
        return osm.FirstOrDefault(p => p.Id == dup.Id) is { } o
            ? PlaceService.ToSummary(o, at.Lat, at.Lng)
            : PlaceService.ToSummary(community.First(p => p.Id == dup.Id), at.Lat, at.Lng);
    }

    private async Task<CommunityPlace> OwnedAsync(Guid userId, string id, CancellationToken ct)
    {
        if (!CommunityPlace.IsCommunityId(id)) throw new ForbiddenException("Only community places can be edited; use suggest-edit for map places.");
        var place = await db.CommunityPlaces.Include(p => p.Owner).FirstOrDefaultAsync(p => p.Id == id, ct) ?? throw new NotFoundException($"Place {id} not found.");
        if (place.OwnerId != userId) throw new ForbiddenException("Only the person who added this place can change it; use suggest-edit.");
        return place;
    }

    /// <summary>The contributing user (add, verify, suggest); a banned account gets 403 (Moderation.EnsureMayContribute).</summary>
    private async Task<User> RequireUserAsync(Guid userId, CancellationToken ct) =>
        Moderation.EnsureMayContribute(await db.Users.FirstOrDefaultAsync(u => u.Id == userId, ct) ?? throw new UnauthorizedAccessException("This account was deleted."));

    /// <summary>The owner's view, with the AI check's state.</summary>
    private PlaceDto Dto(CommunityPlace p) =>
        PlaceService.ToDto(p, null, null, null, [], TimeZoneInfo.ConvertTime(clock.GetUtcNow(), ValhallaMapper.MalaysiaTime).DateTime)
            with
            {
                Status = p.Status, HeldForReview = p.HeldForReview, Screening = ScreeningDto(p),
                // "Not verified yet · x of y" (design A4), while it waits for confirmations or an audit.
                ConfirmationsWeighted = p.Status == PlaceStatus.Pending || p.AuditOpen ? Math.Round(p.WeightedYes, 2) : null,
                Required = p.Status == PlaceStatus.Pending || p.AuditOpen ? RequiredFor(p) : null,
            };

    internal static PlaceScreeningDto ScreeningDto(CommunityPlace p) => new(p.ScreeningState,
        string.IsNullOrEmpty(p.ScreeningReasons) ? [] : p.ScreeningReasons.Split(','),
        CanAppeal: p.Status == PlaceStatus.Rejected && p.AppealedAt is null, Appealed: p.AppealedAt is not null);
}
