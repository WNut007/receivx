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
    /// <summary>
    /// How many PRS_IDs of a mixed sheet are named in the run summary before
    /// the list is cut off. Mixed sheets are rare (2 upstream, all-time), so
    /// the cap is a runaway guard rather than an expected truncation.
    /// </summary>
    public const int MixedPullNumberSampleCap = 20;

    public List<PullDraft> Pulls { get; set; } = new();
    public int SourceRowCount { get; set; }

    /// <summary>
    /// Rows the transform dropped for ordinary reasons: blank PRS_ID, blank
    /// SKU, non-positive QTY.
    ///
    /// <para>Counted since Phase 10.2 and, until the WIP filter landed, read by
    /// absolutely nothing — not <c>ErpSyncLogTotals</c>, not
    /// <c>dbo.ErpSyncLog</c>, not the <c>etl-end</c> audit line. A counter
    /// nothing reads is worse than no counter, because a run that dropped 647
    /// rows looked exactly like a run that dropped none. It is now carried into
    /// the per-source totals JSON alongside the WIP figures.</para>
    /// </summary>
    public int SkippedRowCount { get; set; }

    /// <summary>
    /// Rows dropped because their pull sheet carries a WIP storer. Counts
    /// EVERY row of such a sheet, not only the WIP-vendor rows — the filter is
    /// sheet-grained, so the whole sheet leaves the draft together.
    /// </summary>
    public int WipSkippedRowCount { get; set; }

    /// <summary>Distinct pull sheets dropped by the WIP filter.</summary>
    public int WipSkippedPullCount { get; set; }

    /// <summary>
    /// Of <see cref="WipSkippedPullCount"/>, how many also carried non-WIP
    /// rows. These are the sheets where the sheet-grain rule costs something
    /// real, so they are counted separately rather than folded into the total.
    /// </summary>
    public int WipMixedPullCount { get; set; }

    /// <summary>Non-WIP rows dropped as collateral from mixed sheets.</summary>
    public int WipMixedNonWipRowCount { get; set; }

    /// <summary>Summed QTY of those non-WIP rows — the units that stop being fed.</summary>
    public int WipMixedNonWipQty { get; set; }

    /// <summary>PRS_IDs of the mixed sheets, capped at <see cref="MixedPullNumberSampleCap"/>.</summary>
    public List<string> WipMixedPullNumbers { get; } = new();

    /// <summary>
    /// Records one sheet dropped by the WIP filter. Lives here rather than in
    /// each source so the two readers cannot drift on what counts as mixed or
    /// on where the sample list is cut.
    /// </summary>
    public void NoteWipSkippedSheet(string pullNumber, int totalRows, int nonWipRows, int nonWipQty)
    {
        WipSkippedRowCount += totalRows;
        WipSkippedPullCount++;

        if (nonWipRows <= 0) return;

        WipMixedPullCount++;
        WipMixedNonWipRowCount += nonWipRows;
        WipMixedNonWipQty += nonWipQty;
        if (WipMixedPullNumbers.Count < MixedPullNumberSampleCap)
            WipMixedPullNumbers.Add(pullNumber);
    }

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

/// <summary>
/// Identity of a pull item: SKU **and storer**, never SKU alone.
///
/// <para>One pull sheet routinely carries the same SKU from two storers —
/// 107 such (pull, SKU) pairs in a single day's export, 298 rows,
/// 2,500,523 units, 196 of 504 pull sheets carrying more than one storer.
/// The two storers hold separate purchase orders, so merging them loses the
/// only fact that says whose goods arrived and whose PO should be
/// consumed.</para>
///
/// <para><b>This is not the TrialId case.</b> ItemCode was once synthesised
/// as <c>SKU-TRIAL_ID</c>, which broke the §7.15 FIFO match against
/// bare-SKU PO lines; that fix was correct and stands. Trial id is lot
/// metadata with no purchase order of its own. Vendor has a PO, a
/// liability, and its own line in the PO import — it is part of identity.
/// Hence the KEY widens while <c>PullItemDraft.ItemCode</c> stays the bare
/// SKU.</para>
///
/// <para>A record struct so equality is by value and null vendors group
/// together rather than each landing in their own bucket. Comparison is
/// Ordinal on both parts: these are machine codes, and a culture-aware
/// compare could merge two storers that differ only by case in a locale
/// nobody tested.</para>
/// </summary>
public readonly record struct ItemKey(string ItemCode, string? VendorCode)
{
    public bool Equals(ItemKey other) =>
        string.Equals(ItemCode, other.ItemCode, StringComparison.Ordinal) &&
        string.Equals(VendorCode, other.VendorCode, StringComparison.Ordinal);

    public override int GetHashCode() => HashCode.Combine(
        ItemCode is null ? 0 : StringComparer.Ordinal.GetHashCode(ItemCode),
        VendorCode is null ? 0 : StringComparer.Ordinal.GetHashCode(VendorCode));

    public override string ToString() =>
        VendorCode is null ? ItemCode : $"{ItemCode} @ {VendorCode}";
}
