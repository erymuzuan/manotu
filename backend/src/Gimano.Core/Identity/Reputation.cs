using System.Security.Cryptography;
using Gimano.Core.Contracts;

namespace Gimano.Core.Identity;

/// <summary>Per-pseudonym counters used by the tier rules (docs/identity-and-reputation.md §3).</summary>
public sealed record ReputationCounters(
    int PlacesAccepted, int PlacesRejected, int VerifierVotes, int VerifierAgreed,
    DateTimeOffset CreatedAt, int UpheldDisputes90d, int RejectedPlaces7d);

public enum VoteAnswer { Yes, No, Unsure }

public sealed record NextTier(Tier Name, IReadOnlyList<string> Missing);

/// <summary>Tiers, weights, thresholds, accuracy, suspension and vote unlinking.</summary>
public static class Reputation
{
    public const int AccuracyMinItems = 5;
    public const int NoVotesToHide = 3;
    public const int VotesPerDay = 20;
    public static readonly TimeSpan NewAccountNoWeight = TimeSpan.FromDays(7);
    public static readonly TimeSpan PendingExpiry = TimeSpan.FromDays(30);
    public static readonly TimeSpan SaltRetention = TimeSpan.FromDays(30);
    public static readonly TimeSpan Suspension = TimeSpan.FromDays(7);
    public const double AuditShare = 0.10;
    public const int TownWithinM = 1000;
    public const int RuralWithinM = 5000;

    /// <summary>(placesAccepted + verifierAgreed) / (placesAccepted + placesRejected + verifierVotes); null under 5 items.</summary>
    public static double? Accuracy(ReputationCounters c)
    {
        var denominator = c.PlacesAccepted + c.PlacesRejected + c.VerifierVotes;
        if (denominator < AccuracyMinItems) return null;
        return Math.Round((double)(c.PlacesAccepted + c.VerifierAgreed) / denominator, 4);
    }

    public static Tier ComputeTier(ReputationCounters c, DateTimeOffset now)
    {
        var acc = Accuracy(c) ?? 0;
        if (c.PlacesAccepted >= 50 && acc >= 0.95 && now - c.CreatedAt >= TimeSpan.FromDays(90) && c.UpheldDisputes90d == 0)
            return Tier.Emas;
        // Two upheld disputes in 90 days remove Emas; Perak only needs the counters.
        if (c.PlacesAccepted >= 10 && acc >= 0.90) return Tier.Perak;
        return Tier.Baharu;
    }

    /// <summary>What's missing for the next tier. Key-less legacy accounts stay baharu and also need "signingKey".</summary>
    public static NextTier? Next(ReputationCounters c, DateTimeOffset now, bool hasKey = true)
    {
        var current = CapForLegacy(ComputeTier(c, now), hasKey);
        var acc = Accuracy(c);
        var missing = new List<string>();
        switch (current)
        {
            case Tier.Baharu:
                if (c.PlacesAccepted < 10) missing.Add($"placesAccepted:{10 - c.PlacesAccepted}");
                if (acc is null || acc < 0.90) missing.Add("accuracy:90");
                if (!hasKey) missing.Add("signingKey");
                return new NextTier(Tier.Perak, missing);
            case Tier.Perak:
                if (c.PlacesAccepted < 50) missing.Add($"placesAccepted:{50 - c.PlacesAccepted}");
                if (acc is null || acc < 0.95) missing.Add("accuracy:95");
                var days = (int)Math.Ceiling((TimeSpan.FromDays(90) - (now - c.CreatedAt)).TotalDays);
                if (days > 0) missing.Add($"accountDays:{days}");
                if (c.UpheldDisputes90d > 0) missing.Add("noUpheldDispute90d");
                return new NextTier(Tier.Emas, missing);
            default:
                return null;
        }
    }

    /// <summary>
    /// Vote weight: 0 while the account is under 7 days or for "unsure"; else baharu 1, perak 1.5, emas 2.
    /// Key-less legacy accounts weigh at most 1 (their requests can't be signed).
    /// </summary>
    public static double VoteWeight(Tier tier, DateTimeOffset accountCreated, DateTimeOffset now, VoteAnswer answer, bool hasKey = true, bool launchMode = false)
    {
        if (answer == VoteAnswer.Unsure || now - accountCreated < (launchMode ? LaunchNewAccountNoWeight : NewAccountNoWeight)) return 0;
        var w = tier switch { Tier.Emas => 2, Tier.Perak => 1.5, _ => 1.0 };
        return hasKey ? w : Math.Min(w, 1);
    }

    /// <summary>Key-less legacy accounts are never promoted above baharu.</summary>
    public static Tier CapForLegacy(Tier tier, bool hasKey) => hasKey ? tier : Tier.Baharu;

    /// <summary>Weighted "yes" needed to publish a place added by a contributor of this tier (0 = publishes immediately).</summary>
    public static double RequiredConfirmations(Tier contributorTier) => contributorTier switch
    {
        Tier.Emas => 0,
        Tier.Perak => 2,
        _ => 3,
    };

    // Launch mode (Vetting:LaunchMode, design page "Review", board "Launch mode"): while there are few verifiers, a place the
    // AI check passed needs one confirmation, new accounts' votes count after a day, and pending places wait 90 days.
    public static readonly TimeSpan LaunchNewAccountNoWeight = TimeSpan.FromDays(1);
    public static readonly TimeSpan LaunchPendingExpiry = TimeSpan.FromDays(90);

    public static double RequiredConfirmations(Tier contributorTier, bool launchMode) =>
        launchMode && contributorTier != Tier.Emas ? 1 : RequiredConfirmations(contributorTier);

    public static TimeSpan PendingExpiryFor(bool launchMode) => launchMode ? LaunchPendingExpiry : PendingExpiry;

    public static int PublicPlacesPerDay(Tier tier) => tier == Tier.Baharu ? 5 : 10;

    public enum Outcome { Pending, Published, Hidden }

    public static Outcome Resolve(double weightedYes, double weightedNo, double required) =>
        weightedNo >= NoVotesToHide ? Outcome.Hidden
        : required > 0 && weightedYes >= required ? Outcome.Published
        : Outcome.Pending;

    /// <summary>For an audited Emas place (already published): only "no" ≥ 3 matters (hide + dispute).</summary>
    public static bool AuditFails(double weightedNo) => weightedNo >= NoVotesToHide;

    /// <summary>Repeated spam: 3 rejected places within 7 days → contributions suspended for 7 days.</summary>
    public static bool ShouldSuspend(int rejectedPlaces7d) => rejectedPlaces7d >= 3;

    /// <summary>Did this resolved vote agree with the outcome? (unsure never counts)</summary>
    public static bool? Agreed(VoteAnswer answer, Outcome outcome) => (answer, outcome) switch
    {
        (VoteAnswer.Unsure, _) => null,
        (VoteAnswer.Yes, Outcome.Published) => true,
        (VoteAnswer.No, Outcome.Hidden) => true,
        _ => false,
    };

    /// <summary>Unlinking: hmac_sha256(perPlaceSalt, voterId) — the salt is deleted 30 days after resolution.</summary>
    public static byte[] VoterHash(byte[] salt, Guid voterId) => HMACSHA256.HashData(salt, voterId.ToByteArray());

    public static bool WithinProximity(int withinM, bool rural) => withinM > 0 && withinM <= (rural ? RuralWithinM : TownWithinM);

    /// <summary>10 % of Emas places are also sent for local audit.</summary>
    public static bool PickForAudit(Func<double> random) => random() < AuditShare;
}

/// <summary>Vetting switches (appsettings "Vetting").</summary>
public sealed class VettingOptions
{
    public const string Section = "Vetting";
    /// <summary>Launch mode: see <see cref="Reputation.RequiredConfirmations(Tier, bool)"/>. On until enough people verify.</summary>
    public bool LaunchMode { get; set; } = true;
}
