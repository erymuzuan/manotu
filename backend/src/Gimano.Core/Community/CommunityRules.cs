using System.Text;
using Gimano.Core.Contracts;
using Gimano.Core.Geo;

namespace Gimano.Core.Community;

/// <summary>Rules for community places, reviews and photos (docs/api.md "Community places", "Reviews &amp; photos").</summary>
public static class CommunityRules
{
    public const double DuplicateRadiusM = 100;
    public const double DuplicateSimilarity = 0.6;
    public const int FlagsToHide = 3;

    public const int PlacesPerDay = 10;
    public const int PublicPlacesPerHour = 3;
    public const int ReviewsPerDay = 20;
    public static readonly TimeSpan SelfReviewBlock = TimeSpan.FromHours(24);

    public const int MaxNameLength = 100;
    public const int MaxDescriptionLength = 1000;
    public const int MaxReviewLength = 2000;
    public const int MaxCaptionLength = 200;

    public static class Points
    {
        public const int PlaceAdded = 5;
        public const int PlacePublished = 20;
        public const int Review = 3;
        public const int Photo = 2;
        public const int HelpfulReceived = 1;
    }

    /// <summary>
    /// Who can see a community place (GET by id, nearby): pending and published for everyone (so nearby users can verify), except a
    /// new place the AI is still checking; hidden, rejected and closed only for the owner.
    /// </summary>
    public static bool IsVisibleTo(PlaceStatus status, Guid? ownerId, Guid? viewer, ScreeningState screening = ScreeningState.None) =>
        status == PlaceStatus.Published || (status == PlaceStatus.Pending && screening != ScreeningState.Checking)
        || (viewer is not null && ownerId == viewer);

    /// <summary>
    /// Who sees it in text search: published for everyone, and pending places the AI check passed ("listed", shown as not verified
    /// yet); the owner also sees their own pending places.
    /// </summary>
    public static bool IsSearchableBy(PlaceStatus status, Guid? ownerId, Guid? viewer, bool listed = false) =>
        status == PlaceStatus.Published || (status == PlaceStatus.Pending && (listed || (viewer is not null && ownerId == viewer)));

    public static bool InServiceArea(double lat, double lng) => lat is > 0.8 and < 7.5 && lng is > 99.5 and < 119.5;

    public sealed record NearbyName(string Id, string Name, double Lat, double Lng);

    /// <summary>The first existing place within 100 m whose name is trigram-similar (≥ 0.6, pg_trgm semantics) to <paramref name="name"/>.</summary>
    public static NearbyName? FindDuplicate(string name, GeoPoint at, IEnumerable<NearbyName> nearby) =>
        nearby
            .Where(n => GeoMath.HaversineM(at.Lat, at.Lng, n.Lat, n.Lng) <= DuplicateRadiusM)
            .Select(n => (n, sim: TrigramSimilarity(name, n.Name)))
            .Where(x => x.sim >= DuplicateSimilarity)
            .OrderByDescending(x => x.sim)
            .Select(x => x.n)
            .FirstOrDefault();

    /// <summary>pg_trgm's <c>similarity()</c>: words of lower-case alphanumerics, padded "  w ", |A∩B| / |A∪B| over trigram sets.</summary>
    public static double TrigramSimilarity(string a, string b)
    {
        var ta = Trigrams(a);
        var tb = Trigrams(b);
        if (ta.Count == 0 || tb.Count == 0) return 0;
        var inter = ta.Count(tb.Contains);
        return (double)inter / (ta.Count + tb.Count - inter);
    }

    private static HashSet<string> Trigrams(string s)
    {
        var set = new HashSet<string>(StringComparer.Ordinal);
        var word = new StringBuilder();
        foreach (var ch in (s + " ").ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(ch)) { word.Append(ch); continue; }
            if (word.Length == 0) continue;
            var padded = "  " + word + " ";
            for (var i = 0; i + 3 <= padded.Length; i++) set.Add(padded.Substring(i, 3));
            word.Clear();
        }
        return set;
    }

    /// <summary>Opaque cursor for keyset pagination.</summary>
    public static string EncodeCursor(params object[] parts) =>
        Convert.ToBase64String(Encoding.UTF8.GetBytes(string.Join('|', parts.Select(p => Convert.ToString(p, System.Globalization.CultureInfo.InvariantCulture)))))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');

    public static string[]? DecodeCursor(string? cursor)
    {
        if (string.IsNullOrEmpty(cursor)) return null;
        try
        {
            var b64 = cursor.Replace('-', '+').Replace('_', '/');
            b64 += new string('=', (4 - b64.Length % 4) % 4);
            return Encoding.UTF8.GetString(Convert.FromBase64String(b64)).Split('|');
        }
        catch (FormatException) { return null; }
    }
}
