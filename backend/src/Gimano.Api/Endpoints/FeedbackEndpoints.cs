using Gimano.Api.Auth;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Messaging;
using Gimano.Core.Support;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Api.Endpoints;

public static class FeedbackEndpoints
{
    public const int MaxMessageLength = 2000;
    public const int MaxScreenshotBytes = 1_500_000;
    public const int MaxPerHour = 10;
    /// <summary>How long a feedback POST waits for the spam screen before it saves the feedback unflagged.</summary>
    public static readonly TimeSpan SpamScreenBudget = TimeSpan.FromSeconds(3);

    public static RouteGroupBuilder MapFeedback(this RouteGroupBuilder api)
    {
        // Anonymous users have a device token too, so authorisation is still required.
        api.MapPost("/feedback", Create).WithTags("Feedback").RequireAuthorization()
            .WithSummary("Send feedback (optionally with a screenshot ≤ 1.5 MB). 413 if too big, 429 above 10/hour.");
        api.MapGet("/me/feedback", Mine).WithTags("Feedback").RequireAuthorization();
        api.MapDelete("/feedback/{id:guid}/contact", DeleteContact).WithTags("Feedback").RequireAuthorization()
            .WithSummary("Withdraw the contact details given with this feedback (deleted immediately).");
        return api;
    }

    private static async Task<Results<Created<FeedbackCreatedResponse>, ValidationProblem, ProblemHttpResult>> Create(
        CreateFeedbackRequest req, HttpContext http, GimanoDbContext db, IEventPublisher bus, ContactCrypto crypto, TimeProvider clock,
        ILogger<CreateFeedbackRequest> log, Microsoft.Extensions.Caching.Memory.IMemoryCache cache, Gimano.Core.Community.ContentGate gate, CancellationToken ct)
    {
        if (Validate(req) is { } problem) return problem;
        var (device, location, routeId, placeId) = Normalize(req);

        byte[]? screenshot = null;
        string? contentType = null;
        if (!string.IsNullOrWhiteSpace(req.Screenshot))
        {
            switch (DecodeScreenshot(req.Screenshot))
            {
                case { Error: ScreenshotError.TooLarge }:
                    return TypedResults.Problem(statusCode: StatusCodes.Status413PayloadTooLarge, title: "Screenshot too large",
                        detail: $"Screenshots are limited to {MaxScreenshotBytes / 1_000_000.0:0.#} MB after decoding.");
                case { Error: ScreenshotError.Invalid }:
                    return Validation.Problem("screenshot", "screenshot must be a base64 PNG or JPEG image.");
                case var ok:
                    (screenshot, contentType) = (ok.Bytes, ok.ContentType);
                    break;
            }
        }

        var uid = http.User.RequiredUserId();
        if (!await db.Users.AnyAsync(u => u.Id == uid, ct)) throw new UnauthorizedAccessException("This account was deleted.");
        var now = clock.GetUtcNow();
        var withContact = WillStoreContact(crypto, req.Contact);
        var recent = await db.Feedback.CountAsync(f => f.UserId == uid && f.CreatedAt > now.AddHours(-1), ct)
                     + UnlinkedReports.Count(cache, "feedback", uid, now, TimeSpan.FromHours(1));
        if (recent >= MaxPerHour)
        {
            http.Response.Headers.RetryAfter = "3600";
            return TypedResults.Problem(statusCode: StatusCodes.Status429TooManyRequests, title: "Too much feedback",
                detail: $"At most {MaxPerHour} feedback messages per hour. Terima kasih!");
        }

        var message = req.Message.Trim();
        // Spam/abuse screen: only the message text goes to the model (never contact, device info or the user). It never blocks the feedback;
        // a "yes" only marks it for the maintainers. Off, budget used up, a failed call or a timeout: no flag, silently.
        var suspected = await gate.IsSuspectedSpamAsync(message, SpamScreenBudget, ct);

        var fb = new Feedback
        {
            // A report that carries a contact is not linked to the account (privacy rule: the contact is never linkable to
            // the pseudonym). The app withdraws it with the returned contactToken instead.
            UserId = withContact ? null : uid, Category = req.Category, Message = message, Rating = req.Rating, Screen = req.Screen, SuspectedSpam = suspected,
            Device = device, Lat = location?.Lat, Lng = location?.Lng, RouteId = routeId, PlaceId = placeId,
            Screenshot = screenshot, ScreenshotContentType = contentType, CreatedAt = now,
        };
        db.Feedback.Add(fb);
        StoreContact(db, crypto, ContactSubject.Feedback, fb.Id, req.Contact, now, log);
        await db.SaveChangesAsync(ct);
        if (withContact) UnlinkedReports.Add(cache, "feedback", uid, now, TimeSpan.FromHours(1));
        await bus.PublishAsync(RoutingKeys.FeedbackCreated, new FeedbackCreatedEvent(fb.Id, fb.Category, fb.CreatedAt), ct);
        return TypedResults.Created($"/api/v1/me/feedback/{fb.Id}", new FeedbackCreatedResponse(fb.Id, fb.CreatedAt,
            withContact ? crypto.WithdrawToken(ContactSubject.Feedback, fb.Id) : null));
    }

    private static async Task<Ok<List<FeedbackSummary>>> Mine(HttpContext http, GimanoDbContext db, CancellationToken ct)
    {
        var uid = http.User.RequiredUserId();
        var rows = await db.Feedback.AsNoTracking().Where(f => f.UserId == uid).OrderByDescending(f => f.CreatedAt).Take(100)
            .Select(f => new FeedbackSummary(f.Id, f.Category, f.Message, f.Status, f.CreatedAt,
                db.ReportContacts.Any(c => c.SubjectType == ContactSubject.Feedback && c.SubjectId == f.Id)))
            .ToListAsync(ct);
        return TypedResults.Ok(rows);
    }

    public const string ContactTokenHeader = "X-Contact-Token";

    /// <summary>Withdraw a contact: with the contactToken returned at creation (X-Contact-Token), or, for older feedback that is
    /// still linked to the account, as its author.</summary>
    private static async Task<Results<NoContent, NotFound>> DeleteContact(Guid id, HttpContext http, GimanoDbContext db, ContactCrypto crypto, CancellationToken ct)
    {
        var uid = http.User.RequiredUserId();
        var byToken = crypto.CheckWithdrawToken(ContactSubject.Feedback, id, http.Request.Headers[ContactTokenHeader].ToString());
        if (!byToken && !await db.Feedback.AnyAsync(f => f.Id == id && f.UserId == uid, ct)) return TypedResults.NotFound();
        await db.ReportContacts.Where(c => c.SubjectType == ContactSubject.Feedback && c.SubjectId == id).ExecuteDeleteAsync(ct);
        return TypedResults.NoContent();
    }

    /// <summary>True when <see cref="StoreContact"/> will store this contact (so the report must not carry the user id).</summary>
    internal static bool WillStoreContact(ContactCrypto crypto, ContactDetails? contact) =>
        contact is not null && crypto.Enabled && ContactCrypto.Normalize(contact) is { } c && (c.Email is not null || c.Whatsapp is not null);

    /// <summary>Encrypts and stages the volunteered contact (keyed by the report, never the user). Values are never logged.</summary>
    internal static void StoreContact(GimanoDbContext db, ContactCrypto crypto, ContactSubject type, Guid id, ContactDetails? contact, DateTimeOffset now, ILogger log)
    {
        if (contact is null) return;
        var c = ContactCrypto.Normalize(contact);
        if (c.Email is null && c.Whatsapp is null) return;
        if (!crypto.Enabled)
        {
            log.LogWarning("Contact details were offered on {Type} {Id} but Feedback:ContactKey is not configured; not stored", type, id);
            return;
        }
        db.ReportContacts.Add(crypto.Encrypt(type, id, c, now));
    }

    /// <summary>
    /// Maps the new device/location shape and the legacy 0.1.0 "context". Location is coarse only (2 dp, ≈ 1 km).
    /// </summary>
    internal static (DeviceInfo? Device, CoarseLocation? Location, string? RouteId, string? PlaceId) Normalize(CreateFeedbackRequest req)
    {
        var device = req.Device;
        CoarseLocation? location = req.Location;
        var routeId = req.RouteId;
        var placeId = req.PlaceId;
        if (req.Context is { } c)
        {
            device ??= c.AppVersion is null && c.Platform is null && c.OsVersion is null && c.DeviceModel is null && c.Locale is null
                ? null
                : new DeviceInfo(c.AppVersion, null, c.Platform, c.OsVersion, null, c.DeviceModel, null, null, c.Locale, null, null);
            if (location is null && c.Lat is { } la && c.Lng is { } lo) location = new CoarseLocation(la, lo);
            routeId ??= c.RouteId;
            placeId ??= c.PlaceId;
        }
        if (location is not null) location = new CoarseLocation(Math.Round(location.Lat, 2), Math.Round(location.Lng, 2));
        return (device, location, routeId, placeId);
    }

    internal static ValidationProblem? ValidateDevice(DeviceInfo? d, string field)
    {
        if (d is null) return null;
        var strings = new[] { d.AppVersion, d.Platform, d.OsVersion, d.DeviceModel, d.Manufacturer, d.Locale, d.Theme, d.DataMode };
        return strings.Any(v => v is { Length: > 100 }) ? Validation.Problem(field, $"{field} fields are max 100 chars.") : null;
    }

    internal static ValidationProblem? Validate(CreateFeedbackRequest req)
    {
        if (string.IsNullOrWhiteSpace(req.Message) || req.Message.Trim().Length > MaxMessageLength)
            return Validation.Problem("message", $"message is required (1–{MaxMessageLength} chars).");
        if (req.Rating is < 1 or > 5) return Validation.Problem("rating", "rating must be 1–5.");
        if (ContactCrypto.Validate(req.Contact) is { } contactError) return Validation.Problem("contact", contactError);
        if (ValidateDevice(req.Device, "device") is { } dp) return dp;
        if (req.Location is { } l && !Validation.ValidLatLng(l.Lat, l.Lng)) return Validation.Problem("location", "Invalid coordinates.");
        if (new[] { req.RouteId, req.PlaceId }.Any(v => v is { Length: > 64 })) return Validation.Problem("routeId", "ids are max 64 chars.");
        if (req.Context is { } c)
        {
            if (c.Lat is { } lat && c.Lng is { } lng && !Validation.ValidLatLng(lat, lng)) return Validation.Problem("context.lat", "Invalid coordinates.");
            if (new[] { c.AppVersion, c.Platform, c.OsVersion, c.DeviceModel, c.Locale, c.RouteId, c.PlaceId }.Any(v => v is { Length: > 100 }))
                return Validation.Problem("context", "context fields are max 100 chars.");
        }
        return null;
    }

    internal enum ScreenshotError { None, Invalid, TooLarge }

    internal readonly record struct DecodedScreenshot(ScreenshotError Error, byte[]? Bytes, string? ContentType);

    /// <summary>Accepts raw base64 or a data: URL; PNG or JPEG only; ≤ 1.5 MB decoded.</summary>
    internal static DecodedScreenshot DecodeScreenshot(string input)
    {
        var b64 = input.Trim();
        var comma = b64.IndexOf(',');
        if (b64.StartsWith("data:", StringComparison.OrdinalIgnoreCase) && comma > 0) b64 = b64[(comma + 1)..];
        // Cheap size check before decoding: 4 base64 chars → 3 bytes.
        if ((long)b64.Length * 3 / 4 > MaxScreenshotBytes + 3) return new(ScreenshotError.TooLarge, null, null);

        var buffer = new byte[b64.Length * 3 / 4 + 3];
        if (!Convert.TryFromBase64String(b64, buffer, out var n)) return new(ScreenshotError.Invalid, null, null);
        if (n > MaxScreenshotBytes) return new(ScreenshotError.TooLarge, null, null);
        var bytes = buffer.AsSpan(0, n).ToArray();

        string? type = bytes switch
        {
            [0x89, 0x50, 0x4E, 0x47, ..] => "image/png",
            [0xFF, 0xD8, 0xFF, ..] => "image/jpeg",
            _ => null,
        };
        return type is null ? new(ScreenshotError.Invalid, null, null) : new(ScreenshotError.None, bytes, type);
    }
}
