namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 13.4 — runtime config for the dual-source ERP sync pipeline.
/// Bound from the <c>ErpSync</c> section.
///
/// <para>v3.2 → v3.3 reshape: <c>DefaultWarehouseId</c> and
/// <c>BackfillDays</c> moved from this top-level options class into
/// per-source sub-classes under <see cref="Sources"/> so BPI and PRB
/// can target different warehouses + windows.</para>
///
/// <para>Master kill-switch <see cref="Enabled"/> still gates the
/// recurring Hangfire registration as a whole. Per-source toggles
/// (<see cref="ErpSourceOptions.Enabled"/>) decide which readers
/// participate inside a given fire.</para>
///
/// <para><see cref="CronExpression"/> + <see cref="TimeoutSeconds"/>
/// stay shared — one job, one schedule, one mutex acquisition wraps
/// the serial source iteration.</para>
/// </summary>
public class ErpSyncOptions
{
    /// <summary>Master kill-switch. When false the recurring Hangfire job is NOT registered (and any existing schedule is removed on startup).</summary>
    public bool Enabled { get; set; } = false;

    /// <summary>Hangfire cron string for the recurring trigger. Default <c>0 * * * *</c> (top of every hour). Shared across sources.</summary>
    public string CronExpression { get; set; } = "0 * * * *";

    /// <summary><c>[DisableConcurrentExecution]</c> timeout (seconds). Default 600s. Shared across sources.</summary>
    public int TimeoutSeconds { get; set; } = 600;

    /// <summary>Per-source sub-configs (Enabled + BackfillDays + DefaultWarehouseId).</summary>
    public ErpSyncSources Sources { get; set; } = new();
}

/// <summary>
/// Phase 13.4 — per-source sub-configs. One property per known source.
/// Adding a third source would add another property here and another
/// <see cref="IErpSource"/> registration in Program.cs.
/// </summary>
public class ErpSyncSources
{
    /// <summary>BPI_PRS source. Enabled-by-default (legacy v3.2 behavior).</summary>
    public ErpSourceOptions Bpi { get; set; } = new() { Enabled = true };

    /// <summary>PRB_PRS source. Disabled-by-default — operators opt in via /Config.</summary>
    public ErpSourceOptions Prb { get; set; } = new() { Enabled = false };
}

/// <summary>
/// Phase 13.4 — per-source config triplet. Symmetric across BPI + PRB so
/// the fan-out loop in <see cref="ErpSyncJob"/> reads them uniformly.
/// </summary>
public class ErpSourceOptions
{
    /// <summary>Per-source toggle. False sources are silently skipped by the fan-out loop.</summary>
    public bool Enabled { get; set; }

    /// <summary>Days back from today to include in the source read (filtered by DeliveryDate).</summary>
    public int BackfillDays { get; set; } = 30;

    /// <summary>Target warehouse for the recurring sync. The source table has no WH column, so the caller picks.</summary>
    public Guid DefaultWarehouseId { get; set; } = Guid.Empty;
}
