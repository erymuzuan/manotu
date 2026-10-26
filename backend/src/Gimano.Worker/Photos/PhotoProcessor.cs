using System.Diagnostics;
using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Messaging;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Worker.Photos;

/// <summary>Consumes <c>photo.uploaded</c> (durable): orientation → strip metadata → WebP 1600/400 → content-hash keys → published.</summary>
public sealed class PhotoProcessor(
    RabbitMqConnection connection, IServiceScopeFactory scopes, IMediaStore media, IEventPublisher bus, ILogger<PhotoProcessor> logger)
    : RabbitConsumer<PhotoUploadedEvent>(connection, logger)
{
    protected override string QueueName => "gimano.worker.photos";
    protected override IReadOnlyList<string> RoutingKeyBindings => [RoutingKeys.PhotoUploaded];
    protected override ushort Prefetch => 4;

    protected override async Task HandleAsync(PhotoUploadedEvent message, string routingKey, CancellationToken ct)
    {
        await using var scope = scopes.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<GimanoDbContext>();
        var photo = await db.Photos.Include(p => p.User).FirstOrDefaultAsync(p => p.Id == message.PhotoId, ct);
        if (photo is null || photo.Status != PhotoStatus.Processing || photo.UploadKey is null) return;

        var original = await media.GetAsync(photo.UploadKey, ct);
        var uploadKey = photo.UploadKey;
        if (original is null)
        {
            Reject(photo, "Upload missing.");
        }
        else
        {
            var sw = Stopwatch.StartNew();
            try
            {
                var p = await Task.Run(() => ImageProcessor.Process(original), ct);
                await media.PutAsync(MediaKeys.Webp(p.Key), p.Webp, "image/webp", ct);
                await media.PutAsync(MediaKeys.Webp(p.ThumbKey), p.Thumb, "image/webp", ct);
                photo.Key = p.Key;
                photo.ThumbKey = p.ThumbKey;
                photo.Width = p.Width;
                photo.Height = p.Height;
                logger.LogInformation("Photo {Id}: {In:n0} B → {Out:n0} B WebP {W}×{H} + {Thumb:n0} B thumb in {Ms:n0} ms",
                    photo.Id, original.Length, p.Webp.Length, p.Width, p.Height, p.Thumb.Length, sw.Elapsed.TotalMilliseconds);

                // The content check sees the metadata-free image only (docs/content-safety.md "Photos"): published, held, rejected, or still checking.
                var gate = scope.ServiceProvider.GetRequiredService<ContentGate>();
                var outcome = await CheckAsync(gate, db, photo, p.Webp, ct);
                photo.UploadKey = null;
                await gate.ApplyPhotoAsync(photo, outcome, late: false, ct);
                await media.DeleteAsync(uploadKey, ct); // the original (with its EXIF/GPS) is never kept
                return;
            }
            catch (ImageRejectedException ex)
            {
                Reject(photo, ex.Message);
            }
        }
        photo.UploadKey = null;
        photo.ModerationState = ContentState.None;
        await db.SaveChangesAsync(ct);
        await media.DeleteAsync(uploadKey, ct); // the original (with its EXIF/GPS) is never kept
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(photo.PlaceId), ct);
    }

    /// <summary>JPEG from the stripped WebP, then the check (25 s: this runs in the worker, nobody is waiting on it).</summary>
    internal static async Task<ContentOutcome> CheckAsync(ContentGate gate, GimanoDbContext db, Photo photo, byte[] webp, CancellationToken ct)
    {
        var placeName = CommunityPlace.IsCommunityId(photo.PlaceId)
            ? await db.CommunityPlaces.AsNoTracking().Where(x => x.Id == photo.PlaceId).Select(x => x.Name).FirstOrDefaultAsync(ct)
            : await db.Places.AsNoTracking().Where(x => x.Id == photo.PlaceId).Select(x => x.Name).FirstOrDefaultAsync(ct);
        byte[] jpeg;
        try { jpeg = await Task.Run(() => ImageProcessor.ToScreeningJpeg(webp), ct); }
        catch (ImageRejectedException) { return new ContentOutcome(ContentOutcomeKind.Held, ["unclear"]); }
        return await gate.CheckImageAsync(jpeg, new ContentInput(ContentKind.Photo, photo.Caption, placeName), TimeSpan.FromSeconds(25), ct);
    }

    private void Reject(Photo photo, string reason)
    {
        photo.Status = PhotoStatus.Rejected;
        photo.RejectReason = reason;
        logger.LogInformation("Photo {Id} rejected: {Reason}", photo.Id, reason);
    }
}
