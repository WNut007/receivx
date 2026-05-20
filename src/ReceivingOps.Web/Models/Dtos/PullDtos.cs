namespace ReceivingOps.Web.Models.Dtos;

/// <summary>Pull summary for the dashboard card. Merges Pulls row + vw_PullProgress totals + counts.</summary>
public class PullSummary
{
    public Guid Id { get; set; }
    public string PullNumber { get; set; } = "";
    public Guid WarehouseId { get; set; }
    public string WarehouseCode { get; set; } = "";
    public string WarehouseName { get; set; } = "";
    public DateTime PullDate { get; set; }
    public string Status { get; set; } = "pending";
    public string? Eta { get; set; }
    public string? Notes { get; set; }                  // mockup uses this as a tag (urgent|late|...)
    public string? CreatedByName { get; set; }
    public DateTime? FirstReceiptAt { get; set; }
    public DateTime? LastActivityAt { get; set; }
    public DateTime? ClosedAt { get; set; }
    public string? ClosedByName { get; set; }
    public bool IsReopened { get; set; }

    public int TotalExpected { get; set; }
    public int TotalReceived { get; set; }
    public int ItemCount { get; set; }
    public int CanceledCount { get; set; }
    public int NewCount { get; set; }
    public int WindowsTotal { get; set; }
    public int WindowsPending { get; set; }
}

public class PullDetail : PullSummary
{
    public List<PullItemDto> Items { get; set; } = new();
}

public class PullItemDto
{
    public Guid Id { get; set; }
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public string? Tag { get; set; }
    public string Status { get; set; } = "normal";
    public string? Remark { get; set; }
    public int SortOrder { get; set; }
    public List<PullItemWindowDto> Windows { get; set; } = new();
}

public class PullItemWindowDto
{
    public byte HourOfDay { get; set; }
    public int ExpectedQty { get; set; }
    public int ReceivedQty { get; set; }
}

/// <summary>Query parameters for /api/pulls.</summary>
public record PullQuery(
    Guid? WarehouseId,
    DateOnly? DateFrom,
    DateOnly? DateTo,
    string? Status,
    string? Q);

/// <summary>POST /api/pulls/{id}/close body (§7.4). SignatureSvg is the base64-encoded canvas image; max 200 KB.</summary>
public class CloseRequest
{
    public string SignatureSvg { get; set; } = "";
}

public class CloseResult
{
    public Guid PullId { get; set; }
    public DateTime ClosedAt { get; set; }
    public int TotalReceived { get; set; }
}

/// <summary>POST /api/pulls/{id}/reopen body (§7.5). Reason is required; max 500 chars after trim.</summary>
public class ReopenRequest
{
    public string Reason { get; set; } = "";
}

public class ReopenResult
{
    public Guid PullId { get; set; }
    public DateTime ReopenedAt { get; set; }
}
