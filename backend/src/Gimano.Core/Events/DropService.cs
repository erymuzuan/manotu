using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Gimano.Core.Data;
using Microsoft.EntityFrameworkCore;
using Npgsql;

namespace Gimano.Core.Events;

/// <summary>Persistence for <see cref="Drop"/> rows (Postgres in production, a fake in unit tests).</summary>
public interface IDropStore
{
    /// <summary>False when the id is already taken (the caller retries with a new id).</summary>
    Task<bool> TryInsertAsync(Drop drop, CancellationToken ct);
    /// <summary>The row, with <see cref="Drop.Blob"/> empty unless <paramref name="withBlob"/>.</summary>
    Task<Drop?> FindAsync(string id, bool withBlob, CancellationToken ct);
    Task<int> CountLiveAsync(byte[] ownerHash, DateTimeOffset now, CancellationToken ct);
    /// <summary>Replaces the blob of a live drop; false when it ended in the meantime.</summary>
    Task<bool> UpdateAsync(string id, byte[] blob, DateTimeOffset expiresAt, DateTimeOffset now, CancellationToken ct);
    /// <summary>Marks a drop deleted and clears its blob at once (the row stays as a 410 tombstone until the purge).</summary>
    Task MarkDeletedAsync(string id, DateTimeOffset now, CancellationToken ct);
    Task<int> DeleteByOwnerAsync(byte[] ownerHash, CancellationToken ct);
    /// <summary>Removes expired and deleted rows.</summary>
    Task<int> PurgeAsync(DateTimeOffset now, CancellationToken ct);
}

public sealed class EfDropStore(GimanoDbContext db) : IDropStore
{
    public async Task<bool> TryInsertAsync(Drop drop, CancellationToken ct)
    {
        db.Drops.Add(drop);
        try
        {
            await db.SaveChangesAsync(ct);
            // Reads and mutations below bypass tracking; retain no stale instance after insertion.
            // A later ID collision in this scope must reach the database uniqueness check.
            db.Entry(drop).State = EntityState.Detached;
            return true;
        }
        catch (DbUpdateException ex) when (ex.InnerException is PostgresException { SqlState: PostgresErrorCodes.UniqueViolation })
        {
            db.Entry(drop).State = EntityState.Detached;
            return false;
        }
    }

    public Task<Drop?> FindAsync(string id, bool withBlob, CancellationToken ct) =>
        db.Drops.AsNoTracking().Where(d => d.Id == id).Select(d => new Drop
        {
            Id = d.Id, Blob = withBlob ? d.Blob : Array.Empty<byte>(), WriteTokenHash = d.WriteTokenHash, OwnerHash = d.OwnerHash,
            CreatedAt = d.CreatedAt, UpdatedAt = d.UpdatedAt, ExpiresAt = d.ExpiresAt, DeletedAt = d.DeletedAt,
        }).FirstOrDefaultAsync(ct);

    public Task<int> CountLiveAsync(byte[] ownerHash, DateTimeOffset now, CancellationToken ct) =>
        db.Drops.CountAsync(d => d.OwnerHash == ownerHash && d.DeletedAt == null && d.ExpiresAt > now, ct);

    public async Task<bool> UpdateAsync(string id, byte[] blob, DateTimeOffset expiresAt, DateTimeOffset now, CancellationToken ct) =>
        await db.Drops.Where(d => d.Id == id && d.DeletedAt == null && d.ExpiresAt > now)
            .ExecuteUpdateAsync(s => s.SetProperty(d => d.Blob, blob).SetProperty(d => d.ExpiresAt, expiresAt).SetProperty(d => d.UpdatedAt, now), ct) == 1;

    public Task MarkDeletedAsync(string id, DateTimeOffset now, CancellationToken ct) =>
        db.Drops.Where(d => d.Id == id && d.DeletedAt == null)
            .ExecuteUpdateAsync(s => s.SetProperty(d => d.DeletedAt, now).SetProperty(d => d.Blob, Array.Empty<byte>()), ct);

    public Task<int> DeleteByOwnerAsync(byte[] ownerHash, CancellationToken ct) =>
        db.Drops.Where(d => d.OwnerHash == ownerHash).ExecuteDeleteAsync(ct);

    public Task<int> PurgeAsync(DateTimeOffset now, CancellationToken ct) =>
        db.Drops.Where(d => d.DeletedAt != null || d.ExpiresAt <= now).ExecuteDeleteAsync(ct);
}

/// <summary>
/// Keyed hash of the uploader's user id: owner = HMAC-SHA256(key, user id). It links an organizer's drops for the quota and
/// <c>DELETE /me</c> only; without the key it can't be turned back into the user id.
/// </summary>
public sealed class DropOwnerKey
{
    private readonly byte[] _key;

    public DropOwnerKey(byte[] key)
    {
        if (key.Length < 32) throw new ArgumentException("Drops:OwnerKey must be at least 32 bytes.", nameof(key));
        _key = key;
    }

    /// <summary>
    /// <c>Drops:OwnerKey</c> (base64, ≥ 32 bytes) when set; otherwise a key derived from the JWT signing key with its own
    /// label (HKDF), like <c>Community:AuthorHandleKey</c>. Set the dedicated key in production: rotating the JWT key would
    /// otherwise detach existing drops from their owners (quota and DELETE /me would no longer find them; they still expire).
    /// </summary>
    public static DropOwnerKey FromConfig(string? keyBase64, string jwtSigningKey)
    {
        if (!string.IsNullOrWhiteSpace(keyBase64)) return new DropOwnerKey(Convert.FromBase64String(keyBase64.Trim()));
        return new DropOwnerKey(HKDF.DeriveKey(HashAlgorithmName.SHA256, Encoding.UTF8.GetBytes(jwtSigningKey), 32,
            info: Encoding.ASCII.GetBytes("manotu/drop-owner/v1")));
    }

    public byte[] For(Guid userId)
    {
        Span<byte> data = stackalloc byte[16];
        userId.TryWriteBytes(data);
        return HMACSHA256.HashData(_key, data);
    }
}

/// <summary>Event short links (docs/events.md §5.6): validation, limits, quota, write-token checks.</summary>
public sealed class DropService(IDropStore store, DropOwnerKey owners, TimeProvider clock)
{
    public const int MaxBlobBytes = 256 * 1024;
    /// <summary>24-byte nonce + 16-byte Poly1305 tag: anything shorter can't be a pack.</summary>
    public const int MinBlobBytes = 24 + 16;
    public const int MaxLivePerUser = 50;
    public const int IdLength = 10;
    public const string Base58Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    public static readonly TimeSpan MinLifetime = TimeSpan.FromDays(1);
    public static readonly TimeSpan MaxLifetime = TimeSpan.FromDays(400);

    public enum Result { Ok, NotFound, Gone, Unauthorized, TooMany, TooLarge, Invalid, InvalidExpiry }

    public sealed record Created(string DropId, string WriteToken, DateTimeOffset ExpiresAt);

    public async Task<(Result, Created?)> CreateAsync(Guid userId, byte[] blob, string? expiresHeader, CancellationToken ct = default)
    {
        if (CheckBlob(blob) is { } bad) return (bad, null);
        var now = clock.GetUtcNow();
        if (ParseExpiry(expiresHeader, now) is not { } expiresAt) return (Result.InvalidExpiry, null);
        var owner = owners.For(userId);
        if (await store.CountLiveAsync(owner, now, ct) >= MaxLivePerUser) return (Result.TooMany, null);

        var token = Base64Url(RandomNumberGenerator.GetBytes(32));   // 256-bit
        var tokenHash = HashToken(token);
        for (var attempt = 0; attempt < 8; attempt++)
        {
            var drop = new Drop
            {
                Id = NewId(), Blob = blob, WriteTokenHash = tokenHash, OwnerHash = owner,
                CreatedAt = now, UpdatedAt = now, ExpiresAt = expiresAt,
            };
            if (await store.TryInsertAsync(drop, ct)) return (Result.Ok, new Created(drop.Id, token, expiresAt));
        }
        throw new InvalidOperationException("Could not allocate a drop id.");   // 58^10 ≈ 4·10^17: practically unreachable
    }

    public async Task<(Result, DateTimeOffset?)> PutAsync(string id, string? token, byte[] blob, string? expiresHeader, CancellationToken ct = default)
    {
        var (r, drop) = await AuthorizeAsync(id, token, ct);
        if (r != Result.Ok) return (r, null);
        if (CheckBlob(blob) is { } bad) return (bad, null);
        var now = clock.GetUtcNow();
        var expiresAt = drop!.ExpiresAt;
        if (!string.IsNullOrEmpty(expiresHeader))
        {
            if (ParseExpiry(expiresHeader, now) is not { } e) return (Result.InvalidExpiry, null);
            expiresAt = e;
        }
        return await store.UpdateAsync(id, blob, expiresAt, now, ct) ? (Result.Ok, expiresAt) : (Result.Gone, null);
    }

    public async Task<(Result, byte[]?)> GetAsync(string id, CancellationToken ct = default)
    {
        if (!IsValidId(id)) return (Result.NotFound, null);
        var drop = await store.FindAsync(id, withBlob: true, ct);
        if (drop is null) return (Result.NotFound, null);
        return drop.IsLive(clock.GetUtcNow()) ? (Result.Ok, drop.Blob) : (Result.Gone, null);
    }

    public async Task<Result> DeleteAsync(string id, string? token, CancellationToken ct = default)
    {
        var (r, _) = await AuthorizeAsync(id, token, ct);
        if (r != Result.Ok) return r;
        await store.MarkDeletedAsync(id, clock.GetUtcNow(), ct);
        return Result.Ok;
    }

    /// <summary><c>DELETE /me</c>: every drop the user uploaded, live or not.</summary>
    public Task<int> DeleteAllForUserAsync(Guid userId, CancellationToken ct = default) => store.DeleteByOwnerAsync(owners.For(userId), ct);

    private async Task<(Result, Drop?)> AuthorizeAsync(string id, string? token, CancellationToken ct)
    {
        if (!IsValidId(id)) return (Result.NotFound, null);
        var drop = await store.FindAsync(id, withBlob: false, ct);
        if (drop is null) return (Result.NotFound, null);
        if (string.IsNullOrEmpty(token) || token.Length > 128) return (Result.Unauthorized, null);
        if (!CryptographicOperations.FixedTimeEquals(HashToken(token), drop.WriteTokenHash)) return (Result.Unauthorized, null);
        if (!drop.IsLive(clock.GetUtcNow())) return (Result.Gone, null);
        return (Result.Ok, drop);
    }

    private static Result? CheckBlob(byte[] blob) =>
        blob.Length > MaxBlobBytes ? Result.TooLarge : blob.Length < MinBlobBytes ? Result.Invalid : null;

    /// <summary>ISO-8601 date-time (an offset or Z; none = UTC), clamped to now + 1 day … now + 400 days. Null when unparseable.</summary>
    public static DateTimeOffset? ParseExpiry(string? header, DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(header) || header.Length > 64) return null;
        if (!DateTimeOffset.TryParse(header.Trim(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var at))
            return null;
        var min = now + MinLifetime;
        var max = now + MaxLifetime;
        return at < min ? min : at > max ? max : at;
    }

    public static bool IsValidId(string? id) =>
        id is { Length: IdLength } && id.All(c => Base58Alphabet.Contains(c));

    public static string NewId()
    {
        Span<char> chars = stackalloc char[IdLength];
        for (var i = 0; i < IdLength; i++) chars[i] = Base58Alphabet[RandomNumberGenerator.GetInt32(Base58Alphabet.Length)];
        return new string(chars);
    }

    internal static byte[] HashToken(string token) => SHA256.HashData(Encoding.ASCII.GetBytes(token));

    private static string Base64Url(byte[] b) => Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
