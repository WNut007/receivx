namespace ReceivingOps.Web.Models;

/// <summary>
/// Phase 8.2 — model for the shared <c>_Pagination.cshtml</c> partial.
/// Page/PageSize/Total mirror <see cref="PaginatedResponse{T}"/>; BaseQuery
/// carries the current URL query string (minus any existing <c>page=</c>)
/// so each rendered link preserves filters / search across navigation.
/// </summary>
public class PaginationPartialModel
{
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 50;
    public int Total { get; set; }

    /// <summary>e.g. <c>?dateRange=last_2_days&amp;warehouse=WH-01</c> — partial appends/replaces <c>page=N</c>.</summary>
    public string? BaseQuery { get; set; }

    /// <summary>Caption suffix in "Page X of Y · N <i>records</i>". Defaults to "records".</summary>
    public string? Label { get; set; }

    /// <summary>Window size before ellipsis collapse. Default 7.</summary>
    public int MaxButtons { get; set; }
}
