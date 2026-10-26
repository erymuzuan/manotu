using System.Globalization;
using System.Text;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Core.Community;

/// <summary>wire: gambling, online_gambling, tobacco, high_risk_investment, loan_shark, alcohol.</summary>
public enum BrandGroup { Gambling, OnlineGambling, Tobacco, HighRiskInvestment, LoanShark, Alcohol }

/// <summary>What a match in a place's name or text does to a community place: show a warning, or hold it for a maintainer.</summary>
public enum BrandPlaceMode { Warn, Hold }

/// <summary>What a match in a review, note or caption does: let the model decide mention versus promotion, or always reject.</summary>
public enum BrandTextMode { MentionOk, Reject }

public sealed record BrandMatch(string Name, BrandGroup Group, BrandPlaceMode PlaceMode, BrandTextMode TextMode)
{
    /// <summary>The place warning this brand's group implies, if any ("alcohol", "gambling", "tobacco").</summary>
    public string? Warning => Group switch
    {
        BrandGroup.Alcohol => PlaceWarnings.Alcohol,
        BrandGroup.Gambling => PlaceWarnings.Gambling,
        BrandGroup.Tobacco => PlaceWarnings.Tobacco,
        _ => null,
    };
}

/// <summary>
/// Undoes the usual spelling tricks before matching a brand: case, accents, full-width and look-alike characters (0→o, 1→i, 3→e,
/// 4→a, 5→s, 7→t, @→a, $→s, Cyrillic а/е/о/р/с/х), zero-width characters, and spacing or punctuation inside the name.
/// </summary>
public static class BrandNormalizer
{
    private static readonly Dictionary<char, char> LookAlike = new()
    {
        ['0'] = 'o', ['1'] = 'i', ['!'] = 'i', ['|'] = 'i', ['3'] = 'e', ['4'] = 'a', ['@'] = 'a', ['5'] = 's', ['$'] = 's', ['7'] = 't', ['8'] = 'b',
        ['а'] = 'a', ['е'] = 'e', ['о'] = 'o', ['р'] = 'p', ['с'] = 'c', ['х'] = 'x', ['і'] = 'i', ['у'] = 'y', ['ѕ'] = 's',
        ['ı'] = 'i', ['ɡ'] = 'g', ['ο'] = 'o', ['ν'] = 'v', ['α'] = 'a',
    };

    // The server runs with InvariantGlobalization, where string.Normalize() does nothing, so accents and full-width forms are folded by hand.
    private static readonly string[] AccentGroups =
    [
        "aàáâãäåāăą", "cçćĉċč", "dďđ", "eèéêëēĕėęě", "gĝğġģ", "hĥħ", "iìíîïĩīĭįı", "jĵ", "kķ", "lĺļľŀł", "nñńņňŉ", "oòóôõöøōŏő",
        "rŕŗř", "sśŝşš", "tţťŧ", "uùúûüũūŭůűų", "wŵ", "yýÿŷ", "zźżž",
    ];
    private static readonly Dictionary<char, char> Accents = AccentGroups.SelectMany(g => g.Skip(1).Select(c => (c, to: g[0]))).ToDictionary(x => x.c, x => x.to);

    /// <summary>Words separated by single spaces (letters and digits only, look-alikes folded).</summary>
    public static string Spaced(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return "";
        var sb = new StringBuilder(s.Length);
        var gap = false;
        foreach (var c0 in s)
        {
            var cat = CharUnicodeInfo.GetUnicodeCategory(c0);
            if (cat is UnicodeCategory.NonSpacingMark or UnicodeCategory.Format) continue; // combining accents, zero-width joiners
            if (c0 is '\'' or '’' or '`') continue;                                         // Jack Daniel's → jack daniels
            var c = c0 is >= '\uFF01' and <= '\uFF5E' ? (char)(c0 - 0xFEE0) : c0;           // full-width → ASCII
            c = char.ToLowerInvariant(c);
            c = Accents.GetValueOrDefault(c, c);
            c = LookAlike.GetValueOrDefault(c, c);
            if (char.IsLetterOrDigit(c)) { if (gap && sb.Length > 0) sb.Append(' '); sb.Append(c); gap = false; }
            else gap = true;
        }
        return sb.ToString();
    }

    /// <summary>The same with every space removed ("m a r l b o r o" → "marlboro").</summary>
    public static string Compact(string? s) => Spaced(s).Replace(" ", "");
}

/// <summary>Finds watchlist brands in text or a place name after <see cref="BrandNormalizer"/>.</summary>
public sealed class BrandMatcher
{
    /// <summary>Names at least this long (compact) are also found with spacing tricks inside other words' gaps ("m a r l b o r o").</summary>
    public const int MinCompactLength = 7;

    private readonly List<(WatchedBrand Brand, string Spaced, string Compact)> _forms = [];

    public BrandMatcher(IEnumerable<WatchedBrand> brands)
    {
        foreach (var b in brands.Where(b => b.Enabled))
            foreach (var name in new[] { b.Name }.Concat((b.Aliases ?? "").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)))
            {
                var sp = BrandNormalizer.Spaced(name);
                if (sp.Length >= 2) _forms.Add((b, sp, sp.Replace(" ", "")));
            }
    }

    public int Count => _forms.Count;

    public IReadOnlyList<BrandMatch> Match(params string?[] texts)
    {
        var found = new Dictionary<Guid, BrandMatch>();
        foreach (var t in texts.Where(x => !string.IsNullOrWhiteSpace(x)))
        {
            var spaced = " " + BrandNormalizer.Spaced(t) + " ";
            var compact = spaced.Replace(" ", "");
            foreach (var (b, sp, cp) in _forms)
            {
                if (found.ContainsKey(b.Id)) continue;
                if (spaced.Contains(" " + sp + " ", StringComparison.Ordinal) || (cp.Length >= MinCompactLength && compact.Contains(cp, StringComparison.Ordinal)))
                    found[b.Id] = new BrandMatch(b.Name, b.Group, b.PlaceMode, b.TextMode);
            }
        }
        return found.Values.ToList();
    }
}

/// <summary>A small, neutral starter set. Maintainers edit it in the back office ("Brand watchlist"); seeded once into an empty table.</summary>
public static class BrandWatchlistSeed
{
    private static WatchedBrand B(string name, BrandGroup g, BrandPlaceMode place, BrandTextMode text, string? aliases = null) =>
        new() { Name = name, Group = g, PlaceMode = place, TextMode = text, Aliases = aliases, UpdatedBy = "seed" };

    public static IReadOnlyList<WatchedBrand> Defaults() =>
    [
        B("Magnum 4D", BrandGroup.Gambling, BrandPlaceMode.Warn, BrandTextMode.MentionOk, "Magnum"),
        B("Sports Toto", BrandGroup.Gambling, BrandPlaceMode.Warn, BrandTextMode.MentionOk, "Toto"),
        B("Da Ma Cai", BrandGroup.Gambling, BrandPlaceMode.Warn, BrandTextMode.MentionOk, "Damacai"),
        B("1xBet", BrandGroup.OnlineGambling, BrandPlaceMode.Hold, BrandTextMode.Reject),
        B("Bet365", BrandGroup.OnlineGambling, BrandPlaceMode.Hold, BrandTextMode.Reject),
        B("Mega888", BrandGroup.OnlineGambling, BrandPlaceMode.Hold, BrandTextMode.Reject),
        B("918Kiss", BrandGroup.OnlineGambling, BrandPlaceMode.Hold, BrandTextMode.Reject, "Kiss918"),
        B("Joker123", BrandGroup.OnlineGambling, BrandPlaceMode.Hold, BrandTextMode.Reject),
        B("Sbobet", BrandGroup.OnlineGambling, BrandPlaceMode.Hold, BrandTextMode.Reject),
        B("Marlboro", BrandGroup.Tobacco, BrandPlaceMode.Warn, BrandTextMode.MentionOk),
        B("Dunhill", BrandGroup.Tobacco, BrandPlaceMode.Warn, BrandTextMode.MentionOk),
        B("Geek Bar", BrandGroup.Tobacco, BrandPlaceMode.Warn, BrandTextMode.MentionOk),
        B("Relx", BrandGroup.Tobacco, BrandPlaceMode.Warn, BrandTextMode.MentionOk),
        B("Tiger Beer", BrandGroup.Alcohol, BrandPlaceMode.Warn, BrandTextMode.MentionOk),
        B("Carlsberg", BrandGroup.Alcohol, BrandPlaceMode.Warn, BrandTextMode.MentionOk),
        B("Heineken", BrandGroup.Alcohol, BrandPlaceMode.Warn, BrandTextMode.MentionOk),
        B("Binomo", BrandGroup.HighRiskInvestment, BrandPlaceMode.Hold, BrandTextMode.Reject),
        B("Quotex", BrandGroup.HighRiskInvestment, BrandPlaceMode.Hold, BrandTextMode.Reject),
        B("Ah Long", BrandGroup.LoanShark, BrandPlaceMode.Hold, BrandTextMode.Reject),
    ];
}

/// <summary>Maintainers' view of the watchlist: list, add, edit, enable/disable, and a "test a sentence" box. Every edit is audited.</summary>
public sealed class BrandWatchlistService(GimanoDbContext db, TimeProvider clock)
{
    public async Task<IReadOnlyList<WatchedBrand>> ListAsync(CancellationToken ct = default) =>
        await db.WatchedBrands.AsNoTracking().OrderBy(b => b.Group).ThenBy(b => b.Name).ToListAsync(ct);

    public async Task<BrandMatcher> MatcherAsync(CancellationToken ct = default) =>
        new(await db.WatchedBrands.AsNoTracking().Where(b => b.Enabled).ToListAsync(ct));

    /// <summary>Which brands a sentence matches (the pre-filter only: the model is not called).</summary>
    public async Task<IReadOnlyList<BrandMatch>> TestAsync(string? text, CancellationToken ct = default) => (await MatcherAsync(ct)).Match(text);

    public async Task<WatchedBrand> SaveAsync(Guid? id, string? name, string? aliases, BrandGroup group, BrandPlaceMode placeMode, BrandTextMode textMode,
        bool enabled, string actor, CancellationToken ct = default)
    {
        var n = name?.Trim() ?? "";
        if (n.Length is < 2 or > 80) throw new ValidationException("name", "name must be 2–80 characters.");
        if (BrandNormalizer.Spaced(n).Length < 2) throw new ValidationException("name", "name needs letters or digits.");
        var al = string.Join(", ", (aliases ?? "").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).Distinct().Take(20));
        if (al.Length > 400) throw new ValidationException("aliases", "aliases max 400 characters.");
        var now = clock.GetUtcNow();
        WatchedBrand b;
        string action;
        if (id is { } existing)
        {
            b = await db.WatchedBrands.FirstOrDefaultAsync(x => x.Id == existing, ct) ?? throw new NotFoundException("Brand not found.");
            action = enabled == b.Enabled ? "brand.edit" : enabled ? "brand.enable" : "brand.disable";
        }
        else
        {
            if (await db.WatchedBrands.AnyAsync(x => x.Name.ToLower() == n.ToLower(), ct)) throw new ConflictException("This brand is already on the list.");
            b = new WatchedBrand { Name = n };
            db.WatchedBrands.Add(b);
            action = "brand.add";
        }
        b.Name = n; b.Aliases = al.Length == 0 ? null : al; b.Group = group; b.PlaceMode = placeMode; b.TextMode = textMode; b.Enabled = enabled;
        b.UpdatedAt = now; b.UpdatedBy = actor;
        db.AuditLog.Add(new AuditEntry
        {
            At = now, Actor = actor, ActorKind = "human", Action = action, TargetType = "brand", TargetId = b.Id.ToString(),
            Detail = $"{b.Name} [{GimanoJson.ToWire(group)} place={GimanoJson.ToWire(placeMode)} text={GimanoJson.ToWire(textMode)}]",
        });
        await db.SaveChangesAsync(ct);
        return b;
    }

    /// <summary>Seeds the starter set into an empty table (startup).</summary>
    public static async Task EnsureSeededAsync(GimanoDbContext db, CancellationToken ct = default)
    {
        if (await db.WatchedBrands.AnyAsync(ct)) return;
        db.WatchedBrands.AddRange(BrandWatchlistSeed.Defaults());
        try { await db.SaveChangesAsync(ct); } catch (DbUpdateException) { /* another instance seeded first */ }
    }
}
