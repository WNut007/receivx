namespace ReceivingOps.Web.Services.ErpSync;

// ---------------------------------------------------------------------------
// Phase 10.2 — in-memory transform shape. The ETL service reads BPI_PRS
// rows and projects them into the Draft graph below. 10.3 will consume
// this graph to upsert into Pulls / PullItems / PullItemWindows.
//
// Drafts are deliberately POCOs (no FluentValidation, no DataAnnotations).
// Validation happens at the upsert boundary in 10.3 — the transform is
// best-effort and surfaces all rows so the upsert can decide what to skip.
// ---------------------------------------------------------------------------

/// <summary>
/// Top-level draft for one ETL run. <see cref="Pulls"/> is the projected
/// graph; <see cref="SourceRowCount"/> + <see cref="SkippedRowCount"/> let
/// the job log a summary without re-walking the graph.
/// </summary>
public class ErpSyncDraft
{
    public List<PullDraft> Pulls { get; set; } = new();
    public int SourceRowCount { get; set; }
    public int SkippedRowCount { get; set; }

    /// <summary>Total number of distinct (PRS_ID, synthesized ItemCode) tuples projected.</summary>
    public int ItemCount => Pulls.Sum(p => p.Items.Count);

    /// <summary>Total expected qty across all windows of all items of all pulls.</summary>
    public int TotalExpected => Pulls.Sum(p => p.Items.Sum(i => i.Windows.Sum(w => w.ExpectedQty)));
}

/// <summary>
/// A single pull projected from BPI_PRS, grouped by PRS_ID. The
/// <see cref="WarehouseId"/> is provided at execute time (operator-picked
/// or config-defaulted) — BPI_PRS itself has no warehouse column.
/// </summary>
public class PullDraft
{
    public string PullNumber { get; set; } = "";   // BPI_PRS.PRS_ID
    public Guid WarehouseId { get; set; }
    public DateTime PullDate { get; set; }         // BPI_PRS.DeliveryDate (date only)
    public string Status { get; set; } = "pending";
    public bool LockPoByPull { get; set; } = true; // project default
    public bool LockHourCap { get; set; } = true;  // project default
    public List<PullItemDraft> Items { get; set; } = new();
}

/// <summary>
/// One item under a pull. ItemCode is the SYNTHESIZED key:
/// <c>SKU + "-" + TRIAL_ID</c> when TRIAL_ID is non-empty, else bare SKU.
/// This preserves the ERP's multi-row-per-(PRS_ID,SKU) shape (one BPI_PRS
/// row per trial) without breaking Receivx's UNIQUE(PullId, ItemCode).
/// </summary>
public class PullItemDraft
{
    public string ItemCode { get; set; } = "";
    public string Description { get; set; } = "";
    public string? VendorCode { get; set; }
    public string? Tag { get; set; }
    public string Status { get; set; } = "normal";
    public string? Remark { get; set; }

    // Phase 9.1 ERP fields — mapped 1:1 from BPI_PRS.
    public string? ProductFamily { get; set; }
    public string? FromSubInventory { get; set; }
    public string? ToSubInventory { get; set; }
    public string? SpecialControl { get; set; }
    public string? TrialId { get; set; }
    public string? Location { get; set; }
    public string? Phase { get; set; }

    public List<PullItemWindowDraft> Windows { get; set; } = new();
}

/// <summary>
/// One hour-window for a pull item. HourOfDay defaults to 7 when
/// BPI_PRS.WINDOWS_TIME is NULL (the user-confirmed defaulting rule —
/// 100% of current ERP rows have WINDOWS_TIME = NULL).
/// </summary>
public class PullItemWindowDraft
{
    public byte HourOfDay { get; set; }
    public int ExpectedQty { get; set; }
}
