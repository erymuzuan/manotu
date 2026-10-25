using Gimano.Api.Services;
using Gimano.Core.Contracts;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;

namespace Gimano.Api;

/// <summary>Maps domain exceptions to RFC 7807 problem responses.</summary>
public sealed class ApiExceptionHandler(IProblemDetailsService problems, ILogger<ApiExceptionHandler> logger) : IExceptionHandler
{
    public async ValueTask<bool> TryHandleAsync(HttpContext http, Exception exception, CancellationToken ct)
    {
        if (exception is ValidationException ve)
        {
            http.Response.StatusCode = StatusCodes.Status400BadRequest;
            return await problems.TryWriteAsync(new ProblemDetailsContext
            {
                HttpContext = http,
                ProblemDetails = new HttpValidationProblemDetails(new Dictionary<string, string[]> { [ve.Field] = [ve.Message] })
                    { Status = 400, Title = "One or more validation errors occurred." },
            });
        }
        if (exception is DuplicatePlaceException dup)
        {
            http.Response.StatusCode = StatusCodes.Status409Conflict;
            var pd = new ProblemDetails { Status = 409, Title = "Similar place nearby", Detail = dup.Message };
            pd.Extensions["existing"] = dup.Existing;
            return await problems.TryWriteAsync(new ProblemDetailsContext { HttpContext = http, ProblemDetails = pd });
        }
        if (exception is RestrictedAreaException)
        {
            http.Response.StatusCode = StatusCodes.Status422UnprocessableEntity;
            var pd = new ProblemDetails
            {
                Status = 422, Title = "Restricted area",
                Detail = http.Lang() == Gimano.Core.Community.L10n.Ms
                    ? "Manotu tidak menerima tempat, gambar, ulasan atau laporan di kawasan tentera, keselamatan dan strategik."
                    : "Manotu doesn't accept places, photos, reviews or reports in military, security and strategic areas.",
            };
            pd.Extensions["code"] = "restricted_area";
            return await problems.TryWriteAsync(new ProblemDetailsContext { HttpContext = http, ProblemDetails = pd });
        }

        if (exception is AddingPausedException paused)
        {
            http.Response.StatusCode = StatusCodes.Status403Forbidden;
            var pd = new ProblemDetails { Status = 403, Title = "Adding paused", Detail = paused.Message };
            pd.Extensions["code"] = "adding_paused";
            pd.Extensions["pausedUntil"] = paused.Until;
            return await problems.TryWriteAsync(new ProblemDetailsContext { HttpContext = http, ProblemDetails = pd });
        }
        if (exception is RateLimitedException { RetryAfter: { } after } limited)
        {
            var seconds = (int)Math.Ceiling(Math.Max(1, after.TotalSeconds));
            http.Response.StatusCode = StatusCodes.Status429TooManyRequests;
            http.Response.Headers.RetryAfter = seconds.ToString(System.Globalization.CultureInfo.InvariantCulture);
            var pd = new ProblemDetails { Status = 429, Title = "Too many requests", Detail = limited.Message };
            pd.Extensions["retryAfterSeconds"] = seconds;
            return await problems.TryWriteAsync(new ProblemDetailsContext { HttpContext = http, ProblemDetails = pd });
        }

        var (status, title) = exception switch
        {
            RateLimitedException => (StatusCodes.Status429TooManyRequests, "Too many requests"),
            ForbiddenException => (StatusCodes.Status403Forbidden, "Forbidden"),
            UnsupportedMediaException => (StatusCodes.Status415UnsupportedMediaType, "Unsupported image format"),
            PayloadTooLargeException => (StatusCodes.Status413PayloadTooLarge, "Too large"),
            RoutingUnavailableException => (StatusCodes.Status503ServiceUnavailable, "Routing unavailable"),
            NoRouteException => (StatusCodes.Status422UnprocessableEntity, "No route found"),
            NotFoundException => (StatusCodes.Status404NotFound, "Not found"),
            ConflictException => (StatusCodes.Status409Conflict, "Conflict"),
            // Two requests raced: a row changed under us (xmin) or the same unique row was inserted twice (a double-tapped
            // vote). The client's request was fine; the state moved. 409 with a retryable message, not a logged 500.
            Microsoft.EntityFrameworkCore.DbUpdateConcurrencyException => (StatusCodes.Status409Conflict, "Conflict"),
            Microsoft.EntityFrameworkCore.DbUpdateException { InnerException: Npgsql.PostgresException { SqlState: Npgsql.PostgresErrorCodes.UniqueViolation } }
                => (StatusCodes.Status409Conflict, "Conflict"),
            UnauthorizedAccessException => (StatusCodes.Status401Unauthorized, "Unauthorized"),
            BadHttpRequestException b => (b.StatusCode, "Bad request"),
            _ => (StatusCodes.Status500InternalServerError, "Unexpected error"),
        };
        if (status >= 500 && exception is not RoutingUnavailableException)
            // Drop ids are half of a guest's event link: never in logs.
            logger.LogError(exception, "Unhandled exception for {Method} {Path}", http.Request.Method, Endpoints.DropEndpoints.LogSafePath(http.Request.Path));

        http.Response.StatusCode = status;
        if (status == StatusCodes.Status503ServiceUnavailable) http.Response.Headers.RetryAfter = "30";
        return await problems.TryWriteAsync(new ProblemDetailsContext
        {
            HttpContext = http,
            Exception = exception,
            ProblemDetails = new ProblemDetails
            {
                Status = status,
                Title = title,
                // Database exception messages can name tables/constraints: never echo them.
                Detail = status == 500 ? "An unexpected error occurred."
                    : exception is Microsoft.EntityFrameworkCore.DbUpdateException ? "This changed at the same time as your request; please try again."
                    : exception.Message,
            },
        });
    }
}
