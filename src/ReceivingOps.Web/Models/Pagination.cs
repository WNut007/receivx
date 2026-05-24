namespace ReceivingOps.Web.Models;

/// <summary>
/// Phase 8.1 — shared pagination contract for list endpoints.
///
/// 1-based <see cref="Page"/> (operator-facing) + computed 0-based
/// <see cref="Skip"/> (SQL-facing). Hard cap at 500 rows per page even
/// if the caller passes more — the existing /api/transactions endpoint
/// already enforces the same cap so the cross-page limit is uniform.
/// </summary>
public class PaginatedRequest
{
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 50;

    /// <summary>0-based row offset for SQL OFFSET clause.</summary>
    public int Skip => Math.Max(0, (Math.Max(1, Page) - 1) * Take);

    /// <summary>Clamped page size — caller can't bypass the 500-row ceiling.</summary>
    public int Take => Math.Clamp(PageSize, 1, 500);
}

/// <summary>
/// Generic page envelope. Total is the unfiltered-by-paging row count
/// so the UI can render "X-Y of Z" + page navigation. TotalPages +
/// HasMore are computed properties — clients don't need to derive them.
/// </summary>
public class PaginatedResponse<T>
{
    public IReadOnlyList<T> Items { get; set; } = Array.Empty<T>();
    public int Page { get; set; }
    public int PageSize { get; set; }
    public int Total { get; set; }
    public int TotalPages => PageSize <= 0 ? 0 : (int)Math.Ceiling((double)Total / PageSize);
    public bool HasMore => Page < TotalPages;
}
