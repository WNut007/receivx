namespace ReceivingOps.Web.Models.Dtos;

/// <summary>One row in GET /api/pos. Includes per-PO line summary.</summary>
public class PoListRow
{
    public Guid Id { get; set; }
    public string PoNumber { get; set; } = "";
    public Guid WarehouseId { get; set; }
    public string WarehouseCode { get; set; } = "";
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public DateTime OrderDate { get; set; }
    public DateTime? ExpectedDate { get; set; }
    public string Status { get; set; } = "open";   // open|closed|canceled
    public DateTime CreatedAt { get; set; }
    public DateTime? ClosedAt { get; set; }

    public int LineCount { get; set; }
    public int TotalOrdered { get; set; }
    public int TotalReceived { get; set; }

    // §3.5 — optional pull link. Both NULL when PO is in the cross-pull pool.
    public Guid? PullId { get; set; }
    public string? PullNumber { get; set; }
}

/// <summary>One PO line, used inside PoDetail and as a stand-alone summary row.</summary>
public class PoLineRow
{
    public Guid Id { get; set; }
    public Guid PurchaseOrderId { get; set; }
    public int LineNumber { get; set; }
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public int OrderedQty { get; set; }
    public int ReceivedQty { get; set; }
    public int RemainingQty { get; set; }    // OrderedQty - ReceivedQty
}

/// <summary>GET /api/pos/{id}: header + lines + recent receipts referencing each line.</summary>
public class PoDetail
{
    public Guid Id { get; set; }
    public string PoNumber { get; set; } = "";
    public Guid WarehouseId { get; set; }
    public string WarehouseCode { get; set; } = "";
    public string WarehouseName { get; set; } = "";
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public DateTime OrderDate { get; set; }
    public DateTime? ExpectedDate { get; set; }
    public string Status { get; set; } = "open";
    public string? Notes { get; set; }
    public Guid? CreatedBy { get; set; }
    public string? CreatedByName { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime? ClosedAt { get; set; }

    // §3.5 — optional pull link. Both NULL when PO is in the cross-pull pool.
    public Guid? PullId { get; set; }
    public string? PullNumber { get; set; }

    public List<PoLineRow> Lines { get; set; } = new();
}

/// <summary>One row from vw_PurchaseOrderAvailability — FIFO-ordered open lines.</summary>
public class PoAvailabilityRow
{
    public Guid PurchaseOrderLineId { get; set; }
    public Guid PurchaseOrderId { get; set; }
    public string PoNumber { get; set; } = "";
    public Guid WarehouseId { get; set; }
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public DateTime OrderDate { get; set; }
    public string PoStatus { get; set; } = "open";
    public int LineNumber { get; set; }
    public string ItemCode { get; set; } = "";
    public int OrderedQty { get; set; }
    public int ReceivedQty { get; set; }
    public int RemainingQty { get; set; }
}

// ---- Write DTOs (used by Phase 4 service layer; declared here so controllers
// can reference them in Phase 3 if needed) ----

public class PoCreateRequest
{
    public string PoNumber { get; set; } = "";
    public Guid WarehouseId { get; set; }
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public DateTime OrderDate { get; set; }
    public DateTime? ExpectedDate { get; set; }
    public string? Notes { get; set; }
    public List<PoLineCreateRequest> Lines { get; set; } = new();

    // §3.5 — optional link. When set, validated at create:
    //   pull must exist, status != 'closed', and pull.WarehouseId must match req.WarehouseId.
    // Immutable after create — PUT will refuse any change including NULL ↔ value transitions.
    public Guid? PullId { get; set; }
}

public class PoLineCreateRequest
{
    public int LineNumber { get; set; }     // 1, 2, 3... within the PO
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public int OrderedQty { get; set; }
}

public class PoUpdateRequest
{
    // Refused (§7.13) if any receipt references this PO.
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public DateTime OrderDate { get; set; }
    public DateTime? ExpectedDate { get; set; }
    public string? Notes { get; set; }

    // §3.5 — immutable. Clients MUST echo the current value (or NULL if the PO is unlinked).
    // Any mismatch — including NULL→value or value→NULL — triggers a 409, even on POs that
    // have no receipts (the PullId rule is stricter than the §7.13 receipt-reference rule).
    public Guid? PullId { get; set; }
}

public class PoCloseRequest
{
    public string Reason { get; set; } = "";   // mandatory; audit captures it
}
