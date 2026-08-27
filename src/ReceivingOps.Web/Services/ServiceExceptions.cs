namespace ReceivingOps.Web.Services;

/// <summary>Domain rule violated (cap-at-expected, pull closed, already voided, etc.). Maps to HTTP 409.</summary>
/// <remarks>
/// db/047 — <see cref="Code"/> is an optional machine-readable error code surfaced by the
/// controllers as <c>ProblemDetails.Extensions["code"]</c>. Additive: the existing
/// single-argument constructor leaves it null and every current caller keeps working,
/// so no existing response shape changes.
/// </remarks>
public class BusinessException : Exception
{
    public string? Code { get; }

    public BusinessException(string message) : base(message) { }
    public BusinessException(string message, string code) : base(message) => Code = code;
}

/// <summary>Target entity does not exist. Maps to HTTP 404.</summary>
public class NotFoundException : Exception
{
    public NotFoundException(string message) : base(message) { }
}

/// <summary>Caller authenticated but not authorized for the resource (e.g. wrong warehouse). Maps to HTTP 403.</summary>
public class ForbiddenException : Exception
{
    public ForbiddenException(string message) : base(message) { }
}

/// <summary>Request body too large (e.g. close signature). Maps to HTTP 413.</summary>
public class PayloadTooLargeException : Exception
{
    public PayloadTooLargeException(string message) : base(message) { }
}

/// <summary>Input shape is invalid (out-of-range qty, malformed param). Maps to HTTP 400.</summary>
/// <remarks>db/047 — see <see cref="BusinessException.Code"/> for the code contract.</remarks>
public class ValidationException : Exception
{
    public string? Code { get; }

    public ValidationException(string message) : base(message) { }
    public ValidationException(string message, string code) : base(message) => Code = code;
}
