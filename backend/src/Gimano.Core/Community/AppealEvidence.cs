using Gimano.Core.Contracts;

namespace Gimano.Core.Community;

/// <summary>
/// Evidence images sent with an appeal (docs/content-safety.md "Appeals"): up to 3 JPEG/PNG/WebP of at most 5 MB. They are re-encoded to
/// WebP (which drops EXIF and GPS), stored privately under <c>appeals/{id}/{n}</c> (not served by /media), shown to maintainers only,
/// never published and never sent to the model. Deleted 30 days after the decision and with the account.
/// </summary>
public static class AppealEvidence
{
    public const int MaxPhotos = 3;
    public const int MaxBytes = 5 * 1024 * 1024;
    /// <summary>Appeal text, note and evidence are deleted this long after the decision.</summary>
    public static readonly TimeSpan KeepAfterDecision = TimeSpan.FromDays(30);
    public const int MaxTextLength = 2000;

    /// <summary>Validates and strips the images: format by content (not by the name or content type the client sent), size, count.</summary>
    public static IReadOnlyList<byte[]> Prepare(IReadOnlyList<byte[]> files)
    {
        if (files.Count > MaxPhotos) throw new ValidationException("photos", $"At most {MaxPhotos} photos.");
        var result = new List<byte[]>(files.Count);
        foreach (var data in files)
        {
            if (data.Length == 0) throw new ValidationException("photos", "A photo is empty.");
            if (data.Length > MaxBytes) throw new ApiCodeException(413, "photo_too_large", "Each photo is limited to 5 MB.");
            if (!IsSupported(data)) throw new ValidationException("photos", "Photos must be JPEG, PNG or WebP.");
            try { result.Add(ImageProcessor.Process(data).Webp); }
            catch (ImageRejectedException ex) { throw new ValidationException("photos", ex.Message); }
        }
        return result;
    }

    /// <summary>Stores the stripped images for <paramref name="owner"/> (an appeal, review or photo id); returns the comma-separated keys, or null for none.</summary>
    public static async Task<string?> StoreAsync(IMediaStore media, Guid owner, IReadOnlyList<byte[]> webps, CancellationToken ct)
    {
        if (webps.Count == 0) return null;
        var keys = new List<string>(webps.Count);
        for (var i = 0; i < webps.Count; i++)
        {
            var key = MediaKeys.Appeal(owner, i);
            await media.PutAsync(key, webps[i], "image/webp", ct);
            keys.Add(key);
        }
        return string.Join(',', keys);
    }

    public static IReadOnlyList<string> Split(string? keys) => string.IsNullOrEmpty(keys) ? [] : keys.Split(',');

    public static async Task DeleteAsync(IMediaStore media, string? keys, CancellationToken ct)
    {
        foreach (var key in Split(keys)) await media.DeleteAsync(key, ct);
    }

    internal static bool IsSupported(byte[] d) =>
        d is [0xFF, 0xD8, 0xFF, ..]                                                      // JPEG
        || d is [0x89, 0x50, 0x4E, 0x47, ..]                                             // PNG
        || (d.Length > 12 && d[0] == 'R' && d[1] == 'I' && d[2] == 'F' && d[3] == 'F' && d[8] == 'W' && d[9] == 'E' && d[10] == 'B' && d[11] == 'P');   // WebP
}
