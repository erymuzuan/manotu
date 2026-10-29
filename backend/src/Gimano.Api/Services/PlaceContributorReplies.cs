using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Api.Services;

public sealed record PlaceContributorReplyRequest(Guid RequestId, string? Message, string? Reason);
public sealed record PlaceContributorReplyResult(string Status, Guid? InboxId, bool Replay);

/// <summary>Moderator replies about public submissions, delivered only to their contributor's existing Inbox.</summary>
public sealed class PlaceContributorReplies(GimanoDbContext db, TimeProvider clock)
{
    private GimanoDbContext Db { get; } = db;
    private TimeProvider Clock { get; } = clock;

    private sealed record Receipt(string Hash, string Reason, string Status, Guid? InboxId);

    public async Task<PlaceContributorReplyResult> SendAsync(string submissionId, PlaceContributorReplyRequest request,
        string actor, CancellationToken ct)
    {
        if (!CommunityPlace.IsCommunityId(submissionId)) throw new NotFoundException("Community submission not found.");
        if (request.RequestId == Guid.Empty) throw new ValidationException("requestId", "A nonempty request ID is required; reuse it for retries.");
        var message = request.Message?.Trim();
        if (string.IsNullOrEmpty(message) || message.Length > 1000 || message.Any(c => char.IsControl(c) && c is not '\n' and not '\r' and not '\t'))
            throw new ValidationException("message", "Use 1 to 1000 characters of public-place text.");
        var reason = request.Reason?.Trim();
        if (reason is not ("approved" or "duplicate" or "private_place" or "needs_information" or "other"))
            throw new ValidationException("reason", "Use approved, duplicate, private_place, needs_information or other.");
        if (string.IsNullOrWhiteSpace(actor) || actor.Length > 100) throw new ForbiddenException("An authenticated moderator is required.");

        var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new[] { submissionId, message, reason }))));
        var prefix = $"request={request.RequestId:N};";
        await using var transaction = await this.Db.Database.BeginTransactionAsync(ct);
        // Serialize requests for this submission across API instances. Audit receipts survive Inbox retention/deletion.
        await this.Db.Database.ExecuteSqlInterpolatedAsync($"SELECT pg_advisory_xact_lock(hashtextextended({"place-reply:" + submissionId}, 0))", ct);
        var previous = await this.Db.AuditLog.AsNoTracking().Where(a => a.Action == "place.reply" && a.TargetType == "community_place"
            && a.TargetId == submissionId && a.Detail != null && a.Detail.StartsWith(prefix)).Select(a => a.Detail).SingleOrDefaultAsync(ct);
        if (previous is not null)
        {
            var receipt = JsonSerializer.Deserialize<Receipt>(previous[prefix.Length..])!;
            if (receipt.Hash != hash) throw new ConflictException("This request ID was already used with a different message or reason.");
            await transaction.CommitAsync(ct);
            return new(receipt.Status, receipt.InboxId, true);
        }

        var place = await this.Db.CommunityPlaces.AsNoTracking().SingleOrDefaultAsync(p => p.Id == submissionId, ct)
            ?? throw new NotFoundException("Community submission not found.");
        var author = place.OwnerId is { } owner
            ? await this.Db.Users.AsNoTracking().SingleOrDefaultAsync(u => u.Id == owner, ct) : null;
        Guid? inboxId = null;
        var status = "recipient_unavailable";
        var now = this.Clock.GetUtcNow();
        if (author is not null)
        {
            // Announcement is already supported by both mobile clients and preserves custom text in InboxRules.Render.
            // This is an individual Inbox row, not a broadcast Announcement and not a fabricated feedback thread.
            var item = new InboxItem
            {
                UserId = author.Id, Kind = InboxKind.Announcement,
                Title = InboxRules.IsMalay(author.Locale) ? "Maklum balas tentang tempat yang anda tambah" : "A reply about the place you added",
                Body = message, RefType = "place", RefId = submissionId, CreatedAt = now,
            };
            this.Db.InboxItems.Add(item);
            inboxId = item.Id;
            status = "sent";
        }
        this.Db.AuditLog.Add(new AuditEntry
        {
            At = now, Actor = actor, ActorKind = "admin", Action = "place.reply", TargetType = "community_place", TargetId = submissionId,
            // No message body, recipient identity, contact details or location in the audit receipt.
            Detail = prefix + JsonSerializer.Serialize(new Receipt(hash, reason, status, inboxId)),
        });
        await this.Db.SaveChangesAsync(ct);
        await transaction.CommitAsync(ct);
        return new(status, inboxId, false);
    }
}
