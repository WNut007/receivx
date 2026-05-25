namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 10.1 — runtime config for the ERP sync pipeline. Bound from the
/// <c>ErpSync</c> section.
///
/// <para>Enabled:</para> master kill-switch. When false, the recurring
/// Hangfire job is NOT registered (and any existing schedule is removed
/// on startup so a runtime config flip actually disables the schedule).
/// Default false — dev environments without ERP credentials don't start
/// trying to connect to a host that may not be reachable.
///
/// <para>CronExpression:</para> Hangfire cron string for the recurring
/// trigger. Default <c>0 * * * *</c> (top of every hour). Format is the
/// standard 5-field crontab (minute hour day month dow).
///
/// <para>TimeoutSeconds:</para> <c>[DisableConcurrentExecution]</c>
/// timeout — how long Hangfire waits to acquire the in-job mutex before
/// declaring the previous run hung. Default 600s (10 min) — generous
/// since the ETL is read-mostly and shouldn't run that long even on a
/// full backfill.
/// </summary>
public class ErpSyncOptions
{
    public bool Enabled { get; set; } = false;
    public string CronExpression { get; set; } = "0 * * * *";
    public int TimeoutSeconds { get; set; } = 600;
}
