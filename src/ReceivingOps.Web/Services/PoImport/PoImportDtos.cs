namespace ReceivingOps.Web.Services.PoImport;

// ---------------------------------------------------------------------------
// Phase 12.2 — DTOs for the Excel parser. Mirror the ErpSync drafts pattern:
// POCOs only, no annotations, no FluentValidation. Validation happens inside
// the parser (per-row, recorded in ValidationErrors) and again at the
// atomic-insert boundary in 12.4 (DB-level duplicate detection).
//
// Row-level model rather than header+lines because the source spreadsheet
// is flat (one row per PurchaseOrderLine, with PO-header fields like
// VendorCode/VendorName repeated on every row of the same PoNumber).
// The Hangfire job in 12.4 groups by PoNumber for the upsert.
// ---------------------------------------------------------------------------

/// <summary>
/// Outcome of <see cref="IPoImportReader.ParseAsync"/>. When
/// <see cref="IsValid"/> is false, <see cref="Rows"/> may still be populated
/// — callers should not consume Rows if ValidationErrors is non-empty
/// (Q3=A: atomic — any row error voids the whole import).
/// </summary>
public class PoImportParseResult
{
    /// <summary>Total non-empty data rows the parser attempted (valid + invalid).</summary>
    public int TotalRows { get; set; }

    /// <summary>Successfully-parsed rows. Only consumed by 12.4 when <see cref="IsValid"/>.</summary>
    public List<PoImportRow> Rows { get; set; } = new();

    /// <summary>Per-row + structural validation issues. Empty when <see cref="IsValid"/>.</summary>
    public List<PoImportValidationError> ValidationErrors { get; set; } = new();

    public bool IsValid => ValidationErrors.Count == 0;
}

/// <summary>
/// One row from the Excel sheet. Field names match
/// <c>dbo.PurchaseOrderLines</c> columns 1:1 except for <see cref="PoNumber"/>
/// (which is the PRS_ID per Q1=B — same value lands in both
/// PurchaseOrders.PoNumber and PurchaseOrders.PullId) and the two
/// vendor fields (PO-header, denormalized onto every row).
/// </summary>
public class PoImportRow
{
    /// <summary>Excel row number (1-based, matches what the user sees). Used in error reports.</summary>
    public int RowNumber { get; set; }

    // PO header (denormalized per source row)
    public string PoNumber { get; set; } = "";       // PULL SHEET ID / PRS NO  (also fills PullId)
    public string? VendorCode { get; set; }          // STORER CODE
    public string? VendorName { get; set; }          // STORER NAME

    // Line basics
    public string ItemCode { get; set; } = "";       // SKU
    public string? Description { get; set; }         // SKU DESCRIPTION
    public int OrderedQty { get; set; }              // OPEN QTY
    public DateTime? DeliveryDate { get; set; }      // DELIVERY DATE  (ORDER DATE ignored per C4=A)

    // Tracking IDs
    public string? OrderId { get; set; }             // ORDER ID            (db/031, kept separately per C2=C)
    public string? AsnNo { get; set; }               // ASN NO              (db/021, kept separately per C2=C)
    public string? InvoiceNo { get; set; }           // INVOICE
    public string? KanbanNo { get; set; }            // KANBAN NO
    public string? PCCNo { get; set; }               // PCC NO
    public string? BatchNo { get; set; }             // BATCH / LOT NO
    public string? ManufacturingControlNo { get; set; }    // MANUFACTURING CTRL NO
    public string? ManufacturingReferenceNo { get; set; }  // MANUFACTURING REF
    public string? CustomerReferenceNo { get; set; }       // CUSTOMER REFERENCE
    public string? ExportDeclarationNo { get; set; }       // Export Deceleration No  (sic — header spelling matches source)
    public string? VendorItem { get; set; }                // VENDOR SKU

    // Location
    public string? PalletId { get; set; }            // PALLET ID (uppercase wins per C3=A; "Pallet ID" ignored)
    public string? VmiPalletId { get; set; }         // VMI PALLET ID
    public string? Location { get; set; }            // LOCATION
    public string? Building { get; set; }            // BUILDING
    public string? SubInventory { get; set; }        // SUB INVENTORY
    public string? ToLocation { get; set; }          // TO LOCATION

    // Operations + free text
    public string? ProductionLine { get; set; }      // PRODUCTION LINE
    public string? OrderRound { get; set; }          // ROUND
    public string? Note { get; set; }                // NOTES
}

/// <summary>
/// One validation issue. <see cref="RowNumber"/> is 0 for structural
/// issues (missing required header, no data sheet, wrong extension);
/// non-zero for per-row issues. Surfaced to the operator on the
/// pre-flight modal in 12.5 (first 50 shown, the rest hinted at).
/// </summary>
public class PoImportValidationError
{
    /// <summary>Excel row number (1-based) or 0 for structural issues.</summary>
    public int RowNumber { get; set; }

    /// <summary>Source column header (Excel display name) or empty for whole-row / structural issues.</summary>
    public string Column { get; set; } = "";

    /// <summary>Human-readable explanation surfaced directly to the operator.</summary>
    public string Message { get; set; } = "";
}
