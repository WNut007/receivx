namespace ReceivingOps.Web.Services;

/// <summary>Domain rule violated (cap-at-expected, pull closed, already voided, etc.). Maps to HTTP 409.</summary>
public class BusinessException : Exception
{
    public BusinessException(string message) : base(message) { }
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
