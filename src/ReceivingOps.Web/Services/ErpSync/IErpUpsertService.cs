namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 10.3 — apply an <see cref="ErpSyncDraft"/> to Receivx's
/// Pulls / PullItems / PullItemWindows tables. Per-pull transactions
/// so one bad row doesn't abort the run (spec §2.6).
///
/// <para>Semantics enforced here (spec §2.5):</para>
/// <list type="bullet">
///   <item>Match on <c>Pulls.PullNumber = draft.PullNumber</c>.</item>
///   <item>Missing pull → INSERT with project-default lock flags + Status=pending.</item>
///   <item>Existing pull in <c>closed</c> state → SKIP (ERP cannot revise a signed pull).</item>
///   <item>Existing pull in any open state → UPDATE planning fields only
///         (never <c>ReceivedQty</c>, <c>LockPoByPull</c>, <c>LockHourCap</c>,
///         <c>SignatureSvg</c>, <c>ClosedAt</c>, <c>ClosedBy</c>).</item>
///   <item>Items no longer in the draft → flip their <c>Status</c> to
///         <c>canceled</c> (never DELETE — receipts may FK them).</item>
/// </list>
///
/// <para>Audit rows are 10.5; this service only RETURNS the outcome.</para>
/// </summary>
public interface IErpUpsertService
{
    /// <param name="runId">Correlation id stamped into every per-pull audit
    /// row's message so the 10.6 status page can join start/end/per-pull
    /// rows for one run.</param>
    /// <param name="actorName"><c>"[system]"</c> for the recurring path or
    /// the operator's display name for the manual path. Recorded as the
    /// AuditLog actor on every row written by this service.</param>
    Task<ErpUpsertResult> UpsertAsync(
        ErpSyncDraft draft, Guid runId, string actorName, CancellationToken ct = default);
}
