namespace ReceivingOps.Web.Services.ErpSync;

/// <summary>
/// Phase 10.3 — outcome of applying an <see cref="ErpSyncDraft"/> to the
/// Receivx DB. Per-pull counts let the job log a single-line summary
/// and 10.5 will turn <see cref="PullOutcomes"/> into per-pull audit rows.
/// </summary>
public class ErpUpsertResult
{
    /// <summary>New Pulls inserted (with items + windows).</summary>
    public int Created { get; set; }

    /// <summary>Existing pulls updated in place (planning fields only).</summary>
    public int Updated { get; set; }

    /// <summary>Pulls skipped because they are already <c>closed</c>.</summary>
    public int SkippedClosed { get; set; }

    /// <summary>
    /// Pulls skipped because <c>Pulls.Origin = 'po-import'</c> — the PO import
    /// synthesised them and the ERP feed does not own them. Counted separately
    /// from <see cref="SkippedClosed"/> because the reasons are unrelated: a
    /// closed pull is finished, a synthesised pull is somebody else's.
    /// </summary>
    public int SkippedSynthesised { get; set; }

    /// <summary>
    /// Pulls skipped because of an unrecoverable error (PullNumber too long,
    /// FK lookup failed, constraint violation, etc.). One entry per pull.
    /// </summary>
    public int Errors { get; set; }

    /// <summary>Items that ETL marked <c>canceled</c> because the ERP no longer references them.</summary>
    public int ItemsCanceled { get; set; }

    /// <summary>Items inserted on update-path pulls (newly-added by ERP since last run).</summary>
    public int ItemsAdded { get; set; }

    // ----------------------------------------------------------------------
    // db/052 — field-protection reporting.
    //
    // Nothing recorded what ETL overwrote, which is why remarks reverting went
    // unnoticed for weeks. Aggregated per RUN, not per field: 469 pulls x ~10
    // fields an hour would be thousands of rows saying almost nothing.
    // ----------------------------------------------------------------------

    /// <summary>Field writes suppressed because an operator owns the field.</summary>
    public int FieldsSkipped { get; set; }

    /// <summary>Field writes ETL actually performed.</summary>
    public int FieldsWritten { get; set; }

    /// <summary>Rows on which at least one field write was suppressed.</summary>
    public int RowsWithAnySkip { get; set; }

    /// <summary>Items left alone by the cancel path because Origin='operator'.</summary>
    public int ItemsExemptCreated { get; set; }

    /// <summary>
    /// Items skipped WHOLE because an operator cancelled them — the row was
    /// present in the ERP draft and ETL wrote nothing to it at all.
    ///
    /// <para>Counted separately from <see cref="FieldsSkipped"/> because the
    /// grain differs: that counts suppressed field assignments on rows ETL still
    /// updated, this counts rows ETL did not touch. Rolling them together would
    /// make "how much did protection suppress" unanswerable in one query, which
    /// is the mistake db/052 called out about JSON-only figures.</para>
    /// </summary>
    public int ItemsSkippedOperatorCanceled { get; set; }

    /// <summary>Per-field suppressed counts, e.g. <c>{"Remark": 12}</c>.</summary>
    public Dictionary<string, int> SkippedByField { get; } = new(StringComparer.Ordinal);

    /// <summary>Per-field written counts.</summary>
    public Dictionary<string, int> WrittenByField { get; } = new(StringComparer.Ordinal);

    /// <summary>Records one field's outcome and keeps the totals in step.</summary>
    public void NoteField(string fieldName, bool skipped)
    {
        var bucket = skipped ? SkippedByField : WrittenByField;
        bucket[fieldName] = bucket.TryGetValue(fieldName, out var n) ? n + 1 : 1;
        if (skipped) FieldsSkipped++; else FieldsWritten++;
    }

    /// <summary>
    /// Per-pull detail. Kept small (PullNumber + outcome + optional error)
    /// so it's safe to log + later audit. Populated for every pull in the draft.
    /// </summary>
    public List<PullOutcome> PullOutcomes { get; set; } = new();

    public int TotalProcessed => Created + Updated + SkippedClosed + SkippedSynthesised + Errors;
}

/// <summary>One row in <see cref="ErpUpsertResult.PullOutcomes"/>.</summary>
public class PullOutcome
{
    public string PullNumber { get; set; } = "";
    public string Outcome { get; set; } = "";   // created|updated|skipped-closed|skipped-synthesised|error
    public string? Detail { get; set; }         // error message, or short summary
}
