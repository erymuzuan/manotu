using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Messaging;
using Gimano.Core.Places;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Api.Services;

public sealed class UnsupportedMediaException(string message) : Exception(message);
public sealed class PayloadTooLargeException(string message) : Exception(message);

/// <summary>
/// Upload: validate + header-probe synchronously (415 for undecodable/HEIC), store the original under uploads/,
/// publish photo.uploaded; the worker does orientation → strip metadata → WebP and flips status to published/rejected.
/// </summary>
public sealed class PhotoService(GimanoDbContext db, IMediaStore media, IEventPublisher bus, TimeProvider clock, AuthorHandles handles,
    RestrictedAreaService restricted)
{
    public const int PageSize = 30;
    public const int UploadsPerDay = 50;

    public async Task<PhotoDto> UploadAsync(Guid userId, string placeId, IFormFile file, string? caption, CancellationToken ct)
    {
        var user = Moderation.EnsureMayContribute(await db.Users.FirstOrDefaultAsync(u => u.Id == userId, ct) ?? throw new UnauthorizedAccessException("This account was deleted."));
        if (file.Length > ImageProcessor.MaxBytes) throw new PayloadTooLargeException("Photos are limited to 15 MB.");
        if (file.Length == 0) throw new ValidationException("file", "file is empty.");
        if (caption is { Length: > CommunityRules.MaxCaptionLength }) throw new ValidationException("caption", $"caption max {CommunityRules.MaxCaptionLength} chars.");
        if (TextFilter.Default.Check(caption) != TextVerdict.Ok) throw new ValidationException("caption", "Please keep captions friendly and without links.");
        await CheckPlaceAsync(placeId, userId, ct);
        // No photos inside or near restricted areas (Act 298 forbids photographing them).
        if (await restricted.LevelForPlaceAsync(placeId, ct) != RestrictedLevel.None) restricted.Refuse();
        var now = clock.GetUtcNow();
        if (await db.Photos.CountAsync(p => p.UserId == userId && p.CreatedAt > now.AddDays(-1), ct) >= UploadsPerDay)
            throw new RateLimitedException($"At most {UploadsPerDay} photos per day.");

        byte[] bytes;
        await using (var s = file.OpenReadStream())
        using (var ms = new MemoryStream((int)file.Length))
        {
            await s.CopyToAsync(ms, ct);
            bytes = ms.ToArray();
        }
        int w, h;
        try { (w, h) = ImageProcessor.Probe(bytes); }
        catch (ImageRejectedException ex) when (ex.UnsupportedFormat) { throw new UnsupportedMediaException(ex.Message); }
        catch (ImageRejectedException ex) { throw new ValidationException("file", ex.Message); }

        var photo = new Photo
        {
            PlaceId = placeId, UserId = userId, User = user, Caption = caption?.Trim(), CreatedAt = now,
            Width = w, Height = h, Status = PhotoStatus.Processing,
        };
        photo.UploadKey = MediaKeys.Upload(photo.Id);
        await media.PutAsync(photo.UploadKey, bytes, file.ContentType ?? "application/octet-stream", ct);
        db.Photos.Add(photo);
        await db.SaveChangesAsync(ct);
        await bus.PublishAsync(RoutingKeys.PhotoUploaded, new PhotoUploadedEvent(photo.Id), ct);
        return ToDto(photo, handles);
    }

    public async Task<PhotosPage> ListAsync(string placeId, string? cursor, CancellationToken ct)
    {
        var q = db.Photos.AsNoTracking().Include(p => p.User).Where(p => p.PlaceId == placeId && p.Status == PhotoStatus.Published);
        if (CommunityRules.DecodeCursor(cursor) is [var id] && Guid.TryParse(id, out var after)) q = q.Where(p => p.Id.CompareTo(after) < 0);
        var rows = await q.OrderByDescending(p => p.Id).Take(PageSize + 1).ToListAsync(ct);
        var more = rows.Count > PageSize;
        if (more) rows.RemoveAt(rows.Count - 1);
        return new PhotosPage(rows.Select(p => ToDto(p, handles)).ToList(), more ? CommunityRules.EncodeCursor(rows[^1].Id) : null);
    }

    public async Task<PhotoDto> GetAsync(Guid id, CancellationToken ct)
    {
        var p = await db.Photos.AsNoTracking().Include(x => x.User).FirstOrDefaultAsync(x => x.Id == id, ct) ?? throw new NotFoundException("Photo not found.");
        return ToDto(p, handles);
    }

    public async Task DeleteAsync(Guid userId, Guid id, CancellationToken ct)
    {
        var p = await db.Photos.FirstOrDefaultAsync(x => x.Id == id, ct) ?? throw new NotFoundException("Photo not found.");
        if (p.UserId != userId) throw new ForbiddenException("Only the uploader can delete this photo.");
        db.Photos.Remove(p);
        await db.SaveChangesAsync(ct);
        // Content-addressed blobs may be shared by identical uploads; only delete if nothing else references them.
        foreach (var key in new[] { p.Key, p.ThumbKey }.Where(k => k is not null))
            if (!await db.Photos.AnyAsync(x => x.Key == key || x.ThumbKey == key, ct)) await media.DeleteAsync(MediaKeys.Webp(key!), ct);
        if (p.UploadKey is not null) await media.DeleteAsync(p.UploadKey, ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(p.PlaceId), ct);
    }

    public async Task FlagAsync(Guid userId, Guid id, FlagReason reason, CancellationToken ct)
    {
        var p = await db.Photos.FirstOrDefaultAsync(x => x.Id == id, ct) ?? throw new NotFoundException("Photo not found.");
        if (await db.PhotoFlags.FindAsync([id, userId], ct) is not null) return;
        db.PhotoFlags.Add(new PhotoFlag { PhotoId = id, UserId = userId, Reason = reason });
        p.FlagCount++;
        if (p.FlagCount >= RestrictedAreaRules.FlagsToHide(reason, CommunityRules.FlagsToHide) && p.Status == PhotoStatus.Published) p.Status = PhotoStatus.Rejected;
        await db.SaveChangesAsync(ct);
        if (p.Status == PhotoStatus.Rejected) await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(p.PlaceId), ct);
    }

    private async Task CheckPlaceAsync(string placeId, Guid userId, CancellationToken ct)
    {
        var ok = CommunityPlace.IsCommunityId(placeId)
            ? await db.CommunityPlaces.AnyAsync(p => p.Id == placeId && (p.Status == PlaceStatus.Pending || p.Status == PlaceStatus.Published || p.OwnerId == userId), ct)
            : await db.Places.AnyAsync(p => p.Id == placeId, ct);
        if (!ok) throw new NotFoundException("Place not found.");
    }

    public static PhotoDto ToDto(Photo p, AuthorHandles h) => new(
        p.Id, MediaKeys.Url(p.Key), MediaKeys.Url(p.ThumbKey), p.Width, p.Height, p.Caption,
        p.User is null ? new AddedBy("Pemandu Manotu") : new AddedBy(p.User.DisplayName, h.For(p.UserId)), p.CreatedAt, p.Status);
}
