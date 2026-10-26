using System.Globalization;
using Gimano.Core.Contracts;
using Gimano.Core.Domain;

namespace Gimano.Core.Issues;

/// <summary>Passive evidence for one issue, from segment_traversal_counts (anonymous per-hour counts).</summary>
/// <param name="TraversalsSince">Vehicles through the issue's segment/direction in full hours after the report.</param>
/// <param name="Traversals14d">… in the last 14 days (for "no traversals" rules).</param>
/// <param name="BaselinePerDay">Average per day in the 7 days before the report (is this road normally used?).</param>
public sealed record IssueEvidence(int TraversalsSince, int Traversals14d, double BaselinePerDay)
{
    public static readonly IssueEvidence None = new(0, 0, 0);
}

/// <summary>
/// The issue state machine (docs/complaints.md, docs/api.md "Issues"). Pure: the API applies it after a report or vote,
/// the worker every 15 minutes with fresh passive evidence.
/// </summary>
public static class IssueRules
{
    public const double DedupeRadiusM = 50;
    public const int RefuteTraversals = 5;
    public const double ClearedToRefute = 2;
    public const int ReportsPerDay = 30;
    public const int VotesPerDay = 20;
    public static readonly TimeSpan ClosedConfirmWindow = TimeSpan.FromMinutes(30);
    public static readonly TimeSpan FeedbackKeep = TimeSpan.FromDays(90);
    public static readonly TimeSpan LongLivedKeep = TimeSpan.FromDays(180);
    public static readonly TimeSpan PlaceClosedTempMax = TimeSpan.FromDays(60);

    public static bool IsRoad(IssueKind k) => k is IssueKind.RoadClosedTemp or IssueKind.RoadNotExist or IssueKind.OnewayWrongClosedDir
        or IssueKind.OnewayWrongOpenDir or IssueKind.TurnNotAllowed;

    public static bool IsPlace(IssueKind k) => k is IssueKind.PlaceClosedPerm or IssueKind.PlaceClosedTemp or IssueKind.PlaceHoursWrong
        or IssueKind.PlaceEntranceWrong or IssueKind.PlaceInfoWrong or IssueKind.PlaceDuplicate;

    /// <summary>Feedback for maintainers only: never voted on, never changes routing.</summary>
    public static bool IsFeedbackOnly(IssueKind k) => k is IssueKind.OddRoute or IssueKind.NewRoad;

    /// <summary>Confirmed → Valhalla exclude_polygons (v1). Everything else on roads only warns.</summary>
    public static bool ExcludesRouting(IssueKind k) => k is IssueKind.RoadClosedTemp or IssueKind.RoadNotExist;

    /// <summary>Motorway/trunk/primary (Malaysian toll expressways are motorway/trunk in OSM).</summary>
    public static bool IsMajor(string? highway) => highway is "motorway" or "motorway_link" or "trunk" or "trunk_link" or "primary" or "primary_link";

    public static bool IsOpen(IssueState s) => s is IssueState.Reported or IssueState.Suspected or IssueState.Confirmed;

    public static IssueState InitialState(IssueKind k) => IsFeedbackOnly(k) ? IssueState.Reported : IssueState.Suspected;

    /// <summary>Base lifetime of a temporary closure by subtype (extended by each "still" vote).</summary>
    public static TimeSpan ClosedTempDuration(string? subtype) => subtype switch
    {
        "accident" => TimeSpan.FromHours(2),
        "flood" => TimeSpan.FromHours(6),
        "event" => TimeSpan.FromHours(12),
        "roadworks" => TimeSpan.FromDays(7),
        _ => TimeSpan.FromHours(6),
    };

    /// <summary>The app's duration chips: unknown · today · few_days · long_roadworks.</summary>
    public static TimeSpan? DurationHint(string? hint, DateTimeOffset now) => hint switch
    {
        "today" => EndOfMalaysianDay(now) - now,
        "few_days" => TimeSpan.FromDays(3),
        "long_roadworks" => TimeSpan.FromDays(30),
        _ => null,
    };

    private static DateTimeOffset EndOfMalaysianDay(DateTimeOffset now)
    {
        var my = now.ToOffset(TimeSpan.FromHours(8));
        return new DateTimeOffset(my.Date.AddDays(1), TimeSpan.FromHours(8)).ToUniversalTime();   // Npgsql stores UTC only
    }

    /// <summary>Initial expiry; null = until refuted/resolved (long-lived kinds are swept after 180 days).</summary>
    public static DateTimeOffset? InitialExpiry(IssueKind kind, string? subtype, string? durationHint, string? until, DateTimeOffset now) => kind switch
    {
        IssueKind.RoadClosedTemp => now + (DurationHint(durationHint, now) ?? ClosedTempDuration(subtype)),
        IssueKind.PlaceClosedTemp => ParseUntil(until, now) is { } u ? u : now + TimeSpan.FromDays(7),
        IssueKind.OddRoute or IssueKind.NewRoad => now + FeedbackKeep,
        _ => now + LongLivedKeep,
    };

    /// <summary>"until" date (yyyy-MM-dd, end of that Malaysian day), at most 60 days ahead; null if invalid.</summary>
    public static DateTimeOffset? ParseUntil(string? until, DateTimeOffset now)
    {
        if (!DateOnly.TryParseExact(until, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)) return null;
        var end = new DateTimeOffset(d.ToDateTime(TimeOnly.MinValue).AddDays(1), TimeSpan.FromHours(8)).ToUniversalTime();
        if (end <= now) return null;
        return end - now > PlaceClosedTempMax ? now + PlaceClosedTempMax : end;
    }

    /// <summary>Weighted "still" needed to confirm (display: "1 daripada 2").</summary>
    public static double Required(Issue i) => i.Kind switch
    {
        IssueKind.RoadClosedTemp when i.MajorRoad => 3,
        IssueKind.PlaceClosedPerm => 3,
        IssueKind.OnewayWrongOpenDir => 2, // = one Emas
        _ when IsFeedbackOnly(i.Kind) => 0,
        _ => 2,
    };

    /// <summary>Is there passive evidence that the issue is real?</summary>
    public static bool PassiveSupports(Issue i, IssueEvidence e, DateTimeOffset now) => i.Kind switch
    {
        // Nobody drove through for 30 min where people normally do (≥ 1 an hour on average).
        IssueKind.RoadClosedTemp => now - i.CreatedAt >= ClosedConfirmWindow && e.TraversalsSince == 0 && e.BaselinePerDay >= 24,
        IssueKind.RoadNotExist or IssueKind.OnewayWrongClosedDir => e.Traversals14d == 0,
        // Vehicles keep using the direction the map forbids.
        IssueKind.OnewayWrongOpenDir => e.Traversals14d >= RefuteTraversals,
        _ => false,
    };

    /// <summary>Traffic flowing again refutes closures (principle 3).</summary>
    public static bool PassiveRefutes(Issue i, IssueEvidence e) =>
        i.Kind is IssueKind.RoadClosedTemp or IssueKind.RoadNotExist or IssueKind.OnewayWrongClosedDir && e.TraversalsSince >= RefuteTraversals;

    public static bool ConfirmRule(Issue i, IssueEvidence e, DateTimeOffset now)
    {
        var w = i.WeightedStill;
        var passive = PassiveSupports(i, e, now);
        return i.Kind switch
        {
            IssueKind.RoadClosedTemp when i.MajorRoad => w >= 3 && passive,
            IssueKind.RoadClosedTemp => w >= 2 || (passive && w >= 1) || i.EmasSupport,
            IssueKind.RoadNotExist or IssueKind.OnewayWrongClosedDir => w >= 2 && passive,
            IssueKind.OnewayWrongOpenDir => passive && i.EmasSupport,
            IssueKind.TurnNotAllowed or IssueKind.PlaceClosedTemp or IssueKind.PlaceHoursWrong => w >= 2,
            IssueKind.PlaceClosedPerm => w >= 3 || i.EmasSupport,
            IssueKind.PlaceEntranceWrong or IssueKind.PlaceInfoWrong or IssueKind.PlaceDuplicate => w >= 2 || i.EmasSupport,
            _ => false,
        };
    }

    /// <summary>The next state given votes, passive evidence and the clock. Terminal states never change here.</summary>
    public static IssueState Next(Issue i, IssueEvidence e, DateTimeOffset now)
    {
        if (!IsOpen(i.State)) return i.State;
        if (i.ExpiresAt is { } exp && now >= exp && !(i.Kind == IssueKind.PlaceClosedPerm && i.State == IssueState.Confirmed)) return IssueState.Expired;
        if (IsFeedbackOnly(i.Kind)) return i.State;
        if (i.WeightedCleared >= ClearedToRefute && i.WeightedCleared >= i.WeightedStill) return IssueState.Refuted;
        if (PassiveRefutes(i, e)) return IssueState.Refuted;
        if (i.State == IssueState.Suspected && ConfirmRule(i, e, now)) return IssueState.Confirmed;
        return i.State;
    }

    /// <summary>Applies a vote's weight; a "still" on a temporary closure extends its expiry by the subtype's duration.</summary>
    public static void ApplyVote(Issue i, IssueAnswer answer, double weight, bool emas, DateTimeOffset now)
    {
        switch (answer)
        {
            case IssueAnswer.Still:
                i.WeightedStill += weight; i.StillVotes++;
                if (emas && weight > 0) i.EmasSupport = true;
                if (i.Kind == IssueKind.RoadClosedTemp && i.ExpiresAt is { } exp)
                    i.ExpiresAt = Max(exp, now + ClosedTempDuration(i.Subtype));
                break;
            case IssueAnswer.Cleared:
                i.WeightedCleared += weight; i.ClearedVotes++;
                break;
        }
        if (answer != IssueAnswer.Unsure) i.LastEvidenceAt = now;
        i.Confidence = Confidence(i);
    }

    public static double Confidence(Issue i)
    {
        var req = Math.Max(1, Required(i));
        return Math.Round(Math.Clamp((i.WeightedStill - i.WeightedCleared) / req, 0, 1), 2);
    }

    private static DateTimeOffset Max(DateTimeOffset a, DateTimeOffset b) => a > b ? a : b;

    /// <summary>Records a transition (state, time, reason) in the audit trail; returns whether it changed.</summary>
    public static bool Transition(Issue i, IssueState next, DateTimeOffset now, string reason)
    {
        if (next == i.State) return false;
        i.History.Add(string.Create(CultureInfo.InvariantCulture, $"{now:yyyy-MM-ddTHH:mm}Z {Wire(i.State)}→{Wire(next)} ({reason})"));
        if (i.History.Count > 50) i.History.RemoveAt(0);
        if (next == IssueState.Confirmed) i.ConfirmedAt = now;
        if (!IsOpen(next)) i.ClosedAt = now;
        i.State = next;
        return true;
    }

    private static string Wire(IssueState s) => GimanoJson.ToWire(s);

    /// <summary>Did a vote agree with the outcome? Confirmed: "still" agrees; refuted: "cleared" agrees; others: not scored.</summary>
    public static bool? Agreed(IssueAnswer answer, IssueState outcome) => (answer, outcome) switch
    {
        (IssueAnswer.Unsure, _) => null,
        (IssueAnswer.Still, IssueState.Confirmed) or (IssueAnswer.Still, IssueState.Resolved) => true,
        (IssueAnswer.Cleared, IssueState.Refuted) => true,
        (_, IssueState.Confirmed or IssueState.Refuted or IssueState.Resolved) => false,
        _ => null,
    };

    /// <summary>Coarsens a stored coordinate to ≈ 4.4 m (0.00004°).</summary>
    public static double Round5m(double deg) => Math.Round(deg / 0.00004) * 0.00004;

    /// <summary>Odd-route from/to are kept at ≈ 1 km (2 dp).</summary>
    public static double Round1km(double deg) => Math.Round(deg, 2);

    /// <summary>A new-road trace: only the user-chosen part, with 200 m trimmed at each end, at most 500 points.</summary>
    public static List<(double Lat, double Lng)> TrimTrace(IReadOnlyList<(double Lat, double Lng)> trace, double trimM = 200)
    {
        if (trace.Count < 2) return [];
        var cum = new double[trace.Count];
        for (var k = 1; k < trace.Count; k++)
            cum[k] = cum[k - 1] + Geo.GeoMath.HaversineM(trace[k - 1].Lat, trace[k - 1].Lng, trace[k].Lat, trace[k].Lng);
        var total = cum[^1];
        if (total <= 2 * trimM) return [];
        return trace.Where((_, k) => cum[k] >= trimM && cum[k] <= total - trimM)
            .Select(p => (Round5m(p.Lat), Round5m(p.Lng))).Take(500).ToList();
    }
}
