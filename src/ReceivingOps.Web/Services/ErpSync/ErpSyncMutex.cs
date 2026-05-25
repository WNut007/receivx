namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 10.4 — app-level singleton mutex that excludes the recurring
/// sync path (<see cref="ErpSyncJob.RunAsync"/>) from the manual-trigger
/// path (<see cref="ErpSyncJob.RunForWarehouseAsync"/>).
///
/// <para>Why a separate primitive instead of just <c>[DisableConcurrentExecution]</c>:
/// Hangfire's attribute scopes its lock by method signature, so the two
/// job entry points have INDEPENDENT Hangfire locks. The two could
/// overlap without this. Both code paths call <see cref="TryAcquire"/>
/// before doing real work; the second caller sees <c>false</c> and
/// skips with a clear log line.</para>
///
/// <para>Implementation: a single int + Interlocked. No <see cref="System.Threading.SemaphoreSlim"/>
/// is needed because we only ever want a try-acquire-with-zero-timeout
/// (the spec contract is "skip if busy", never "wait for it to finish").</para>
///
/// <para>Scope: in-process. A multi-instance deployment would need a
/// distributed lock (Redis, SQL-row-level, etc.) — out of scope for v3.0
/// since the spec assumes single in-process Hangfire worker.</para>
/// </summary>
public class ErpSyncMutex
{
    private int _running;  // 0 = idle, 1 = running

    /// <summary>
    /// Atomically transitions idle → running. Returns true on success;
    /// false if a sync is already in progress (caller must skip).
    /// </summary>
    public bool TryAcquire()
        => Interlocked.CompareExchange(ref _running, 1, 0) == 0;

    /// <summary>Marks the mutex idle. Call from a finally block.</summary>
    public void Release()
        => Interlocked.Exchange(ref _running, 0);

    /// <summary>
    /// UX-only probe used by the manual-trigger endpoint to fail fast
    /// with 409 BEFORE enqueueing. The job body's <see cref="TryAcquire"/>
    /// is still the correctness gate — this is just to give the operator
    /// an instant "already running" response instead of enqueueing a
    /// job that will immediately no-op.
    /// </summary>
    public bool IsRunning => Volatile.Read(ref _running) == 1;
}
