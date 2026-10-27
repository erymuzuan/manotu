namespace Gimano.Core.Contracts;

// Domain exceptions shared by the API (mapped to problem+json by ApiExceptionHandler) and the back office.

/// <summary>400 with the offending field.</summary>
public sealed class ValidationException(string field, string message) : Exception(message)
{
    public string Field { get; } = field;
}

/// <summary>404.</summary>
public sealed class NotFoundException(string message) : Exception(message);

/// <summary>409.</summary>
public sealed class ConflictException(string message) : Exception(message);

/// <summary>403: authenticated, but not allowed.</summary>
public sealed class ForbiddenException(string message) : Exception(message);

/// <summary>403 <c>adding_paused</c>: new places are paused until <see cref="Until"/> (3 not accepted in 24 h, or a 7-day suspension).</summary>
public sealed class AddingPausedException(DateTimeOffset until, string message) : Exception(message)
{
    public DateTimeOffset Until { get; } = until;
}

/// <summary>403 <c>posting_paused</c>: reviews, photos and notes are paused until <see cref="Until"/> (3 rejections in 24 h).</summary>
public sealed class PostingPausedException(DateTimeOffset until, string message) : Exception(message)
{
    public DateTimeOffset Until { get; } = until;
}

/// <summary>422 <c>content_rejected</c>: the content check didn't accept the text. Nothing is stored; <see cref="SafeText"/> is the text without the offending part.</summary>
public sealed class ContentRejectedException(IReadOnlyList<string> reasons, string? safeText) : Exception("This content isn't accepted.")
{
    public IReadOnlyList<string> Reasons { get; } = reasons;
    public string? SafeText { get; } = safeText;
}

/// <summary>A refusal with a machine-readable <c>code</c> in the problem+json (appeals: <c>note_required</c> 400, <c>already_appealed</c> 409).</summary>
public sealed class ApiCodeException(int status, string code, string message) : Exception(message)
{
    public int Status { get; } = status;
    public string Code { get; } = code;
}
