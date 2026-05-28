namespace ReceivingOps.Web.Models;

/// <summary>
/// Phase 13.8.2 — model for the shared <c>_ErpSyncTriggerModal.cshtml</c>
/// partial. The trigger modal renders on both <c>/Admin/ErpSync</c> and the
/// Dashboard with parallel-but-disjoint DOM ids — this model parameterizes
/// those ids so the partial body is identical in both contexts.
///
/// <para>Convention in this codebase: each consumer chooses a short
/// <see cref="FieldPrefix"/> (e.g. <c>"sync"</c>, <c>"erp"</c>) and the
/// partial builds field ids as <c>{FieldPrefix}-source</c>,
/// <c>{FieldPrefix}-warehouse</c>, <c>{FieldPrefix}-backfill-days</c>, etc.
/// The per-page JS knows its own prefix and queries by that.</para>
/// </summary>
public class ErpSyncTriggerModalModel
{
    /// <summary>DOM id for the outer modal — e.g. <c>"syncModal"</c>, <c>"erpSyncModal"</c>.</summary>
    public string ModalId { get; set; } = "syncModal";

    /// <summary>Short prefix prepended to every interior field id. Lowercase, no trailing dash.</summary>
    public string FieldPrefix { get; set; } = "sync";
}
