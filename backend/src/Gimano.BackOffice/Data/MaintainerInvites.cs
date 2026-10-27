using System.Security.Cryptography;
using System.Text;
using Microsoft.EntityFrameworkCore;

namespace Gimano.BackOffice.Data;

/// <summary>
/// A one-time registration invite for one allowlisted email (docs/back-office.md "Maintainer sign-in"). There is no
/// self-registration: an operator mints an invite on the host (<c>invite &lt;email&gt;</c>) and hands
/// over the link, or adds <c>--send</c> to email it through ACS. Only the sha256 of the token is stored; it expires after 24 hours and works once.
/// </summary>
public sealed class MaintainerInvite
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    /// <summary>Upper-cased, trimmed (Identity's normalisation).</summary>
    public required string NormalizedEmail { get; set; }
    public required string TokenHash { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset ExpiresAt { get; set; }
    public DateTimeOffset? UsedAt { get; set; }
}

public sealed class MaintainerInvites(ApplicationDbContext db, MaintainerAllowlist allowlist, TimeProvider clock)
{
    public static readonly TimeSpan Lifetime = TimeSpan.FromHours(24);
    public const string Prefix = "inv_";

    public static string Normalize(string email) => email.Trim().ToUpperInvariant();

    public static string Hash(string token) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(token.Trim())));

    public static string NewToken() =>
        Prefix + Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    /// <summary>Pure rule: may this invite register <paramref name="email"/> now?</summary>
    public static bool Usable(MaintainerInvite? invite, string email, DateTimeOffset now) =>
        invite is { UsedAt: null } && invite.ExpiresAt > now && invite.NormalizedEmail == Normalize(email);

    /// <summary>Mints an invite (replacing unused ones for the same email) and returns the secret, shown once.</summary>
    public async Task<string> CreateAsync(string email, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(email) || !email.Contains('@')) throw new ArgumentException("Give the maintainer's email address.");
        if (!allowlist.Allows(email)) throw new InvalidOperationException($"{email.Trim()} is not listed in BackOffice:Maintainers.");
        var normalized = Normalize(email);
        await db.MaintainerInvites.Where(i => i.NormalizedEmail == normalized && i.UsedAt == null).ExecuteDeleteAsync(ct);
        var token = NewToken();
        var now = clock.GetUtcNow();
        db.MaintainerInvites.Add(new MaintainerInvite { NormalizedEmail = normalized, TokenHash = Hash(token), CreatedAt = now, ExpiresAt = now + Lifetime });
        await db.SaveChangesAsync(ct);
        return token;
    }

    /// <summary>
    /// Atomically marks the invite used for this email. False when unknown, expired, already used or for another email.
    /// Call <see cref="ReleaseAsync"/> if the account could not be created after all.
    /// </summary>
    public async Task<bool> TryConsumeAsync(string? token, string email, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(token) || !token.Trim().StartsWith(Prefix, StringComparison.Ordinal) || token.Length > 100) return false;
        var hash = Hash(token);
        var normalized = Normalize(email);
        var now = clock.GetUtcNow();
        return await db.MaintainerInvites
            .Where(i => i.TokenHash == hash && i.NormalizedEmail == normalized && i.UsedAt == null && i.ExpiresAt > now)
            .ExecuteUpdateAsync(s => s.SetProperty(i => i.UsedAt, now), ct) == 1;
    }

    public async Task ReleaseAsync(string token, CancellationToken ct = default)
    {
        var hash = Hash(token);
        await db.MaintainerInvites.Where(i => i.TokenHash == hash).ExecuteUpdateAsync(s => s.SetProperty(i => i.UsedAt, (DateTimeOffset?)null), ct);
    }
}
