using System.Text.Json;
using Gimano.Core.Community;
using Gimano.Core.Contracts;

namespace Gimano.Api.Endpoints;

/// <summary>What the apps send to <c>POST /appeals</c> (multipart/form-data); see docs/content-safety.md "Appeals".</summary>
public sealed record AppealInput(string? RefusalId, string? Kind, string? PlaceId, string? Text, IReadOnlyList<string> Reasons, string? Note, string? Rating,
    IReadOnlyList<byte[]> Photos);

/// <summary>Reads the appeal body. Request bodies are never logged.</summary>
public static class AppealForm
{
    public const long MaxRequestBytes = AppealEvidence.MaxPhotos * (long)AppealEvidence.MaxBytes + 1024 * 1024;

    /// <summary>Multipart only (<c>POST /appeals</c>).</summary>
    public static async Task<AppealInput> ReadAsync(HttpContext http, CancellationToken ct)
    {
        if (!http.Request.HasFormContentType) throw new ValidationException("note", "Use multipart/form-data.");
        return await ReadFormAsync(http, ct);
    }

    /// <summary>The older review/photo appeal endpoints: JSON <c>{"note": "…"}</c> or multipart with <c>note</c> and <c>photos</c>.</summary>
    public static async Task<AppealInput> ReadLegacyAsync(HttpContext http, CancellationToken ct)
    {
        if (http.Request.HasFormContentType) return await ReadFormAsync(http, ct);
        AppealContentRequest? body = null;
        try { if (http.Request.ContentLength is not 0) body = await http.Request.ReadFromJsonAsync<AppealContentRequest>(GimanoJson.Options, ct); }
        catch (JsonException) { /* an unreadable body is the same as no note */ }
        return new AppealInput(null, null, null, null, [], body?.Note, null, []);
    }

    private static async Task<AppealInput> ReadFormAsync(HttpContext http, CancellationToken ct)
    {
        var form = await http.Request.ReadFormAsync(ct);
        var files = form.Files.GetFiles("photos");
        if (files.Count > AppealEvidence.MaxPhotos) throw new ValidationException("photos", $"At most {AppealEvidence.MaxPhotos} photos.");
        var photos = new List<byte[]>(files.Count);
        foreach (var f in files)
        {
            if (f.Length > AppealEvidence.MaxBytes) throw new ApiCodeException(413, "photo_too_large", "Each photo is limited to 5 MB.");
            await using var s = f.OpenReadStream();
            using var ms = new MemoryStream((int)f.Length);
            await s.CopyToAsync(ms, ct);
            photos.Add(ms.ToArray());
        }
        // `reasons` is a repeated field; a single comma-separated value is accepted too.
        var reasons = form["reasons"].SelectMany(v => (v ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)).ToList();
        string? One(string name) => form.TryGetValue(name, out var v) && v.Count > 0 ? v[0] : null;
        return new AppealInput(One("refusalId"), One("kind"), One("placeId"), One("text"), reasons, One("note"), One("rating"), photos);
    }
}
