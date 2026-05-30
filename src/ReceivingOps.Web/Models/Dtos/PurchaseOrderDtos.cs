namespace ReceivingOps.Web.Models.Dtos;

/// <summary>One row in GET /api/pos. Includes per-PO line summary.</summary>
public class PoListRow
{
    public Guid Id { get; set; }
    public string PoNumber { get; set; } = "";
    public Guid WarehouseId { get; set; }
    public string WarehouseCode { get; set; } = "";
    // Phase 14 (db/036): vendor lives on the PO line. The repo collapses
    // line-level values into a single PO-header summary — non-null iff every
    // line of the PO carries the same vendor; null when mixed or absent.
    // The list-row UI treats null as "Mixed / —".
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

    // db/033 — denormalized external pull reference (PRS_ID from Phase 12
    // import). Independent of PullId/FK. UI uses precedence:
    // PullNumber (FK link) > PullExternalRef (import) > "(none — pool)".
    public string? PullExternalRef { get; set; }
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

    // Phase 14 (db/036): vendor at the line level. The Phase 9.2 extended-fields
    // modal edits these via the Tracking section; the PoImportJob writes them
    // per row from the workbook's STORER CODE / STORER NAME columns.
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }

    // Phase 9 — ERP-sourced fields (migration db/021). All nullable; populated
    // by Phase 10's POST /api/erp/pos. The PO Detail UI surfaces 5 of these
    // (InvoiceNo, SubInventory, ToLocation, PalletId, VmiPalletId); the other
    // 15 are API + Excel-export only.
    public string? InvoiceNo { get; set; }
    public string? KanbanNo { get; set; }
    public string? AsnNo { get; set; }
    public string? OrderId { get; set; }            // Phase 12.1 (db/031) — C2=C split sibling of AsnNo (sales-order ref vs ASN ref)
    public string? PCCNo { get; set; }
    public string? BatchNo { get; set; }
    public string? ManufacturingControlNo { get; set; }
    public string? ManufacturingReferenceNo { get; set; }
    public string? CustomerReferenceNo { get; set; }
    public string? ExportDeclarationNo { get; set; }
    public string? VendorItem { get; set; }
    public string? PalletId { get; set; }
    public string? VmiPalletId { get; set; }
    public string? Location { get; set; }
    public string? Building { get; set; }
    public string? SubInventory { get; set; }
    public string? ToLocation { get; set; }
    public string? ProductionLine { get; set; }
    public string? OrderRound { get; set; }
    public DateTime? DeliveryDate { get; set; }
    public string? Note { get; set; }
}

/// <summary>GET /api/pos/{id}: header + lines + recent receipts referencing each line.</summary>
public class PoDetail
{
    public Guid Id { get; set; }
    public string PoNumber { get; set; } = "";
    public Guid WarehouseId { get; set; }
    public string WarehouseCode { get; set; } = "";
    public string WarehouseName { get; set; } = "";
    // Phase 14 (db/036): same line-level collapse as PoListRow — non-null
    // when every line agrees, null when mixed or unset. The PO Detail page
    // shows vendor at the line grid (line-level truth) and treats this
    // header summary as a courtesy hint.
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

    // db/033 — denormalized external pull reference (PRS_ID from Phase 12
    // import). Independent of PullId/FK. UI uses precedence:
    // PullNumber (FK link) > PullExternalRef (import) > "(none — pool)".
    public string? PullExternalRef { get; set; }

    public List<PoLineRow> Lines { get; set; } = new();
}

/// <summary>
/// Phase 9 — line-level export row. One row per PO line for the
/// PosExportJob "Lines" sheet, with PO header context inlined so the
/// XLSX is human-readable without cross-sheet lookups. Carries all 20
/// ERP-sourced fields from <see cref="PoLineRow"/> verbatim plus the
/// PO header bits operators need to identify which PO a line belongs
/// to (PoNumber, OrderDate, Vendor*, WarehouseCode, Status).
/// </summary>
public class PoLineExportRow
{
    // PO header context
    public Guid PurchaseOrderId { get; set; }
    public string PoNumber { get; set; } = "";
    public DateTime OrderDate { get; set; }
    public DateTime? ExpectedDate { get; set; }
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public string WarehouseCode { get; set; } = "";
    public string PoStatus { get; set; } = "open";

    // Line basic
    public Guid LineId { get; set; }
    public int LineNumber { get; set; }
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public int OrderedQty { get; set; }
    public int ReceivedQty { get; set; }
    public int RemainingQty { get; set; }

    // ERP-sourced — Tracking IDs (11; +OrderId from Phase 12.1 db/031, C2=C split)
    public string? InvoiceNo { get; set; }
    public string? KanbanNo { get; set; }
    public string? AsnNo { get; set; }
    public string? OrderId { get; set; }
    public string? PCCNo { get; set; }
    public string? BatchNo { get; set; }
    public string? ManufacturingControlNo { get; set; }
    public string? ManufacturingReferenceNo { get; set; }
    public string? CustomerReferenceNo { get; set; }
    public string? ExportDeclarationNo { get; set; }
    public string? VendorItem { get; set; }

    // ERP-sourced — Location (6)
    public string? PalletId { get; set; }
    public string? VmiPalletId { get; set; }
    public string? Location { get; set; }
    public string? Building { get; set; }
    public string? SubInventory { get; set; }
    public string? ToLocation { get; set; }

    // ERP-sourced — Operations (2)
    public string? ProductionLine { get; set; }
    public string? OrderRound { get; set; }

    // ERP-sourced — Dates (1)
    public DateTime? DeliveryDate { get; set; }

    // ERP-sourced — Note (1)
    public string? Note { get; set; }
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

    // Phase 14 (db/036): vendor at line grain. Optional — UI may leave both
    // blank when the operator doesn't know; the importer fills them from the
    // workbook's STORER columns.
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
}

public class PoUpdateRequest
{
    // Refused (§7.13) if any receipt references this PO.
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

/// <summary>
/// Phase 9.2 — PUT /api/pos/{id}/lines/{lineId}/extended-fields body.
/// Bulk overwrite of the 20 ERP-sourced metadata fields on a single
/// PurchaseOrderLine. Mirror of <see cref="PullItemExtendedFieldsUpdateRequest"/>
/// for the PO side. Blanks from the UI coerce to null at the service so
/// the column NULL's out (not stored as empty string — keeps the Phase 10
/// ERP-vs-Receivx value comparison clean). Refused with 409 if the parent
/// PO is closed/canceled (mirror of Pull's closed-pull refusal in §9.1).
/// PO-immutability fields (OrderedQty, ItemCode, Description) and Receivx-
/// owned fields (ReceivedQty, ReceivedAt) are intentionally absent.
/// </summary>
public class PoLineExtendedFieldsUpdateRequest
{
    // Tracking IDs (Phase 14 added VendorCode + VendorName at the top of this
    // group — they're conceptually the line's owning vendor, displayed first
    // so the operator sees who shipped the part before scanning supporting IDs).
    public string? VendorCode { get; set; }
    public string? VendorName { get; set; }
    public string? OrderId { get; set; }
    public string? AsnNo { get; set; }
    public string? KanbanNo { get; set; }
    public string? VendorItem { get; set; }

    // Location
    public string? Location { get; set; }
    public string? SubInventory { get; set; }
    public string? ToLocation { get; set; }
    public string? Building { get; set; }
    public string? ProductionLine { get; set; }

    // Pallets
    public string? PalletId { get; set; }
    public string? VmiPalletId { get; set; }
    public string? BatchNo { get; set; }

    // References
    public string? InvoiceNo { get; set; }
    public string? PCCNo { get; set; }
    public string? ManufacturingControlNo { get; set; }
    public string? OrderRound { get; set; }

    // Special
    public string? ExportDeclarationNo { get; set; }
    public string? CustomerReferenceNo { get; set; }
    public string? ManufacturingReferenceNo { get; set; }

    // Notes
    public string? Note { get; set; }
}
