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
