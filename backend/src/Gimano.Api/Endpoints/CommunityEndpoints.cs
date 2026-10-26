using Gimano.Api.Auth;
using Gimano.Api.Services;
using Gimano.Api.Identity;
using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.AspNetCore.Mvc;

namespace Gimano.Api.Endpoints;

/// <summary>Community places, reviews, photos and the public media endpoint (docs/api.md).</summary>
public static class CommunityEndpoints
{
    public const long MaxUploadBytes = ImageProcessor.MaxBytes + 512 * 1024; // file + multipart overhead

    public static RouteGroupBuilder MapCommunity(this RouteGroupBuilder api)
    {
        var places = api.MapGroup("/places").WithTags("Community places").RequireAuthorization();
        places.MapGet("/pending-nearby", PendingNearby).WithSummary("Pending places in a geohash-6 cell and its 8 neighbours (excludes your own).");
        places.MapPost("", CreatePlace).RequireSignature().WithSummary("Add a missing place (always public: pending → published after 3 confirmations). 409 if a similar place exists within 100 m.");
        places.MapPatch("/{id}", PatchPlace).RequireSignature().WithSummary("Owner only, community places only. A changed place is checked again.");
        places.MapPost("/{id}/appeal", AppealPlace).RequireSignature()
            .WithSummary("Owner only: ask a maintainer to review a place the AI check didn't accept (once per place; note ≤ 200 chars).");
        places.MapDelete("/{id}", DeletePlace).WithSummary("Owner only; published places become closed.");
        places.MapPost("/{id}/suggest-edit", SuggestEdit).RequireSignature();
        places.MapPost("/{id}/verify", Verify).RequireSignature();
        places.MapGet("/{id}/reviews", ListReviews).AllowAnonymous();
        places.MapPost("/{id}/reviews", CreateReview).RequireSignature();
        places.MapGet("/{id}/photos", ListPhotos).AllowAnonymous();
        places.MapPost("/{id}/flag", FlagPlace).WithSummary("Report a community place (spam, offensive, …). 3 reports hide it pending moderation.");

        api.MapGet("/me/places/contributed", Contributed).WithTags("Community places").RequireAuthorization();

        var reviews = api.MapGroup("/reviews").WithTags("Reviews").RequireAuthorization();
        reviews.MapPatch("/{id:guid}", PatchReview).RequireSignature();
        reviews.MapDelete("/{id:guid}", DeleteReview).RequireSignature();
        reviews.MapPost("/{id:guid}/appeal", AppealReview).RequireSignature()
            .WithSummary("Author only: ask a maintainer to review a review the content check didn't accept (once per review; note ≤ 200 chars).");
        reviews.MapPost("/{id:guid}/helpful", Helpful);
        reviews.MapPost("/{id:guid}/flag", FlagReview);

        var photos = api.MapGroup("/photos").WithTags("Photos").RequireAuthorization();
        photos.MapPost("", Upload).RequireSignature().DisableAntiforgery().WithMetadata(new RequestSizeLimitAttribute(MaxUploadBytes))
            .WithSummary("multipart/form-data: file (JPEG/PNG/WebP, ≤ 15 MB), placeId, caption?. 415 for HEIC/undecodable.");
        photos.MapGet("/{id:guid}", GetPhoto).AllowAnonymous();
        photos.MapPost("/{id:guid}/appeal", AppealPhoto).RequireSignature()
            .WithSummary("Uploader only: ask a maintainer to review a photo the content check didn't accept (once per photo; note ≤ 200 chars).");
        photos.MapDelete("/{id:guid}", DeletePhoto);
        photos.MapPost("/{id:guid}/flag", FlagPhoto);
        return api;
    }

    /// <summary>GET /media/{key}.webp — public, immutable (content-addressed).</summary>
    public static void MapMedia(this IEndpointRouteBuilder app) =>
        app.MapGet("/media/{file}", async (string file, IMediaStore media, HttpContext http, CancellationToken ct) =>
        {
            if (!file.EndsWith(".webp", StringComparison.Ordinal) || !MediaKeys.IsValidHash(file[..^5])) return Results.NotFound();
            var bytes = await media.GetAsync(file, ct);
            if (bytes is null) return Results.NotFound();
            http.Response.Headers.CacheControl = "public, max-age=31536000, immutable";
            http.Response.Headers.ETag = $"\"{file[..^5]}\"";
            return Results.File(bytes, "image/webp");
        }).WithTags("Photos").AllowAnonymous().ExcludeFromDescription();

    private static async Task<Created<PlaceDto>> CreatePlace(CreatePlaceRequest req, HttpContext http, CommunityService svc, CancellationToken ct)
    {
        if (!Validation.ValidLatLng(req.Lat, req.Lng)) throw new ValidationException("lat", "lat/lng must be valid WGS84 coordinates.");
        var p = await svc.CreateAsync(http.User.RequiredUserId(), req, ct);
        return TypedResults.Created($"/api/v1/places/{p.Id}", p);
    }

    private static async Task<Ok<PlaceDto>> PatchPlace(string id, PatchCommunityPlaceRequest req, HttpContext http, CommunityService svc, CancellationToken ct) =>
        TypedResults.Ok(await svc.PatchAsync(http.User.RequiredUserId(), id, req, ct));

    private static async Task<Ok<PlaceDto>> AppealPlace(string id, AppealPlaceRequest req, HttpContext http, CommunityService svc, CancellationToken ct) =>
        TypedResults.Ok(await svc.AppealAsync(http.User.RequiredUserId(), id, req, ct));

    private static async Task<NoContent> DeletePlace(string id, HttpContext http, CommunityService svc, CancellationToken ct)
    {
        await svc.DeleteAsync(http.User.RequiredUserId(), id, ct);
        return TypedResults.NoContent();
    }

    private static async Task<Accepted<SuggestionAccepted>> SuggestEdit(string id, SuggestEditRequest req, HttpContext http, CommunityService svc, CancellationToken ct) =>
        TypedResults.Accepted((string?)null, new SuggestionAccepted(await svc.SuggestEditAsync(http.User.RequiredUserId(), id, req, ct)));

    private static async Task<Ok<VerifyResult>> Verify(string id, VerifyPlaceRequest req, HttpContext http, CommunityService svc,
        AttestationService attestation, TimeProvider clock, CancellationToken ct)
    {
        var uid = http.User.RequiredUserId();
        var ts = long.TryParse(http.Request.Headers["X-Gimano-Ts"], out var t) ? t : clock.GetUtcNow().ToUnixTimeSeconds();
        var verdict = await attestation.VerifyVoteAsync(uid, req.Attestation, id, ts, ct);
        return TypedResults.Ok(await svc.VerifyAsync(uid, id, req, verdict, ct));
    }

    private static async Task<Ok<List<PlaceSummary>>> PendingNearby(string? cell, HttpContext http, CommunityService svc, CancellationToken ct) =>
        TypedResults.Ok((await svc.PendingNearbyAsync(http.User.RequiredUserId(), cell ?? "", ct)).ToList());

    private static async Task<Ok<List<PlaceSummary>>> Contributed(HttpContext http, CommunityService svc, CancellationToken ct) =>
        TypedResults.Ok((await svc.ContributedAsync(http.User.RequiredUserId(), ct)).ToList());

    private static async Task<Ok<ReviewsPage>> ListReviews(string id, string? sort, string? cursor, HttpContext http, ReviewService svc, CancellationToken ct)
    {
        var s = GimanoJson.TryParseWire<ReviewSort>(sort, out var parsed) ? parsed : ReviewSort.Recent;
        return TypedResults.Ok(await svc.ListAsync(id, s, cursor, ct, http.User.UserId()));
    }

    private static async Task<Created<ReviewDto>> CreateReview(string id, CreateReviewRequest req, HttpContext http, ReviewService svc, CancellationToken ct)
    {
        var r = await svc.CreateAsync(http.User.RequiredUserId(), id, req, ct);
        return TypedResults.Created($"/api/v1/reviews/{r.Id}", r);
    }

    private static async Task<Ok<ReviewDto>> PatchReview(Guid id, PatchReviewRequest req, HttpContext http, ReviewService svc, CancellationToken ct) =>
        TypedResults.Ok(await svc.PatchAsync(http.User.RequiredUserId(), id, req, ct));

    private static async Task<Accepted> AppealReview(Guid id, AppealContentRequest req, HttpContext http, ReviewService svc, CancellationToken ct)
    {
        await svc.AppealAsync(http.User.RequiredUserId(), id, req.Note, ct);
        return TypedResults.Accepted((string?)null);
    }

    private static async Task<Accepted> AppealPhoto(Guid id, AppealContentRequest req, HttpContext http, PhotoService svc, CancellationToken ct)
    {
        await svc.AppealAsync(http.User.RequiredUserId(), id, req.Note, ct);
        return TypedResults.Accepted((string?)null);
    }

    private static async Task<NoContent> DeleteReview(Guid id, HttpContext http, ReviewService svc, CancellationToken ct)
    {
        await svc.DeleteAsync(http.User.RequiredUserId(), id, ct);
        return TypedResults.NoContent();
    }

    private static async Task<NoContent> Helpful(Guid id, HttpContext http, ReviewService svc, CancellationToken ct)
    {
        await svc.ToggleHelpfulAsync(http.User.RequiredUserId(), id, ct);
        return TypedResults.NoContent();
    }

    private static async Task<Accepted> FlagPlace(string id, FlagRequest req, HttpContext http, CommunityService svc, CancellationToken ct)
    {
        await svc.FlagAsync(http.User.RequiredUserId(), id, req.Reason, ct);
        return TypedResults.Accepted((string?)null);
    }

    private static async Task<Accepted> FlagReview(Guid id, FlagRequest req, HttpContext http, ReviewService svc, CancellationToken ct)
    {
        await svc.FlagAsync(http.User.RequiredUserId(), id, req.Reason, ct);
        return TypedResults.Accepted((string?)null);
    }

    private static async Task<Created<PhotoDto>> Upload(HttpContext http, PhotoService svc, CancellationToken ct)
    {
        if (!http.Request.HasFormContentType) throw new ValidationException("file", "Use multipart/form-data with file, placeId and optional caption.");
        var form = await http.Request.ReadFormAsync(ct);
        var file = form.Files.GetFile("file") ?? throw new ValidationException("file", "file is required.");
        var placeId = form["placeId"].ToString();
        if (string.IsNullOrWhiteSpace(placeId)) throw new ValidationException("placeId", "placeId is required.");
        var caption = form["caption"].ToString();
        var photo = await svc.UploadAsync(http.User.RequiredUserId(), placeId, file, string.IsNullOrWhiteSpace(caption) ? null : caption, ct);
        return TypedResults.Created($"/api/v1/photos/{photo.Id}", photo);
    }

    private static async Task<Ok<PhotosPage>> ListPhotos(string id, string? cursor, PhotoService svc, CancellationToken ct) =>
        TypedResults.Ok(await svc.ListAsync(id, cursor, ct));

    private static async Task<Ok<PhotoDto>> GetPhoto(Guid id, HttpContext http, PhotoService svc, CancellationToken ct) =>
        TypedResults.Ok(await svc.GetAsync(id, ct, http.User.UserId()));

    private static async Task<NoContent> DeletePhoto(Guid id, HttpContext http, PhotoService svc, CancellationToken ct)
    {
        await svc.DeleteAsync(http.User.RequiredUserId(), id, ct);
        return TypedResults.NoContent();
    }

    private static async Task<Accepted> FlagPhoto(Guid id, FlagRequest req, HttpContext http, PhotoService svc, CancellationToken ct)
    {
        await svc.FlagAsync(http.User.RequiredUserId(), id, req.Reason, ct);
        return TypedResults.Accepted((string?)null);
    }
}
